// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Threading;

namespace Knot.NativePreview
{
    internal static partial class NativeChecks
    {
        private enum NumberConnectionEnd { Disconnect, Silence, OwnerStop, MalformedInput, UnsafeInput }
        private static void RegisteredTransportRecoveryChecks()
        {
            RecoveryFixtureBoundaryChecks();
            TemporaryNumberConnectionEnd(true, NumberConnectionEnd.Disconnect);
            TemporaryNumberConnectionEnd(false, NumberConnectionEnd.Disconnect);
            TemporaryNumberConnectionEnd(true, NumberConnectionEnd.Silence);
            TemporaryNumberConnectionEnd(false, NumberConnectionEnd.Silence);
            TemporaryNumberConnectionEnd(true, NumberConnectionEnd.OwnerStop);
            TemporaryNumberConnectionEnd(true, NumberConnectionEnd.MalformedInput);
            TemporaryNumberConnectionEnd(true, NumberConnectionEnd.UnsafeInput);
            foreach (int status in new int[] { -1, -2, -3, -4 }) TemporaryNumberMediaFailure(status);
            TerminalInputWinsConcurrentTransportFailure();
            RecoveryTrustedProofChecks();
        }
        private static void RecoveryFixtureBoundaryChecks()
        {
            bool rejected = false;
            try
            {
                using (HostServer server = new HostServer(IPAddress.Parse("192.168.50.123"), 48631,
                    new FakeMediaFactory(), new FakeInput(), false, null, true, Stopwatch.GetTimestamp,
                    "Synthetic validation", syntheticRegisteredDevices: true)) { }
            }
            catch (ArgumentException) { rejected = true; }
            Check(rejected);
            rejected = false;
            try
            {
                using (HostServer server = new HostServer(IPAddress.Parse("192.168.50.123"), 48631,
                    new FakeMediaFactory(), new FakeInput(), true, null, true, Stopwatch.GetTimestamp,
                    "Synthetic store boundary", syntheticTrustedDevices: new NativeTrustedDeviceStore(new MemoryTrustStorage()))) { }
            }
            catch (ArgumentException) { rejected = true; }
            Check(rejected);
        }
        private static HostServer RecoveryHost(IMediaFactory media, FakeInput sink, bool saved, Func<long> inputClock = null)
        {
            // Inject only the existence of an older record. Never open the user's
            // trust storage, persistent certificate, desktop, audio or input APIs.
            return new HostServer(IPAddress.Loopback, 0, media, sink, true, null, true,
                Stopwatch.GetTimestamp, "Synthetic Windows", inputClock: inputClock, syntheticRegisteredDevices: saved);
        }
        private static string RecoveryNumberOffer(HostServer server)
        {
            Check(!server.MayResumeRegisteredConnection && !server.IsRegisteredSession);
            server.Start();
            string offer = Enroll(server, Discover(server), server.EnrollmentCode, false);
            Check(server.EnrollmentGrantsIssued == 1 && !server.IsRegisteredSession);
            return offer;
        }
        private static void TemporaryNumberConnectionEnd(bool saved, NumberConnectionEnd ending)
        {
            FakeInput sink = new FakeInput(); long inputTicks = 0;
            using (TerminalStatusMediaFactory media = new TerminalStatusMediaFactory())
            using (HostServer server = RecoveryHost(media, sink, saved, delegate { return Interlocked.Read(ref inputTicks); }))
            {
                Check(server.HasRegisteredDevices == saved);
                string offer = RecoveryNumberOffer(server);
                ++tlsFixtures;
                try
                {
                    using (TlsClient client = new TlsClient(server, OfferedPin(offer)))
                    {
                        client.Send(1, Hello(StrictJson.String(InvitationObject(offer), "token")));
                        Check(client.ReadNonHeartbeat().Kind == 2 && media.Entered.WaitOne(3000));
                        Check(server.IsActive && !server.IsRegisteredSession && server.HasRegisteredDevices == saved);
                        client.Send(0x20, Key(1, 30).Payload); Check(sink.Down.WaitOne(3000));
                        switch (ending)
                        {
                            case NumberConnectionEnd.Disconnect: client.Client.Close(); break;
                            case NumberConnectionEnd.Silence: Interlocked.Exchange(ref inputTicks, 11L * Stopwatch.Frequency); break;
                            case NumberConnectionEnd.OwnerStop: server.Stop(); break;
                            case NumberConnectionEnd.MalformedInput: client.Send(0x22, new byte[] { 7, 0, 0, 0, 0 }); break;
                            case NumberConnectionEnd.UnsafeInput: sink.FailScan = 31; client.Send(0x20, Key(1, 31).Payload); break;
                        }
                        // Hold the writer inside fake capture until the reader,
                        // watchdog or owner has actually revoked this session.
                        WaitFor(delegate { return !server.IsActive; });
                        bool transport = ending == NumberConnectionEnd.Disconnect || ending == NumberConnectionEnd.Silence;
                        Check(server.MayResumeRegisteredConnection == (saved && transport));
                        if (saved && transport)
                        {
                            // A clipboard worker can pass Allowed just before
                            // transport Stop. Its subsequent closed callback is
                            // cancellation, never a new unsafe-input failure.
                            Reject(delegate { server.ApplyClipboardShortcut(1); });
                            Check(server.MayResumeRegisteredConnection);
                        }
                        media.Continue.Set(); Check(server.WaitStopped(4000));
                        Check(server.MayResumeRegisteredConnection == (saved && transport));
                        Check(media.Closed == 1 && sink.Events.Contains("key:30:up"));
                        Check(!server.IsActive && !server.IsRegisteredSession && server.EnrollmentCode == "");
                        if (!transport)
                        {
                            int reads = 0, constructions = 0;
                            Check(!RegisteredConnectionResume.TryResume(ending != NumberConnectionEnd.OwnerStop, false,
                                server.MayResumeRegisteredConnection, delegate { ++constructions; }, delegate { ++reads; return true; }));
                            Check(reads == 0 && constructions == 0);
                        }
                    }
                }
                finally { media.Continue.Set(); }
            }
        }
        private static void TemporaryNumberMediaFailure(int status)
        {
            FakeInput sink = new FakeInput();
            using (RecoveryFailureMediaFactory media = new RecoveryFailureMediaFactory(status))
            using (HostServer server = RecoveryHost(media, sink, true))
            {
                string offer = RecoveryNumberOffer(server); ++tlsFixtures;
                using (TlsClient client = new TlsClient(server, OfferedPin(offer)))
                {
                    client.Send(1, Hello(StrictJson.String(InvitationObject(offer), "token")));
                    Check(client.ReadNonHeartbeat().Kind == 2 && media.Entered.WaitOne(3000));
                    media.Continue.Set(); Packet error = client.ReadNonHeartbeat();
                    Check(error.Kind == 127 && StrictJson.String(StrictJson.Parse(error.Payload, "code"), "code") == (status == -3 ? "encoder" : "capture"));
                    Check(server.WaitStopped(4000) && !server.IsActive && !server.MayResumeRegisteredConnection);
                    Check(media.Closed == 1 && sink.Events.Count == 0 && !server.IsRegisteredSession);
                }
            }
        }
        private sealed class RecoveryFailureMediaFactory : IMediaFactory, IDisposable
        {
            private readonly int status;
            internal readonly ManualResetEvent Entered = new ManualResetEvent(false), Continue = new ManualResetEvent(false);
            internal int Closed;
            internal RecoveryFailureMediaFactory(int status) { this.status = status; }
            public IMediaSource Open() { return new Source(this); }
            public void Dispose() { Continue.Set(); Entered.Dispose(); Continue.Dispose(); }
            private sealed class Source : IMediaSource
            {
                private readonly RecoveryFailureMediaFactory owner;
                internal Source(RecoveryFailureMediaFactory owner) { this.owner = owner; }
                public MediaInfo Info { get { return new MediaInfo { Width = 1280, Height = 720, Fps = 60, Bitrate = 12000000, DesktopWidth = 1920, DesktopHeight = 1080, HardwareEncoder = 1 }; } }
                public int Read(byte[] buffer, out uint written, out uint flags, out ulong timestamp)
                {
                    owner.Entered.Set();
                    if (!owner.Continue.WaitOne(15000)) throw new InvalidOperationException("Fresh synthetic media failure wait expired.");
                    if (owner.status == 0) throw new IOException("Fresh synthetic concurrent transport failure.");
                    written = flags = 0; timestamp = 0; return owner.status;
                }
                public void Dispose() { Interlocked.Increment(ref owner.Closed); }
            }
        }
        private static void TerminalInputWinsConcurrentTransportFailure()
        {
            FakeInput sink = new FakeInput();
            using (ManualResetEvent terminalNotice = new ManualResetEvent(false))
            using (ManualResetEvent releaseNotice = new ManualResetEvent(false))
            using (ManualResetEvent noticeReturned = new ManualResetEvent(false))
            using (RecoveryFailureMediaFactory media = new RecoveryFailureMediaFactory(0))
            using (HostServer server = RecoveryHost(media, sink, true))
            {
                server.StatusChanged = delegate(string text)
                {
                    if (text != HostServer.Guidance("protocol")) return;
                    terminalNotice.Set();
                    try { Check(releaseNotice.WaitOne(8000)); }
                    finally { noticeReturned.Set(); }
                };
                string offer = RecoveryNumberOffer(server); ++tlsFixtures;
                try
                {
                    using (TlsClient client = new TlsClient(server, OfferedPin(offer)))
                    {
                        client.Send(1, Hello(StrictJson.String(InvitationObject(offer), "token")));
                        Check(client.ReadNonHeartbeat().Kind == 2 && media.Entered.WaitOne(3000));
                        client.Send(0x22, new byte[] { 7, 0, 0, 0, 0 });
                        Check(terminalNotice.WaitOne(3000));
                        // The reader has reported a terminal protocol failure but
                        // is deliberately held before Stop. The writer's IO
                        // catch must not convert that failure into recovery.
                        Check(server.IsActive && !server.MayResumeRegisteredConnection);
                        media.Continue.Set(); Check(server.WaitStopped(4000));
                        Check(!server.MayResumeRegisteredConnection && !server.IsActive && media.Closed == 1);
                        releaseNotice.Set(); Check(noticeReturned.WaitOne(3000));
                    }
                }
                finally { releaseNotice.Set(); media.Continue.Set(); }
            }
        }
        private static void RecoveryTrustedProofChecks()
        {
            byte[] key = new byte[32]; for (int i = 0; i < key.Length; ++i) key[i] = 13;
            string id = NativeProtocol.Base64Url(new byte[32]);
            bool revoked = false; int issued = 0, registrations = 0;
            using (RunCertificate certificate = new RunCertificate())
            using (TrustedDeviceServer server = new TrustedDeviceServer(IPAddress.Loopback, certificate.Certificate, certificate.Pin,
                delegate(IPAddress peer, string token, string registrationId, string name, string secret) { ++registrations; return false; },
                delegate(IPAddress peer, string name) { ++issued; return "fresh-synthetic-recovery-invitation"; }, delegate { return true; },
                syntheticLoopback: true, port: 0,
                lookupKey: delegate(string candidate) { if (revoked || candidate != id) throw new ProtocolException("auth"); return (byte[])key.Clone(); },
                revoke: delegate(string candidate) { Check(candidate == id); revoked = true; }))
            {
                server.Start();
                Check(RecoveryTrustedRequest(server, certificate.Pin, id, key, "connect", false, false).Kind == 1 && issued == 1);
                Check(RecoveryTrustedRequest(server, certificate.Pin, id, key, "connect", true, false).Kind == 127 && issued == 1);
                bool pinRejected = false;
                try { RecoveryTrustedRequest(server, new string('0', 64), id, key, "connect", false, false); }
                catch (AuthenticationException) { pinRejected = true; } catch (IOException) { pinRejected = true; }
                Check(pinRejected && issued == 1);
                Check(RecoveryTrustedRequest(server, certificate.Pin, id, key, "revoke", false, false).Kind == 1 && revoked);
                Check(RecoveryTrustedRequest(server, certificate.Pin, id, key, "connect", false, true).Kind == 127);
                Check(issued == 1 && registrations == 0 && revoked);
            }
            Array.Clear(key, 0, key.Length);
        }
        private static Packet RecoveryTrustedRequest(TrustedDeviceServer server, string pin, string id, byte[] key, string operation, bool invalid, bool revoked)
        {
            ++tlsFixtures;
            using (TcpClient client = new TcpClient())
            {
                client.Connect(IPAddress.Loopback, server.ListeningPort); client.ReceiveTimeout = client.SendTimeout = 3000;
                using (SslStream tls = new SslStream(client.GetStream(), false,
                    delegate(object sender, X509Certificate peer, X509Chain chain, SslPolicyErrors errors) { return RunCertificate.VerifyPinned(peer, errors, pin); }))
                {
                    tls.AuthenticateAsClient("knot-native", null, SslProtocols.Tls12, false);
                    TrustedWrite(tls, "{\"op\":" + StrictJson.Quote(operation) + ",\"id\":" + StrictJson.Quote(id) + ",\"name\":\"Synthetic Mac\",\"value\":\"\",\"key\":\"\"}");
                    Packet first = ReadRecoveryTrusted(tls);
                    if (revoked) { Check(first.Kind == 127); return first; }
                    Check(first.Kind == 1);
                    string nonce = StrictJson.String(StrictJson.Parse(first.Payload, "nonce"), "nonce");
                    byte[] proof = NativeTrustedDevices.Proof(key, id, nonce, "Synthetic Mac", pin, operation);
                    if (invalid) proof[0] ^= 1;
                    TrustedWrite(tls, "{\"proof\":" + StrictJson.Quote(NativeProtocol.Base64Url(proof)) + "}");
                    return ReadRecoveryTrusted(tls);
                }
            }
        }
        private static Packet ReadRecoveryTrusted(Stream stream)
        {
            byte[] header = NativeProtocol.ReadExactly(stream, 5); uint length = NativeProtocol.U32(header, 1);
            Check(length > 0 && length <= 4096);
            Packet result = new Packet(header[0], NativeProtocol.ReadExactly(stream, (int)length));
            if (result.Kind == 127) Check(StrictJson.String(StrictJson.Parse(result.Payload, "code"), "code") == "rejected");
            return result;
        }
    }
}
