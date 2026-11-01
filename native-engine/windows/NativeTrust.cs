using System;
using System.Diagnostics;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace Knot.NativePreview
{
    internal sealed class RunCertificate : IDisposable
    {
        internal readonly string OwnedKeyContainerName;
        internal X509Certificate2 Certificate { get; private set; }
        private RSACryptoServiceProvider key;
        internal RunCertificate()
        {
            OwnedKeyContainerName = "KnotNativePreview_" + Guid.NewGuid().ToString("N");
            CspParameters parameters = Parameters(OwnedKeyContainerName);
            try
            {
                // Schannel on .NET Framework needs an associated persisted key.
                // This random run-owned container is deleted on every teardown.
                key = new RSACryptoServiceProvider(2048, parameters);
                key.PersistKeyInCsp = true;
                CertificateRequest request = new CertificateRequest(new X500DistinguishedName("CN=knot-native"), key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
                request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, true));
                OidCollection purposes = new OidCollection(); purposes.Add(new Oid("1.3.6.1.5.5.7.3.1"));
                request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(purposes, false));
                byte[] dns = Encoding.ASCII.GetBytes("knot-native");
                byte[] san = new byte[dns.Length + 4]; san[0] = 0x30; san[1] = (byte)(dns.Length + 2); san[2] = 0x82; san[3] = (byte)dns.Length; Buffer.BlockCopy(dns, 0, san, 4, dns.Length);
                request.CertificateExtensions.Add(new X509Extension("2.5.29.17", san, false));
                Certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow.AddMinutes(5));
                if (!Certificate.HasPrivateKey) throw new CryptographicException("Fresh certificate has no associated key.");
            }
            catch { Dispose(); throw; }
        }
        internal static CspParameters Parameters(string name)
        {
            return new CspParameters(24, "Microsoft Enhanced RSA and AES Cryptographic Provider", name)
            { KeyNumber = (int)KeyNumber.Exchange, Flags = CspProviderFlags.NoPrompt | CspProviderFlags.UseNonExportableKey };
        }
        internal string Pin
        {
            get
            {
                using (SHA256 sha = SHA256.Create())
                {
                    byte[] hash = sha.ComputeHash(Certificate.RawData);
                    StringBuilder b = new StringBuilder(64);
                    foreach (byte v in hash) b.Append(v.ToString("x2", System.Globalization.CultureInfo.InvariantCulture));
                    return b.ToString();
                }
            }
        }
        public void Dispose()
        {
            if (Certificate != null) { Certificate.Dispose(); Certificate = null; }
            if (key != null) { key.PersistKeyInCsp = false; key.Dispose(); key = null; }
        }

        // Used by the synthetic Windows TLS client. A pinned certificate is the sole
        // permitted chain anchor; all name, validity and server-purpose checks remain.
        internal static bool VerifyPinned(X509Certificate certificate, SslPolicyErrors errors, string expectedPin)
        {
            if (certificate == null || (errors & ~SslPolicyErrors.RemoteCertificateChainErrors) != 0) return false;
            using (X509Certificate2 cert = new X509Certificate2(certificate))
            using (SHA256 sha = SHA256.Create())
            {
                string pin = BitConverter.ToString(sha.ComputeHash(cert.RawData)).Replace("-", "").ToLowerInvariant();
                if (!NativeProtocol.Equal(Encoding.ASCII.GetBytes(pin), Encoding.ASCII.GetBytes(expectedPin))) return false;
                DateTime now = DateTime.UtcNow;
                if (now < cert.NotBefore.ToUniversalTime() || now > cert.NotAfter.ToUniversalTime() || cert.GetNameInfo(X509NameType.DnsName, false) != "knot-native") return false;
                bool hasSan = false, hasPurpose = false;
                foreach (X509Extension extension in cert.Extensions)
                {
                    if (extension.Oid.Value == "2.5.29.17")
                    {
                        byte[] expected = new byte[] { 0x30, 13, 0x82, 11, 107, 110, 111, 116, 45, 110, 97, 116, 105, 118, 101 };
                        hasSan = NativeProtocol.Equal(extension.RawData, expected);
                    }
                    X509EnhancedKeyUsageExtension eku = extension as X509EnhancedKeyUsageExtension;
                    if (eku != null) foreach (Oid purpose in eku.EnhancedKeyUsages) if (purpose.Value == "1.3.6.1.5.5.7.3.1") hasPurpose = true;
                }
                if (!hasSan || !hasPurpose) return false;
                using (X509Chain chain = new X509Chain())
                {
                    chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
                    chain.ChainPolicy.VerificationFlags = X509VerificationFlags.AllowUnknownCertificateAuthority;
                    chain.ChainPolicy.ApplicationPolicy.Add(new Oid("1.3.6.1.5.5.7.3.1"));
                    chain.ChainPolicy.ExtraStore.Add(cert);
                    chain.ChainPolicy.UrlRetrievalTimeout = TimeSpan.FromMilliseconds(1);
                    return chain.Build(cert) && chain.ChainElements.Count == 1 && NativeProtocol.Equal(chain.ChainElements[0].Certificate.RawData, cert.RawData);
                }
            }
        }
    }

    internal sealed class Invitation
    {
        private readonly object gate = new object();
        private readonly byte[] token = new byte[32];
        private readonly long created;
        private readonly Func<long> clock;
        private bool claimed, revoked;
        internal Invitation() : this(Stopwatch.GetTimestamp) { }
        internal Invitation(Func<long> clock)
        {
            this.clock = clock; created = clock();
            using (RandomNumberGenerator random = RandomNumberGenerator.Create()) random.GetBytes(token);
        }
        internal bool IsExpired { get { lock (gate) return clock() - created >= 120L * Stopwatch.Frequency; } }
        internal string Encode(IPAddress address, int port, string pin)
        {
            lock (gate)
            {
                if (revoked || claimed || IsExpired) throw new ProtocolException("expired");
                string json = "{\"v\":1,\"address\":" + StrictJson.Quote(address.ToString()) + ",\"port\":" + port.ToString(System.Globalization.CultureInfo.InvariantCulture) +
                    ",\"certificateSHA256\":" + StrictJson.Quote(pin) + ",\"token\":" + StrictJson.Quote(NativeProtocol.Base64Url(token)) + "}";
                string result = "knot-native:v1:" + NativeProtocol.Base64Url(StrictJson.Utf8.GetBytes(json));
                if (StrictJson.Utf8.GetByteCount(result) > 2048) throw new ProtocolException("protocol");
                return result;
            }
        }
        internal void Claim(byte[] candidate)
        {
            lock (gate)
            {
                if (revoked || claimed) throw new ProtocolException("auth");
                if (IsExpired) throw new ProtocolException("expired");
                if (!NativeProtocol.Equal(token, candidate)) throw new ProtocolException("auth");
                claimed = true;
                Array.Clear(token, 0, token.Length);
            }
        }
        internal void Revoke() { lock (gate) { revoked = true; Array.Clear(token, 0, token.Length); } }
    }
}
