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
        private static int videoControlTlsFixtures;
        private static byte[] VideoRequest(byte operation, ulong id, uint width = 0, uint height = 0, uint fps = 0, uint bitrate = 0)
        {
            byte[] bytes = new byte[26]; bytes[0] = 1; bytes[1] = operation; NativeProtocol.Put64(bytes, 2, id);
            NativeProtocol.Put32(bytes, 10, width); NativeProtocol.Put32(bytes, 14, height);
            NativeProtocol.Put32(bytes, 18, fps); NativeProtocol.Put32(bytes, 22, bitrate); return bytes;
        }
        private static byte[] VideoHello(string token, int version = 1)
        {
            string json = StrictJson.Utf8.GetString(Hello(token));
            return Bytes(json.Substring(0, json.Length - 1) + ",\"videoControlVersion\":" + version + "}");
        }
        private static string HexVideo(byte[] bytes)
        { return BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant(); }
        private static void VideoControlChecks()
        {
            byte[] vector = VideoRequest(1, 0x0102030405060708UL, 2560, 1440, 60, 20000000);
            Check(HexVideo(vector) == "0101010203040506070800000a00000005a00000003c01312d00");
            VideoControlRequest request = VideoControlProtocol.Request(vector);
            Check(request.Id == 0x0102030405060708UL && request.Config.Width == 2560 && request.Config.Height == 1440 && VideoControlProtocol.Allowed(request.Config));
            MediaInfo info = new MediaInfo { Width = 2560, Height = 1440, Fps = 60, Bitrate = 20000000 };
            Check(HexVideo(VideoControlProtocol.Status(request, 9, 1, 0, false, info, 17)) ==
                "01010102030405060708000000000000000901000000000a00000005a00000003c01312d000000000000000011");
            Reject(delegate { VideoControlProtocol.Request(new byte[25]); });
            Reject(delegate { byte[] bad = (byte[])vector.Clone(); bad[0] = 2; VideoControlProtocol.Request(bad); });
            Reject(delegate { byte[] bad = (byte[])vector.Clone(); bad[1] = 4; VideoControlProtocol.Request(bad); });
            Reject(delegate { VideoControlProtocol.Request(VideoRequest(2, 1, 1920)); });
            Reject(delegate { VideoControlProtocol.Request(VideoRequest(3, 0)); });
            Check(!VideoControlProtocol.Allowed(new MediaConfig { Width = 3840, Height = 2160, Fps = 15, Bitrate = 20000000 }));
            Check(!VideoControlProtocol.Allowed(new MediaConfig { Width = 1920, Height = 1080, Fps = 30, Bitrate = 40000001 }));
            byte[] token = EnrollmentProtocol.Random(32), parsed; bool files, video;
            string encoded = NativeProtocol.Base64Url(token);
            Check(NativeProtocol.HelloName(Hello(encoded), out parsed, out files, out video) == "Synthetic viewer" && !files && !video);
            Check(NativeProtocol.HelloName(VideoHello(encoded), out parsed, out files, out video) == "Synthetic viewer" && !files && video);
            string helloFiles = StrictJson.Utf8.GetString(VideoHello(encoded));
            NativeProtocol.HelloName(Bytes(helloFiles.Substring(0, helloFiles.Length - 1) + ",\"filesVersion\":2}"), out parsed, out files, out video);
            Check(files && video);
            Reject(delegate { NativeProtocol.HelloName(VideoHello(encoded, 2), out parsed, out files, out video); });
            Reject(delegate { NativeProtocol.HelloName(Bytes(helloFiles.Substring(0, helloFiles.Length - 1) + ",\"unknown\":1}"), out parsed, out files, out video); });
            VideoControlMailbox mailbox = new VideoControlMailbox();
            Reject(delegate { mailbox.Submit(VideoControlProtocol.Request(VideoRequest(2, 2))); });
            mailbox = new VideoControlMailbox();
            VideoControlRequest first = VideoControlProtocol.Request(VideoRequest(2, 1)); mailbox.Submit(first);
            mailbox.Submit(VideoControlProtocol.Request(VideoRequest(3, 2)));
            Reject(delegate { mailbox.Submit(VideoControlProtocol.Request(VideoRequest(3, 3))); });
            VideoControlRequest taken;
            Check(mailbox.TryTake(out taken) && object.ReferenceEquals(first, taken)); mailbox.Complete(taken);
            Check(mailbox.TryTake(out taken) && taken.Id == 2 && taken.RejectionReason == 3); mailbox.Complete(taken);
            Check(!mailbox.TryTake(out taken));
            Reject(delegate { mailbox.Submit(VideoControlProtocol.Request(VideoRequest(3, 2))); });
            VideoControlInputChecks();
            VideoControlLiveTransitions();
            VideoControlRollback(false); VideoControlRollback(true);
            VideoControlLegacyAndMalformed();
            VideoControlPauseDesktopDenial();
            VideoControlStopDuringOpen();
            VideoControlFailedResumeStaysPaused();
            VideoControlPrimeFailure();
            VideoControlDrainFailure(1, 1, "encoder");
            VideoControlDrainFailure(2, 2, "capture");
            VideoControlDrainFailure(3, 1, "encoder");
            VideoControlDrainFailure(4, 2, "encoder");
        }
        private static void VideoControlInputChecks()
        {
            FakeInput sink = new FakeInput(); InputSession input = new InputSession(sink, new CaptureRectangle(0, 0, 3840, 2160));
            input.Accept(Key(1, 30)); input.Accept(new Packet(0x22, new byte[] { 1, 0, 0, 0, 0 }));
            byte[] nonce = EnrollmentProtocol.Random(16); input.Accept(new Packet(0x26, nonce));
            using (IExplorerDragInputLease lease = input.AcquireExplorerDrag(FileProtocol.Hex(nonce)))
            {
                Check(lease.IsActive && input.Suspend() && input.IsSuspended && !lease.IsActive && !lease.Nudge() && !lease.ReleaseLeft());
                Check(sink.Events.Contains("key:30:up") && sink.Events.Contains("pointer:2"));
                int count = sink.Events.Count;
                input.Accept(Key(1, 31)); input.Accept(new Packet(0x21, Bytes("synthetic"))); input.ClipboardShortcut(2);
                Check(sink.Events.Count == count);
                bool denied = false; try { input.AcquireExplorerDrag(FileProtocol.Hex(nonce)); } catch (FileTransferException) { denied = true; }
                Check(denied); Reject(delegate { input.Accept(new Packet(0x20, new byte[] { 2, 0, 30, 0 })); });
                Check(input.Resume() && !input.IsSuspended); input.Accept(Key(1, 31)); Check(sink.Events.Count == count + 1);
            }
            input.Close(); Check(!input.Resume() && !input.Suspend() && input.IsSuspended);
            Reject(delegate { input.Accept(Key(1, 32)); });
        }
        private sealed class VideoFixtureFactory : IConfigurableMediaFactory, IDisposable
        {
            internal readonly List<string> Trace = new List<string>();
            internal readonly ManualResetEvent OpenEntered = new ManualResetEvent(false), ContinueOpen = new ManualResetEvent(true);
            internal readonly ManualResetEvent DrainEntered = new ManualResetEvent(false), ContinueDrain = new ManualResetEvent(true);
            internal int Opened, Closed, Reads, DrainReads, Active, PeakActive, Attempts, BlockAttempt, DrainFailure;
            internal bool SameThread = true;
            internal volatile bool FailRollback;
            private int ownerThread;
            public MediaConfig InitialConfig { get { return new MediaConfig { Width = 1920, Height = 1080, Fps = 60, Bitrate = 12000000 }; } }
            public IMediaSource Open() { return Open(InitialConfig); }
            public IMediaSource Open(MediaConfig config)
            {
                if (ownerThread == 0) ownerThread = Thread.CurrentThread.ManagedThreadId;
                CheckThread(); int attempt = Interlocked.Increment(ref Attempts);
                lock (Trace) Trace.Add("open:" + config.Bitrate);
                Check(Active == 0);
                if (attempt == BlockAttempt)
                { OpenEntered.Set(); if (!ContinueOpen.WaitOne(8000)) throw new InvalidOperationException("Synthetic open gate expired."); }
                if (config.Bitrate == 13000000 || FailRollback && attempt >= 2) throw new ProtocolException("encoder");
                Interlocked.Increment(ref Opened); int active = Interlocked.Increment(ref Active); PeakActive = Math.Max(PeakActive, active);
                return new Source(this, config);
            }
            private void CheckThread() { SameThread &= ownerThread == Thread.CurrentThread.ManagedThreadId && Thread.CurrentThread.GetApartmentState() == ApartmentState.MTA; }
            public void Dispose() { ContinueOpen.Set(); ContinueDrain.Set(); ContinueOpen.Dispose(); OpenEntered.Dispose(); ContinueDrain.Dispose(); DrainEntered.Dispose(); }
            private sealed class Source : IDrainableMediaSource, IAdaptiveMediaSource
            {
                private readonly VideoFixtureFactory owner;
                private readonly MediaConfig config;
                private bool first = true, draining, drained, disposed;
                internal Source(VideoFixtureFactory owner, MediaConfig config) { this.owner = owner; this.config = config; }
                public MediaInfo Info { get { return new MediaInfo { Width = config.Width, Height = config.Height, Fps = config.Fps, Bitrate = config.Bitrate,
                    DesktopWidth = 3840, DesktopHeight = 2160, HardwareEncoder = 1 }; } }
                private int Unit(byte[] buffer, bool idr, out uint written, out uint flags, out ulong timestamp)
                {
                    byte[] bytes = idr ? Join(NalFixture(1, 7, 2), Join(NalFixture(1, 8, 2), NalFixture(1, 5, 2))) : NalFixture(1, 1, 2);
                    Buffer.BlockCopy(bytes, 0, buffer, 0, bytes.Length); written = (uint)bytes.Length; flags = idr ? 1U : 0U; timestamp = 123456; return 0;
                }
                public int Read(byte[] buffer, out uint written, out uint flags, out ulong timestamp)
                {
                    owner.CheckThread(); Check(!draining && !disposed); Interlocked.Increment(ref owner.Reads);
                    if (first) { first = false; return Unit(buffer, config.Bitrate != 14000000, out written, out flags, out timestamp); }
                    Thread.Sleep(10); written = flags = 0; timestamp = 0; return 1;
                }
                public int BeginDrain()
                {
                    owner.CheckThread(); Check(!disposed && !draining); draining = true;
                    lock (owner.Trace) owner.Trace.Add("begin-drain");
                    if (owner.DrainFailure != 0)
                    {
                        owner.DrainEntered.Set();
                        if (!owner.ContinueDrain.WaitOne(8000)) throw new InvalidOperationException("Synthetic drain gate expired.");
                    }
                    return owner.DrainFailure == 1 ? -3 : 0;
                }
                public int ReadDrain(byte[] buffer, out uint written, out uint flags, out ulong timestamp)
                {
                    owner.CheckThread(); Check(draining && !disposed); Interlocked.Increment(ref owner.DrainReads);
                    if (owner.DrainFailure == 2) { written = flags = 0; timestamp = 0; return -4; }
                    if (owner.DrainFailure == 3)
                    {
                        int status = Unit(buffer, false, out written, out flags, out timestamp);
                        buffer[0] = 0xff; return status;
                    }
                    if (owner.DrainFailure == 4) { Thread.Sleep(50); written = flags = 0; timestamp = 0; return 1; }
                    if (!drained) { drained = true; return Unit(buffer, false, out written, out flags, out timestamp); }
                    written = flags = 0; timestamp = 0; return 2;
                }
                public bool TrySetQuality(uint fps, uint bitrate) { owner.CheckThread(); Check(!disposed && !draining && fps <= config.Fps && bitrate <= config.Bitrate); return true; }
                public void Dispose()
                {
                    owner.CheckThread(); Check(!disposed); disposed = true;
                    lock (owner.Trace) owner.Trace.Add("close:" + config.Bitrate);
                    Interlocked.Increment(ref owner.Closed); Interlocked.Decrement(ref owner.Active);
                }
            }
        }
        private static HostServer VideoHost(VideoFixtureFactory factory, FakeInput sink, Func<long> clock, Func<bool> desktop = null)
        {
            HostServer server = new HostServer(IPAddress.Loopback, 0, factory, sink, true, null, false, clock, "Synthetic video PC", syntheticPausedDesktopAllowed: desktop);
            server.ApprovalRequested = delegate { server.RespondToApproval(true); };
            ++tlsFixtures; ++videoControlTlsFixtures; return server;
        }
        private static Packet ReadVideoStatus(TlsClient client, List<Packet> video)
        {
            for (int i = 0; i < 100; ++i)
            {
                Packet packet = client.Read();
                if (packet.Kind == 3) { video.Add(packet); continue; }
                if (packet.Kind == 4 || packet.Kind == 0x34) continue;
                Check(packet.Kind == 0x36 && packet.Payload.Length == 45); return packet;
            }
            throw new InvalidOperationException("Synthetic video response bound exceeded.");
        }
        private static void CheckVideoStatus(Packet packet, ulong id, ulong epoch, byte outcome, byte reason, byte state, ulong next)
        {
            byte[] p = packet.Payload;
            Check(p[0] == 1 && NativeProtocol.U64(p, 2) == id && NativeProtocol.U64(p, 10) == epoch &&
                p[18] == outcome && p[19] == reason && p[20] == state && NativeProtocol.U64(p, 37) == next);
        }
        private static void VideoControlLiveTransitions()
        {
            long ticks = 0; FakeInput sink = new FakeInput();
            using (VideoFixtureFactory factory = new VideoFixtureFactory())
            using (HostServer server = VideoHost(factory, sink, delegate { return Interlocked.Read(ref ticks); }))
            {
                string token = Token(server); server.Start();
                using (TlsClient client = new TlsClient(server, server.Pin))
                {
                    client.Send(1, VideoHello(token)); Packet ready = client.ReadNonHeartbeat(); Check(ready.Kind == 2);
                    Check(StrictJson.Utf8.GetString(ready.Payload).Contains("\"videoControlVersion\":1") && StrictJson.Utf8.GetString(ready.Payload).Contains("\"qualityVersion\":1"));
                    List<Packet> videos = new List<Packet>();
                    client.Send(0x20, Key(1, 30).Payload); Check(sink.Down.WaitOne(3000));
                    client.Send(0x35, VideoRequest(1, 1, 2560, 1440, 30, 20000000));
                    CheckVideoStatus(ReadVideoStatus(client, videos), 1, 0, 0, 0, 0, 0);
                    Check(sink.Events.Contains("key:30:up"));
                    Packet applied = ReadVideoStatus(client, videos); CheckVideoStatus(applied, 1, 1, 1, 0, 0, 3);
                    Check(NativeProtocol.U32(applied.Payload, 21) == 2560 && NativeProtocol.U32(applied.Payload, 29) == 30);
                    Check(videos.Count == 2 && NativeProtocol.U64(videos[0].Payload, 0) == 1 && NativeProtocol.U64(videos[1].Payload, 0) == 2);
                    Packet fresh = client.Read(); Check(fresh.Kind == 3 && NativeProtocol.U64(fresh.Payload, 0) == 3 && fresh.Payload[16] == 1);
                    client.Send(0x35, VideoRequest(2, 2)); CheckVideoStatus(ReadVideoStatus(client, videos), 2, 1, 2, 3, 0, 0);
                    Interlocked.Exchange(ref ticks, 3L * Stopwatch.Frequency);
                    client.Send(0x35, VideoRequest(1, 3, 222, 1080, 60, 12000000)); CheckVideoStatus(ReadVideoStatus(client, videos), 3, 1, 2, 2, 0, 0);
                    client.Send(0x35, VideoRequest(2, 4)); CheckVideoStatus(ReadVideoStatus(client, videos), 4, 1, 0, 0, 0, 0);
                    CheckVideoStatus(ReadVideoStatus(client, videos), 4, 1, 1, 0, 1, 0);
                    Check(factory.Opened == 2 && factory.Closed == 2 && factory.Active == 0 && videos.Count == 3);
                    int reads = factory.Reads, events = sink.Events.Count;
                    client.Send(0x20, Key(1, 31).Payload); client.Send(0x25, new byte[0]);
                    bool heartbeat = false;
                    for (int i = 0; i < 5 && !heartbeat; ++i) { Packet packet = client.Read(); Check(packet.Kind != 3); heartbeat = packet.Kind == 4; }
                    Check(heartbeat && server.IsActive && sink.Events.Count == events && factory.Reads == reads);
                    Interlocked.Exchange(ref ticks, 6L * Stopwatch.Frequency);
                    client.Send(0x35, VideoRequest(3, 5)); CheckVideoStatus(ReadVideoStatus(client, videos), 5, 1, 0, 0, 1, 0);
                    CheckVideoStatus(ReadVideoStatus(client, videos), 5, 2, 1, 0, 0, 5);
                    fresh = client.Read(); Check(fresh.Kind == 3 && NativeProtocol.U64(fresh.Payload, 0) == 5 && fresh.Payload[16] == 1);
                    server.Stop(); Check(server.WaitStopped(4000));
                    Check(factory.Opened == 3 && factory.Closed == 3 && factory.PeakActive == 1 && factory.SameThread);
                    Check(factory.Trace.IndexOf("close:12000000") < factory.Trace.IndexOf("open:20000000"));
                }
            }
        }
        private static void VideoControlRollback(bool rollbackFails)
        {
            using (VideoFixtureFactory factory = new VideoFixtureFactory())
            using (HostServer server = VideoHost(factory, new FakeInput(), Stopwatch.GetTimestamp))
            {
                factory.FailRollback = rollbackFails; string token = Token(server); server.Start();
                using (TlsClient client = new TlsClient(server, server.Pin))
                {
                    client.Send(1, VideoHello(token)); Check(client.ReadNonHeartbeat().Kind == 2);
                    List<Packet> videos = new List<Packet>(); client.Send(0x35, VideoRequest(1, 1, 2560, 1440, 60, 13000000));
                    CheckVideoStatus(ReadVideoStatus(client, videos), 1, 0, 0, 0, 0, 0);
                    if (rollbackFails)
                    {
                        Packet terminal;
                        do { terminal = client.Read(); } while (terminal.Kind == 3 || terminal.Kind == 4 || terminal.Kind == 0x34);
                        Check(terminal.Kind == 127 && server.WaitStopped(4000));
                        Check(factory.Opened == 1 && factory.Closed == 1 && factory.Attempts == 3 && factory.Active == 0);
                    }
                    else
                    {
                        Packet rolledBack = ReadVideoStatus(client, videos); CheckVideoStatus(rolledBack, 1, 1, 3, 4, 0, 3);
                        Check(NativeProtocol.U32(rolledBack.Payload, 21) == 1920 && NativeProtocol.U32(rolledBack.Payload, 33) == 12000000);
                        Packet fresh = client.Read(); Check(fresh.Kind == 3 && fresh.Payload[16] == 1 && NativeProtocol.U64(fresh.Payload, 0) == 3);
                        Check(server.IsActive && factory.Opened == 2 && factory.Closed == 1 && factory.Active == 1);
                        server.Stop(); Check(server.WaitStopped(4000)); Check(factory.Closed == 2);
                    }
                    Check(factory.SameThread && factory.PeakActive == 1 && !server.MayResumeRegisteredConnection);
                }
            }
        }
        private static void VideoControlLegacyAndMalformed()
        {
            using (VideoFixtureFactory factory = new VideoFixtureFactory())
            using (HostServer server = VideoHost(factory, new FakeInput(), Stopwatch.GetTimestamp))
            {
                string token = Token(server); server.Start();
                using (TlsClient invalid = new TlsClient(server, server.Pin))
                { invalid.Send(1, VideoHello(token, 2)); Check(invalid.Read().Kind == 127); }
                using (TlsClient client = new TlsClient(server, server.Pin))
                {
                    client.Send(1, Hello(token)); Packet ready = client.ReadNonHeartbeat();
                    Check(ready.Kind == 2 && !StrictJson.Utf8.GetString(ready.Payload).Contains("videoControlVersion"));
                    client.Send(0x35, VideoRequest(2, 1)); Check(server.WaitStopped(4000));
                    Check(factory.Opened == 1 && factory.Closed == 1 && factory.SameThread);
                }
            }
        }
        private static void VideoControlPauseDesktopDenial()
        {
            int allowed = 1;
            using (VideoFixtureFactory factory = new VideoFixtureFactory())
            using (HostServer server = VideoHost(factory, new FakeInput(), Stopwatch.GetTimestamp, delegate { return Interlocked.CompareExchange(ref allowed, 0, 0) == 1; }))
            {
                string token = Token(server); server.Start();
                using (TlsClient client = new TlsClient(server, server.Pin))
                {
                    client.Send(1, VideoHello(token)); Check(client.ReadNonHeartbeat().Kind == 2);
                    List<Packet> videos = new List<Packet>(); client.Send(0x35, VideoRequest(2, 1));
                    CheckVideoStatus(ReadVideoStatus(client, videos), 1, 0, 0, 0, 0, 0);
                    CheckVideoStatus(ReadVideoStatus(client, videos), 1, 0, 1, 0, 1, 0);
                    Interlocked.Exchange(ref allowed, 0); Check(server.WaitStopped(4000));
                    Check(factory.Opened == 1 && factory.Closed == 1 && factory.Active == 0 && !server.MayResumeRegisteredConnection);
                }
            }
        }
        private static void VideoControlDrainFailure(int failure, byte operation, string expectedCode)
        {
            FakeInput sink = new FakeInput();
            using (VideoFixtureFactory factory = new VideoFixtureFactory())
            using (HostServer server = VideoHost(factory, sink, Stopwatch.GetTimestamp))
            {
                factory.DrainFailure = failure; factory.ContinueDrain.Reset(); string token = Token(server); server.Start();
                using (TlsClient client = new TlsClient(server, server.Pin))
                {
                    client.Send(1, VideoHello(token)); Check(client.ReadNonHeartbeat().Kind == 2);
                    client.Send(0x20, Key(1, 30).Payload); Check(sink.Down.WaitOne(3000));
                    List<Packet> videos = new List<Packet>();
                    client.Send(0x35, operation == 1 ? VideoRequest(1, 1, 2560, 1440, 60, 20000000) : VideoRequest(2, 1));
                    CheckVideoStatus(ReadVideoStatus(client, videos), 1, 0, 0, 0, 0, 0);
                    // Already-in-flight input after preparing must never be
                    // injected, even while a failing drain polls to its deadline.
                    Check(factory.DrainEntered.WaitOne(3000));
                    client.Send(0x20, Key(1, 31).Payload); factory.ContinueDrain.Set();
                    Packet terminal;
                    do { terminal = client.Read(); } while (terminal.Kind == 4 || terminal.Kind == 0x34);
                    Check(terminal.Kind == 127 && StrictJson.String(StrictJson.Parse(terminal.Payload, "code"), "code") == expectedCode);
                    Check(server.WaitStopped(4000) && !server.IsActive && !server.MayResumeRegisteredConnection);
                    Check(factory.Attempts == 1 && factory.Opened == 1 && factory.Closed == 1 && factory.Active == 0 && factory.PeakActive == 1 && factory.SameThread);
                    Check(sink.Events.Contains("key:30:up") && !sink.Events.Contains("key:31:down"));
                    Check(videos.Count == 1 && videos[0].Payload[16] == 1 && NativeProtocol.U64(videos[0].Payload, 0) == 1);
                    Check(factory.Trace.Count == 3 && factory.Trace[0] == "open:12000000" && factory.Trace[1] == "begin-drain" && factory.Trace[2] == "close:12000000");
                    Check(failure == 1 ? factory.DrainReads == 0 : factory.DrainReads >= 1);
                }
            }
        }
        private static void VideoControlFailedResumeStaysPaused()
        {
            long ticks = 0; FakeInput sink = new FakeInput();
            using (VideoFixtureFactory factory = new VideoFixtureFactory())
            using (HostServer server = VideoHost(factory, sink, delegate { return Interlocked.Read(ref ticks); }))
            {
                string token = Token(server); server.Start();
                using (TlsClient client = new TlsClient(server, server.Pin))
                {
                    client.Send(1, VideoHello(token)); Check(client.ReadNonHeartbeat().Kind == 2);
                    List<Packet> videos = new List<Packet>(); client.Send(0x35, VideoRequest(2, 1));
                    CheckVideoStatus(ReadVideoStatus(client, videos), 1, 0, 0, 0, 0, 0);
                    CheckVideoStatus(ReadVideoStatus(client, videos), 1, 0, 1, 0, 1, 0);
                    Interlocked.Exchange(ref ticks, 3L * Stopwatch.Frequency); factory.FailRollback = true;
                    client.Send(0x35, VideoRequest(3, 2)); CheckVideoStatus(ReadVideoStatus(client, videos), 2, 0, 0, 0, 1, 0);
                    CheckVideoStatus(ReadVideoStatus(client, videos), 2, 0, 2, 4, 1, 0);
                    client.Send(0x20, Key(1, 30).Payload); client.Send(0x25, new byte[0]);
                    Thread.Sleep(150);
                    Check(server.IsActive && factory.Opened == 1 && factory.Closed == 1 && factory.Attempts == 2 && factory.Active == 0 && sink.Events.Count == 0);
                    server.Stop(); Check(server.WaitStopped(4000));
                }
            }
        }
        private static void VideoControlPrimeFailure()
        {
            long ticks = 0;
            using (VideoFixtureFactory factory = new VideoFixtureFactory())
            using (HostServer server = VideoHost(factory, new FakeInput(), delegate { return Interlocked.Read(ref ticks); }))
            {
                string token = Token(server); server.Start();
                using (TlsClient client = new TlsClient(server, server.Pin))
                {
                    client.Send(1, VideoHello(token)); Check(client.ReadNonHeartbeat().Kind == 2);
                    List<Packet> videos = new List<Packet>(); client.Send(0x35, VideoRequest(1, 1, 2560, 1440, 60, 14000000));
                    CheckVideoStatus(ReadVideoStatus(client, videos), 1, 0, 0, 0, 0, 0);
                    CheckVideoStatus(ReadVideoStatus(client, videos), 1, 1, 3, 4, 0, 3);
                    Packet fresh = client.Read(); Check(fresh.Kind == 3 && fresh.Payload[16] == 1 && NativeProtocol.U64(fresh.Payload, 0) == 3);
                    Check(videos.Count == 2 && factory.Opened == 3 && factory.Closed == 2 && factory.PeakActive == 1);
                    Check(factory.Trace.IndexOf("close:14000000") < factory.Trace.LastIndexOf("open:12000000"));
                    // Even identical requested host bounds require a real reset:
                    // Ready exposed only actual output, never those bounds.
                    Interlocked.Exchange(ref ticks, 3L * Stopwatch.Frequency);
                    client.Send(0x35, VideoRequest(1, 2, 1920, 1080, 60, 12000000));
                    CheckVideoStatus(ReadVideoStatus(client, videos), 2, 1, 0, 0, 0, 0);
                    CheckVideoStatus(ReadVideoStatus(client, videos), 2, 2, 1, 0, 0, 5);
                    fresh = client.Read(); Check(fresh.Kind == 3 && fresh.Payload[16] == 1 && NativeProtocol.U64(fresh.Payload, 0) == 5);
                    Check(videos.Count == 3 && NativeProtocol.U64(videos[2].Payload, 0) == 4 && videos[2].Payload[16] == 0);
                    Check(factory.Opened == 4 && factory.Closed == 3 && factory.PeakActive == 1);
                    server.Stop(); Check(server.WaitStopped(4000)); Check(factory.Closed == 4 && factory.SameThread);
                }
            }
        }
        private static void VideoControlStopDuringOpen()
        {
            using (VideoFixtureFactory factory = new VideoFixtureFactory())
            using (HostServer server = VideoHost(factory, new FakeInput(), Stopwatch.GetTimestamp))
            {
                factory.BlockAttempt = 2; factory.ContinueOpen.Reset(); string token = Token(server); server.Start();
                try
                {
                    using (TlsClient client = new TlsClient(server, server.Pin))
                    {
                        client.Send(1, VideoHello(token)); Check(client.ReadNonHeartbeat().Kind == 2);
                        List<Packet> videos = new List<Packet>(); client.Send(0x35, VideoRequest(1, 1, 2560, 1440, 30, 20000000));
                        CheckVideoStatus(ReadVideoStatus(client, videos), 1, 0, 0, 0, 0, 0); Check(factory.OpenEntered.WaitOne(3000));
                        server.Stop(); factory.ContinueOpen.Set(); Check(server.WaitStopped(4000));
                        Check(factory.Attempts == 2 && factory.Opened == 2 && factory.Closed == 2 && factory.Active == 0 && factory.SameThread);
                    }
                }
                finally { factory.ContinueOpen.Set(); }
            }
        }
    }
}
