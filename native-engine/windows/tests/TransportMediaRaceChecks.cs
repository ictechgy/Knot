// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Diagnostics;
using System.Threading;

namespace Knot.NativePreview
{
    internal static partial class NativeChecks
    {
        internal enum LatchedSuccess { Valid, Empty, Oversize, BadNal, InvalidFlags, MismatchedFlags }
        private static void TransportMediaRaceChecks()
        {
            foreach (bool silence in new bool[] { false, true })
            {
                foreach (int status in new int[] { -1, -2, -3, -4, 2 }) TransportStopsBeforeMediaResult(status, silence, false);
                // Valid frame/no-frame results arriving during teardown retain
                // transport recovery and never try to write a cancelled frame.
                foreach (int status in new int[] { 0, 1 }) TransportStopsBeforeMediaResult(status, silence, true);
                foreach (LatchedSuccess result in new LatchedSuccess[] { LatchedSuccess.Empty, LatchedSuccess.Oversize,
                    LatchedSuccess.BadNal, LatchedSuccess.InvalidFlags, LatchedSuccess.MismatchedFlags })
                    TransportStopsBeforeMediaResult(0, silence, false, result);
            }
        }
        private static void TransportStopsBeforeMediaResult(int status, bool silence, bool resume, LatchedSuccess result = LatchedSuccess.Valid)
        {
            FakeInput sink = new FakeInput(); long inputTicks = 0;
            using (LatchedMediaResultFactory media = new LatchedMediaResultFactory(status, result))
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
            private readonly LatchedSuccess result;
            internal readonly ManualResetEvent Entered = new ManualResetEvent(false), Continue = new ManualResetEvent(false);
            internal int Opened, Reads, Closed;
            internal bool SameThread = true;
            internal LatchedMediaResultFactory(int status, LatchedSuccess result) { this.status = status; this.result = result; }
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
                    written = flags = 0; timestamp = 123456;
                    if (owner.status == 0)
                    {
                        // Fresh structural AnnexB bytes only; no codec, capture
                        // or previously generated media participates in this ABI fixture.
                        byte[] accessUnit = Join(NalFixture(1, 7, 2), Join(NalFixture(1, 8, 2), NalFixture(1, 5, 2)));
                        Buffer.BlockCopy(accessUnit, 0, buffer, 0, accessUnit.Length);
                        written = (uint)accessUnit.Length; flags = 1;
                        switch (owner.result)
                        {
                            case LatchedSuccess.Empty: written = 0; break;
                            case LatchedSuccess.Oversize: written = (uint)buffer.Length + 1; break;
                            case LatchedSuccess.BadNal: buffer[4] = 0xff; break;
                            case LatchedSuccess.InvalidFlags: flags = 2; break;
                            case LatchedSuccess.MismatchedFlags: flags = 0; break;
                        }
                    }
                    return owner.status;
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
