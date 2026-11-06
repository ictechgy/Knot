// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Threading;
using IDataObject = System.Runtime.InteropServices.ComTypes.IDataObject;

namespace Knot.NativePreview
{
    internal static partial class NativeChecks
    {
        // These checks call the production IDropTarget methods directly with
        // newly constructed in-memory IDataObjects. They never call Capture,
        // enter DoDragDrop, inspect a clipboard, read a directory, send input or
        // start a file/network adapter. The separate window fixture registers
        // only a fresh, hidden, offscreen HWND on this owned STA.
        private static void DragBridgeChecks()
        {
            Exception failure = null;
            Thread fixture = new Thread(delegate()
            {
                try { DragStateChecks(); DragDataChecks(); DragOwnedWindowChecks(); } catch (Exception error) { failure = error; }
            });
            fixture.IsBackground = true; fixture.SetApartmentState(ApartmentState.STA); fixture.Start();
            Check(fixture.Join(5000));
            if (failure != null) throw failure;
        }

        private sealed class DragFixture
        {
            internal long Clock;
            internal bool Active = true;
            internal int Releases, Finishes;
            internal readonly ExplorerDropState State;
            internal readonly ExplorerDropTarget Target;
            internal DragFixture(IExplorerDropReader reader)
            {
                State = new ExplorerDropState(delegate { return Active; }, delegate { return Clock; }, 1000, 2000);
                Target = new ExplorerDropTarget(State, reader, delegate { ++Releases; return true; }, delegate { ++Finishes; return true; });
            }
            internal uint Enter(IDataObject data, uint keys, uint allowed)
            { Target.DragEnter(data, keys, new ExplorerPoint(0, 0), ref allowed); return allowed; }
            internal uint Drop(IDataObject data, uint allowed)
            { Target.Drop(data, 0, new ExplorerPoint(0, 0), ref allowed); return allowed; }
        }

        private sealed class InertDragReader : IExplorerDropReader
        {
            internal bool Supported = true;
            internal int Queries, Reads;
            internal Action OnQuery, OnRead;
            public bool Supports(IDataObject ignored)
            { ++Queries; if (OnQuery != null) OnQuery(); return Supported; }
            public string[] CopyPaths(IDataObject ignored)
            { ++Reads; if (OnRead != null) OnRead(); return new string[] { @"C:\Knot synthetic\fresh.txt" }; }
        }

        private static void DragStateChecks()
        {
            InertDragReader reader = new InertDragReader(); DragFixture fixture = new DragFixture(reader);
            Check(fixture.Enter(null, 0, 1) == 0 && reader.Queries == 0 && fixture.Releases == 0);
            Check(fixture.Enter(null, 1, 2) == 0 && reader.Queries == 0); // MOVE is never allowed.
            Check(fixture.Enter(null, 1, 4) == 0 && reader.Queries == 0); // LINK is never allowed.
            reader.Supported = false;
            Check(fixture.Enter(null, 1, 7) == 0 && reader.Queries == 1 && reader.Reads == 0 && fixture.Releases == 0);
            Check(fixture.Drop(null, 7) == 0 && reader.Reads == 0);
            fixture.State.CompleteOffCallback(); Check(fixture.State.Result == null);

            reader = new InertDragReader(); fixture = new DragFixture(reader);
            Check(fixture.Enter(null, 1, 7) == 1 && reader.Queries == 1 && reader.Reads == 0 && fixture.Releases == 1);
            uint effect = 7; fixture.Target.DragOver(1, new ExplorerPoint(), ref effect); Check(effect == 1);
            effect = 6; fixture.Target.DragOver(1, new ExplorerPoint(), ref effect); Check(effect == 0);
            Check(fixture.Drop(null, 7) == 1 && reader.Reads == 1 && fixture.Finishes == 1);
            Check(fixture.State.Result == null && fixture.State.CompletionRequested); // No publication in Drop.
            fixture.State.CompleteOffCallback(); Check(fixture.State.Result.Length == 1 && !fixture.State.Live);
            string[] copied = fixture.State.Result; copied[0] = @"C:\changed.txt";
            Check(fixture.State.Result[0] == @"C:\Knot synthetic\fresh.txt");
            Check(fixture.Enter(null, 1, 1) == 0 && fixture.Drop(null, 1) == 0 && reader.Reads == 1);

            reader = new InertDragReader(); fixture = new DragFixture(reader);
            Check(fixture.Drop(null, 1) == 0 && reader.Reads == 0); // No supported DragEnter.
            reader = new InertDragReader(); fixture = new DragFixture(reader);
            fixture.Enter(null, 1, 1); fixture.Target.DragLeave();
            Check(fixture.Drop(null, 1) == 0 && reader.Reads == 0 && fixture.State.Result == null);

            reader = new InertDragReader(); fixture = new DragFixture(reader);
            fixture.Clock = 2000;
            Check(fixture.Enter(null, 1, 1) == 0 && fixture.State.Expired && reader.Queries == 0);
            reader = new InertDragReader(); fixture = new DragFixture(reader);
            reader.OnQuery = delegate { fixture.Clock = 2000; };
            Check(fixture.Enter(null, 1, 1) == 0 && fixture.Releases == 0 && reader.Reads == 0);

            reader = new InertDragReader(); fixture = new DragFixture(reader);
            fixture.Enter(null, 1, 1); reader.OnRead = delegate { fixture.Clock = 2000; };
            Check(fixture.Drop(null, 1) == 0 && reader.Reads == 1);
            fixture.State.CompleteOffCallback(); Check(fixture.State.Result == null);

            reader = new InertDragReader(); fixture = new DragFixture(reader);
            fixture.Enter(null, 1, 1); reader.OnRead = delegate { fixture.Active = false; };
            Check(fixture.Drop(null, 1) == 0); fixture.State.CompleteOffCallback(); Check(fixture.State.Result == null);
            reader = new InertDragReader(); fixture = new DragFixture(reader);
            fixture.Enter(null, 1, 1); Check(fixture.Drop(null, 1) == 1);
            fixture.Active = false; fixture.State.CompleteOffCallback(); Check(fixture.State.Result == null);

            reader = new InertDragReader(); fixture = new DragFixture(reader);
            fixture.Enter(null, 1, 1); fixture.State.Revoke();
            Check(fixture.Drop(null, 1) == 0 && reader.Reads == 0);
            reader = new InertDragReader(); fixture = new DragFixture(reader);
            fixture.Enter(null, 1, 1); reader.OnRead = delegate { fixture.State.Revoke(); };
            Check(fixture.Drop(null, 1) == 0 && fixture.State.Result == null);

            reader = new InertDragReader(); fixture = new DragFixture(reader);
            ExplorerDropTarget failedQueue = new ExplorerDropTarget(fixture.State, reader, delegate { return false; }, delegate { return true; });
            effect = 1; failedQueue.DragEnter(null, 1, new ExplorerPoint(), ref effect);
            Check(effect == 0 && !fixture.State.Live && reader.Reads == 0);
        }

        // WinForms DataObject renders a real Unicode CF_HDROP HGLOBAL from only
        // these inert strings. None of the paths need exist or are inspected.
        private sealed class SyntheticDragData : IDataObject
        {
            private readonly IDataObject inner;
            internal int Queries, Reads;
            internal bool CorrectFormat = true;
            internal SyntheticDragData(string[] paths)
            {
                System.Windows.Forms.DataObject value = new System.Windows.Forms.DataObject();
                if (paths == null) value.SetData(System.Windows.Forms.DataFormats.UnicodeText, "synthetic text");
                else value.SetData(System.Windows.Forms.DataFormats.FileDrop, true, paths);
                inner = (IDataObject)value;
            }
            private void Format(FORMATETC format)
            {
                CorrectFormat &= format.cfFormat == 15 && format.dwAspect == DVASPECT.DVASPECT_CONTENT &&
                    format.lindex == -1 && format.ptd == IntPtr.Zero && format.tymed == TYMED.TYMED_HGLOBAL;
            }
            public int QueryGetData(ref FORMATETC format) { ++Queries; Format(format); return inner.QueryGetData(ref format); }
            public void GetData(ref FORMATETC format, out STGMEDIUM medium) { ++Reads; Format(format); inner.GetData(ref format, out medium); }
            public void GetDataHere(ref FORMATETC format, ref STGMEDIUM medium) { throw new NotSupportedException(); }
            public int GetCanonicalFormatEtc(ref FORMATETC format, out FORMATETC output) { output = new FORMATETC(); return 1; }
            public void SetData(ref FORMATETC format, ref STGMEDIUM medium, bool release) { throw new NotSupportedException(); }
            public IEnumFORMATETC EnumFormatEtc(DATADIR direction) { return inner.EnumFormatEtc(direction); }
            public int DAdvise(ref FORMATETC format, ADVF flags, IAdviseSink sink, out int connection) { connection = 0; return unchecked((int)0x80040003); }
            public void DUnadvise(int connection) { throw new NotSupportedException(); }
            public int EnumDAdvise(out IEnumSTATDATA connections) { connections = null; return unchecked((int)0x80040003); }
        }

        private static void DragDataChecks()
        {
            ExplorerHDropReader reader = new ExplorerHDropReader();
            foreach (string valid in new string[] { @"C:\Knot synthetic\fresh.txt", @"D:\새 폴더\빈 폴더", @"e:\ordinary😀.txt" })
                Check(ExplorerHDropReader.ValidLocalPath(valid));
            foreach (string invalid in new string[] { null, "", "C:\\", "C:relative", "relative.txt", @"\\host\share\file", @"\\?\C:\file", @"\\.\C:\file", @"C:\a\..\file", @"C:\.\file", "C:\\a\\", "C:\\a\\\\b", "C:\\a:b", "C:/file", "C:\\bad\nname", "C:\\bad?name", "C:\\bad.", "C:\\bad ", "C:\\bad\ud800name" })
                Check(!ExplorerHDropReader.ValidLocalPath(invalid));

            SyntheticDragData text = new SyntheticDragData(null); DragFixture fixture = new DragFixture(reader);
            Check(fixture.Enter(text, 1, 1) == 0 && text.Reads == 0 && fixture.Releases == 0 && text.CorrectFormat);
            SyntheticDragData data = new SyntheticDragData(new string[] { @"C:\Knot synthetic\fresh.txt", @"D:\새 폴더\빈 폴더" });
            fixture = new DragFixture(reader);
            Check(fixture.Enter(data, 1, 7) == 1 && data.Queries == 1 && data.Reads == 0);
            Check(fixture.Drop(data, 7) == 1 && data.Reads == 1 && data.CorrectFormat);
            Check(fixture.State.Result == null); fixture.State.CompleteOffCallback();
            Check(fixture.State.Result.Length == 2 && fixture.State.Result[1] == @"D:\새 폴더\빈 폴더");

            List<string> paths = new List<string>();
            for (int i = 0; i < 32; ++i) paths.Add(@"C:\Knot synthetic\item" + i + ".txt");
            data = new SyntheticDragData(paths.ToArray()); fixture = new DragFixture(reader);
            Check(fixture.Enter(data, 1, 1) == 1 && fixture.Drop(data, 1) == 1);
            fixture.State.CompleteOffCallback(); Check(fixture.State.Result.Length == 32);
            paths.Add(@"C:\Knot synthetic\item32.txt");
            data = new SyntheticDragData(paths.ToArray()); fixture = new DragFixture(reader);
            Check(fixture.Enter(data, 1, 1) == 1 && fixture.Drop(data, 1) == 0);
            fixture.State.CompleteOffCallback(); Check(fixture.State.Result == null && data.Reads == 1);
            foreach (string[] invalid in new string[][] {
                new string[0], new string[] { @"\\host\share\fresh.txt" }, new string[] { "C:relative.txt" },
                new string[] { @"C:\Knot synthetic\fresh.txt", @"c:\knot synthetic\FRESH.TXT" },
                new string[] { "C:\\" + new string('x', 32766) } })
            {
                data = new SyntheticDragData(invalid); fixture = new DragFixture(reader);
                fixture.Enter(data, 1, 1); Check(fixture.Drop(data, 1) == 0);
                fixture.State.CompleteOffCallback(); Check(fixture.State.Result == null);
            }
        }

        [DllImport("user32.dll", EntryPoint = "SendMessageW")]
        private static extern IntPtr DragFixtureMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
        private static extern int DragFixtureWindowStyle(IntPtr window, int index);
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetLayeredWindowAttributes(IntPtr window, out uint key, out byte alpha, out uint flags);
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool IsWindow(IntPtr window);

        private static void DragOwnedWindowChecks()
        {
            int initialized = ExplorerOle.OleInitialize(IntPtr.Zero); Check(initialized >= 0);
            ExplorerDropWindow window = new ExplorerDropWindow(); bool registered = false;
            InertDragReader reader = new InertDragReader(); DragFixture fixture = new DragFixture(reader);
            IntPtr handle = IntPtr.Zero;
            try
            {
                // No ShowWindow/SetWindowPos, cursor query or input. Messages go
                // only to this exact newly created, hidden offscreen window.
                window.Create(-30000, -30000); handle = window.Handle;
                Check(handle != IntPtr.Zero && IsWindow(handle));
                int style = DragFixtureWindowStyle(handle, -20);
                Check((style & 0x08080088) == 0x08080088 && (style & 0x20) == 0);
                Check((DragFixtureWindowStyle(handle, -16) & 0x10000000) == 0); // Hidden throughout.
                Check(ExplorerOle.SetLayeredWindowAttributes(handle, 0, 1, 2));
                uint key, flags; byte alpha;
                Check(GetLayeredWindowAttributes(handle, out key, out alpha, out flags) && alpha == 1 && (flags & 2) != 0);
                Check(DragFixtureMessage(handle, 0x84, IntPtr.Zero, IntPtr.Zero) == new IntPtr(1)); // HTCLIENT
                Check(DragFixtureMessage(handle, 0x21, IntPtr.Zero, IntPtr.Zero) == new IntPtr(3)); // MA_NOACTIVATE
                Check(ExplorerOle.RegisterDragDrop(handle, fixture.Target) == 0); registered = true;
                Check(ExplorerOle.RegisterDragDrop(handle, fixture.Target) == unchecked((int)0x80040101));
                const uint marker = 0x8051;
                Check(ExplorerOle.PostMessage(handle, marker, IntPtr.Zero, IntPtr.Zero));
                bool observed = false; Stopwatch until = Stopwatch.StartNew();
                while (!observed && until.ElapsedMilliseconds < 1000)
                {
                    ExplorerOle.Message message;
                    while (ExplorerOle.PeekMessage(out message, IntPtr.Zero, 0, 0, 1))
                    {
                        if (message.Window == handle && message.Value == marker) observed = true;
                        ExplorerOle.TranslateMessage(ref message); ExplorerOle.DispatchMessage(ref message);
                    }
                    if (!observed) ExplorerOle.MsgWaitForMultipleObjectsEx(0, IntPtr.Zero, 20, 0x4ff, 4);
                }
                Check(observed && reader.Queries == 0 && reader.Reads == 0 && fixture.Releases == 0);
                fixture.State.Revoke();
                Check(ExplorerOle.RevokeDragDrop(handle) == 0); registered = false;
                Check(ExplorerOle.RevokeDragDrop(handle) == unchecked((int)0x80040100));
            }
            finally
            {
                if (registered) ExplorerOle.RevokeDragDrop(handle);
                window.DestroyHandle();
                GC.KeepAlive(fixture.Target);
                ExplorerOle.OleUninitialize();
            }
            Check(!IsWindow(handle));
        }
    }
}
