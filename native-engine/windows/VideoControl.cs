// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Diagnostics;
using System.Net.Security;
using System.Runtime.InteropServices;
using System.Text;

namespace Knot.NativePreview
{
    internal sealed class VideoControlRequest
    {
        internal byte Operation, RejectionReason;
        internal ulong Id;
        internal MediaConfig Config;
    }

    internal static class VideoControlProtocol
    {
        internal static VideoControlRequest Request(byte[] bytes)
        {
            if (bytes == null || bytes.Length != 26 || bytes[0] != 1 || bytes[1] < 1 || bytes[1] > 3)
                throw new ProtocolException("protocol");
            VideoControlRequest request = new VideoControlRequest {
                Operation = bytes[1], Id = NativeProtocol.U64(bytes, 2),
                Config = new MediaConfig { Width = NativeProtocol.U32(bytes, 10), Height = NativeProtocol.U32(bytes, 14),
                    Fps = NativeProtocol.U32(bytes, 18), Bitrate = NativeProtocol.U32(bytes, 22) } };
            if (request.Id == 0 || request.Operation != 1 &&
                (request.Config.Width != 0 || request.Config.Height != 0 || request.Config.Fps != 0 || request.Config.Bitrate != 0))
                throw new ProtocolException("protocol");
            return request;
        }
        internal static bool Allowed(MediaConfig config)
        {
            return (config.Width == 1920 && config.Height == 1080 || config.Width == 2560 && config.Height == 1440 ||
                config.Width == 3840 && config.Height == 2160) && (config.Fps == 30 || config.Fps == 60) && MediaLimits.ValidConfig(config);
        }
        internal static bool Same(MediaConfig a, MediaConfig b)
        { return a.Width == b.Width && a.Height == b.Height && a.Fps == b.Fps && a.Bitrate == b.Bitrate; }
        internal static byte[] WithOffer(byte[] ready)
        {
            string json = StrictJson.Utf8.GetString(ready);
            if (!json.EndsWith("}", StringComparison.Ordinal)) throw new ProtocolException("protocol");
            return StrictJson.Utf8.GetBytes(json.Substring(0, json.Length - 1) + ",\"videoControlVersion\":1}");
        }
        internal static byte[] Status(VideoControlRequest request, ulong epoch, byte outcome, byte reason, bool paused, MediaInfo info, ulong nextSequence)
        {
            byte[] bytes = new byte[45]; bytes[0] = 1; bytes[1] = request.Operation;
            NativeProtocol.Put64(bytes, 2, request.Id); NativeProtocol.Put64(bytes, 10, epoch);
            bytes[18] = outcome; bytes[19] = reason; bytes[20] = paused ? (byte)1 : (byte)0;
            NativeProtocol.Put32(bytes, 21, info.Width); NativeProtocol.Put32(bytes, 25, info.Height);
            NativeProtocol.Put32(bytes, 29, info.Fps); NativeProtocol.Put32(bytes, 33, info.Bitrate);
            NativeProtocol.Put64(bytes, 37, nextSequence); return bytes;
        }
    }

    // The reader owns admission, the MTA owns completion and every reply.
    // One operation and one busy rejection are the entire bounded mailbox.
    internal sealed class VideoControlMailbox
    {
        private readonly object gate = new object();
        private VideoControlRequest pending, busy;
        private ulong lastId;
        private bool active;
        internal void Submit(VideoControlRequest request)
        {
            lock (gate)
            {
                if (request.Id <= lastId || lastId == 0 && request.Id != 1 || lastId == ulong.MaxValue)
                    throw new ProtocolException("protocol");
                lastId = request.Id;
                if (busy != null) throw new ProtocolException("protocol");
                if (active) { request.RejectionReason = 3; busy = request; }
                else { active = true; pending = request; }
            }
        }
        internal bool TryTake(out VideoControlRequest request)
        {
            lock (gate)
            {
                if (pending != null) { request = pending; pending = null; return true; }
                request = busy; busy = null; return request != null;
            }
        }
        internal void Complete(VideoControlRequest request)
        { if (request.RejectionReason == 0) lock (gate) active = false; }
    }

    // Only metadata is inspected while capture is closed. Never enumerate or
    // open windows on the input desktop, switch desktops, or bypass its ACL.
    internal static class WindowsPausedDesktopPolicy
    {
        [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool GetUserObjectInformation(IntPtr handle, int index, StringBuilder value, uint bytes, out uint needed);
        [DllImport("user32.dll")] private static extern bool CloseDesktop(IntPtr desktop);
        internal static bool Allowed()
        {
            IntPtr desktop = OpenInputDesktop(0, false, 1);
            if (desktop == IntPtr.Zero) return false;
            try
            {
                StringBuilder name = new StringBuilder(64); uint needed;
                return GetUserObjectInformation(desktop, 2, name, 128, out needed) && name.ToString() == "Default";
            }
            finally { CloseDesktop(desktop); }
        }
    }

    internal sealed partial class HostServer
    {
        private long nextVideoChange;
        private MediaInfo ActualVideoInfo(MediaInfo info)
        { if (quality != null) quality.Snapshot(ref info); return info; }
        private void SuspendVideoInput()
        {
            lock (gate)
            {
                if (isStopped || input == null) throw new ProtocolException("closed");
                videoInputSuspended = true;
                if (!input.Suspend()) throw new ProtocolException("closed");
            }
            if (clipboard != null) clipboard.Cancel();
        }
        private void ResumeVideoInput()
        {
            lock (gate)
            {
                if (isStopped || input == null || !input.Resume()) throw new ProtocolException("closed");
                videoInputSuspended = false;
            }
        }
        private void WriteVideoSidecars(SslStream tls, ref long lastHeartbeat)
        {
            byte[] response;
            if (quality != null && (response = quality.TakeStatus()) != null) NativeProtocol.Write(tls, 0x34, response);
            if (clipboard != null && clipboard.TryTake(out response)) NativeProtocol.Write(tls, 0x31, response);
            if (Stopwatch.GetTimestamp() - lastHeartbeat >= 2L * Stopwatch.Frequency)
            { NativeProtocol.Write(tls, 4, new byte[0]); lastHeartbeat = Stopwatch.GetTimestamp(); }
        }
        private static void ValidateMediaRead(int status, uint written, uint flags, byte[] encoded, bool draining)
        {
            // A genuine result is validated even if Stop raced the driver call;
            // malformed or failed media must never become transport recovery.
            if (status < 0) throw NativeMediaErrors.ForStatus(status);
            if (status != 0 && status != 1 && !(draining && status == 2)) throw new ProtocolException("capture");
            if (status == 0)
            {
                if (written == 0 || written > encoded.Length) throw new ProtocolException("encoder");
                AnnexB.Validate(encoded, (int)written, flags);
            }
        }
        private void WriteVideoUnit(SslStream tls, byte[] encoded, byte[] payload, uint written, uint flags, ulong timestamp, ref ulong sequence)
        {
            if (sequence == ulong.MaxValue) throw new ProtocolException("encoder");
            NativeProtocol.Put64(payload, 0, ++sequence); NativeProtocol.Put64(payload, 8, timestamp); payload[16] = (byte)flags;
            Buffer.BlockCopy(encoded, 0, payload, 17, (int)written);
            long started = Stopwatch.GetTimestamp(); NativeProtocol.Write(tls, 3, payload, (int)written + 17);
            if (quality != null) quality.ObserveWrite((Stopwatch.GetTimestamp() - started) * 1000.0 / Stopwatch.Frequency);
        }
        private void DrainVideo(IMediaSource media, SslStream tls, byte[] encoded, byte[] payload, ref ulong sequence, ref long heartbeat)
        {
            IDrainableMediaSource source = media as IDrainableMediaSource;
            if (source == null) throw new ProtocolException("encoder");
            int begin = source.BeginDrain();
            if (begin < 0) throw NativeMediaErrors.ForStatus(begin);
            if (begin != 0) throw new ProtocolException("capture");
            long until = Stopwatch.GetTimestamp() + 2L * Stopwatch.Frequency;
            while (!Stopping)
            {
                if (Stopwatch.GetTimestamp() >= until) throw new ProtocolException("encoder");
                uint written, flags; ulong timestamp;
                int status = source.ReadDrain(encoded, out written, out flags, out timestamp);
                ValidateMediaRead(status, written, flags, encoded, true);
                if (Stopping) throw new ProtocolException("closed");
                if (status == 0) WriteVideoUnit(tls, encoded, payload, written, flags, timestamp, ref sequence);
                WriteVideoSidecars(tls, ref heartbeat);
                if (status == 2) return;
            }
            throw new ProtocolException("closed");
        }
        private IMediaSource OpenPrimedVideo(MediaConfig config, CaptureRectangle rectangle, byte[] encoded, SslStream tls,
            ref long heartbeat, MediaInfo? restoreQuality, out MediaInfo info, out uint written, out ulong timestamp)
        {
            IMediaSource target = null; info = new MediaInfo(); written = 0; timestamp = 0;
            try
            {
                if (Stopping) throw new ProtocolException("closed");
                target = ((IConfigurableMediaFactory)mediaFactory).Open(config);
                if (Stopping) throw new ProtocolException("closed");
                info = target.Info; info.ValidateProfile(config);
                CaptureRectangle actual = info.Rectangle;
                if (actual.Left != rectangle.Left || actual.Top != rectangle.Top || actual.Width != rectangle.Width || actual.Height != rectangle.Height)
                    throw new ProtocolException("capture", "display");
                if (!(target is IDrainableMediaSource) || !(target is IAdaptiveMediaSource)) throw new ProtocolException("encoder");
                if (restoreQuality.HasValue)
                {
                    MediaInfo effective = restoreQuality.Value;
                    if ((info.Fps != effective.Fps || info.Bitrate != effective.Bitrate) &&
                        !((IAdaptiveMediaSource)target).TrySetQuality(effective.Fps, effective.Bitrate)) throw new ProtocolException("encoder");
                    info.Fps = effective.Fps; info.Bitrate = effective.Bitrate;
                }
                long until = Stopwatch.GetTimestamp() + 5L * Stopwatch.Frequency;
                while (!Stopping)
                {
                    if (Stopwatch.GetTimestamp() >= until) throw new ProtocolException("encoder");
                    uint flags;
                    int status = target.Read(encoded, out written, out flags, out timestamp);
                    ValidateMediaRead(status, written, flags, encoded, false);
                    if (Stopping) throw new ProtocolException("closed");
                    WriteVideoSidecars(tls, ref heartbeat);
                    if (status == 0)
                    {
                        if (flags != 1) throw new ProtocolException("encoder");
                        IMediaSource result = target; target = null; return result;
                    }
                }
                throw new ProtocolException("closed");
            }
            finally { if (target != null) DisposeVideoSource(target); }
        }
        private static void DisposeVideoSource(IMediaSource source)
        {
            try { source.Dispose(); }
            catch { throw new ProtocolException("capture", "media-close"); }
        }
        private void ProcessVideoControl(VideoControlRequest request, ref IMediaSource media, ref MediaConfig profile,
            ref MediaInfo info, ref ulong epoch, ref ulong sequence, SslStream tls, byte[] encoded, byte[] payload, ref long heartbeat)
        {
            try
            {
                bool paused = media == null;
                MediaInfo actual = ActualVideoInfo(info);
                byte reason = request.RejectionReason;
                if (reason == 0 && request.Operation == 1 && !VideoControlProtocol.Allowed(request.Config)) reason = 2;
                if (reason == 0 && paused && request.Operation == 1) reason = 3;
                bool noOp = request.Operation == 2 && paused || request.Operation == 3 && !paused ||
                    request.Operation == 1 && VideoControlProtocol.Same(profile, request.Config);
                if (reason == 0 && !noOp && clock() < nextVideoChange) reason = 3;
                if (reason != 0 || noOp)
                {
                    NativeProtocol.Write(tls, 0x36, VideoControlProtocol.Status(request, epoch, reason == 0 ? (byte)1 : (byte)2, reason, paused, actual, 0));
                    return;
                }
                SuspendVideoInput();
                NativeProtocol.Write(tls, 0x36, VideoControlProtocol.Status(request, epoch, 0, 0, paused, actual, 0));
                nextVideoChange = clock() + 2L * Stopwatch.Frequency;
                MediaConfig oldProfile = profile;
                CaptureRectangle rectangle = info.Rectangle;
                bool wasPaused = paused, committed = false;
                // The old encoder must drain successfully before replacement is
                // allowed. A failed/malformed drain is a terminal media failure,
                // never a target initialization failure eligible for rollback.
                if (media != null)
                {
                    DrainVideo(media, tls, encoded, payload, ref sequence, ref heartbeat);
                    IMediaSource old = media; media = null; DisposeVideoSource(old);
                }
                if (Stopping) throw new ProtocolException("closed");
                if (request.Operation == 2)
                {
                    info = actual;
                    NativeProtocol.Write(tls, 0x36, VideoControlProtocol.Status(request, epoch, 1, 0, true, info, 0));
                    Notify("화면과 원격 입력을 일시 정지했어요. 연결, 파일과 허용된 소리는 유지돼요.");
                    return;
                }
                try
                {
                    MediaConfig targetProfile = request.Operation == 1 ? request.Config : profile;
                    uint written; ulong timestamp; MediaInfo targetInfo;
                    media = OpenPrimedVideo(targetProfile, rectangle, encoded, tls, ref heartbeat, wasPaused ? (MediaInfo?)actual : null, out targetInfo, out written, out timestamp);
                    if (epoch == ulong.MaxValue || sequence == ulong.MaxValue) throw new ProtocolException("encoder");
                    committed = true;
                    ++epoch; profile = targetProfile; info = targetInfo; quality.ResetProfile(info, profile);
                    NativeProtocol.Write(tls, 0x36, VideoControlProtocol.Status(request, epoch, 1, 0, false, info, sequence + 1));
                    WriteVideoUnit(tls, encoded, payload, written, 1, timestamp, ref sequence);
                    ResumeVideoInput();
                    Notify("화면을 전송하고 있어요. 연결된 Mac에서 최대 4K · 60fps · 40Mbps까지 화질을 바꿀 수 있어요.");
                }
                catch (Exception failure)
                {
                    if (Stopping || committed) throw;
                    ProtocolException protocol = failure as ProtocolException;
                    if (failure is System.IO.IOException || failure is System.Net.Sockets.SocketException ||
                        protocol != null && (protocol.Code == "input" || protocol.GuidanceCategory == "display" || protocol.GuidanceCategory == "media-close")) throw;
                    if (media != null) { IMediaSource failed = media; media = null; DisposeVideoSource(failed); }
                    if (wasPaused)
                    {
                        // Resume failure retains the authenticated paused session.
                        NativeProtocol.Write(tls, 0x36, VideoControlProtocol.Status(request, epoch, 2, 4, true, actual, 0));
                        return;
                    }
                    // The failed target was fully closed before rollback. There
                    // is never a second simultaneous output-duplication owner.
                    uint written; ulong timestamp; MediaInfo restored;
                    media = OpenPrimedVideo(oldProfile, rectangle, encoded, tls, ref heartbeat, actual, out restored, out written, out timestamp);
                    if (epoch == ulong.MaxValue || sequence == ulong.MaxValue) throw new ProtocolException("encoder");
                    ++epoch; profile = oldProfile; info = restored; quality.ResetProfile(info, profile);
                    NativeProtocol.Write(tls, 0x36, VideoControlProtocol.Status(request, epoch, 3, 4, false, info, sequence + 1));
                    WriteVideoUnit(tls, encoded, payload, written, 1, timestamp, ref sequence);
                    ResumeVideoInput();
                    Notify("요청한 화질을 준비하지 못해 이전 화질로 돌아왔어요. 화면 연결은 유지돼요.");
                }
            }
            finally { videoControl.Complete(request); }
        }
    }
}
