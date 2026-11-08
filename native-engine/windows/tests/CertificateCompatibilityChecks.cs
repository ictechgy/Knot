// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Threading;

namespace Knot.NativePreview
{
    internal static partial class NativeChecks
    {
        private static int actualPersistentCertificateFixtures;
        private static int actualCrossProcessCertificateLeaseFixtures;
        private sealed class ObservedCertificateStorage : IPersistentCertificateStorage
        {
            internal readonly ProtectedCertificateStorage Inner;
            internal int Writes, Revocations;
            internal bool FailRevocation, FailPublication, RequireRevocation;
            internal Action BeforeRevocation;
            internal ObservedCertificateStorage(string directory)
            { Inner = new ProtectedCertificateStorage(directory, delegate { }); }
            public IDisposable AcquireLease() { return Inner.AcquireLease(); }
            public bool Exists { get { return Inner.Exists; } }
            public byte[] Read() { return Inner.Read(); }
            public void RevokeCredentials()
            {
                ++Revocations;
                if (BeforeRevocation != null) BeforeRevocation();
                if (FailRevocation) throw new IOException("Synthetic revocation failure.");
            }
            public void Write(byte[] pfx)
            {
                ++Writes;
                if (RequireRevocation) Check(Revocations == 1);
                if (FailPublication) throw new IOException("Synthetic publication failure.");
                Inner.Write(pfx);
            }
        }
        private static void RejectCertificate(Action action, bool compatibility)
        {
            bool rejected = false;
            try { action(); }
            catch (CryptographicException error) { rejected = true; Check((error is CertificateCompatibilityException) == compatibility); }
            Check(rejected);
        }
        private static void RejectCertificateIo(Action action)
        {
            bool rejected = false;
            try { action(); } catch (IOException) { rejected = true; }
            Check(rejected);
        }
        private static bool SameCertificateStore(IPersistentCertificateStorage storage, byte[] expected)
        {
            byte[] actual = storage.Read();
            try { return NativeProtocol.Equal(expected, actual); }
            finally { Array.Clear(actual, 0, actual.Length); }
        }
        private static void CertificateCompatibilityChecks()
        {
            // The only files touched by this stage live below this new random
            // temporary directory. No Production() store is constructed here.
            string root = Path.Combine(Path.GetTempPath(), "KnotCertificateCheck_" + Guid.NewGuid().ToString("N"));
            byte[] legacy = null;
            try
            {
                stage = "persistent-certificate-missing-readonly";
                string missing = Path.Combine(root, "fresh");
                ObservedCertificateStorage fresh = new ObservedCertificateStorage(missing);
                Check(!RunCertificate.RequiresCompatibilityMigration(fresh));
                Check(!Directory.Exists(root) && fresh.Writes == 0 && fresh.Revocations == 0);
                RejectCertificate(delegate { RunCertificate.ConvertPersistentForCompatibility(fresh); }, false);
                Check(!Directory.Exists(root) && fresh.Writes == 0 && fresh.Revocations == 0);
                string originalPin;
                using (RunCertificate certificate = RunCertificate.Persistent(fresh))
                {
                    stage = "persistent-certificate-production-pfx-import";
                    Check(certificate.Certificate.HasPrivateKey && certificate.OwnedKeyContainerName == "");
                    using (RSA publicKey = certificate.Certificate.GetRSAPublicKey()) Check(publicKey != null && publicKey.KeySize == 2048);
                    Check(certificate.Certificate.NotAfter.ToUniversalTime() - certificate.Certificate.NotBefore.ToUniversalTime() == TimeSpan.FromDays(365));
                    Check(!PersistentCertificateFactory.RequiresMigration(certificate.Certificate));
                    Check(RunCertificate.VerifyPinned(certificate.Certificate, SslPolicyErrors.RemoteCertificateChainErrors, certificate.Pin));
                    originalPin = certificate.Pin;
                    stage = "persistent-certificate-userkeyset-tls";
                    PersistentCertificateTls(certificate);
                    ++actualPersistentCertificateFixtures;
                    if (persistentCertificateExportPath != null)
                    {
                        stage = "persistent-certificate-public-der-export";
                        byte[] der = certificate.Certificate.Export(X509ContentType.Cert);
                        Check(der.Length > 0 && der.Length <= 16384);
                        using (FileStream output = new FileStream(persistentCertificateExportPath, FileMode.CreateNew, FileAccess.Write, FileShare.None)) output.Write(der, 0, der.Length);
                        byte[] pin = System.Text.Encoding.ASCII.GetBytes(certificate.Pin + "\n");
                        using (FileStream output = new FileStream(Path.ChangeExtension(persistentCertificateExportPath, ".sha256"), FileMode.CreateNew, FileAccess.Write, FileShare.None)) output.Write(pin, 0, pin.Length);
                        using (X509Certificate2 exported = new X509Certificate2(File.ReadAllBytes(persistentCertificateExportPath)))
                        { Check(!exported.HasPrivateKey && NativeProtocol.Equal(exported.RawData, certificate.Certificate.RawData)); }
                    }
                }
                Check(fresh.Writes == 1 && fresh.Revocations == 0);
                byte[] unchanged = File.ReadAllBytes(Path.Combine(missing, "identity.dpapi"));
                stage = "persistent-certificate-compatible-reuse";
                Check(!RunCertificate.RequiresCompatibilityMigration(fresh));
                using (RunCertificate reopened = RunCertificate.Persistent(fresh)) Check(reopened.Pin == originalPin);
                RunCertificate.ConvertPersistentForCompatibility(fresh);
                Check(fresh.Writes == 1 && fresh.Revocations == 0);
                Check(NativeProtocol.Equal(unchanged, File.ReadAllBytes(Path.Combine(missing, "identity.dpapi"))));
                using (RunCertificate reopened = RunCertificate.Persistent(fresh)) Check(reopened.Pin == originalPin);

                DateTimeOffset now = DateTimeOffset.UtcNow;
                legacy = PersistentCertificateFactory.CreatePfx(now.AddDays(-1), now.AddYears(5));
                stage = "persistent-certificate-cross-process-lease";
                CertificateLeaseChecks(root, legacy);
                stage = "host-owner-abandoned-recovery";
                HostOwnerAbandonmentChecks(Path.Combine(root, "abandoned-owner"));
                stage = "persistent-certificate-legacy-explicit-conversion";
                ObservedCertificateStorage old = new ObservedCertificateStorage(Path.Combine(root, "legacy")); old.Inner.Write(legacy);
                Check(RunCertificate.RequiresCompatibilityMigration(old));
                RejectCertificate(delegate { using (RunCertificate blocked = RunCertificate.Persistent(old)) { } }, true);
                Check(old.Writes == 0 && old.Revocations == 0 && SameCertificateStore(old, legacy));
                old.RequireRevocation = true;
                old.BeforeRevocation = delegate { Check(SameCertificateStore(old, legacy)); };
                RunCertificate.ConvertPersistentForCompatibility(old);
                Check(old.Revocations == 1 && old.Writes == 1 && !RunCertificate.RequiresCompatibilityMigration(old));
                string oldPin;
                using (X509Certificate2 prior = PersistentCertificateFactory.Inspect(legacy))
                using (SHA256 sha = SHA256.Create()) oldPin = BitConverter.ToString(sha.ComputeHash(prior.RawData)).Replace("-", "").ToLowerInvariant();
                using (RunCertificate converted = RunCertificate.Persistent(old))
                {
                    using (RSA publicKey = converted.Certificate.GetRSAPublicKey()) Check(publicKey != null && publicKey.KeySize == 2048);
                    Check(converted.Pin != oldPin && !PersistentCertificateFactory.RequiresMigration(converted.Certificate));
                    Check(!RunCertificate.VerifyPinned(converted.Certificate, SslPolicyErrors.RemoteCertificateChainErrors, oldPin));
                    stage = "persistent-certificate-converted-userkeyset-tls";
                    PersistentCertificateTls(converted); ++actualPersistentCertificateFixtures;
                }
                stage = "persistent-certificate-weak-key-explicit-conversion";
                byte[] weakPfx = SyntheticPersistentPfx(now, 1024, "1.3.6.1.5.5.7.3.1");
                try
                {
                    ObservedCertificateStorage weak = new ObservedCertificateStorage(Path.Combine(root, "weak")); weak.Inner.Write(weakPfx);
                    Check(RunCertificate.RequiresCompatibilityMigration(weak));
                    RejectCertificate(delegate { using (RunCertificate blocked = RunCertificate.Persistent(weak)) { } }, true);
                    Check(weak.Writes == 0 && weak.Revocations == 0 && SameCertificateStore(weak, weakPfx));
                    weak.RequireRevocation = true;
                    weak.BeforeRevocation = delegate { Check(SameCertificateStore(weak, weakPfx)); };
                    RunCertificate.ConvertPersistentForCompatibility(weak);
                    Check(weak.Revocations == 1 && weak.Writes == 1 && !RunCertificate.RequiresCompatibilityMigration(weak));
                    using (RunCertificate converted = RunCertificate.Persistent(weak))
                    {
                        using (RSA publicKey = converted.Certificate.GetRSAPublicKey()) Check(publicKey != null && publicKey.KeySize == 2048);
                        PersistentCertificateTls(converted); ++actualPersistentCertificateFixtures;
                    }
                }
                finally { Array.Clear(weakPfx, 0, weakPfx.Length); }
                stage = "persistent-certificate-revoke-failure-no-publication";
                ObservedCertificateStorage revokeFailure = new ObservedCertificateStorage(Path.Combine(root, "revoke-failure")); revokeFailure.Inner.Write(legacy); revokeFailure.FailRevocation = true;
                RejectCertificateIo(delegate { RunCertificate.ConvertPersistentForCompatibility(revokeFailure); });
                Check(revokeFailure.Revocations == 1 && revokeFailure.Writes == 0 && SameCertificateStore(revokeFailure, legacy));
                RejectCertificate(delegate { using (RunCertificate blocked = RunCertificate.Persistent(revokeFailure)) { } }, true);
                stage = "persistent-certificate-publication-failure-stays-blocked";
                ObservedCertificateStorage writeFailure = new ObservedCertificateStorage(Path.Combine(root, "write-failure")); writeFailure.Inner.Write(legacy); writeFailure.RequireRevocation = true; writeFailure.FailPublication = true;
                RejectCertificateIo(delegate { RunCertificate.ConvertPersistentForCompatibility(writeFailure); });
                Check(writeFailure.Revocations == 1 && writeFailure.Writes == 1 && SameCertificateStore(writeFailure, legacy));
                RejectCertificate(delegate { using (RunCertificate blocked = RunCertificate.Persistent(writeFailure)) { } }, true);

                stage = "persistent-certificate-corrupt-fails-closed";
                InvalidPersistentCertificate(root, "corrupt", new byte[] { 1, 2, 3, 4 });
                stage = "persistent-certificate-corrupt-dpapi-fails-closed";
                string corruptDirectory = Path.Combine(root, "corrupt-dpapi"); Directory.CreateDirectory(corruptDirectory);
                string corruptPath = Path.Combine(corruptDirectory, "identity.dpapi");
                byte[] corrupt = new byte[] { 5, 6, 7, 8 }; File.WriteAllBytes(corruptPath, corrupt);
                ObservedCertificateStorage corruptStorage = new ObservedCertificateStorage(corruptDirectory);
                RejectCertificate(delegate { RunCertificate.RequiresCompatibilityMigration(corruptStorage); }, false);
                RejectCertificate(delegate { using (RunCertificate blocked = RunCertificate.Persistent(corruptStorage)) { } }, false);
                RejectCertificate(delegate { RunCertificate.ConvertPersistentForCompatibility(corruptStorage); }, false);
                Check(corruptStorage.Writes == 0 && corruptStorage.Revocations == 0 && NativeProtocol.Equal(corrupt, File.ReadAllBytes(corruptPath)));
                stage = "persistent-certificate-expired-fails-closed";
                byte[] expired = PersistentCertificateFactory.CreatePfx(now.AddYears(-6), now.AddDays(-1));
                try { InvalidPersistentCertificate(root, "expired", expired); } finally { Array.Clear(expired, 0, expired.Length); }
                stage = "persistent-certificate-explicit-expired-renewal";
                byte[] renewable = PersistentCertificateFactory.CreatePfx(now.AddDays(-2), now.AddDays(-1));
                try
                {
                    ObservedCertificateStorage renewal = new ObservedCertificateStorage(Path.Combine(root, "renewal")); renewal.Inner.Write(renewable);
                    Check(RunCertificate.RequiresRenewal(renewal));
                    bool renewalClassified = false;
                    try { RunCertificate.ConvertPersistentForCompatibility(renewal); }
                    catch (CertificateRenewalRequiredException) { renewalClassified = true; }
                    Check(renewalClassified && renewal.Writes == 0 && renewal.Revocations == 0);
                    Check(renewal.Writes == 0 && renewal.Revocations == 0 && SameCertificateStore(renewal, renewable));
                    string expiredPin;
                    using (X509Certificate2 oldIdentity = PersistentCertificateFactory.Inspect(renewable))
                    using (SHA256 sha = SHA256.Create()) expiredPin = BitConverter.ToString(sha.ComputeHash(oldIdentity.RawData)).Replace("-", "").ToLowerInvariant();
                    renewal.RequireRevocation = true;
                    RunCertificate.RenewExpiredPersistent(renewal);
                    Check(renewal.Writes == 1 && renewal.Revocations == 1 && !RunCertificate.RequiresRenewal(renewal));
                    using (RunCertificate current = RunCertificate.Persistent(renewal)) Check(current.Pin != expiredPin);
                    RunCertificate.RenewExpiredPersistent(renewal); // Stale owner action must not rotate twice.
                    Check(renewal.Writes == 1 && renewal.Revocations == 1);
                    ObservedCertificateStorage failedRenewal = new ObservedCertificateStorage(Path.Combine(root, "renewal-failure")); failedRenewal.Inner.Write(renewable); failedRenewal.FailRevocation = true;
                    RejectCertificateIo(delegate { RunCertificate.RenewExpiredPersistent(failedRenewal); });
                    Check(failedRenewal.Revocations == 1 && failedRenewal.Writes == 0 && SameCertificateStore(failedRenewal, renewable));
                    Check(RunCertificate.RequiresRenewal(failedRenewal));
                    ObservedCertificateStorage failedWrite = new ObservedCertificateStorage(Path.Combine(root, "renewal-write-failure")); failedWrite.Inner.Write(renewable); failedWrite.FailPublication = true;
                    RejectCertificateIo(delegate { RunCertificate.RenewExpiredPersistent(failedWrite); });
                    Check(failedWrite.Revocations == 1 && failedWrite.Writes == 1 && SameCertificateStore(failedWrite, renewable));
                }
                finally { Array.Clear(renewable, 0, renewable.Length); }
                stage = "persistent-certificate-future-fails-closed";
                byte[] future = PersistentCertificateFactory.CreatePfx(now.AddDays(1), now.AddDays(366));
                try { InvalidPersistentCertificate(root, "future", future); } finally { Array.Clear(future, 0, future.Length); }
                stage = "persistent-certificate-keyless-fails-closed";
                using (X509Certificate2 cert = PersistentCertificateFactory.Inspect(legacy)) InvalidPersistentCertificate(root, "keyless", cert.Export(X509ContentType.Cert));
                stage = "persistent-certificate-wrong-purpose-fails-closed";
                byte[] wrong = SyntheticPersistentPfx(now, 2048, "1.3.6.1.5.5.7.3.2");
                try { InvalidPersistentCertificate(root, "wrong-purpose", wrong); } finally { Array.Clear(wrong, 0, wrong.Length); }
            }
            finally
            {
                if (legacy != null) Array.Clear(legacy, 0, legacy.Length);
                if (Directory.Exists(root)) Directory.Delete(root, true);
            }
        }
        private static void InvalidPersistentCertificate(string root, string name, byte[] pfx)
        {
            ObservedCertificateStorage storage = new ObservedCertificateStorage(Path.Combine(root, name)); storage.Inner.Write(pfx);
            RejectCertificate(delegate { RunCertificate.RequiresCompatibilityMigration(storage); }, false);
            RejectCertificate(delegate { using (RunCertificate blocked = RunCertificate.Persistent(storage)) { } }, false);
            RejectCertificate(delegate { RunCertificate.ConvertPersistentForCompatibility(storage); }, false);
            Check(storage.Writes == 0 && storage.Revocations == 0 && SameCertificateStore(storage, pfx));
        }
        private static byte[] SyntheticPersistentPfx(DateTimeOffset now, int keySize, string purpose)
        {
            using (RSACryptoServiceProvider rsa = new RSACryptoServiceProvider(keySize))
            {
                rsa.PersistKeyInCsp = false;
                Check(rsa.KeySize == keySize);
                CertificateRequest request = new CertificateRequest("CN=knot-native", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
                request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, true));
                request.CertificateExtensions.Add(new X509Extension("2.5.29.17", new byte[] { 0x30,13,0x82,11,107,110,111,116,45,110,97,116,105,118,101 }, false));
                OidCollection purposes = new OidCollection(); purposes.Add(new Oid(purpose));
                request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(purposes, false));
                using (X509Certificate2 certificate = request.CreateSelfSigned(now.AddDays(-1), now.AddDays(364))) return certificate.Export(X509ContentType.Pfx);
            }
        }
        private static void HostOwnerAbandonmentChecks(string directory)
        {
            // Keep a passive handle alive after the owner thread exits; a sole
            // crashed process normally closes its last handle and destroys the
            // mutex instead. This exercises the actual abandonment condition.
            Mutex retained = null; Exception threadFailure = null;
            Thread owner = new Thread(delegate()
            {
                try
                {
                    var user = System.Security.Principal.WindowsIdentity.GetCurrent().User;
                    var security = new System.Security.AccessControl.MutexSecurity();
                    security.SetAccessRuleProtection(true, false); security.SetOwner(user);
                    security.AddAccessRule(new System.Security.AccessControl.MutexAccessRule(user,
                        System.Security.AccessControl.MutexRights.FullControl, System.Security.AccessControl.AccessControlType.Allow));
                    bool created;
                    retained = new Mutex(false, PersistentCertificateLease.HostOwnerName(directory), out created, security);
                    Check(created && retained.WaitOne(0));
                    // Deliberately leave ownership held when this fresh thread exits.
                }
                catch (Exception failure) { threadFailure = failure; }
            });
            owner.IsBackground = true; owner.Start(); Check(owner.Join(5000));
            try
            {
                if (threadFailure != null) throw threadFailure;
                using (IDisposable recovered = PersistentCertificateLease.TryAcquireHostOwner(directory)) Check(recovered != null);
            }
            finally { if (retained != null) retained.Dispose(); }
        }
        private static int CertificateLeaseProbe(string root, string nonce)
        {
            Guid parsed;
            if (nonce.Length != 32 || !Guid.TryParseExact(nonce, "N", out parsed) ||
                !String.Equals(Path.GetFullPath(root), Path.Combine(Path.GetTempPath(), "KnotCertificateCheck_" + nonce), StringComparison.OrdinalIgnoreCase) ||
                !Directory.Exists(root)) throw new ArgumentException("Invalid fresh certificate lease fixture.");
            ObservedCertificateStorage storage = new ObservedCertificateStorage(Path.Combine(root, "lease"));
            using (FileStream ready = new FileStream(Path.Combine(root, "lease-ready"), FileMode.CreateNew, FileAccess.Write, FileShare.Read)) ready.WriteByte(1);
            // The parent still owns the lease when this starts. All certificate
            // reads happen after it publishes and releases the replacement.
            Check(!RunCertificate.RequiresCompatibilityMigration(storage));
            byte[] unchanged = File.ReadAllBytes(Path.Combine(root, "lease", "identity.dpapi"));
            string pin;
            using (RunCertificate current = RunCertificate.Persistent(storage)) { Check(current.Certificate.HasPrivateKey); pin = current.Pin; }
            // This is the stale second form's same direct button call. It must
            // return successfully so that form can proceed to StartShare.
            RunCertificate.ConvertPersistentForCompatibility(storage);
            using (RunCertificate current = RunCertificate.Persistent(storage)) Check(current.Pin == pin);
            Check(NativeProtocol.Equal(unchanged, File.ReadAllBytes(Path.Combine(root, "lease", "identity.dpapi"))));
            Check(storage.Revocations == 0 && storage.Writes == 0);
            Console.WriteLine("{\"status\":\"passed\",\"freshSyntheticOnly\":true,\"crossProcessCertificateLease\":true,\"writes\":0,\"revocations\":0}");
            return 0;
        }
        private static void CertificateLeaseChecks(string root, byte[] legacy)
        {
            ObservedCertificateStorage storage = new ObservedCertificateStorage(Path.Combine(root, "lease")); storage.Inner.Write(legacy);
            string nonce = Path.GetFileName(root).Substring("KnotCertificateCheck_".Length);
            string executable;
            using (Process current = Process.GetCurrentProcess()) executable = current.MainModule.FileName;
            ProcessStartInfo start = new ProcessStartInfo(executable, "--certificate-lease-probe \"" + root + "\" " + nonce);
            start.UseShellExecute = false; start.CreateNoWindow = true; start.RedirectStandardOutput = true; start.RedirectStandardError = true;
            Process child = null;
            try
            {
                using (storage.AcquireLease())
                {
                    child = Process.Start(start); Check(child != null);
                    Stopwatch ready = Stopwatch.StartNew();
                    while (!File.Exists(Path.Combine(root, "lease-ready")) && !child.HasExited && ready.ElapsedMilliseconds < 5000) Thread.Sleep(10);
                    Check(File.Exists(Path.Combine(root, "lease-ready")) && !child.HasExited);
                    Check(!child.WaitForExit(200));
                    storage.RequireRevocation = true;
                    RunCertificate.ConvertPersistentForCompatibility(storage);
                    Check(storage.Revocations == 1 && storage.Writes == 1);
                    Check(!child.HasExited);
                }
                Check(child.WaitForExit(15000));
                string output = child.StandardOutput.ReadToEnd(), errors = child.StandardError.ReadToEnd();
                Check(child.ExitCode == 0 && errors.Length == 0 && output.Contains("\"crossProcessCertificateLease\":true"));
                Check(!RunCertificate.RequiresCompatibilityMigration(storage));
                ++actualCrossProcessCertificateLeaseFixtures;
            }
            finally
            {
                if (child != null)
                {
                    if (!child.HasExited) { child.Kill(); child.WaitForExit(5000); }
                    child.Dispose();
                }
            }
        }
        private static void PersistentCertificateTls(RunCertificate certificate)
        {
            TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start(1); Exception serverFailure = null;
            Thread server = new Thread(delegate()
            {
                try
                {
                    using (TcpClient accepted = listener.AcceptTcpClient())
                    using (ConnectionDeadline deadline = new ConnectionDeadline(5000, accepted.Close))
                    using (SslStream tls = new SslStream(accepted.GetStream(), false))
                    {
                        tls.ReadTimeout = tls.WriteTimeout = 5000;
                        tls.AuthenticateAsServer(certificate.Certificate, false, SslProtocols.Tls12, false);
                        tls.WriteByte(73);
                        if (tls.ReadByte() != 74) throw new InvalidOperationException("Synthetic certificate TLS reply mismatch.");
                        deadline.TryComplete();
                    }
                }
                catch (Exception error) { serverFailure = error; }
            });
            server.IsBackground = true; server.Start();
            try
            {
                using (TcpClient client = new TcpClient())
                {
                    client.Connect(IPAddress.Loopback, ((IPEndPoint)listener.LocalEndpoint).Port);
                    using (ConnectionDeadline deadline = new ConnectionDeadline(5000, client.Close))
                    using (SslStream tls = new SslStream(client.GetStream(), false,
                        delegate(object sender, X509Certificate remote, X509Chain chain, SslPolicyErrors errors) { return RunCertificate.VerifyPinned(remote, errors, certificate.Pin); }))
                    {
                        tls.ReadTimeout = tls.WriteTimeout = 5000;
                        tls.AuthenticateAsClient("knot-native", new X509CertificateCollection(), SslProtocols.Tls12, false);
                        Check(tls.ReadByte() == 73); tls.WriteByte(74); deadline.TryComplete();
                    }
                }
            }
            finally { listener.Stop(); Check(server.Join(6000)); }
            if (serverFailure != null) throw serverFailure;
            ++tlsFixtures;
        }
    }
}
