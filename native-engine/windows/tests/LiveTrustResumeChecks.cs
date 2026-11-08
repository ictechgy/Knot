// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Threading;

namespace Knot.NativePreview
{
    internal static partial class NativeChecks
    {
        private static void LiveTrustResumeChecks()
        {
            ResumeOwnerAndTerminalGates();
            CrossProcessTrustTransactions();
            IntegratedHostTrustChecks();
            foreach (bool silence in new bool[] { false, true })
            {
                ResumeAfterAuthenticatedRevocation(false, silence, false);
                ResumeAfterAuthenticatedRevocation(true, silence, false);
            }
            ResumeAfterAuthenticatedRevocation(true, false, true);
        }
        private sealed class FreshTrustStorage : ITrustedDeviceStorage
        {
            private readonly ProtectedCertificateStorage inner;
            internal FreshTrustStorage(string directory) { inner = new ProtectedCertificateStorage(directory, delegate { }); }
            public IDisposable AcquireLease() { return inner.AcquireLease(); }
            public bool Exists { get { return inner.Exists; } }
            public byte[] Read() { return inner.Read(); }
            public void Write(byte[] bytes) { inner.Write(bytes); }
        }
        private static string TrustId(byte value)
        { byte[] bytes = new byte[32]; bytes[0] = value; return NativeProtocol.Base64Url(bytes); }
        private static int TrustStoreProbe(string root, string nonce, string mode)
        {
            Guid parsed;
            if (nonce.Length != 32 || !Guid.TryParseExact(nonce, "N", out parsed) ||
                !String.Equals(Path.GetFullPath(root), Path.Combine(Path.GetTempPath(), "KnotTrustCheck_" + nonce), StringComparison.OrdinalIgnoreCase) ||
                !Directory.Exists(root) || (mode != "revoke" && mode != "all")) throw new ArgumentException("Invalid fresh trust fixture.");
            using (IDisposable owner = PersistentCertificateLease.TryAcquireHostOwner(root)) Check(owner == null);
            using (FileStream ready = new FileStream(Path.Combine(root, mode + "-ready"), FileMode.CreateNew, FileAccess.Write, FileShare.Read)) ready.WriteByte(1);
            NativeTrustedDeviceStore store = new NativeTrustedDeviceStore(new FreshTrustStorage(Path.Combine(root, mode)));
            store.Add(TrustId(2), "Synthetic Mac B", TrustId(9));
            Check(!store.List().ContainsKey(TrustId(1)) && store.List().ContainsKey(TrustId(2)));
            Console.WriteLine("{\"status\":\"passed\",\"freshSyntheticOnly\":true,\"crossProcessTrustLease\":true}");
            return 0;
        }
        private static void CrossProcessTrustTransactions()
        {
            string nonce = Guid.NewGuid().ToString("N"), root = Path.Combine(Path.GetTempPath(), "KnotTrustCheck_" + nonce);
            Directory.CreateDirectory(root);
            try
            {
                using (IDisposable owner = PersistentCertificateLease.TryAcquireHostOwner(root))
                {
                    Check(owner != null);
                    foreach (string mode in new string[] { "revoke", "all" })
                    {
                        FreshTrustStorage storage = new FreshTrustStorage(Path.Combine(root, mode));
                        NativeTrustedDeviceStore store = new NativeTrustedDeviceStore(storage);
                        store.Add(TrustId(1), "Synthetic Mac A", TrustId(8));
                        string executable;
                        using (Process current = Process.GetCurrentProcess()) executable = current.MainModule.FileName;
                        ProcessStartInfo start = new ProcessStartInfo(executable, "--trust-store-probe \"" + root + "\" " + nonce + " " + mode);
                        start.UseShellExecute = false; start.CreateNoWindow = true; start.RedirectStandardOutput = true; start.RedirectStandardError = true;
                        Process child = null;
                        try
                        {
                            using (storage.AcquireLease())
                            {
                                child = Process.Start(start); Check(child != null);
                                Stopwatch timer = Stopwatch.StartNew();
                                while (!File.Exists(Path.Combine(root, mode + "-ready")) && !child.HasExited && timer.ElapsedMilliseconds < 5000) Thread.Sleep(10);
                                Check(File.Exists(Path.Combine(root, mode + "-ready")) && !child.WaitForExit(200));
                                if (mode == "all") store.RevokeAll(); else store.Revoke(TrustId(1));
                                Check(!store.HasDevices && !child.HasExited);
                            }
                            Check(child.WaitForExit(15000));
                            string output = child.StandardOutput.ReadToEnd(), errors = child.StandardError.ReadToEnd();
                            Check(child.ExitCode == 0 && errors.Length == 0 && output.Contains("\"crossProcessTrustLease\":true"));
                            Check(!store.List().ContainsKey(TrustId(1)) && store.List().Count == 1 && store.List().ContainsKey(TrustId(2)));
                        }
                        finally { if (child != null) { if (!child.HasExited) { child.Kill(); child.WaitForExit(5000); } child.Dispose(); } }
                    }
                }
            }
            finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
        }
        private sealed class MemoryTrustStorage : ITrustedDeviceStorage
        {
            private byte[] bytes;
            private sealed class Lease : IDisposable { public void Dispose() { } }
            public IDisposable AcquireLease() { return new Lease(); }
            public bool Exists { get { return bytes != null; } }
            public byte[] Read() { return (byte[])bytes.Clone(); }
            public void Write(byte[] value) { bytes = (byte[])value.Clone(); }
        }
        private sealed class OpenActionMediaFactory : IMediaFactory
        {
            private readonly Action open;
            internal OpenActionMediaFactory(Action open) { this.open = open; }
            public IMediaSource Open() { open(); return new FakeMediaFactory().Open(); }
        }
        private static void IntegratedHostTrustChecks()
        {
            // These are the production HostServer callbacks and trusted listener,
            // with injected fresh storage and a loopback-only disposable identity.
            NativeTrustedDeviceStore store = new NativeTrustedDeviceStore(new MemoryTrustStorage());
            byte[] key = NativeProtocol.DecodeToken(TrustId(9));
            long ticks = Stopwatch.GetTimestamp();
            OpenActionMediaFactory media = new OpenActionMediaFactory(delegate { Interlocked.Add(ref ticks, 40L * Stopwatch.Frequency); }); FakeInput input = new FakeInput();
            using (HostServer host = new HostServer(IPAddress.Loopback, 0, media, input, true, null, true,
                delegate { return Interlocked.Read(ref ticks); }, "Synthetic integrated trust", syntheticTrustedDevices: store))
            {
                host.Start(); Check(host.TrustedPort > 0 && !host.HasRegisteredDevices);
                string offer = Enroll(host, Discover(host), host.EnrollmentCode, false);
                // An otherwise successful media initialization may take longer
                // than 30s; registration starts at Ready, not the earlier claim.
                using (TlsClient client = new TlsClient(host, OfferedPin(offer)))
                {
                    client.Send(1, Hello(StrictJson.String(InvitationObject(offer), "token")));
                    Check(client.ReadNonHeartbeat().Kind == 2 && host.IsActive);
                    Packet registered = IntegratedRegister(host, offer, TrustId(1), TrustId(9));
                    Check(registered.Kind == 1 && store.HasDevices && host.HasRegisteredDevices);
                    Check(IntegratedRegister(host, offer, TrustId(2), TrustId(9)).Kind == 127); // One-use registration.
                    host.Stop(); Check(host.WaitStopped(4000));
                }
            }
            // Consume a fresh registered grant without claiming it. Expiry must
            // return to registered waiting; the last revoke must stop that run.
            ticks = Stopwatch.GetTimestamp();
            using (HostServer host = new HostServer(IPAddress.Loopback, 0, new FakeMediaFactory(), new FakeInput(), true, null, true,
                delegate { return Interlocked.Read(ref ticks); }, "Synthetic trusted expiry", syntheticTrustedDevices: store))
            {
                host.Start();
                Check(IntegratedTrustedRequest(host, TrustId(1), key, "connect").Kind == 1 && host.EnrollmentReady);
                Interlocked.Add(ref ticks, 31L * Stopwatch.Frequency);
                WaitFor(delegate { return !host.EnrollmentReady; });
                Check(host.HasRegisteredDevices && !host.IsActive);
                Interlocked.Add(ref ticks, 100L * Stopwatch.Frequency);
                WaitFor(delegate { return host.WaitingForRegisteredDevice; });
                Check(IntegratedTrustedRequest(host, TrustId(1), key, "revoke").Kind == 1);
                Check(!host.HasRegisteredDevices && !store.HasDevices && host.WaitStopped(4000));
            }
            Array.Clear(key, 0, key.Length);
            Check(PreviewCopy.Privacy(false, true).IndexOf("내 PC로 등록", StringComparison.Ordinal) < 0);
            Check(PreviewCopy.Privacy(true, true).IndexOf("내 PC로 등록", StringComparison.Ordinal) >= 0);
            Check(PreviewCopy.Status("Connection ended. Waiting to reconnect a registered device.") != "Connection ended. Waiting to reconnect a registered device.");
        }
        private static Packet IntegratedRegister(HostServer host, string offer, string id, string key)
        {
            using (System.Net.Sockets.TcpClient client = new System.Net.Sockets.TcpClient())
            {
                client.Connect(IPAddress.Loopback, host.TrustedPort); client.ReceiveTimeout = client.SendTimeout = 3000;
                using (System.Net.Security.SslStream tls = new System.Net.Security.SslStream(client.GetStream(), false,
                    delegate(object sender, System.Security.Cryptography.X509Certificates.X509Certificate peer, System.Security.Cryptography.X509Certificates.X509Chain chain, System.Net.Security.SslPolicyErrors errors) { return RunCertificate.VerifyPinned(peer, errors, host.Pin); }))
                {
                    tls.AuthenticateAsClient("knot-native", null, System.Security.Authentication.SslProtocols.Tls12, false);
                    TrustedWrite(tls, "{\"op\":\"register\",\"id\":" + StrictJson.Quote(id) + ",\"name\":\"Synthetic Mac\",\"value\":" + StrictJson.Quote(StrictJson.String(InvitationObject(offer), "token")) + ",\"key\":" + StrictJson.Quote(key) + "}");
                    return ReadRecoveryTrusted(tls);
                }
            }
        }
        private static Packet IntegratedTrustedRequest(HostServer host, string id, byte[] key, string op)
        {
            using (System.Net.Sockets.TcpClient client = new System.Net.Sockets.TcpClient())
            {
                client.Connect(IPAddress.Loopback, host.TrustedPort); client.ReceiveTimeout = client.SendTimeout = 3000;
                using (System.Net.Security.SslStream tls = new System.Net.Security.SslStream(client.GetStream(), false,
                    delegate(object sender, System.Security.Cryptography.X509Certificates.X509Certificate peer, System.Security.Cryptography.X509Certificates.X509Chain chain, System.Net.Security.SslPolicyErrors errors) { return RunCertificate.VerifyPinned(peer, errors, host.Pin); }))
                {
                    tls.AuthenticateAsClient("knot-native", null, System.Security.Authentication.SslProtocols.Tls12, false);
                    TrustedWrite(tls, "{\"op\":" + StrictJson.Quote(op) + ",\"id\":" + StrictJson.Quote(id) + ",\"name\":\"Synthetic Mac\",\"value\":\"\",\"key\":\"\"}");
                    Packet challenge = ReadRecoveryTrusted(tls); Check(challenge.Kind == 1);
                    string nonce = StrictJson.String(StrictJson.Parse(challenge.Payload, "nonce"), "nonce");
                    byte[] proof = NativeTrustedDevices.Proof(key, id, nonce, "Synthetic Mac", host.Pin, op);
                    TrustedWrite(tls, "{\"proof\":" + StrictJson.Quote(NativeProtocol.Base64Url(proof)) + "}");
                    return ReadRecoveryTrusted(tls);
                }
            }
        }
        private static void ResumeOwnerAndTerminalGates()
        {
            int reads = 0, constructions = 0;
            Func<bool> live = delegate { ++reads; return true; };
            Action construct = delegate { ++constructions; };
            Check(!RegisteredConnectionResume.TryResume(false, false, true, construct, live));
            Check(!RegisteredConnectionResume.TryResume(true, true, true, construct, live));
            Check(!RegisteredConnectionResume.TryResume(true, false, false, construct, live));
            Check(reads == 0 && constructions == 0);
            Check(!RegisteredConnectionResume.TryResume(true, false, true, construct,
                delegate { ++reads; throw new IOException("Fresh synthetic trust-read failure."); }));
            Check(reads == 1 && constructions == 0);
        }
        private static void ResumeAfterAuthenticatedRevocation(bool anotherRemains, bool silence, bool failRead)
        {
            byte[] key = new byte[32]; for (int i = 0; i < key.Length; ++i) key[i] = 17;
            string id = NativeProtocol.Base64Url(new byte[32]);
            byte[] otherIdBytes = new byte[32]; otherIdBytes[0] = 1;
            string otherId = NativeProtocol.Base64Url(otherIdBytes);
            object storeGate = new object();
            Dictionary<string, byte[]> store = new Dictionary<string, byte[]>(StringComparer.Ordinal);
            store.Add(id, (byte[])key.Clone());
            if (anotherRemains) store.Add(otherId, (byte[])key.Clone());
            FakeInput sink = new FakeInput(); long inputTicks = 0;
            int reads = 0, constructions = 0, registrations = 0, revocations = 0, connectGrants = 0;
            using (TerminalStatusMediaFactory media = new TerminalStatusMediaFactory())
            using (HostServer host = RecoveryHost(media, sink, true, delegate { return Interlocked.Read(ref inputTicks); }))
            using (RunCertificate certificate = new RunCertificate())
            using (TrustedDeviceServer trusted = new TrustedDeviceServer(IPAddress.Loopback, certificate.Certificate, certificate.Pin,
                delegate(IPAddress peer, string token, string candidate, string name, string secret) { ++registrations; return false; },
                delegate(IPAddress peer, string name) { ++connectGrants; throw new ProtocolException("busy"); },
                delegate { return host.IsActive; }, syntheticLoopback: true, port: 0,
                lookupKey: delegate(string candidate) {
                    lock (storeGate) {
                        byte[] secret;
                        if (!store.TryGetValue(candidate, out secret)) throw new ProtocolException("auth");
                        return (byte[])secret.Clone();
                    }
                },
                revoke: delegate(string candidate) {
                    lock (storeGate) {
                        byte[] secret;
                        if (store.TryGetValue(candidate, out secret)) { store.Remove(candidate); Array.Clear(secret, 0, secret.Length); ++revocations; }
                    }
                }))
            {
                string offer = RecoveryNumberOffer(host); trusted.Start(); ++tlsFixtures;
                try
                {
                    using (TlsClient client = new TlsClient(host, OfferedPin(offer)))
                    {
                        client.Send(1, Hello(StrictJson.String(InvitationObject(offer), "token")));
                        Check(client.ReadNonHeartbeat().Kind == 2 && media.Entered.WaitOne(3000));
                        Check(host.IsActive && !host.IsRegisteredSession && host.HasRegisteredDevices);
                        // Revoke saved Mac A with a real fresh challenge while
                        // temporary number Mac B is latched in fake capture.
                        Check(RecoveryTrustedRequest(trusted, certificate.Pin, id, key, "revoke", false, false).Kind == 1);
                        lock (storeGate) Check(!store.ContainsKey(id) && store.Count == (anotherRemains ? 1 : 0));
                        Check(revocations == 1 && registrations == 0 && connectGrants == 0);
                        Check(host.HasRegisteredDevices && host.IsActive);
                        if (silence) Interlocked.Exchange(ref inputTicks, 11L * Stopwatch.Frequency);
                        else client.Client.Close();
                        WaitFor(delegate { return !host.IsActive; });
                        Check(host.MayResumeRegisteredConnection);
                        media.Continue.Set(); Check(host.WaitStopped(4000));
                        bool resumed = RegisteredConnectionResume.TryResume(true, false, host.MayResumeRegisteredConnection,
                            delegate {
                                // This is the same admission seam as Program's
                                // StartShare callback; construct only owned
                                // synthetic listeners after the live check.
                                ++constructions;
                                using (HostServer next = RecoveryHost(new FakeMediaFactory(), new FakeInput(), true))
                                    Check(next.Port > 0 && !next.IsActive);
                            },
                            delegate {
                                ++reads;
                                if (failRead) throw new IOException("Fresh synthetic trust-read failure.");
                                lock (storeGate) return store.Count != 0;
                            });
                        Check(resumed == (anotherRemains && !failRead));
                        Check(reads == 1 && constructions == (resumed ? 1 : 0));
                        Check(!host.IsActive && !host.IsRegisteredSession && media.Closed == 1 && sink.Events.Count == 0);
                        lock (storeGate) Check(!store.ContainsKey(id) && store.Count == (anotherRemains ? 1 : 0));
                    }
                }
                finally { media.Continue.Set(); }
            }
            Array.Clear(key, 0, key.Length);
            lock (storeGate) foreach (byte[] secret in store.Values) Array.Clear(secret, 0, secret.Length);
        }
    }
}
