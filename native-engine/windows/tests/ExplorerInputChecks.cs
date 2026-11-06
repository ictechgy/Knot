// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.Threading;

namespace Knot.NativePreview
{
    internal static partial class NativeChecks
    {
        private static int explorerInputFixtures, explorerOleFixtures;
        private sealed class ExplorerInputFixture : IInputSink
        {
            internal readonly List<string> Calls = new List<string>();
            internal readonly ManualResetEvent Released = new ManualResetEvent(false);
            internal int FailedUps;
            public bool Key(ushort scan, bool extended, bool down)
            { Calls.Add((down ? "down:" : "up:") + scan); return true; }
            public bool Text(string text) { Calls.Add("text"); return true; }
            public bool ReleaseUnicode() { return true; }
            public bool Pointer(byte action, ushort x, ushort y, CaptureRectangle rectangle)
            { Calls.Add("pointer:" + action); return true; }
            public bool ReleaseButton(byte button)
            {
                Calls.Add("release:" + button);
                if (FailedUps-- > 0) return false;
                Released.Set(); return true;
            }
            public bool Wheel(int vertical, int horizontal) { Calls.Add("wheel"); return true; }
        }
        private static void ExplorerInputChecks()
        {
            byte[] nonce = new byte[16]; nonce[15] = 7;
            string hex = FileProtocol.Hex(nonce);
            ExplorerInputFixture sink = new ExplorerInputFixture();
            InputSession input = new InputSession(sink, new CaptureRectangle(10, 20, 1920, 1080));
            Reject(delegate { input.Accept(new Packet(0x26, new byte[15])); });
            input.Accept(new Packet(0x22, new byte[] { 1, 0, 0, 255, 255 }));
            input.Accept(new Packet(0x26, nonce));
            input.Accept(new Packet(0x22, new byte[] { 0, 255, 255, 0, 0 }));
            input.Accept(Key(1, 30)); input.Accept(new Packet(0x21, Bytes("not replayed")));
            Check(sink.Calls.Count == 1);
            FileReject(delegate { input.AcquireExplorerDrag(new string('f', 32)); });
            IExplorerDragInputLease lease = input.AcquireExplorerDrag(hex);
            Check(lease.X == 10 && lease.Y == 1099 && lease.IsActive);
            FileReject(delegate { input.AcquireExplorerDrag(hex); });
            Check(lease.Nudge() && sink.Calls.Count == 2);
            Check(lease.ReleaseLeft() && lease.IsActive && sink.Calls[2] == "release:1");
            Check(lease.ReleaseLeft() && sink.Calls.Count == 3);
            lease.Dispose(); Check(!lease.IsActive && !lease.Nudge());
            input.Accept(Key(1, 30)); input.Accept(Key(0, 30)); input.Close();
            Check(sink.Calls.Count == 5 && !sink.Calls.Contains("down:1"));

            sink = new ExplorerInputFixture(); input = new InputSession(sink, new CaptureRectangle(0, 0, 100, 100));
            input.Accept(new Packet(0x22, new byte[] { 1, 0, 0, 0, 0 })); input.Accept(new Packet(0x26, nonce));
            lease = input.AcquireExplorerDrag(hex); Check(lease.CancelDrag());
            Check(!lease.IsActive && sink.Calls[1] == "down:1" && sink.Calls[2] == "up:1" && sink.Calls[3] == "release:1");
            lease.Dispose(); input.Close(); Check(sink.Calls.Count == 4);

            sink = new ExplorerInputFixture(); input = new InputSession(sink, new CaptureRectangle(0, 0, 100, 100));
            input.Accept(new Packet(0x22, new byte[] { 1, 0, 0, 0, 0 })); input.Accept(new Packet(0x26, nonce));
            lease = input.AcquireExplorerDrag(hex); input.Accept(new Packet(0x24, new byte[0]));
            Check(!lease.IsActive && sink.Calls.Count == 4); lease.Dispose(); input.Close();

            sink = new ExplorerInputFixture(); sink.FailedUps = 1;
            input = new InputSession(sink, new CaptureRectangle(0, 0, 100, 100)); int failures = 0;
            input.ExplorerReleaseFailed = delegate { ++failures; };
            input.Accept(new Packet(0x22, new byte[] { 1, 0, 0, 0, 0 })); input.Accept(new Packet(0x26, nonce));
            lease = input.AcquireExplorerDrag(hex); Check(!lease.ReleaseLeft() && failures == 1);
            input.Close(); Check(!lease.IsActive && sink.Released.WaitOne(0)); lease.Dispose();

            sink = new ExplorerInputFixture(); input = new InputSession(sink, new CaptureRectangle(0, 0, 100, 100));
            input.Accept(new Packet(0x22, new byte[] { 1, 0, 0, 0, 0 })); input.Accept(new Packet(0x26, nonce));
            Check(sink.Released.WaitOne(4000)); input.Close();
            using (System.IO.MemoryStream framed = new System.IO.MemoryStream())
            {
                NativeProtocol.Write(framed, 0x26, nonce); framed.Position = 0;
                Check(NativeProtocol.ReadClient(framed, false).Payload.Length == 16);
            }
            ++explorerInputFixtures;
        }
    }
}
