// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.IO;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Principal;
using System.Text;
using System.Threading;

namespace Knot.NativePreview
{
    internal sealed class CertificateCompatibilityException : CryptographicException
    {
        internal CertificateCompatibilityException() : base("The registered host certificate requires explicit compatibility conversion. Previously registered Macs must remove this host and pair again.") { }
    }

    internal static class PersistentCertificateFactory
    {
        internal const int MaximumValidityDays = 397;
        internal static byte[] CreatePfx(DateTimeOffset now) { return CreatePfx(now.AddDays(-1), now.AddDays(364)); }
        // Both the production identity and fresh test identities take this exact
        // request -> PFX export -> UserKeySet import path. The date overload lets
        // synthetic checks exercise old/expired identities without reading stores.
        internal static byte[] CreatePfx(DateTimeOffset notBefore, DateTimeOffset notAfter)
        {
            using (RSA rsa = RSA.Create())
            {
                rsa.KeySize = 2048;
                CertificateRequest request = new CertificateRequest("CN=knot-native", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
                request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, true));
                OidCollection purposes = new OidCollection(); purposes.Add(new Oid("1.3.6.1.5.5.7.3.1"));
                request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(purposes, false));
                request.CertificateExtensions.Add(new X509Extension("2.5.29.17", new byte[] { 0x30,13,0x82,11,107,110,111,116,45,110,97,116,105,118,101 }, false));
                using (X509Certificate2 fresh = request.CreateSelfSigned(notBefore, notAfter)) return fresh.Export(X509ContentType.Pfx);
            }
        }
        internal static X509Certificate2 Import(byte[] pfx) { return new X509Certificate2(pfx, (string)null, X509KeyStorageFlags.UserKeySet); }
        // Inspection must not persist or attach an imported key container. This
        // certificate is never passed to Schannel; production TLS uses Import.
        internal static X509Certificate2 Inspect(byte[] pfx) { return new X509Certificate2(pfx, (string)null, X509KeyStorageFlags.EphemeralKeySet); }
        internal static bool RequiresMigration(X509Certificate2 certificate)
        { return certificate.NotAfter.ToUniversalTime() - certificate.NotBefore.ToUniversalTime() > TimeSpan.FromDays(MaximumValidityDays); }
        internal static void Validate(X509Certificate2 certificate)
        {
            DateTime now = DateTime.UtcNow;
            if (!certificate.HasPrivateKey || now < certificate.NotBefore.ToUniversalTime() || now >= certificate.NotAfter.ToUniversalTime())
                throw new CryptographicException("Registered host identity must be explicitly renewed.");
            string pin;
            using (SHA256 sha = SHA256.Create()) pin = BitConverter.ToString(sha.ComputeHash(certificate.RawData)).Replace("-", "").ToLowerInvariant();
            if (!RunCertificate.VerifyPinned(certificate, System.Net.Security.SslPolicyErrors.RemoteCertificateChainErrors, pin, now))
                throw new CryptographicException("Invalid registered host identity.");
        }
    }

    internal interface IPersistentCertificateStorage
    {
        IDisposable AcquireLease();
        bool Exists { get; }
        byte[] Read();
        void Write(byte[] pfx);
        void RevokeCredentials();
    }

    // A per-user, per-store kernel lease covers the whole read/generate/revoke/
    // publish operation across app processes. A second conversion must reread
    // the first process's result before it can revoke or replace anything.
    internal sealed class PersistentCertificateLease : IDisposable
    {
        private Mutex mutex;
        private PersistentCertificateLease(Mutex mutex) { this.mutex = mutex; }
        internal static IDisposable Acquire(string directory)
        {
            SecurityIdentifier user = WindowsIdentity.GetCurrent().User;
            string suffix;
            using (SHA256 sha = SHA256.Create())
                suffix = BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar).ToUpperInvariant()))).Replace("-", "");
            string name = "Global\\KnotNativeCertificate_" + user.Value + "_" + suffix;
            MutexSecurity security = new MutexSecurity(); security.SetAccessRuleProtection(true, false); security.SetOwner(user);
            security.AddAccessRule(new MutexAccessRule(user, MutexRights.FullControl, AccessControlType.Allow));
            bool created;
            Mutex candidate = new Mutex(false, name, out created, security);
            bool acquired = false;
            try
            {
                MutexSecurity actual = candidate.GetAccessControl();
                if (!actual.AreAccessRulesProtected || !user.Equals(actual.GetOwner(typeof(SecurityIdentifier))))
                    throw new CryptographicException("Invalid certificate operation lease owner.");
                foreach (MutexAccessRule rule in actual.GetAccessRules(true, true, typeof(SecurityIdentifier)))
                    if (!user.Equals(rule.IdentityReference) || rule.AccessControlType != AccessControlType.Allow)
                        throw new CryptographicException("Invalid certificate operation lease access.");
                try { acquired = candidate.WaitOne(10000); }
                catch (AbandonedMutexException)
                {
                    // WaitOne acquired the abandoned mutex. Release it while
                    // failing this operation closed; a later explicit retry can
                    // validate the atomically stored state from the beginning.
                    candidate.ReleaseMutex();
                    throw new CryptographicException("A previous certificate operation did not finish. Retry explicitly.");
                }
                if (!acquired) throw new CryptographicException("Another certificate operation is still running. Retry explicitly.");
                PersistentCertificateLease lease = new PersistentCertificateLease(candidate); candidate = null; return lease;
            }
            finally { if (candidate != null) { if (acquired) candidate.ReleaseMutex(); candidate.Dispose(); } }
        }
        public void Dispose()
        {
            Mutex held = mutex; mutex = null;
            if (held != null) { try { held.ReleaseMutex(); } finally { held.Dispose(); } }
        }
    }

    // The directory is injected only by fresh fixtures; production resolves the
    // existing DPAPI identity location without opening it in the constructor.
    internal sealed class ProtectedCertificateStorage : IPersistentCertificateStorage
    {
        private readonly string directory, path;
        private readonly Action revokeCredentials;
        internal ProtectedCertificateStorage(string directory, Action revokeCredentials)
        {
            if (String.IsNullOrEmpty(directory) || revokeCredentials == null) throw new ArgumentException("Invalid certificate storage.");
            this.directory = directory; path = Path.Combine(directory, "identity.dpapi"); this.revokeCredentials = revokeCredentials;
        }
        internal static ProtectedCertificateStorage Production() { return new ProtectedCertificateStorage(NativeTrustedDevices.DirectoryPath, NativeTrustedDevices.RevokeAll); }
        public IDisposable AcquireLease() { return PersistentCertificateLease.Acquire(directory); }
        public bool Exists { get { return File.Exists(path); } }
        public byte[] Read() { return NativeTrustedDevices.ReadProtected(path); }
        public void RevokeCredentials() { revokeCredentials(); }
        public void Write(byte[] pfx)
        {
            Directory.CreateDirectory(directory);
            if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) throw new IOException("Trust storage cannot be linked.");
            DirectorySecurity security = new DirectorySecurity(); security.SetAccessRuleProtection(true, false);
            security.AddAccessRule(new FileSystemAccessRule(WindowsIdentity.GetCurrent().User, FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            new DirectoryInfo(directory).SetAccessControl(security);
            byte[] encrypted = ProtectedData.Protect(pfx, null, DataProtectionScope.CurrentUser);
            string temporary = Path.Combine(directory, Guid.NewGuid().ToString("N") + ".tmp");
            try
            {
                using (FileStream file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                { file.Write(encrypted, 0, encrypted.Length); file.Flush(true); }
                if (File.Exists(path))
                { if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new IOException("Invalid trust storage."); File.Replace(temporary, path, null); }
                else File.Move(temporary, path);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); Array.Clear(encrypted, 0, encrypted.Length); }
        }
    }
}
