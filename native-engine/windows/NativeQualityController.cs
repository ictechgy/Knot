using System;
using System.Diagnostics;

namespace Knot.NativePreview
{
    internal interface IAdaptiveMediaSource { bool TrySetQuality(uint fps, uint bitrate); }

    internal sealed class PreparedVideoQuality
    {
        internal MediaInfo Info;
        internal MediaConfig Profile;
        internal long PreferenceRevision, ReceiverRevision, WriteRevision;
    }

    // Receiver pressure and slow socket writes are hints, never authority to
    // exceed the locally selected profile. Only the media MTA applies changes.
    internal sealed class NativeQualityController
    {
        private readonly object gate = new object();
        private uint maxFps, maxBitrate;
        private uint fps, bitrate;
        private byte preference;
        private bool receiverPressure, writePressure, changed = true, supported = true;
        private long nextChange, preferenceRevision, receiverRevision, writeRevision;
        private int healthy;
        internal NativeQualityController(MediaInfo info) : this(info, new MediaConfig { Fps = info.Fps, Bitrate = info.Bitrate }) { }
        internal NativeQualityController(MediaInfo info, MediaConfig profile)
        { fps = info.Fps; bitrate = info.Bitrate; maxFps = profile.Fps; maxBitrate = profile.Bitrate; }
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
                if (packet.Kind == 0x32) { preference = packet.Payload[0]; ++preferenceRevision; nextChange = 0; healthy = 0; }
                else if (packet.Payload[0] == 1) { receiverPressure = true; ++receiverRevision; }
            }
        }
        internal void ObserveWrite(double milliseconds) { if (milliseconds >= 100) lock (gate) { writePressure = true; ++writeRevision; } }
        internal void Apply(IMediaSource source) { Apply(source, Stopwatch.GetTimestamp()); }
        internal void Apply(IMediaSource source, long now)
        {
            lock (gate) {
                if (now < nextChange || !supported) return;
                nextChange = now + Stopwatch.Frequency * 2;
                // Auto holds the applied cadence until its healthy window is
                // complete. A single healthy tick must not undo a pressure cut.
                uint desiredFps = preference == 0 ? fps : preference == 1 ? Math.Min(30U, maxFps) : maxFps;
                uint ceiling = preference == 2 ? Math.Min(20000000U, maxBitrate) : maxBitrate;
                uint desiredRate = Math.Min(bitrate, ceiling);
                if (preference == 0 && (receiverPressure || writePressure)) {
                    // Decoder/presenter overload needs fewer frames, not more
                    // quantization. Preserve image quality unless writes also
                    // report pressure on the end-to-end transport path.
                    if (writePressure) desiredRate = Math.Max(Math.Min(4000000U, ceiling), desiredRate * 3U / 4U);
                    desiredFps = Math.Min(fps, Math.Min(30U, maxFps)); healthy = 0;
                } else if (preference != 0 || ++healthy >= 5) {
                    desiredRate = preference == 0 ? Math.Min(ceiling, desiredRate + 2000000U) : ceiling;
                    desiredFps = preference == 0 ? maxFps : desiredFps;
                    healthy = 0;
                }
                receiverPressure = writePressure = false;
                if (desiredFps == fps && desiredRate == bitrate) return;
                IAdaptiveMediaSource adaptive = source as IAdaptiveMediaSource;
                supported = adaptive != null && adaptive.TrySetQuality(desiredFps, desiredRate);
                if (supported) { fps = desiredFps; bitrate = desiredRate; }
                changed = true;
            }
        }
        // Compute the current policy before the new encoder's first submission.
        // This does not publish a new current profile or consume pressure until
        // priming succeeds, so target failure can still restore the old source.
        internal PreparedVideoQuality PrepareProfile(IMediaSource source, MediaConfig profile, MediaInfo? restore)
        {
            MediaInfo info = source.Info;
            PreparedVideoQuality prepared;
            lock (gate)
            {
                uint desiredFps = restore.HasValue ? Math.Min(info.Fps, restore.Value.Fps) : info.Fps;
                uint desiredRate = restore.HasValue ? Math.Min(info.Bitrate, restore.Value.Bitrate) : info.Bitrate;
                if (preference == 1) { desiredFps = Math.Min(30U, info.Fps); desiredRate = info.Bitrate; }
                else if (preference == 2) { desiredFps = info.Fps; desiredRate = Math.Min(20000000U, info.Bitrate); }
                else if (receiverPressure || writePressure)
                {
                    desiredFps = Math.Min(desiredFps, Math.Min(30U, info.Fps));
                    if (writePressure) desiredRate = Math.Max(Math.Min(4000000U, info.Bitrate), desiredRate * 3U / 4U);
                }
                prepared = new PreparedVideoQuality { Info = info, Profile = profile,
                    PreferenceRevision = preferenceRevision, ReceiverRevision = receiverRevision, WriteRevision = writeRevision };
                prepared.Info.Fps = desiredFps; prepared.Info.Bitrate = desiredRate;
            }
            // Driver work stays on the media MTA but never holds up the reader's
            // policy/heartbeat admission lock. A later preference is retained.
            IAdaptiveMediaSource adaptive = source as IAdaptiveMediaSource;
            if ((info.Fps != prepared.Info.Fps || info.Bitrate != prepared.Info.Bitrate) &&
                (adaptive == null || !adaptive.TrySetQuality(prepared.Info.Fps, prepared.Info.Bitrate)))
                throw new ProtocolException("encoder");
            return prepared;
        }
        internal void CommitProfile(PreparedVideoQuality prepared, long now)
        {
            lock (gate)
            {
                fps = prepared.Info.Fps; bitrate = prepared.Info.Bitrate;
                maxFps = prepared.Profile.Fps; maxBitrate = prepared.Profile.Bitrate;
                // Events admitted after preparation belong to the next policy
                // tick. Never erase them when publishing the primed profile.
                if (receiverRevision == prepared.ReceiverRevision) receiverPressure = false;
                if (writeRevision == prepared.WriteRevision) writePressure = false;
                healthy = 0; supported = true; changed = true;
                nextChange = preferenceRevision == prepared.PreferenceRevision ? now + 2L * Stopwatch.Frequency : 0;
            }
        }
        internal void Snapshot(ref MediaInfo info)
        { lock (gate) { info.Fps = fps; info.Bitrate = bitrate; } }
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
