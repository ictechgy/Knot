// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using IDataObject = System.Runtime.InteropServices.ComTypes.IDataObject;

namespace Knot.NativePreview
{
    // The input session creates this lease only for its ordered, single-use nonce.
    // IsActive remains true after ReleaseLeft until the handoff is disposed/revoked.
    internal interface IExplorerDragInputLease : IDisposable
    {
        int X { get; }
        int Y { get; }
        bool IsActive { get; }
        bool Nudge();
        bool ReleaseLeft();
        // Cancel the source OLE operation with an owned Escape down/up before
        // releasing the owned button. Also required when window creation fails.
        bool CancelDrag();
    }

    internal static class WindowsDragBridge
    {
        private static int running;

        internal static string[] Capture(IExplorerDragInputLease lease, Func<bool> active, int timeoutMilliseconds = 2000)
        {
            if (lease == null) throw new FileTransferException("denied");
            CaptureSession session = null;
            bool gateOwned = false, returned = false;
            try
            {
                if (active == null || timeoutMilliseconds < 1 || timeoutMilliseconds > 3000 || !active() || !lease.IsActive)
                    throw new FileTransferException("denied");
                gateOwned = Interlocked.CompareExchange(ref running, 1, 0) == 0;
                if (!gateOwned) throw new FileTransferException("busy");
                session = new CaptureSession(lease, active, timeoutMilliseconds);
                Thread thread = new Thread(session.Run);
                thread.IsBackground = true;
                thread.Name = "Knot Explorer drop target";
                thread.SetApartmentState(ApartmentState.STA);
                session.Thread = thread;
                thread.Start();
                session.Started = true;
                gateOwned = false; // The STA owns the global gate through its cleanup.
                while (!session.Done.WaitOne(20))
                {
                    if (session.State.Expired || !active() || !lease.IsActive)
                    {
                        // An out-of-process IDataObject can wedge an RPC in GetData.
                        // Revoke publication immediately, cancel owned input without
                        // waiting for that RPC, and let the STA destroy its own HWND
                        // when the OS call returns. At most one such STA can exist.
                        session.State.Revoke();
                        session.CancelOwnedInput();
                        session.Wake();
                        session.Done.WaitOne(150);
                        break;
                    }
                }
                string[] result = session.State.Result;
                if (result == null || !active() || !lease.IsActive)
                    throw new FileTransferException(session.State.Expired ? "timeout" : "denied");
                returned = true;
                return result;
            }
            finally
            {
                if (!returned)
                {
                    if (session != null) { session.State.Revoke(); session.CancelOwnedInput(); session.Wake(); }
                    else { try { lease.CancelDrag(); } catch { } }
                }
                try { lease.Dispose(); }
                finally
                {
                    if (gateOwned) Interlocked.Exchange(ref running, 0);
                    if (session != null && (!session.Started || session.Thread.Join(150))) session.Done.Dispose();
                }
            }
        }

        private sealed class CaptureSession
        {
            internal readonly ManualResetEvent Done = new ManualResetEvent(false);
            internal readonly ExplorerDropState State;
            internal Thread Thread;
            internal bool Started;
            private readonly IExplorerDragInputLease lease;
            private readonly object inputGate = new object();
            private readonly object windowGate = new object();
            private IntPtr window;
            private bool inputCancelled, leftReleased;
            private const uint ReleaseMessage = 0x8001, FinishMessage = 0x8002;

            internal CaptureSession(IExplorerDragInputLease input, Func<bool> active, int timeout)
            {
                lease = input;
                State = new ExplorerDropState(delegate { return active() && input.IsActive; }, Stopwatch.GetTimestamp,
                    Stopwatch.Frequency, timeout);
            }

            internal void Wake()
            {
                // Serialize posting with destruction so a recycled HWND can
                // never receive a cancellation message intended for our target.
                lock (windowGate)
                    if (window != IntPtr.Zero) ExplorerOle.PostMessage(window, FinishMessage, IntPtr.Zero, IntPtr.Zero);
            }

            internal void CancelOwnedInput()
            {
                lock (inputGate)
                {
                    if (inputCancelled || leftReleased) return;
                    inputCancelled = true;
                    try { lease.CancelDrag(); } catch { }
                }
            }

            private void ReleaseIntoTarget()
            {
                lock (inputGate)
                {
                    if (leftReleased || inputCancelled || !State.Entered || !State.Live) return;
                    // Nudge is restricted by the input lease to its captured point.
                    // It refreshes OLE hit testing after our tiny window appears.
                    // Never release a drag over a foreign window, even if another
                    // topmost window has covered the target in the meantime.
                    ExplorerPoint cursor;
                    if (!lease.Nudge() || !State.Live || !ExplorerOle.GetCursorPos(out cursor) ||
                        ExplorerOle.WindowFromPoint(cursor) != window)
                    { State.Revoke(); CancelOwnedInput(); return; }
                    if (!lease.ReleaseLeft()) { State.Revoke(); CancelOwnedInput(); return; }
                    leftReleased = true;
                }
            }

            internal void Run()
            {
                bool initialized = false, registered = false;
                ExplorerDropWindow owned = null;
                ExplorerDropTarget target = null;
                try
                {
                    if (!State.Live) return;
                    int initializedResult = ExplorerOle.OleInitialize(IntPtr.Zero);
                    if (initializedResult < 0) Marshal.ThrowExceptionForHR(initializedResult);
                    initialized = true;
                    owned = new ExplorerDropWindow();
                    owned.Create(lease.X, lease.Y);
                    lock (windowGate) window = owned.Handle;
                    target = new ExplorerDropTarget(State, new ExplorerHDropReader(delegate { return State.Live; }),
                        delegate { return ExplorerOle.PostMessage(owned.Handle, ReleaseMessage, IntPtr.Zero, IntPtr.Zero); },
                        delegate { return ExplorerOle.PostMessage(owned.Handle, FinishMessage, IntPtr.Zero, IntPtr.Zero); });
                    int registration = ExplorerOle.RegisterDragDrop(owned.Handle, target);
                    if (registration < 0) Marshal.ThrowExceptionForHR(registration);
                    registered = true;
                    if (!ExplorerOle.SetLayeredWindowAttributes(owned.Handle, 0, 1, 2) ||
                        !ExplorerOle.SetWindowPos(owned.Handle, new IntPtr(-1), lease.X - 16, lease.Y - 16, 33, 33, 0x50))
                        throw new InvalidOperationException("Temporary drop target unavailable.");
                    if (!State.Live || !lease.Nudge()) State.Revoke();
                    while (State.Live && !State.CompletionRequested)
                    {
                        ExplorerOle.Message message;
                        while (ExplorerOle.PeekMessage(out message, IntPtr.Zero, 0, 0, 1))
                        {
                            if (message.Value == ReleaseMessage) ReleaseIntoTarget();
                            else if (message.Value == FinishMessage) { }
                            else
                            {
                                ExplorerOle.TranslateMessage(ref message);
                                ExplorerOle.DispatchMessage(ref message);
                            }
                            if (!State.Live || State.CompletionRequested) break;
                        }
                        if (State.Live && !State.CompletionRequested)
                            ExplorerOle.MsgWaitForMultipleObjectsEx(0, IntPtr.Zero, 20, 0x4ff, 4);
                    }
                    // Publication and signaling occur after the OLE callback returns.
                    State.CompleteOffCallback();
                }
                catch { State.Revoke(); }
                finally
                {
                    State.CloseAdmission();
                    // Keep the rejecting shield present until abort input is sent.
                    // CancelDrag sends Escape before left-up if no shield exists.
                    if (State.Result == null) CancelOwnedInput();
                    if (registered && owned != null) { try { ExplorerOle.RevokeDragDrop(owned.Handle); } catch { } }
                    lock (windowGate)
                    {
                        window = IntPtr.Zero;
                        if (owned != null) { try { owned.DestroyHandle(); } catch { } }
                    }
                    if (initialized) ExplorerOle.OleUninitialize();
                    GC.KeepAlive(target);
                    Interlocked.Exchange(ref running, 0);
                    Done.Set();
                }
            }
        }
    }

    // Inert state seam: no HWND, OLE initialization, input, clipboard or networking.
    // Production and synthetic IDataObject callbacks use this same admission gate.
    internal sealed class ExplorerDropState
    {
        private readonly object gate = new object();
        private readonly Func<bool> active;
        private readonly Func<long> now;
        private readonly long deadline;
        private bool revoked, closed, entered, completionRequested;
        private string[] candidate, result;

        internal ExplorerDropState(Func<bool> live, Func<long> clock, long frequency, int timeout)
        {
            if (live == null || clock == null || frequency <= 0 || timeout < 1 || timeout > 3000)
                throw new ArgumentException("Invalid capture state.");
            active = live; now = clock; deadline = checked(clock() + checked(frequency * timeout) / 1000);
        }
        internal bool Expired { get { return now() >= deadline; } }
        internal bool Live
        {
            get
            {
                lock (gate) if (revoked || closed || Expired) return false;
                try { return active(); } catch { return false; }
            }
        }
        internal bool Entered { get { lock (gate) return entered; } }
        internal bool CompletionRequested { get { lock (gate) return completionRequested; } }
        internal string[] Result { get { lock (gate) return result == null ? null : (string[])result.Clone(); } }
        internal bool BeginEnter(uint keys, uint effects)
        {
            lock (gate) entered = false;
            return (keys & 1) != 0 && (effects & 1) != 0 && Live;
        }
        internal bool AcceptEnter()
        {
            if (!Live) return false;
            lock (gate) { if (revoked || closed || Expired) return false; entered = true; return true; }
        }
        internal bool CanOver(uint effects) { return (effects & 1) != 0 && Entered && Live; }
        internal bool BeginDrop(uint effects)
        {
            if (!CanOver(effects)) return false;
            lock (gate) { if (!entered || revoked || closed || Expired) return false; entered = false; return true; }
        }
        internal bool SetCandidate(string[] paths)
        {
            if (!Live || paths == null || paths.Length < 1 || paths.Length > 32) return false;
            lock (gate)
            {
                if (revoked || closed || Expired || completionRequested) return false;
                candidate = (string[])paths.Clone(); completionRequested = true; return true;
            }
        }
        internal void CompleteOffCallback()
        {
            bool live = Live;
            lock (gate)
            {
                if (live && !revoked && !closed && !Expired && candidate != null) result = candidate;
                candidate = null; closed = true;
            }
        }
        internal void Revoke()
        { lock (gate) { revoked = true; entered = false; candidate = result = null; completionRequested = true; } }
        internal void CloseAdmission() { lock (gate) { closed = true; entered = false; candidate = null; } }
    }

    internal interface IExplorerDropReader
    {
        bool Supports(IDataObject data);
        string[] CopyPaths(IDataObject data);
    }

    internal sealed class ExplorerHDropReader : IExplorerDropReader
    {
        private readonly Func<bool> canRead;
        internal ExplorerHDropReader() : this(delegate { return true; }) { }
        internal ExplorerHDropReader(Func<bool> live) { canRead = live; }
        private bool CanRead { get { try { return canRead != null && canRead(); } catch { return false; } } }
        private static FORMATETC Format()
        { return new FORMATETC { cfFormat = 15, dwAspect = DVASPECT.DVASPECT_CONTENT, lindex = -1, ptd = IntPtr.Zero, tymed = TYMED.TYMED_HGLOBAL }; }
        public bool Supports(IDataObject data)
        {
            if (data == null) return false;
            FORMATETC format = Format();
            try { return data.QueryGetData(ref format) == 0; } catch { return false; }
        }
        public string[] CopyPaths(IDataObject data)
        {
            // This is called only by Drop on the OLE STA. Neither the data object
            // nor STGMEDIUM is retained, enqueued or returned to a file worker.
            if (!CanRead || !Supports(data) || !CanRead) return null;
            FORMATETC format = Format(); STGMEDIUM medium = new STGMEDIUM();
            bool acquired = false;
            try
            {
                data.GetData(ref format, out medium); acquired = true;
                if (!CanRead || medium.tymed != TYMED.TYMED_HGLOBAL || medium.unionmember == IntPtr.Zero) return null;
                uint count = ExplorerOle.DragQueryFile(medium.unionmember, uint.MaxValue, null, 0);
                if (count < 1 || count > 32) return null;
                string[] paths = new string[(int)count]; int total = 0;
                HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                for (uint i = 0; i < count; ++i)
                {
                    if (!CanRead) return null;
                    uint size = ExplorerOle.DragQueryFile(medium.unionmember, i, null, 0);
                    if (size < 4 || size > 32767 || (total += (int)size) > 32768) return null;
                    StringBuilder text = new StringBuilder((int)size + 1);
                    if (ExplorerOle.DragQueryFile(medium.unionmember, i, text, (uint)text.Capacity) != size) return null;
                    string path = text.ToString();
                    if (path.Length != size || !ValidLocalPath(path) || !seen.Add(path)) return null;
                    paths[(int)i] = path;
                }
                return paths;
            }
            catch { return null; }
            finally { if (acquired) ExplorerOle.ReleaseStgMedium(ref medium); }
        }
        internal static bool ValidLocalPath(string path)
        {
            if (path == null || path.Length < 4 || path.Length > 32767 ||
                !((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z')) ||
                path[1] != ':' || path[2] != '\\') return false;
            string[] components = path.Substring(3).Split('\\');
            foreach (string component in components)
            {
                if (component.Length == 0 || component == "." || component == ".." ||
                    component[component.Length - 1] == '.' || component[component.Length - 1] == ' ') return false;
                for (int i = 0; i < component.Length; ++i)
                {
                    char c = component[i];
                    if (c < 32 || c == 127 || c == ':' || c == '/' || c == '*' || c == '?' || c == '"' || c == '<' || c == '>' || c == '|') return false;
                    if (char.IsHighSurrogate(c)) { if (++i >= component.Length || !char.IsLowSurrogate(component[i])) return false; }
                    else if (char.IsLowSurrogate(c)) return false;
                }
            }
            return true;
        }
    }

    [ComImport, ComVisible(true), Guid("00000122-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IExplorerDropTarget
    {
        [PreserveSig] int DragEnter([MarshalAs(UnmanagedType.Interface)] IDataObject data, uint keys, ExplorerPoint point, ref uint effect);
        [PreserveSig] int DragOver(uint keys, ExplorerPoint point, ref uint effect);
        [PreserveSig] int DragLeave();
        [PreserveSig] int Drop([MarshalAs(UnmanagedType.Interface)] IDataObject data, uint keys, ExplorerPoint point, ref uint effect);
    }

    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    internal sealed class ExplorerDropTarget : IExplorerDropTarget
    {
        private readonly ExplorerDropState state;
        private readonly IExplorerDropReader reader;
        private readonly Func<bool> release, finish;
        internal ExplorerDropTarget(ExplorerDropState capture, IExplorerDropReader source, Func<bool> queueRelease, Func<bool> queueFinish)
        { state = capture; reader = source; release = queueRelease; finish = queueFinish; }
        public int DragEnter(IDataObject data, uint keys, ExplorerPoint point, ref uint effect)
        {
            uint allowed = effect; effect = 0;
            try
            {
                if (state.BeginEnter(keys, allowed) && reader.Supports(data) && state.AcceptEnter())
                {
                    if (release()) effect = 1;
                    else state.Revoke();
                }
            }
            catch { state.Revoke(); }
            return 0;
        }
        public int DragOver(uint keys, ExplorerPoint point, ref uint effect)
        { effect = state.CanOver(effect) ? 1U : 0U; return 0; }
        public int DragLeave() { state.Revoke(); try { finish(); } catch { } return 0; }
        public int Drop(IDataObject data, uint keys, ExplorerPoint point, ref uint effect)
        {
            uint allowed = effect; effect = 0;
            try
            {
                if (state.BeginDrop(allowed))
                {
                    string[] paths = reader.CopyPaths(data);
                    if (state.SetCandidate(paths)) effect = 1;
                    else state.Revoke();
                }
                else state.Revoke();
                if (!finish()) { state.Revoke(); effect = 0; }
            }
            catch { state.Revoke(); effect = 0; }
            return 0;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct ExplorerPoint
    {
        internal int X, Y;
        internal ExplorerPoint(int x, int y) { X = x; Y = y; }
    }

    internal sealed class ExplorerDropWindow : NativeWindow
    {
        internal void Create(int x, int y)
        {
            CreateHandle(new CreateParams { Caption = "Knot temporary copy handoff", X = x - 16, Y = y - 16,
                Width = 33, Height = 33, Style = unchecked((int)0x80000000), ExStyle = 0x08080088 });
        }
        protected override void WndProc(ref System.Windows.Forms.Message message)
        {
            if (message.Msg == 0x21) { message.Result = new IntPtr(3); return; } // MA_NOACTIVATE
            if (message.Msg == 0x84) { message.Result = new IntPtr(1); return; } // HTCLIENT
            base.WndProc(ref message);
        }
    }

    internal static class ExplorerOle
    {
        [StructLayout(LayoutKind.Sequential)]
        internal struct Message { internal IntPtr Window; internal uint Value; internal UIntPtr WParam; internal IntPtr LParam; internal uint Time; internal ExplorerPoint Point; }
        [DllImport("ole32.dll")] internal static extern int OleInitialize(IntPtr reserved);
        [DllImport("ole32.dll")] internal static extern void OleUninitialize();
        [DllImport("ole32.dll")] internal static extern int RegisterDragDrop(IntPtr window, [MarshalAs(UnmanagedType.Interface)] IExplorerDropTarget target);
        [DllImport("ole32.dll")] internal static extern int RevokeDragDrop(IntPtr window);
        [DllImport("ole32.dll")] internal static extern void ReleaseStgMedium(ref STGMEDIUM medium);
        [DllImport("shell32.dll", EntryPoint = "DragQueryFileW", CharSet = CharSet.Unicode)]
        internal static extern uint DragQueryFile(IntPtr drop, uint index, StringBuilder path, uint size);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool PeekMessage(out Message message, IntPtr window, uint minimum, uint maximum, uint remove);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool TranslateMessage(ref Message message);
        [DllImport("user32.dll")] internal static extern IntPtr DispatchMessage(ref Message message);
        [DllImport("user32.dll")] internal static extern uint MsgWaitForMultipleObjectsEx(uint count, IntPtr handles, uint timeout, uint wakeMask, uint flags);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetLayeredWindowAttributes(IntPtr window, uint color, byte alpha, uint flags);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
        [DllImport("user32.dll")] internal static extern IntPtr WindowFromPoint(ExplorerPoint point);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetCursorPos(out ExplorerPoint point);
    }
}
