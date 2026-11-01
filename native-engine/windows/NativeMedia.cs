using System;
using System.IO;
using System.Runtime.InteropServices;

namespace Knot.NativePreview
{
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    internal struct MediaConfig { internal uint Width, Height, Fps, Bitrate; }
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    internal struct MediaInfo
    {
        internal uint Width, Height, Fps, Bitrate;
        internal int Left, Top, DesktopWidth, DesktopHeight;
        internal uint HardwareEncoder;
        internal CaptureRectangle Rectangle { get { return new CaptureRectangle(Left, Top, DesktopWidth, DesktopHeight); } }
        internal byte[] Ready()
        {
            if (Width < 16 || Width > 1920 || Height < 16 || Height > 1080 || Width % 2 != 0 || Height % 2 != 0 ||
                Fps < 1 || Fps > 60 || Bitrate < 1000000 || Bitrate > 40000000 || HardwareEncoder != 1 ||
                DesktopWidth < 1 || DesktopWidth > 32768 || DesktopHeight < 1 || DesktopHeight > 32768 ||
                Math.Abs((long)Left) > 65536 || Math.Abs((long)Top) > 65536) throw new ProtocolException("encoder");
            return StrictJson.Utf8.GetBytes(string.Format(System.Globalization.CultureInfo.InvariantCulture,
                "{{\"v\":1,\"codec\":\"h264-annexb\",\"width\":{0},\"height\":{1},\"fps\":{2},\"bitrate\":{3},\"hardwareEncoder\":true}}", Width, Height, Fps, Bitrate));
        }
    }
    internal interface IMediaSource : IDisposable
    {
        MediaInfo Info { get; }
        int Read(byte[] buffer, out uint written, out uint flags, out ulong timestampMicros);
    }
    internal interface IMediaFactory { IMediaSource Open(); }

    internal sealed class WindowsMediaFactory : IMediaFactory
    {
        public IMediaSource Open() { return new WindowsMediaSource(); }
    }

    // The owned DLL is resolved by absolute application path with dependency search
    // limited to that directory and System32. No PATH/current-directory probing.
    internal sealed class WindowsMediaSource : IMediaSource
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibraryEx(string name, IntPtr reserved, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
        private static extern IntPtr GetProcAddress(IntPtr module, string name);
        [DllImport("kernel32.dll")] private static extern bool FreeLibrary(IntPtr module);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate IntPtr CreateDelegate(ref MediaConfig config, out MediaInfo info, out int error);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int ReadDelegate(IntPtr media, [Out] byte[] buffer, uint capacity, out uint written, out uint flags, out ulong timestamp);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void CloseDelegate(IntPtr media);
        private IntPtr library, media;
        private ReadDelegate read;
        private CloseDelegate close;
        private MediaInfo info;
        private readonly int ownerThread;
        public MediaInfo Info { get { return info; } }
        private T Export<T>(string name) where T : class
        {
            IntPtr p = GetProcAddress(library, name);
            if (p == IntPtr.Zero) throw new ProtocolException("capture");
            return Marshal.GetDelegateForFunctionPointer(p, typeof(T)) as T;
        }
        internal WindowsMediaSource()
        {
            ownerThread = System.Threading.Thread.CurrentThread.ManagedThreadId;
            if (System.Threading.Thread.CurrentThread.GetApartmentState() != System.Threading.ApartmentState.MTA) throw new ProtocolException("capture");
            try
            {
                string path = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "KnotNativeMedia.dll"));
                library = LoadLibraryEx(path, IntPtr.Zero, 0x00000100 | 0x00000800);
                if (library == IntPtr.Zero) throw new ProtocolException("capture");
                CreateDelegate create = Export<CreateDelegate>("kn_media_create");
                read = Export<ReadDelegate>("kn_media_read");
                close = Export<CloseDelegate>("kn_media_close");
                MediaConfig config = new MediaConfig { Width = 1920, Height = 1080, Fps = 60, Bitrate = 12000000 };
                int error;
                media = create(ref config, out info, out error);
                if (media == IntPtr.Zero) throw new ProtocolException(error == -3 ? "encoder" : "capture");
                info.Ready();
            }
            catch { Dispose(); throw; }
        }
        public int Read(byte[] buffer, out uint written, out uint flags, out ulong timestampMicros)
        {
            if (ownerThread != System.Threading.Thread.CurrentThread.ManagedThreadId || media == IntPtr.Zero) throw new ProtocolException("capture");
            return read(media, buffer, (uint)buffer.Length, out written, out flags, out timestampMicros);
        }
        public void Dispose()
        {
            if (ownerThread != System.Threading.Thread.CurrentThread.ManagedThreadId) throw new InvalidOperationException("Media ownership thread mismatch.");
            if (media != IntPtr.Zero) { close(media); media = IntPtr.Zero; }
            if (library != IntPtr.Zero) { FreeLibrary(library); library = IntPtr.Zero; }
        }
    }

    internal static class AnnexB
    {
        private static int Prefix(byte[] b, int i, int count)
        {
            if (i + 3 > count || b[i] != 0 || b[i + 1] != 0) return 0;
            if (b[i + 2] == 1) return 3;
            return i + 4 <= count && b[i + 2] == 0 && b[i + 3] == 1 ? 4 : 0;
        }
        internal static void Validate(byte[] bytes, int count, uint flags)
        {
            if (count < 4 || count > NativeProtocol.VideoLimit - 17 || flags > 1 || Prefix(bytes, 0, count) == 0) throw new ProtocolException("encoder");
            int at = 0, nals = 0, spsCount = 0, ppsCount = 0;
            bool sps = false, pps = false, idr = false;
            while (at < count)
            {
                int prefix = Prefix(bytes, at, count), payload = at + prefix;
                if (prefix == 0 || payload >= count || ++nals > 128) throw new ProtocolException("encoder");
                int next = payload + 1;
                while (next < count && Prefix(bytes, next, count) == 0) ++next;
                int type = bytes[payload] & 31;
                if ((bytes[payload] & 128) != 0 || type < 1 || type > 23 || (type == 7 || type == 8) && next - payload > 65536) throw new ProtocolException("encoder");
                if (type == 7) { sps = true; if (++spsCount > 8) throw new ProtocolException("encoder"); }
                if (type == 8) { pps = true; if (++ppsCount > 8) throw new ProtocolException("encoder"); }
                if (type == 5) idr = true;
                at = next;
            }
            if (flags == 1 && !(sps && pps && idr)) throw new ProtocolException("encoder");
        }
    }
}
