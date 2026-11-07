// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace Knot.NativePreview
{
    internal interface IAudioCapture : IDisposable
    {
        // 0 = one PCM packet, 1 = no data yet. Negative results are audio-only failure.
        int Read(byte[] pcm, out int frames, out ulong firstSampleIndex);
    }
    internal interface IAudioCaptureFactory { IAudioCapture Open(); }
    internal sealed class WindowsAudioCaptureFactory : IAudioCaptureFactory
    { public IAudioCapture Open() { return new WindowsAudioCapture(); } }

    internal sealed class WindowsAudioCapture : IAudioCapture
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibraryEx(string name, IntPtr reserved, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
        private static extern IntPtr GetProcAddress(IntPtr module, string name);
        [DllImport("kernel32.dll")] private static extern bool FreeLibrary(IntPtr module);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int OpenDelegate(out IntPtr handle);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int ReadDelegate(IntPtr handle, [Out] byte[] samples,
            uint capacityFrames, out uint frames, out ulong firstSampleIndex, uint timeoutMilliseconds);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void CloseDelegate(IntPtr handle);
        private IntPtr library, capture;
        private ReadDelegate read;
        private CloseDelegate close;
        private readonly int owner;
        internal WindowsAudioCapture()
        {
            owner = Thread.CurrentThread.ManagedThreadId;
            if (Thread.CurrentThread.GetApartmentState() != ApartmentState.MTA) throw new NativeAudioException("unavailable");
            try
            {
                string path = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "KnotNativeMedia.dll"));
                library = LoadLibraryEx(path, IntPtr.Zero, 0x00000100 | 0x00000800);
                if (library == IntPtr.Zero) throw new NativeAudioException("unavailable");
                OpenDelegate open = Export<OpenDelegate>("kn_audio_open");
                read = Export<ReadDelegate>("kn_audio_read"); close = Export<CloseDelegate>("kn_audio_close");
                if (open(out capture) != 0 || capture == IntPtr.Zero) throw new NativeAudioException("unavailable");
            }
            catch { Dispose(); throw; }
        }
        private T Export<T>(string name) where T : class
        {
            IntPtr address = GetProcAddress(library, name);
            if (address == IntPtr.Zero) throw new NativeAudioException("unavailable");
            return Marshal.GetDelegateForFunctionPointer(address, typeof(T)) as T;
        }
        public int Read(byte[] pcm, out int frames, out ulong firstSampleIndex)
        {
            frames = 0; firstSampleIndex = 0;
            if (Thread.CurrentThread.ManagedThreadId != owner || capture == IntPtr.Zero || pcm == null ||
                pcm.Length < NativeAudioProtocol.MaximumPcmBytes) throw new NativeAudioException("unavailable");
            uint count;
            int result = read(capture, pcm, NativeAudioProtocol.MaximumFrames, out count, out firstSampleIndex, 20);
            if (result == 0 && (count < 1 || count > NativeAudioProtocol.MaximumFrames) || result != 0 && count != 0)
                throw new NativeAudioException("protocol");
            frames = (int)count; return result;
        }
        public void Dispose()
        {
            if (Thread.CurrentThread.ManagedThreadId != owner) throw new InvalidOperationException("Audio owner thread mismatch.");
            if (capture != IntPtr.Zero) { close(capture); capture = IntPtr.Zero; }
            if (library != IntPtr.Zero) { FreeLibrary(library); library = IntPtr.Zero; }
        }
    }
}
