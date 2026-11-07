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
        private static int audioFixtures, audioTlsFixtures, audioCaptureFixtures, audioHostFixtures;
        private static void AudioReject(Action action)
        {
            bool rejected = false;
            try { action(); } catch (NativeAudioException) { rejected = true; }
            Check(rejected);
        }
        private static void AudioChecks()
        {
            AudioStage("protocol"); AudioProtocolChecks();
            AudioStage("authenticated-capture"); AudioAuthenticatedCapture();
            AudioStage("silence-heartbeat"); AudioSilenceHeartbeat();
            AudioStage("wrong-authentication"); AudioWrongAuthentication();
            AudioStage("wrong-peer"); AudioWrongPeer();
            AudioStage("stopped-before-authentication"); AudioStoppedBeforeAuthentication();
            AudioStage("revoked-before-hello"); AudioRevokedBeforeHello();
            AudioStage("start-lifecycle"); AudioServerStartLifecycle();
            AudioStage("host-consent-disabled"); AudioHostConsent(false);
            AudioStage("host-consent-enabled"); AudioHostConsent(true);
            AudioStage("host-approval-cancelled"); AudioHostApprovalCancelled();
        }
        // Callers pass only authored literals; diagnostics never include a
        // token, certificate, endpoint, OS error text or captured data.
        private static void AudioStage(string substage) { stage = "optional-playback-audio/" + substage; }
        private static void WriteSyntheticAudioHello(Stream stream, byte[] key)
        {
            byte[] payload = NativeAudioProtocol.Hello(key);
            try
            {
                if (payload.Length < 1 || payload.Length > 256) throw new NativeAudioException("protocol");
                // NativeProtocol.Write is host-to-viewer only and deliberately
                // rejects kind1. This independent client writes its bounded
                // Hello envelope without widening the main writer allowlist.
                byte[] header = new byte[5]; header[0] = 1;
                NativeProtocol.Put32(header, 1, (uint)payload.Length);
                stream.Write(header, 0, header.Length); stream.Write(payload, 0, payload.Length);
            }
            finally { Array.Clear(payload, 0, payload.Length); }
        }
        private static void AudioProtocolChecks()
        {
            byte[] media = new byte[32]; for (int i = 0; i < media.Length; ++i) media[i] = (byte)i;
            byte[] key = NativeAudioProtocol.DeriveKey(media);
            Check(NativeProtocol.Base64Url(key) == "EXzCDp5VzgU5ELME1HJ5wjXGir85QbvzSypBhAW_Yrs");
            Check(NativeAudioProtocol.Authenticate(NativeAudioProtocol.Hello(key), key));
            using (MemoryStream helloFrame = new MemoryStream())
            {
                WriteSyntheticAudioHello(helloFrame, key); byte[] envelope = helloFrame.ToArray();
                byte[] payload = NativeAudioProtocol.Hello(key);
                Check(envelope[0] == 1 && NativeProtocol.U32(envelope, 1) == payload.Length && envelope.Length == payload.Length + 5);
                for (int i = 0; i < payload.Length; ++i) Check(envelope[i + 5] == payload[i]);
                helloFrame.Position = 0; Packet decoded = NativeAudioProtocol.ReadHello(helloFrame);
                Check(decoded.Kind == 1 && NativeAudioProtocol.Authenticate(decoded.Payload, key) && helloFrame.Position == helloFrame.Length);
                // Preserve the existing main-stream writer's direction limit.
                Reject(delegate { NativeProtocol.Write(new MemoryStream(), 1, payload); });
            }
            byte[] wrong = (byte[])key.Clone(); wrong[0] ^= 1;
            Check(!NativeAudioProtocol.Authenticate(NativeAudioProtocol.Hello(wrong), key));
            string token = NativeProtocol.Base64Url(key);
            foreach (string invalid in new string[] {
                "{\"v\":1,\"v\":1,\"token\":\"" + token + "\"}",
                "{\"v\":1,\"token\":\"" + token + "\",\"extra\":true}",
                "{\"v\":2,\"token\":\"" + token + "\"}",
                "{\"v\":1,\"token\":\"" + new string('_', 43) + "\"}",
                "{\"v\":1,\"token\":\"" + token + "=\"}" })
                AudioReject(delegate { NativeAudioProtocol.Authenticate(Bytes(invalid), key); });
            AudioReject(delegate { NativeAudioProtocol.ReadHello(new MemoryStream(new byte[] { 1, 0xff, 0xff, 0xff, 0xff })); });
            AudioReject(delegate { NativeAudioProtocol.ReadHello(new MemoryStream(new byte[] { 2, 0, 0, 0, 1, 0 })); });
            byte[] pcm = new byte[NativeAudioProtocol.MaximumPcmBytes]; pcm[0] = 0xff; pcm[1] = 0x7f;
            byte[] first = NativeAudioProtocol.Pcm(1, 400, pcm, 960);
            NativeAudioProtocol.ValidatePcm(first, 0, 0); Check(first.Length == 3860 && first[20] == 0xff && first[21] == 0x7f);
            byte[] gap = NativeAudioProtocol.Pcm(2, 2000, pcm, 1); NativeAudioProtocol.ValidatePcm(gap, 1, 1360); Check(true);
            AudioReject(delegate { NativeAudioProtocol.ValidatePcm(first, 1, 0); });
            AudioReject(delegate { NativeAudioProtocol.ValidatePcm(gap, 1, 2001); });
            AudioReject(delegate { NativeAudioProtocol.Pcm(0, 0, pcm, 1); });
            AudioReject(delegate { NativeAudioProtocol.Pcm(1, 0, pcm, 961); });
            AudioReject(delegate { NativeAudioProtocol.Pcm(1, ulong.MaxValue, pcm, 1); });
            byte[] malformed = (byte[])first.Clone(); NativeProtocol.Put32(malformed, 16, 959);
            AudioReject(delegate { NativeAudioProtocol.ValidatePcm(malformed, 0, 0); });
            using (MemoryStream framed = new MemoryStream())
            {
                NativeAudioProtocol.Write(framed, 2, NativeAudioProtocol.Ready());
                NativeAudioProtocol.Write(framed, 3, first); NativeAudioProtocol.Write(framed, 4, new byte[0]);
                Check(framed.Length > first.Length);
                AudioReject(delegate { NativeAudioProtocol.Write(framed, 4, new byte[1]); });
                AudioReject(delegate { NativeAudioProtocol.Write(framed, 5, new byte[0]); });
            }
            foreach (string code in new string[] { "auth", "closed", "unavailable", "protocol", "timeout" })
                Check(StrictJson.String(StrictJson.Parse(NativeAudioProtocol.Error(code), "code"), "code") == code);
            ++audioFixtures;
        }
        private sealed class SyntheticAudioFactory : IAudioCaptureFactory
        {
            internal int Opens, Reads, Closes, OwnerMismatch;
            internal readonly bool Quiet;
            internal SyntheticAudioFactory(bool quiet = false) { Quiet = quiet; }
            public IAudioCapture Open()
            {
                if (Thread.CurrentThread.GetApartmentState() != ApartmentState.MTA) Interlocked.Exchange(ref OwnerMismatch, 1);
                Interlocked.Increment(ref Opens); return new SyntheticAudioCapture(this);
            }
        }
        private sealed class SyntheticAudioCapture : IAudioCapture
        {
            private readonly SyntheticAudioFactory factory;
            private readonly int owner = Thread.CurrentThread.ManagedThreadId;
            private bool sent;
            internal SyntheticAudioCapture(SyntheticAudioFactory factory) { this.factory = factory; }
            public int Read(byte[] pcm, out int frames, out ulong firstSampleIndex)
            {
                if (owner != Thread.CurrentThread.ManagedThreadId) Interlocked.Exchange(ref factory.OwnerMismatch, 1);
                Interlocked.Increment(ref factory.Reads); frames = 0; firstSampleIndex = 0;
                if (factory.Quiet || sent) { Thread.Sleep(10); return 1; }
                sent = true; frames = 960; firstSampleIndex = 400;
                for (int i = 0; i < frames * 4; ++i) pcm[i] = (byte)(i & 127);
                return 0;
            }
            public void Dispose()
            {
                if (owner != Thread.CurrentThread.ManagedThreadId) Interlocked.Exchange(ref factory.OwnerMismatch, 1);
                Interlocked.Increment(ref factory.Closes);
            }
        }
        private sealed class AudioTlsClient : IDisposable
        {
            internal readonly TcpClient Client;
            internal readonly SslStream Stream;
            internal AudioTlsClient(int port, string pin, IPAddress source = null)
            {
                Client = new TcpClient(AddressFamily.InterNetwork);
                if (source != null) Client.Client.Bind(new IPEndPoint(source, 0));
                try
                {
                    Client.Connect(IPAddress.Loopback, port); Client.NoDelay = true;
                    Client.SendTimeout = Client.ReceiveTimeout = 4000;
                    Stream = new SslStream(Client.GetStream(), false, delegate(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors)
                    { return RunCertificate.VerifyPinned(cert, errors, pin); });
                    Stream.ReadTimeout = Stream.WriteTimeout = 4000;
                    Stream.AuthenticateAsClient("knot-native", new X509CertificateCollection(), SslProtocols.Tls12, false);
                    ++audioTlsFixtures;
                }
                catch { Client.Close(); throw; }
            }
            internal void Hello(byte[] key) { WriteSyntheticAudioHello(Stream, key); }
            internal Packet Read()
            {
                byte[] header = NativeProtocol.ReadExactly(Stream, 5); uint size = NativeProtocol.U32(header, 1);
                if (size > NativeAudioProtocol.MaximumPayload) throw new NativeAudioException("protocol");
                return new Packet(header[0], NativeProtocol.ReadExactly(Stream, (int)size));
            }
            public void Dispose() { try { if (Stream != null) Stream.Dispose(); } finally { Client.Close(); } }
        }
        private static NativeAudioServer NewAudioServer(RunCertificate certificate, byte[] key, Func<bool> active, SyntheticAudioFactory factory)
        {
            NativeAudioServer server = new NativeAudioServer(IPAddress.Loopback, IPAddress.Loopback, certificate.Certificate,
                key, active, factory, null, true, 0);
            server.Start(); return server;
        }
        private static void WaitAudio(Func<bool> done)
        {
            Stopwatch clock = Stopwatch.StartNew();
            while (!done() && clock.ElapsedMilliseconds < 4000) Thread.Sleep(10);
            Check(done());
        }
        private static void AudioAuthenticatedCapture()
        {
            int active = 1; byte[] key = NativeAudioProtocol.DeriveKey(new byte[32]);
            SyntheticAudioFactory factory = new SyntheticAudioFactory();
            using (RunCertificate certificate = new RunCertificate())
            using (NativeAudioServer server = NewAudioServer(certificate, key, delegate { return Interlocked.CompareExchange(ref active, 0, 0) == 1; }, factory))
            {
                for (int connection = 1; connection <= 2; ++connection)
                {
                    AudioStage(connection == 1 ? "capture-first-tls" : "capture-reconnect-tls");
                    using (AudioTlsClient client = new AudioTlsClient(server.Port, certificate.Pin))
                    {
                        AudioStage(connection == 1 ? "capture-first-hello" : "capture-reconnect-hello");
                        Check(factory.Opens == connection - 1); client.Hello(key);
                        AudioStage(connection == 1 ? "capture-first-ready" : "capture-reconnect-ready");
                        Packet ready = client.Read(); Check(ready.Kind == 2);
                        StrictJson.Parse(ready.Payload, "v", "codec", "sampleRate", "channels");
                        Packet pcm = client.Read(); Check(pcm.Kind == 3);
                        NativeAudioProtocol.ValidatePcm(pcm.Payload, 0, 0);
                        Check(NativeAudioProtocol.U64(pcm.Payload, 8) == 400 && pcm.Payload[20] == 0 && pcm.Payload[21] == 1);
                        if (connection == 2)
                        {
                            AudioStage("capture-revocation-disposal");
                            Interlocked.Exchange(ref active, 0); WaitAudio(delegate { return factory.Closes == 2; });
                        }
                    }
                    AudioStage(connection == 1 ? "capture-first-disposal" : "capture-reconnect-disposal");
                    WaitAudio(delegate { return factory.Closes == connection; });
                }
                Check(factory.Opens == 2 && factory.OwnerMismatch == 0); audioCaptureFixtures += factory.Closes;
            }
            ++audioFixtures;
        }
        private static void AudioSilenceHeartbeat()
        {
            byte[] key = new byte[32]; SyntheticAudioFactory factory = new SyntheticAudioFactory(true);
            using (RunCertificate certificate = new RunCertificate())
            using (NativeAudioServer server = NewAudioServer(certificate, key, delegate { return true; }, factory))
            {
                using (AudioTlsClient client = new AudioTlsClient(server.Port, certificate.Pin))
                {
                    client.Hello(key); Check(client.Read().Kind == 2);
                    Stopwatch idle = Stopwatch.StartNew(); Packet heartbeat = client.Read();
                    Check(heartbeat.Kind == 4 && heartbeat.Payload.Length == 0 && idle.ElapsedMilliseconds >= 800 && idle.ElapsedMilliseconds < 3000);
                    server.Stop(); WaitAudio(delegate { return factory.Closes == 1; });
                }
                Check(factory.OwnerMismatch == 0); ++audioCaptureFixtures;
            }
            ++audioFixtures;
        }
        private static void AudioWrongAuthentication()
        {
            byte[] key = new byte[32], wrong = new byte[32]; wrong[0] = 1;
            SyntheticAudioFactory factory = new SyntheticAudioFactory();
            using (RunCertificate certificate = new RunCertificate())
            using (NativeAudioServer server = NewAudioServer(certificate, key, delegate { return true; }, factory))
            using (AudioTlsClient client = new AudioTlsClient(server.Port, certificate.Pin))
            {
                client.Hello(wrong); Packet error = client.Read(); Check(error.Kind == 127);
                Check(StrictJson.String(StrictJson.Parse(error.Payload, "code"), "code") == "auth");
                Check(factory.Opens == 0 && factory.Reads == 0 && factory.Closes == 0);
            }
            ++audioFixtures;
        }
        private static void AudioWrongPeer()
        {
            SyntheticAudioFactory factory = new SyntheticAudioFactory();
            using (RunCertificate certificate = new RunCertificate())
            using (NativeAudioServer server = NewAudioServer(certificate, new byte[32], delegate { return true; }, factory))
            {
                bool rejected = false;
                try { using (AudioTlsClient client = new AudioTlsClient(server.Port, certificate.Pin, IPAddress.Parse("127.0.0.2"))) { } }
                catch (IOException) { rejected = true; } catch (AuthenticationException) { rejected = true; }
                Check(rejected && factory.Opens == 0);
            }
            ++audioFixtures;
        }
        private static void AudioStoppedBeforeAuthentication()
        {
            SyntheticAudioFactory factory = new SyntheticAudioFactory();
            using (RunCertificate certificate = new RunCertificate())
            using (NativeAudioServer server = NewAudioServer(certificate, new byte[32], delegate { return true; }, factory))
            using (TcpClient raw = new TcpClient())
            {
                raw.Connect(IPAddress.Loopback, server.Port); Thread.Sleep(50);
                Stopwatch clock = Stopwatch.StartNew(); server.Stop(); raw.ReceiveTimeout = 1000;
                bool closed = false; try { closed = raw.GetStream().ReadByte() == -1; } catch (IOException) { closed = true; }
                Check(closed && clock.ElapsedMilliseconds < 1500 && factory.Opens == 0);
            }
            ++audioFixtures;
        }
        private static void AudioRevokedBeforeHello()
        {
            int active = 1; SyntheticAudioFactory factory = new SyntheticAudioFactory();
            using (RunCertificate certificate = new RunCertificate())
            using (NativeAudioServer server = NewAudioServer(certificate, new byte[32], delegate { return Interlocked.CompareExchange(ref active, 0, 0) == 1; }, factory))
            using (AudioTlsClient client = new AudioTlsClient(server.Port, certificate.Pin))
            {
                Interlocked.Exchange(ref active, 0); client.Hello(new byte[32]);
                bool closed = false; try { closed = client.Stream.ReadByte() == -1; } catch (IOException) { closed = true; }
                Check(closed && factory.Opens == 0);
            }
            ++audioFixtures;
        }
        private static void AudioServerStartLifecycle()
        {
            SyntheticAudioFactory factory = new SyntheticAudioFactory();
            using (RunCertificate certificate = new RunCertificate())
            {
                NativeAudioServer denied = new NativeAudioServer(IPAddress.Loopback, IPAddress.Loopback, certificate.Certificate,
                    new byte[32], delegate { return false; }, factory, null, true, 0);
                AudioReject(denied.Start); denied.Dispose(); denied.Stop(); AudioReject(denied.Start);
                TcpListener occupied = new TcpListener(IPAddress.Loopback, 0); occupied.Start(1);
                try
                {
                    int port = ((IPEndPoint)occupied.LocalEndpoint).Port;
                    NativeAudioServer conflict = new NativeAudioServer(IPAddress.Loopback, IPAddress.Loopback, certificate.Certificate,
                        new byte[32], delegate { return true; }, factory, null, true, port);
                    bool rejected = false; try { conflict.Start(); } catch (SocketException) { rejected = true; }
                    conflict.Stop(); conflict.Dispose(); AudioReject(conflict.Start);
                    Check(rejected && factory.Opens == 0);
                }
                finally { occupied.Stop(); }
            }
            ++audioFixtures;
        }
        private static void AudioHostConsent(bool allowed)
        {
            SyntheticAudioFactory audio = new SyntheticAudioFactory(); FakeMediaFactory media = new FakeMediaFactory();
            using (ManualResetEvent pending = new ManualResetEvent(false))
            using (HostServer host = new HostServer(IPAddress.Loopback, 0, media, new FakeInput(), true, null,
                false, Stopwatch.GetTimestamp, "Synthetic audio PC", allowAudio: allowed, audioFactory: audio))
            {
                host.ApprovalRequested = delegate { pending.Set(); };
                string token = Token(host); byte[] key = NativeAudioProtocol.DeriveKey(NativeProtocol.DecodeToken(token));
                host.Start();
                using (TlsClient main = new TlsClient(host, host.Pin))
                {
                    main.Send(1, Hello(token)); Check(pending.WaitOne(3000));
                    Check(audio.Opens == 0 && media.Opened == 0 && host.AudioPort == 0);
                    host.RespondToApproval(true); Check(main.ReadNonHeartbeat().Kind == 2);
                    Check(host.IsActive && media.Opened == 1 && audio.Opens == 0);
                    if (allowed)
                    {
                        Check(host.AudioPort > 0);
                        using (AudioTlsClient sidecar = new AudioTlsClient(host.AudioPort, host.Pin))
                        {
                            Check(audio.Opens == 0); sidecar.Hello(key); Check(sidecar.Read().Kind == 2);
                            Packet pcm = sidecar.Read(); Check(pcm.Kind == 3); NativeAudioProtocol.ValidatePcm(pcm.Payload, 0, 0);
                            Check(audio.Opens == 1 && media.Opened == 1);
                            host.Stop(); Check(host.WaitStopped(4000)); WaitAudio(delegate { return audio.Closes == 1; });
                            Check(audio.OwnerMismatch == 0 && media.Closed == 1 && host.AudioPort == 0);
                            ++audioCaptureFixtures;
                        }
                    }
                    else
                    {
                        Check(host.AudioPort == 0); host.Stop(); Check(host.WaitStopped(4000));
                        Check(audio.Opens == 0 && audio.Reads == 0 && audio.Closes == 0 && media.Closed == 1);
                    }
                }
                Array.Clear(key, 0, key.Length);
            }
            ++audioHostFixtures; ++audioFixtures;
        }
        private static void AudioHostApprovalCancelled()
        {
            SyntheticAudioFactory audio = new SyntheticAudioFactory(); FakeMediaFactory media = new FakeMediaFactory();
            using (ManualResetEvent pending = new ManualResetEvent(false))
            using (HostServer host = new HostServer(IPAddress.Loopback, 0, media, new FakeInput(), true, null,
                false, Stopwatch.GetTimestamp, "Synthetic audio cancellation", allowAudio: true, audioFactory: audio))
            {
                host.ApprovalRequested = delegate { pending.Set(); };
                string token = Token(host); host.Start();
                using (TlsClient main = new TlsClient(host, host.Pin))
                {
                    main.Send(1, Hello(token)); Check(pending.WaitOne(3000)); host.Stop();
                    Check(host.WaitStopped(4000));
                    Check(audio.Opens == 0 && audio.Reads == 0 && audio.Closes == 0 && media.Opened == 0 && host.AudioPort == 0);
                }
            }
            ++audioHostFixtures; ++audioFixtures;
        }
    }
}
