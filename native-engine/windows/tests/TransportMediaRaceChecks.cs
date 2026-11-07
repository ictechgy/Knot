// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Diagnostics;
using System.Threading;

namespace Knot.NativePreview
{
    internal static partial class NativeChecks
    {
        private static void TransportMediaRaceChecks()
        {
            foreach (bool silence in new bool[] { false, true })
            {
                foreach (int status in new int[] { -1, -2, -3, -4, 2 }) TransportStopsBeforeMediaResult(status, silence, false);
                // Valid frame/no-frame results arriving during teardown retain
                // transport recovery and never try to write a cancelled frame.
                foreach (int status in new int[] { 0, 1 }) TransportStopsBeforeMediaResult(status, silence, true);
            }
        }
        private static void TransportStopsBeforeMediaResult(int status, bool silence, bool resume)
        {
            FakeInput sink = new FakeInput(); long inputTicks = 0;
            using (LatchedMediaResultFactory media = new LatchedMediaResultFactory(status))
            using (HostServer server = RecoveryHost(media, sink, true, delegate { return Interlocked.Read(ref inputTicks); }))
            {
                string offer = RecoveryNumberOffer(server); ++tlsFixtures;
                try
                {
                    using (TlsClient client = new TlsClient(server, OfferedPin(offer)))
                    {
                        client.Send(1, Hello(StrictJson.String(InvitationObject(offer), "token")));
                        Check(client.ReadNonHeartbeat().Kind == 2 && media.Entered.WaitOne(3000));
                        Check(server.IsActive && !server.IsRegisteredSession && media.Opened == 1);
                        if (silence) Interlocked.Exchange(ref inputTicks, 11L * Stopwatch.Frequency);
                        else client.Client.Close();
                        // Keep Read in flight until EOF or the actual watchdog
                        // has both stopped this host and marked transport resume.
                        WaitFor(delegate { return !server.IsActive; });
                        Check(server.MayResumeRegisteredConnection && media.Closed == 0);
                        media.Continue.Set(); Check(server.WaitStopped(4000));
                        Check(server.MayResumeRegisteredConnection == resume && !server.IsActive);
                        Check(media.Reads == 1 && media.Closed == 1 && media.SameThread);
                        Check(sink.Events.Count == 0 && !server.IsRegisteredSession);
                    }
                }
                finally { media.Continue.Set(); }
            }
        }
        private sealed class LatchedMediaResultFactory : IMediaFactory, IDisposable
        {
            private readonly int status;
            internal readonly ManualResetEvent Entered = new ManualResetEvent(false), Continue = new ManualResetEvent(false);
            internal int Opened, Reads, Closed;
            internal bool SameThread = true;
            internal LatchedMediaResultFactory(int status) { this.status = status; }
            public IMediaSource Open() { Interlocked.Increment(ref Opened); return new Source(this); }
            public void Dispose() { Continue.Set(); Entered.Dispose(); Continue.Dispose(); }
            private sealed class Source : IMediaSource
            {
                private readonly LatchedMediaResultFactory owner;
                private readonly int thread = Thread.CurrentThread.ManagedThreadId;
                internal Source(LatchedMediaResultFactory owner) { this.owner = owner; }
                public MediaInfo Info { get { return new MediaInfo { Width = 1280, Height = 720, Fps = 60, Bitrate = 12000000, DesktopWidth = 1920, DesktopHeight = 1080, HardwareEncoder = 1 }; } }
                public int Read(byte[] buffer, out uint written, out uint flags, out ulong timestamp)
                {
                    owner.SameThread &= thread == Thread.CurrentThread.ManagedThreadId;
                    Interlocked.Increment(ref owner.Reads); owner.Entered.Set();
                    if (!owner.Continue.WaitOne(15000)) throw new InvalidOperationException("Fresh synthetic media-result wait expired.");
                    written = flags = 0; timestamp = 0; return owner.status;
                }
                public void Dispose()
                {
                    owner.SameThread &= thread == Thread.CurrentThread.ManagedThreadId;
                    Interlocked.Increment(ref owner.Closed);
                }
            }
        }
    }
}
