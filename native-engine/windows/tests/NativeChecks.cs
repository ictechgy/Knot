using System;
using System.Collections.Generic;
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
    // Compile this separate entry with /main:Knot.NativePreview.NativeChecks.
    // It never starts WinForms, loads the media DLL, captures a display, calls
    // SendInput, enumerates certificates, or opens application stores/preferences.
    internal static class NativeChecks
    {
        private static int assertions, tlsFixtures;
        private static string stage = "protocol";
        private static void Check(bool result) { ++assertions; if (!result) throw new InvalidOperationException("Synthetic assertion failed."); }
        private static void Reject(Action action)
        {
            bool rejected = false;
            try { action(); } catch (ProtocolException) { rejected = true; }
            Check(rejected);
        }
        private static int Main()
        {
            try
            {
                ProtocolChecks(); stage = "invitation"; InvitationChecks(); stage = "input"; InputChecks();
                stage = "fresh-certificate"; FreshCertificateChecks();
                stage = "tls-pin-mismatch"; TlsPinMismatch(); stage = "tls-approval-stop"; TlsApprovalStop();
                stage = "tls-decline"; TlsDecline(); stage = "tls-expired"; TlsExpired(); stage = "tls-single-use"; TlsSingleUse();
                stage = "tls-wrong-token"; TlsWrongToken(); stage = "tls-disconnect"; TlsDisconnect(false); stage = "tls-malformed-input"; TlsDisconnect(true);
                stage = "tls-delayed-approval"; TlsDelayedApproval();
                Console.WriteLine("{\"status\":\"passed\",\"freshSyntheticOnly\":true,\"actualCapture\":false,\"actualSendInput\":false,\"actualFreshTlsFixtures\":" + tlsFixtures + ",\"assertions\":" + assertions + ",\"ownedTemporaryCspContainersOnly\":true}");
                return 0;
            }
            catch (Exception failure)
            {
                // Synthetic-only diagnostics identify the API category without any raw
                // message, stack, token, pin, key, endpoint or operating-system path.
                string kind = failure.GetType().FullName;
                if (kind.Length > 128) kind = "Exception";
                Console.WriteLine("{\"status\":\"failed\",\"freshSyntheticOnly\":true,\"actualCapture\":false,\"actualSendInput\":false,\"stage\":\"" + stage + "\",\"exceptionType\":" + StrictJson.Quote(kind) + ",\"exceptionHResult\":" + failure.HResult + ",\"assertions\":" + assertions + "}");
                return 1;
            }
        }
        private static byte[] Bytes(string s) { return StrictJson.Utf8.GetBytes(s); }
        private static void ProtocolChecks()
        {
            Check(NativeProtocol.IsPrivate(IPAddress.Parse("10.2.3.4")));
            Check(NativeProtocol.IsPrivate(IPAddress.Parse("172.16.0.1")));
            Check(NativeProtocol.IsPrivate(IPAddress.Parse("172.31.255.254")));
            Check(NativeProtocol.IsPrivate(IPAddress.Parse("192.168.1.2")));
            Check(NativeProtocol.IsPrivate(IPAddress.Parse("100.64.0.1")));
            Check(NativeProtocol.IsPrivate(IPAddress.Parse("100.127.255.254")));
            foreach (string ip in new string[] { "8.8.8.8", "100.63.1.1", "100.128.1.1", "172.32.1.1", "127.0.0.1", "169.254.1.1", "::1", "::ffff:10.1.2.3" }) Check(!NativeProtocol.IsPrivate(IPAddress.Parse(ip)));
            byte[] token = new byte[32]; token[31] = 255;
            string hello = "{\"v\":1,\"token\":\"" + NativeProtocol.Base64Url(token) + "\",\"name\":\"Synthetic viewer\"}";
            byte[] decoded;
            Check(NativeProtocol.HelloName(Bytes(hello), out decoded) == "Synthetic viewer" && NativeProtocol.Equal(token, decoded));
            Reject(delegate { NativeProtocol.HelloName(Bytes(hello.Replace("\"v\":1", "\"v\":1,\"v\":1")), out decoded); });
            Reject(delegate { NativeProtocol.HelloName(Bytes(hello.Replace("\"v\":1", "\"v\":1,\"extra\":true")), out decoded); });
            Reject(delegate { NativeProtocol.HelloName(Bytes(hello.Replace("\"v\":1", "\"v\":true")), out decoded); });
            Reject(delegate { NativeProtocol.HelloName(Bytes(hello.Replace("\"v\":1", "\"v\":01")), out decoded); });
            Reject(delegate { NativeProtocol.HelloName(Bytes(hello + "[]"), out decoded); });
            Reject(delegate { NativeProtocol.HelloName(Bytes(hello.Replace("Synthetic viewer", "\\ud800")), out decoded); });
            Reject(delegate { NativeProtocol.HelloName(Bytes(hello.Replace("Synthetic viewer", "\\u000a")), out decoded); });
            Reject(delegate { NativeProtocol.HelloName(Bytes(hello.Replace("Synthetic viewer", new string('x', 65))), out decoded); });
            Reject(delegate { StrictJson.Parse(new byte[] { 0xc0, 0x80 }, "v"); });
            Reject(delegate { NativeProtocol.DecodeToken(new string('_', 43)); }); // noncanonical trailing bits
            Reject(delegate { NativeProtocol.ReadClient(new MemoryStream(new byte[] { 1, 0xff, 0xff, 0xff, 0xff }), true); });
            Reject(delegate { NativeProtocol.ReadClient(new MemoryStream(new byte[] { 0x20, 0, 0, 0, 5 }), false); });
            Reject(delegate { NativeProtocol.ReadClient(new MemoryStream(new byte[] { 0x26, 0, 0, 0, 0 }), false); });
            Reject(delegate { NativeProtocol.ReadClient(new MemoryStream(new byte[] { 0x25, 0, 0, 0, 1 }), false); });
            Reject(delegate { NativeProtocol.ReadClient(new MemoryStream(new byte[] { 0x21, 0, 0, 0, 0 }), false); });
            using (MemoryStream framed = new MemoryStream(new byte[] { 0x20, 0, 0, 0, 4, 1, 0, 30, 0 }))
            { Packet p = NativeProtocol.ReadClient(framed, false); Check(p.Kind == 0x20 && p.Payload.Length == 4 && framed.Position == framed.Length); }
            byte[] accessUnit = { 0, 0, 0, 1, 0x67, 0x42, 0, 0, 1, 0x68, 0x12, 0, 0, 1, 0x65, 0x88 };
            AnnexB.Validate(accessUnit, accessUnit.Length, 1); Check(true);
            Reject(delegate { AnnexB.Validate(new byte[] { 0, 0, 1, 0x65, 1 }, 5, 1); });
            Reject(delegate { AnnexB.Validate(new byte[] { 0, 0, 1, 0xff, 1 }, 5, 0); });
            Reject(delegate { AnnexB.Validate(accessUnit, accessUnit.Length, 2); });
        }
        private static Dictionary<string, object> InvitationObject(string text)
        {
            Check(text.StartsWith("knot-native:v1:", StringComparison.Ordinal) && text.Length <= 2048);
            string body = text.Substring("knot-native:v1:".Length).Replace('-', '+').Replace('_', '/');
            body += new string('=', (4 - body.Length % 4) % 4);
            Dictionary<string, object> fields = StrictJson.Parse(Convert.FromBase64String(body), "v", "address", "port", "certificateSHA256", "token");
            Check(StrictJson.Integer(fields, "v", 1, 1) == 1);
            Check(StrictJson.String(fields, "certificateSHA256").Length == 64);
            return fields;
        }
        private static byte[] InvitationToken(Invitation invitation)
        {
            return NativeProtocol.DecodeToken(StrictJson.String(InvitationObject(invitation.Encode(IPAddress.Parse("192.168.50.2"), 48631, new string('a', 64))), "token"));
        }
        private static void InvitationChecks()
        {
            long ticks = 0;
            Invitation expired = new Invitation(delegate { return ticks; });
            byte[] token = InvitationToken(expired);
            ticks = 120L * Stopwatch.Frequency;
            Reject(delegate { expired.Claim(token); });
            Invitation single = new Invitation();
            byte[] one = InvitationToken(single);
            single.Claim(one); Reject(delegate { single.Claim(one); });
            Invitation revoked = new Invitation(); byte[] old = InvitationToken(revoked); revoked.Revoke(); Reject(delegate { revoked.Claim(old); });
            Invitation atomic = new Invitation(); byte[] shared = InvitationToken(atomic);
            int winners = 0;
            ManualResetEvent go = new ManualResetEvent(false);
            Thread[] claimants = new Thread[16];
            for (int i = 0; i < claimants.Length; ++i)
            {
                claimants[i] = new Thread(delegate()
                {
                    go.WaitOne();
                    try { atomic.Claim(shared); Interlocked.Increment(ref winners); } catch (ProtocolException) { }
                });
                claimants[i].Start();
            }
            go.Set(); foreach (Thread thread in claimants) Check(thread.Join(2000)); go.Dispose(); Check(winners == 1);
        }
        private static Packet Key(byte action, byte scan) { return new Packet(0x20, new byte[] { action, 0, scan, 0 }); }
        private static void InputChecks()
        {
            FakeInput sink = new FakeInput(); InputSession session = new InputSession(sink, new CaptureRectangle(-1920, 0, 1920, 1080));
            session.Accept(Key(0, 30)); Check(sink.Events.Count == 0);
            session.Accept(Key(1, 30)); session.Accept(Key(1, 30));
            session.Accept(new Packet(0x22, new byte[] { 1, 255, 255, 255, 255 }));
            session.Accept(new Packet(0x21, Bytes("가😀")));
            Check(sink.LastText == "가😀");
            session.Accept(new Packet(0x24, new byte[0]));
            Check(sink.Events.Contains("key:30:up") && sink.Events.Contains("pointer:2"));
            int before = sink.Events.Count; session.Close(); Check(sink.Events.Count == before);
            Reject(delegate { session.Accept(Key(1, 30)); });
            FakeInput failed = new FakeInput(); failed.FailScan = 20;
            InputSession failure = new InputSession(failed, new CaptureRectangle(0, 0, 1920, 1080));
            failure.Accept(Key(1, 30)); Reject(delegate { failure.Accept(Key(1, 20)); }); failure.Close();
            Check(failed.Events.Contains("key:30:up") && !failed.Events.Contains("key:20:up"));
            InputSession validation = new InputSession(new FakeInput(), new CaptureRectangle(0, 0, 1920, 1080));
            Reject(delegate { validation.Accept(new Packet(0x20, new byte[] { 1, 1, 0, 0 })); });
            Reject(delegate { validation.Accept(new Packet(0x20, new byte[] { 1, 0, 0, 0 })); });
            Reject(delegate { validation.Accept(new Packet(0x20, new byte[] { 2, 0, 30, 0 })); });
            Reject(delegate { validation.Accept(new Packet(0x21, new byte[] { 0 })); });
            Reject(delegate { validation.Accept(new Packet(0x21, new byte[] { 0xed, 0xa0, 0x80 })); });
            Reject(delegate { validation.Accept(new Packet(0x21, Bytes(new string('a', 513)))); });
            Reject(delegate { validation.Accept(new Packet(0x22, new byte[] { 7, 0, 0, 0, 0 })); });
            byte[] excessiveWheel = new byte[8]; NativeProtocol.Put32(excessiveWheel, 0, 1201);
            Reject(delegate { validation.Accept(new Packet(0x23, excessiveWheel)); });
            for (byte i = 1; i <= 128; ++i) validation.Accept(Key(1, i));
            Reject(delegate { validation.Accept(Key(1, 129)); }); validation.Close();
            Check(WindowsInputSink.Normalize(-1920, -1920, 3840) == 0);
            Check(WindowsInputSink.Normalize(1919, -1920, 3840) == 65535);
        }
        private static void FreshCertificateChecks()
        {
            string owned;
            using (RunCertificate cert = new RunCertificate())
            {
                stage = "fresh-certificate-created";
                owned = cert.OwnedKeyContainerName;
                Check(cert.Certificate.HasPrivateKey);
                stage = "fresh-certificate-valid-pin";
                Check(RunCertificate.VerifyPinned(cert.Certificate, SslPolicyErrors.RemoteCertificateChainErrors, cert.Pin));
                stage = "fresh-certificate-name-reject";
                Check(!RunCertificate.VerifyPinned(cert.Certificate, SslPolicyErrors.RemoteCertificateNameMismatch, cert.Pin));
                stage = "fresh-certificate-pin-reject";
                Check(!RunCertificate.VerifyPinned(cert.Certificate, SslPolicyErrors.RemoteCertificateChainErrors, new string('0', 64)));
            }
            stage = "fresh-certificate-owned-key-cleanup";
            bool deleted = false;
            CspParameters onlyOwned = RunCertificate.Parameters(owned);
            // Generation-only flags must not accompany an existing-key lookup.
            onlyOwned.Flags = CspProviderFlags.NoPrompt | CspProviderFlags.UseExistingKey;
            try { using (RSACryptoServiceProvider residual = new RSACryptoServiceProvider(onlyOwned)) { residual.PersistKeyInCsp = false; } }
            catch (CryptographicException) { deleted = true; }
            Check(deleted); // Lookup is solely this fixture's random owned name, never enumeration.
        }
        private static HostServer Server(FakeMediaFactory media, FakeInput sink, Invitation invitation)
        {
            HostServer server = new HostServer(IPAddress.Loopback, 0, media, sink, true, invitation);
            ++tlsFixtures; return server;
        }
        private sealed class TlsClient : IDisposable
        {
            internal readonly TcpClient Client;
            internal readonly SslStream Stream;
            internal TlsClient(HostServer server, string pin)
            {
                Client = new TcpClient();
                try
                {
                    Client.Connect(IPAddress.Loopback, server.Port);
                    Client.NoDelay = true; Client.ReceiveTimeout = Client.SendTimeout = 4000;
                    Stream = new SslStream(Client.GetStream(), false, delegate(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors errors) { return RunCertificate.VerifyPinned(certificate, errors, pin); });
                    Stream.ReadTimeout = Stream.WriteTimeout = 4000;
                    Stream.AuthenticateAsClient("knot-native", new X509CertificateCollection(), SslProtocols.Tls12, false);
                }
                catch { Client.Close(); throw; }
            }
            internal void Send(byte kind, byte[] payload)
            {
                byte[] header = new byte[5]; header[0] = kind; NativeProtocol.Put32(header, 1, (uint)payload.Length);
                Stream.Write(header, 0, header.Length); if (payload.Length > 0) Stream.Write(payload, 0, payload.Length);
            }
            internal Packet Read()
            {
                byte[] header = NativeProtocol.ReadExactly(Stream, 5); uint length = NativeProtocol.U32(header, 1);
                if (length > 4096) throw new InvalidOperationException("Unexpected fixture length.");
                return new Packet(header[0], NativeProtocol.ReadExactly(Stream, (int)length));
            }
            internal Packet ReadNonHeartbeat()
            {
                for (int i = 0; i < 32; ++i)
                {
                    Packet packet = Read();
                    if (packet.Kind != 4) return packet;
                    if (packet.Payload.Length != 0) throw new InvalidOperationException("Invalid synthetic heartbeat.");
                }
                throw new InvalidOperationException("Synthetic approval budget exceeded.");
            }
            public void Dispose() { if (Stream != null) Stream.Dispose(); Client.Close(); }
        }
        private static byte[] Hello(string token) { return Bytes("{\"v\":1,\"token\":" + StrictJson.Quote(token) + ",\"name\":\"Synthetic viewer\"}"); }
        private static string Token(HostServer server) { return StrictJson.String(InvitationObject(server.GetInvitation()), "token"); }
        private static void TlsPinMismatch()
        {
            FakeMediaFactory media = new FakeMediaFactory(); FakeInput sink = new FakeInput();
            using (HostServer server = Server(media, sink, null))
            {
                server.Start(); bool failed = false;
                try { using (TlsClient client = new TlsClient(server, new string('0', 64))) { } }
                catch (AuthenticationException) { failed = true; } catch (IOException) { failed = true; }
                Check(failed); server.Stop(); Check(server.WaitStopped(4000)); Check(media.Opened == 0 && sink.Events.Count == 0);
            }
        }
        private static void TlsApprovalStop()
        {
            FakeMediaFactory media = new FakeMediaFactory(); FakeInput sink = new FakeInput();
            using (ManualResetEvent pending = new ManualResetEvent(false))
            using (HostServer server = Server(media, sink, null))
            {
                server.ApprovalRequested = delegate { pending.Set(); };
                string token = Token(server), pin = server.Pin; server.Start();
                using (TlsClient client = new TlsClient(server, pin))
                {
                    client.Send(1, Hello(token)); Check(pending.WaitOne(3000));
                    Check(media.Opened == 0 && sink.Events.Count == 0 && !server.IsActive);
                    server.RespondToApproval(true);
                    Packet ready = client.ReadNonHeartbeat(); Check(ready.Kind == 2);
                    StrictJson.Parse(ready.Payload, "v", "codec", "width", "height", "fps", "bitrate", "hardwareEncoder");
                    Check(media.Opened == 1);
                    client.Send(0x20, Key(1, 30).Payload);
                    Check(sink.Down.WaitOne(3000));
                    server.Stop(); Check(server.WaitStopped(4000));
                    Check(sink.Events.Contains("key:30:up") && media.Closed == 1 && media.SameThread);
                    Check(!server.IsActive);
                }
            }
        }
        private static void TlsDecline()
        {
            FakeMediaFactory media = new FakeMediaFactory(); FakeInput sink = new FakeInput();
            using (ManualResetEvent pending = new ManualResetEvent(false))
            using (HostServer server = Server(media, sink, null))
            {
                server.ApprovalRequested = delegate { pending.Set(); };
                string token = Token(server), pin = server.Pin; server.Start();
                using (TlsClient client = new TlsClient(server, pin))
                {
                    client.Send(1, Hello(token)); Check(pending.WaitOne(3000)); server.RespondToApproval(false);
                    Packet error = client.ReadNonHeartbeat(); Check(error.Kind == 127 && StrictJson.String(StrictJson.Parse(error.Payload, "code"), "code") == "declined");
                    Check(server.WaitStopped(4000)); Check(media.Opened == 0 && sink.Events.Count == 0);
                }
            }
        }
        private static void TlsExpired()
        {
            long clock = 0;
            Invitation invitation = new Invitation(delegate { return Interlocked.Read(ref clock); });
            FakeMediaFactory media = new FakeMediaFactory();
            using (HostServer server = Server(media, new FakeInput(), invitation))
            {
                string token = Token(server), pin = server.Pin; server.Start();
                using (TlsClient client = new TlsClient(server, pin))
                {
                    Interlocked.Exchange(ref clock, 120L * Stopwatch.Frequency);
                    client.Send(1, Hello(token)); Packet error = client.Read();
                    Check(error.Kind == 127 && StrictJson.String(StrictJson.Parse(error.Payload, "code"), "code") == "expired");
                    Check(server.WaitStopped(4000)); Check(media.Opened == 0);
                }
            }
        }
        private static void TlsSingleUse()
        {
            FakeMediaFactory media = new FakeMediaFactory();
            using (ManualResetEvent pending = new ManualResetEvent(false))
            using (HostServer server = Server(media, new FakeInput(), null))
            {
                server.ApprovalRequested = delegate { pending.Set(); };
                string token = Token(server), pin = server.Pin; server.Start();
                using (TlsClient first = new TlsClient(server, pin))
                {
                    first.Send(1, Hello(token)); Check(pending.WaitOne(3000));
                    Reject(delegate { server.GetInvitation(); });
                    bool secondFailed = false;
                    try { using (TlsClient second = new TlsClient(server, pin)) { second.Send(1, Hello(token)); } }
                    catch (SocketException) { secondFailed = true; } catch (IOException) { secondFailed = true; } catch (AuthenticationException) { secondFailed = true; }
                    // Listener is closed atomically after the first authenticated claim.
                    Check(secondFailed); server.Stop(); Check(server.WaitStopped(4000)); Check(media.Opened == 0);
                }
            }
        }
        private static void TlsWrongToken()
        {
            FakeMediaFactory media = new FakeMediaFactory(); FakeInput sink = new FakeInput();
            using (HostServer server = Server(media, sink, null))
            {
                string validToken = Token(server);
                byte[] wrong = NativeProtocol.DecodeToken(validToken); wrong[0] ^= 1;
                string pin = server.Pin; int approvals = 0;
                server.ApprovalRequested = delegate { Interlocked.Increment(ref approvals); }; server.Start();
                using (TlsClient client = new TlsClient(server, pin))
                {
                    client.Send(1, Hello(NativeProtocol.Base64Url(wrong))); Packet error = client.Read();
                    Check(error.Kind == 127 && StrictJson.String(StrictJson.Parse(error.Payload, "code"), "code") == "auth");
                    Check(approvals == 0 && media.Opened == 0 && sink.Events.Count == 0);
                }
                server.ApprovalRequested = delegate { Interlocked.Increment(ref approvals); server.RespondToApproval(true); };
                using (TlsClient legitimate = new TlsClient(server, pin))
                {
                    legitimate.Send(1, Hello(validToken)); Check(legitimate.Read().Kind == 2);
                    Check(approvals == 1 && media.Opened == 1);
                    server.Stop(); Check(server.WaitStopped(4000));
                }
            }
        }
        private static void TlsDisconnect(bool malformed)
        {
            FakeMediaFactory media = new FakeMediaFactory(); FakeInput sink = new FakeInput();
            using (HostServer server = Server(media, sink, null))
            {
                server.ApprovalRequested = delegate { server.RespondToApproval(true); };
                string token = Token(server), pin = server.Pin; server.Start();
                using (TlsClient client = new TlsClient(server, pin))
                {
                    client.Send(1, Hello(token)); Check(client.Read().Kind == 2);
                    client.Send(0x20, Key(1, 30).Payload); Check(sink.Down.WaitOne(3000));
                    if (malformed) client.Send(0x22, new byte[] { 7, 0, 0, 0, 0 });
                    else client.Client.Close();
                    Check(server.WaitStopped(4000));
                    Check(sink.Events.Contains("key:30:up") && media.Closed == 1);
                }
            }
        }
        private static void TlsDelayedApproval()
        {
            FakeMediaFactory media = new FakeMediaFactory(); FakeInput sink = new FakeInput();
            using (ManualResetEvent pending = new ManualResetEvent(false))
            using (HostServer server = Server(media, sink, null))
            {
                server.ApprovalRequested = delegate { pending.Set(); };
                string token = Token(server), pin = server.Pin; server.Start();
                using (TlsClient client = new TlsClient(server, pin))
                {
                    client.Send(1, Hello(token)); Check(pending.WaitOne(3000));
                    Stopwatch waiting = Stopwatch.StartNew();
                    for (int i = 0; i < 6; ++i)
                    {
                        Packet heartbeat = client.Read(); Check(heartbeat.Kind == 4 && heartbeat.Payload.Length == 0);
                        Check(media.Opened == 0 && sink.Events.Count == 0 && !server.IsActive);
                    }
                    Check(waiting.ElapsedMilliseconds >= 10500);
                    server.RespondToApproval(true); Check(client.ReadNonHeartbeat().Kind == 2); Check(media.Opened == 1);
                    server.Stop(); Check(server.WaitStopped(4000));
                }
            }
        }
        private sealed class FakeInput : IInputSink
        {
            internal readonly List<string> Events = new List<string>();
            internal readonly ManualResetEvent Down = new ManualResetEvent(false);
            internal string LastText;
            internal ushort FailScan;
            public bool Key(ushort scan, bool extended, bool down)
            {
                lock (Events)
                {
                    if (scan == FailScan) return false;
                    Events.Add("key:" + scan + (down ? ":down" : ":up")); if (down) Down.Set(); return true;
                }
            }
            public bool Text(string text) { LastText = text; lock (Events) Events.Add("text"); return true; }
            public bool Pointer(byte action, ushort x, ushort y, CaptureRectangle rectangle) { lock (Events) Events.Add("pointer:" + action); return true; }
            public bool ReleaseButton(byte button) { lock (Events) Events.Add("pointer:" + (button * 2)); return true; }
            public bool Wheel(int vertical, int horizontal) { lock (Events) Events.Add("wheel"); return true; }
        }
        private sealed class FakeMediaFactory : IMediaFactory
        {
            internal int Opened, Closed;
            internal bool SameThread = true;
            public IMediaSource Open() { Interlocked.Increment(ref Opened); return new FakeMedia(this); }
            private sealed class FakeMedia : IMediaSource
            {
                private readonly FakeMediaFactory owner;
                private readonly int thread;
                internal FakeMedia(FakeMediaFactory owner) { this.owner = owner; thread = Thread.CurrentThread.ManagedThreadId; }
                public MediaInfo Info { get { return new MediaInfo { Width = 1280, Height = 720, Fps = 60, Bitrate = 12000000, DesktopWidth = 1920, DesktopHeight = 1080, HardwareEncoder = 1 }; } }
                public int Read(byte[] buffer, out uint written, out uint flags, out ulong timestamp)
                {
                    owner.SameThread &= thread == Thread.CurrentThread.ManagedThreadId;
                    Thread.Sleep(20); written = 0; flags = 0; timestamp = 0; return 1;
                }
                public void Dispose() { owner.SameThread &= thread == Thread.CurrentThread.ManagedThreadId; Interlocked.Increment(ref owner.Closed); }
            }
        }
    }
}
