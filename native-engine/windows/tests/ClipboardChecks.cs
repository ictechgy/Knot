using System;
using System.Threading;

namespace Knot.NativePreview
{
    internal static partial class NativeChecks
    {
        private sealed class SyntheticClipboard : IClipboardText
        {
            internal uint SequenceNumber = 1;
            internal int Reads, Writes;
            internal string Text = "synthetic";
            public uint Sequence { get { return SequenceNumber; } }
            public string ReadText() { ++Reads; return Text; }
            public void WriteText(string text) { ++Writes; Text = text; ++SequenceNumber; }
        }
        private static byte[] ClipboardRequestBytes(byte operation, string text)
        {
            byte[] bytes = Bytes(text), result = new byte[17 + bytes.Length]; result[0] = operation;
            for (int i = 1; i < 17; ++i) result[i] = (byte)i;
            Buffer.BlockCopy(bytes, 0, result, 17, bytes.Length); return result;
        }
        private static byte[] WaitClipboard(ClipboardBridge bridge)
        {
            byte[] response;
            for (int i = 0; i < 250; ++i) { if (bridge.TryTake(out response)) return response; Thread.Sleep(10); }
            throw new InvalidOperationException("Synthetic clipboard response timeout.");
        }
        private static void ClipboardChecks()
        {
            ClipboardRequest copy = ClipboardProtocol.Request(ClipboardRequestBytes(1, ""));
            Check(copy.Operation == 1 && copy.Nonce.Length == 16 && copy.Text == "");
            Check(ClipboardProtocol.Request(ClipboardRequestBytes(2, "한글\ncode")).Text == "한글\ncode");
            Reject(delegate { ClipboardProtocol.Request(ClipboardRequestBytes(1, "stale")); });
            Reject(delegate { ClipboardProtocol.Request(ClipboardRequestBytes(2, "bad\0value")); });
            Reject(delegate { ClipboardProtocol.Request(new byte[16]); });
            Reject(delegate { ClipboardProtocol.Request(ClipboardRequestBytes(2, new string('x', ClipboardProtocol.MaximumTextBytes + 1))); });
            byte[] invalidUtf8 = ClipboardRequestBytes(2, "x"); invalidUtf8[17] = 255;
            Reject(delegate { ClipboardProtocol.Request(invalidUtf8); });
            SyntheticClipboard clipboard = new SyntheticClipboard(); int shortcuts = 0;
            using (ClipboardBridge bridge = new ClipboardBridge(delegate(byte operation) { ++shortcuts; ++clipboard.SequenceNumber; }, delegate { return true; }, clipboard))
            {
                Check(clipboard.Reads == 0 && clipboard.Writes == 0);
                bridge.Handle(ClipboardRequestBytes(1, "")); byte[] result = WaitClipboard(bridge);
                Check(result[0] == 1 && result[1] == 0 && ClipboardProtocol.Text(result, 18, result.Length - 18) == "synthetic");
                Check(clipboard.Reads == 1 && shortcuts == 1);
                bridge.Handle(ClipboardRequestBytes(2, "pasted")); result = WaitClipboard(bridge);
                Check(result.Length == 18 && result[0] == 2 && result[1] == 0 && clipboard.Text == "pasted" && clipboard.Writes == 1 && shortcuts == 2);
            }
            // A copy which never publishes fresh data cannot disclose old text.
            SyntheticClipboard stale = new SyntheticClipboard();
            using (ClipboardBridge bridge = new ClipboardBridge(delegate(byte operation) { }, delegate { return true; }, stale))
            {
                bridge.Handle(ClipboardRequestBytes(1, "")); byte[] result = WaitClipboard(bridge);
                Check(result[1] == 1 && result.Length == 18 && stale.Reads == 0);
            }
            // Cancel while the owned shortcut is pending: do not read or emit late data.
            using (ManualResetEvent entered = new ManualResetEvent(false))
            using (ManualResetEvent release = new ManualResetEvent(false))
            using (ManualResetEvent finished = new ManualResetEvent(false))
            {
                SyntheticClipboard cancelled = new SyntheticClipboard();
                using (ClipboardBridge bridge = new ClipboardBridge(delegate(byte operation) { entered.Set(); release.WaitOne(2000); ++cancelled.SequenceNumber; finished.Set(); }, delegate { return true; }, cancelled))
                {
                    bridge.Handle(ClipboardRequestBytes(1, "")); Check(entered.WaitOne(2000));
                    bridge.Cancel(); release.Set(); Check(finished.WaitOne(2000));
                    for (int i = 0; i < 250 && bridge.IsBusy; ++i) Thread.Sleep(10);
                    Check(!bridge.IsBusy); byte[] ignored;
                    Check(!bridge.TryTake(out ignored) && cancelled.Reads == 0);
                }
            }
            FakeInput sink = new FakeInput();
            InputSession session = new InputSession(sink, new CaptureRectangle(0, 0, 1920, 1080));
            session.ClipboardShortcut(1);
            Check(sink.Events.Count == 4 && sink.Events[0] == "key:29:down" && sink.Events[1] == "key:46:down" && sink.Events[2] == "key:46:up" && sink.Events[3] == "key:29:up");
            session.Close(); Reject(delegate { session.ClipboardShortcut(2); });
        }
    }
}
