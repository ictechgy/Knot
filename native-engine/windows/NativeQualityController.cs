using System;
using System.Diagnostics;

namespace Knot.NativePreview
{
    internal interface IAdaptiveMediaSource { bool TrySetQuality(uint fps, uint bitrate); }

    // Receiver pressure and slow socket writes are hints, never authority to
    // exceed the locally selected profile. Only the media MTA applies changes.
    internal sealed class NativeQualityController
    {
        private readonly object gate = new object();
        private readonly uint maxFps, maxBitrate;
        private uint fps, bitrate;
        private byte preference;
        private bool pressure, changed = true, supported = true;
        private long nextChange;
        private int healthy;
        internal NativeQualityController(MediaInfo info) { fps = maxFps = info.Fps; bitrate = maxBitrate = info.Bitrate; }
        internal static byte[] WithOffer(byte[] ready) {
            string json = StrictJson.Utf8.GetString(ready);
            if (!json.EndsWith("}", StringComparison.Ordinal)) throw new ProtocolException("protocol");
            return StrictJson.Utf8.GetBytes(json.Substring(0, json.Length - 1) + ",\"qualityVersion\":1}");
        }
        internal void Handle(Packet packet)
        {
            if (packet.Payload.Length != 1 || (packet.Kind == 0x32 ? packet.Payload[0] > 2 : packet.Kind != 0x33 || packet.Payload[0] > 1))
                throw new ProtocolException("protocol");
            lock (gate) {
                if (packet.Kind == 0x32) { preference = packet.Payload[0]; nextChange = 0; healthy = 0; }
                else if (packet.Payload[0] == 1) pressure = true;
            }
        }
        internal void ObserveWrite(double milliseconds) { if (milliseconds >= 100) lock (gate) pressure = true; }
        internal void Apply(IMediaSource source) { Apply(source, Stopwatch.GetTimestamp()); }
        internal void Apply(IMediaSource source, long now)
        {
            lock (gate) {
                if (now < nextChange || !supported) return;
                nextChange = now + Stopwatch.Frequency * 2;
                uint desiredFps = preference == 1 ? Math.Min(30U, maxFps) : maxFps;
                uint ceiling = preference == 2 ? Math.Min(20000000U, maxBitrate) : maxBitrate;
                uint desiredRate = Math.Min(bitrate, ceiling);
                if (preference == 0 && pressure) {
                    desiredRate = Math.Max(Math.Min(4000000U, ceiling), desiredRate * 3U / 4U);
                    desiredFps = Math.Min(30U, maxFps); healthy = 0;
                } else if (preference != 0 || ++healthy >= 5) {
                    desiredRate = preference == 0 ? Math.Min(ceiling, desiredRate + 2000000U) : ceiling;
                    healthy = 0;
                }
                pressure = false;
                if (desiredFps == fps && desiredRate == bitrate) return;
                IAdaptiveMediaSource adaptive = source as IAdaptiveMediaSource;
                supported = adaptive != null && adaptive.TrySetQuality(desiredFps, desiredRate);
                if (supported) { fps = desiredFps; bitrate = desiredRate; }
                changed = true;
            }
        }
        internal byte[] TakeStatus()
        {
            lock (gate) {
                if (!changed) return null; changed = false;
                byte[] result = new byte[9]; Put(result, 0, fps); Put(result, 4, bitrate); result[8] = supported ? (byte)1 : (byte)0;
                return result;
            }
        }
        private static void Put(byte[] bytes, int at, uint value) { for (int i = 3; i >= 0; --i) { bytes[at + i] = (byte)value; value >>= 8; } }
    }
}
