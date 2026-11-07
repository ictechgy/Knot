using System;
using System.Collections.Generic;
using System.Diagnostics;

namespace Knot.NativePreview
{
    internal static partial class NativeChecks
    {
        private class QualityFixtureMedia : IMediaSource
        {
            internal MediaInfo Information;
            public MediaInfo Info { get { return Information; } }
            public int Read(byte[] buffer, out uint written, out uint flags, out ulong timestamp)
            { throw new InvalidOperationException("Synthetic quality fixture never reads media."); }
            public void Dispose() { }
        }
        private sealed class AdaptiveQualityFixture : QualityFixtureMedia, IAdaptiveMediaSource
        {
            internal readonly List<uint[]> Applied = new List<uint[]>();
            internal bool Supports = true;
            public bool TrySetQuality(uint fps, uint bitrate)
            {
                Check(fps >= 1 && fps <= Information.Fps && bitrate >= 1000000 && bitrate <= Information.Bitrate);
                Applied.Add(new uint[] { fps, bitrate }); return Supports;
            }
        }
        private static void QualityChecks()
        {
            MediaInfo info = new MediaInfo { Fps = 60, Bitrate = 40000000 };
            AdaptiveQualityFixture media = new AdaptiveQualityFixture(); media.Information = info;
            NativeQualityController quality = new NativeQualityController(info);
            byte[] status = quality.TakeStatus();
            Check(status.Length == 9 && NativeProtocol.U32(status, 0) == 60 && NativeProtocol.U32(status, 4) == 40000000 && status[8] == 1);
            Check(quality.TakeStatus() == null);
            Reject(delegate { quality.Handle(new Packet(0x32, new byte[] { 3 })); });
            Reject(delegate { quality.Handle(new Packet(0x33, new byte[] { 2 })); });
            Reject(delegate { quality.Handle(new Packet(0x20, new byte[] { 0 })); });
            quality.Handle(new Packet(0x33, new byte[] { 1 }));
            quality.Apply(media, 1);
            Check(media.Applied.Count == 1 && media.Applied[0][0] == 30 && media.Applied[0][1] == 40000000);
            quality.Apply(media, Stopwatch.Frequency);
            Check(media.Applied.Count == 1); // cooldown prevents oscillating on every frame.
            long now = 1;
            for (int i = 0; i < 5; ++i) {
                now += Stopwatch.Frequency * 2; quality.Apply(media, now);
                if (i < 4) Check(media.Applied.Count == 1); // no immediate30/60 FPS oscillation.
            }
            status = quality.TakeStatus();
            Check(NativeProtocol.U32(status, 0) == 60 && NativeProtocol.U32(status, 4) == 40000000);
            AlternatingQualityPressureChecks(info, false);
            AlternatingQualityPressureChecks(info, true);
            // Sustained congestion cannot exceed the configured floor/ceiling.
            for (int i = 0; i < 30; ++i) { quality.ObserveWrite(150); now += Stopwatch.Frequency * 2; quality.Apply(media, now); }
            status = quality.TakeStatus();
            Check(NativeProtocol.U32(status, 0) == 30 && NativeProtocol.U32(status, 4) == 4000000);
            quality.Handle(new Packet(0x32, new byte[] { 1 })); quality.Apply(media, now + 1);
            status = quality.TakeStatus(); Check(NativeProtocol.U32(status, 0) == 30 && NativeProtocol.U32(status, 4) == 40000000);
            quality.Handle(new Packet(0x32, new byte[] { 2 })); quality.Apply(media, now + 2);
            status = quality.TakeStatus(); Check(NativeProtocol.U32(status, 0) == 60 && NativeProtocol.U32(status, 4) == 20000000);
            AdaptiveQualityFixture low = new AdaptiveQualityFixture(); low.Information = new MediaInfo { Fps = 15, Bitrate = 1000000 };
            NativeQualityController capped = new NativeQualityController(low.Info);
            capped.Handle(new Packet(0x32, new byte[] { 2 })); capped.Apply(low, 1);
            status = capped.TakeStatus(); Check(NativeProtocol.U32(status, 0) == 15 && NativeProtocol.U32(status, 4) == 1000000);
            // An unsupported encoder retains its applied status and stops retries.
            AdaptiveQualityFixture unsupported = new AdaptiveQualityFixture(); unsupported.Information = info; unsupported.Supports = false;
            NativeQualityController unavailable = new NativeQualityController(info);
            unavailable.Handle(new Packet(0x33, new byte[] { 1 })); unavailable.Apply(unsupported, 1);
            status = unavailable.TakeStatus(); Check(status[8] == 0 && NativeProtocol.U32(status, 0) == 60 && NativeProtocol.U32(status, 4) == 40000000);
            unavailable.Apply(unsupported, Stopwatch.Frequency * 10); Check(unsupported.Applied.Count == 1);
            QualityFixtureMedia fixedMedia = new QualityFixtureMedia(); fixedMedia.Information = info;
            NativeQualityController fixedQuality = new NativeQualityController(info);
            fixedQuality.Handle(new Packet(0x32, new byte[] { 1 })); fixedQuality.Apply(fixedMedia, 1);
            Check(fixedQuality.TakeStatus()[8] == 0);
        }
        private static void AlternatingQualityPressureChecks(MediaInfo info, bool slowWrites)
        {
            AdaptiveQualityFixture media = new AdaptiveQualityFixture(); media.Information = info;
            NativeQualityController quality = new NativeQualityController(info);
            quality.TakeStatus();
            long now = 1;
            uint lastRate = info.Bitrate;
            for (int tick = 0; tick < 20; ++tick)
            {
                if (tick % 2 == 0)
                {
                    // Both signals demand fewer frames. Only measured slow
                    // writes may additionally reduce the selected bitrate.
                    quality.Handle(new Packet(0x33, new byte[] { 1 }));
                    if (slowWrites) quality.ObserveWrite(150);
                }
                quality.Apply(media, now);
                byte[] status = quality.TakeStatus();
                if (status != null)
                {
                    Check(NativeProtocol.U32(status, 0) == 30);
                    lastRate = NativeProtocol.U32(status, 4);
                }
                Check(media.Applied.Count > 0 && media.Applied[media.Applied.Count - 1][0] == 30);
                Check(slowWrites ? lastRate <= info.Bitrate : lastRate == info.Bitrate);
                now += Stopwatch.Frequency * 2;
            }
            if (slowWrites) Check(lastRate < info.Bitrate);
            int beforeRecovery = media.Applied.Count;
            // The final odd tick above is one healthy interval. Four more
            // complete the same five-interval recovery requirement.
            for (int healthy = 0; healthy < 4; ++healthy)
            {
                quality.Apply(media, now); now += Stopwatch.Frequency * 2;
                if (healthy < 3) Check(media.Applied.Count == beforeRecovery);
            }
            byte[] recovered = quality.TakeStatus();
            Check(recovered != null && NativeProtocol.U32(recovered, 0) == info.Fps);
            Check(NativeProtocol.U32(recovered, 4) == (slowWrites ? Math.Min(info.Bitrate, lastRate + 2000000U) : info.Bitrate));
        }
    }
}
