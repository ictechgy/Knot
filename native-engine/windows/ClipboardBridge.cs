using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace Knot.NativePreview
{
    internal interface IClipboardText
    {
        uint Sequence { get; }
        string ReadText();
        void WriteText(string text);
    }
    // Only an OS resource temporarily unavailable is retriable. Malformed,
    // oversized content remains a permanent gesture failure. A format absent
    // while the owner publishes its selection spends only the same deadline.
    internal sealed class ClipboardUnavailableException : ExternalException { }
    internal sealed class WindowsClipboardText : IClipboardText
    {
        [DllImport("user32.dll")] private static extern uint GetClipboardSequenceNumber();
        [DllImport("user32.dll", SetLastError = true)] private static extern bool OpenClipboard(IntPtr owner);
        [DllImport("user32.dll")] private static extern bool CloseClipboard();
        [DllImport("user32.dll")] private static extern IntPtr GetClipboardData(uint format);
        [DllImport("user32.dll")] private static extern bool IsClipboardFormatAvailable(uint format);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern UIntPtr GlobalSize(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr GlobalLock(IntPtr handle);
        [DllImport("kernel32.dll")] private static extern bool GlobalUnlock(IntPtr handle);
        public uint Sequence { get { return GetClipboardSequenceNumber(); } }
        public string ReadText()
        {
            // Never materialize an unbounded external OLE object or follow files.
            if (!OpenClipboard(IntPtr.Zero)) throw new ClipboardUnavailableException();
            try
            {
                if (!IsClipboardFormatAvailable(13)) throw new ClipboardUnavailableException();
                IntPtr handle = GetClipboardData(13); // CF_UNICODETEXT only.
                if (handle == IntPtr.Zero) throw new ClipboardUnavailableException();
                ulong size = GlobalSize(handle).ToUInt64();
                if (size < 2 || size > (ulong)(ClipboardProtocol.MaximumTextBytes + 1) * 2 || size % 2 != 0) throw new ProtocolException("protocol");
                IntPtr address = GlobalLock(handle);
                if (address == IntPtr.Zero) throw new ClipboardUnavailableException();
                try
                {
                    int units = (int)size / 2, length = 0;
                    while (length < units && Marshal.ReadInt16(address, length * 2) != 0) ++length;
                    if (length == units) throw new ProtocolException("protocol");
                    string text = Marshal.PtrToStringUni(address, length);
                    byte[] bytes = StrictJson.Utf8.GetBytes(text);
                    return ClipboardProtocol.Text(bytes, 0, bytes.Length);
                }
                finally { GlobalUnlock(handle); }
            }
            finally { CloseClipboard(); }
        }
        public void WriteText(string text)
        {
            // Reuse explicit-copy history/cloud exclusions; never copy files or HTML.
            SecretClipboard.CopyOwnInvitation(text);
        }
    }
    internal sealed class ClipboardBridge : IDisposable
    {
        private static int staOwned;
        private readonly object gate = new object();
        private readonly Action<byte> shortcut;
        private readonly Func<bool> authorized;
        private readonly IClipboardText clipboard;
        private bool disposed, busy;
        private int generation;
        private byte[] response;
        internal ClipboardBridge(Action<byte> shortcut, Func<bool> authorized) : this(shortcut, authorized, new WindowsClipboardText()) { }
        internal ClipboardBridge(Action<byte> shortcut, Func<bool> authorized, IClipboardText clipboard)
        { this.shortcut = shortcut; this.authorized = authorized; this.clipboard = clipboard; }
        internal void Handle(byte[] payload)
        {
            ClipboardRequest request = ClipboardProtocol.Request(payload);
            lock (gate)
            {
                if (disposed || !authorized()) return;
                // At most one gesture and one result per session. A wedged OS
                // adapter retains the process-wide STA lease until it returns.
                if (busy || response != null) return;
                if (Interlocked.CompareExchange(ref staOwned, 1, 0) != 0)
                { response = ClipboardProtocol.Response(request, 3, ""); return; }
                busy = true;
                int ownedGeneration = generation;
                Thread worker = new Thread(delegate() { Execute(request, ownedGeneration); });
                worker.IsBackground = true; worker.Name = "Knot explicit text clipboard";
                worker.SetApartmentState(ApartmentState.STA);
                try { worker.Start(); }
                catch { busy = false; Interlocked.Exchange(ref staOwned, 0); throw; }
            }
        }
        private bool Allowed(int ownedGeneration) { lock (gate) return !disposed && generation == ownedGeneration && authorized(); }
        private void Execute(ClipboardRequest request, int ownedGeneration)
        {
            byte status = 1; string text = "";
            try
            {
                if (!Allowed(ownedGeneration)) { status = 2; return; }
                if (request.Operation == 1)
                {
                    uint before = clipboard.Sequence;
                    if (!Allowed(ownedGeneration)) { status = 2; return; }
                    shortcut(1);
                    long deadline = Stopwatch.GetTimestamp() + Stopwatch.Frequency;
                    // Ctrl+C is asynchronous. Never return the previous selection
                    // if the application does not publish a new clipboard value.
                    while (Allowed(ownedGeneration) && clipboard.Sequence == before && Stopwatch.GetTimestamp() < deadline) Thread.Sleep(10);
                    if (!Allowed(ownedGeneration)) { status = 2; return; }
                    if (clipboard.Sequence == before) return;
                    while (true)
                    {
                        if (!Allowed(ownedGeneration)) { status = 2; return; }
                        try { text = clipboard.ReadText(); break; }
                        catch (ClipboardUnavailableException)
                        {
                            if (Stopwatch.GetTimestamp() >= deadline) return;
                            Thread.Sleep(10);
                        }
                    }
                    if (!Allowed(ownedGeneration)) { text = ""; status = 2; return; }
                    byte[] bytes = StrictJson.Utf8.GetBytes(text); ClipboardProtocol.Text(bytes, 0, bytes.Length);
                }
                else
                {
                    if (!Allowed(ownedGeneration)) { status = 2; return; }
                    clipboard.WriteText(request.Text);
                    if (!Allowed(ownedGeneration)) { status = 2; return; }
                    shortcut(2);
                }
                status = 0;
            }
            catch { status = 1; text = ""; }
            finally
            {
                Interlocked.Exchange(ref staOwned, 0);
                lock (gate)
                {
                    busy = false;
                    if (!disposed && generation == ownedGeneration && authorized()) response = ClipboardProtocol.Response(request, status, status == 0 ? text : "");
                }
            }
        }
        internal bool IsBusy { get { lock (gate) return busy; } }
        internal bool TryTake(out byte[] result)
        {
            lock (gate) { result = response; response = null; return result != null && !disposed && authorized(); }
        }
        internal void Cancel() { lock (gate) { ++generation; response = null; } }
        public void Dispose() { lock (gate) { disposed = true; response = null; } }
    }
}
