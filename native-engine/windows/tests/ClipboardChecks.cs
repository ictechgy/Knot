using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Threading;

namespace Knot.NativePreview
{
    internal static partial class NativeChecks
    {
        private sealed class SyntheticClipboard : IClipboardText
        {
            internal uint SequenceNumber = 1;
            internal int Reads, Writes, TransientFailures;
            internal bool PermanentFailure;
            internal string Text = "synthetic";
            public uint Sequence { get { return SequenceNumber; } }
            public string ReadText() { ++Reads; if (PermanentFailure) throw new ProtocolException("protocol"); if (TransientFailures-- > 0) throw new ClipboardUnavailableException(); return Text; }
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
            SyntheticClipboard contended = new SyntheticClipboard { TransientFailures = 2 }; int once = 0;
            using (ClipboardBridge bridge = new ClipboardBridge(delegate(byte operation) { ++once; ++contended.SequenceNumber; }, delegate { return true; }, contended))
            {
                bridge.Handle(ClipboardRequestBytes(1, "")); byte[] result = WaitClipboard(bridge);
                Check(result[1] == 0 && contended.Reads == 3 && once == 1);
            }
            SyntheticClipboard permanent = new SyntheticClipboard { PermanentFailure = true };
            using (ClipboardBridge bridge = new ClipboardBridge(delegate(byte operation) { ++permanent.SequenceNumber; }, delegate { return true; }, permanent))
            {
                bridge.Handle(ClipboardRequestBytes(1, "")); byte[] result = WaitClipboard(bridge);
                Check(result[1] == 1 && permanent.Reads == 1);
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
            // Suspension may land after Allowed() but before the host shortcut.
            // Even a silent suspended shortcut cannot disclose stale copy text:
            // authorization and Cancel's generation both void the worker reply.
            using (ManualResetEvent entered = new ManualResetEvent(false))
            using (ManualResetEvent release = new ManualResetEvent(false))
            {
                SyntheticClipboard cancelled = new SyntheticClipboard(); FakeInput suspendedSink = new FakeInput();
                InputSession suspendedInput = new InputSession(suspendedSink, new CaptureRectangle(0, 0, 1920, 1080));
                int authorized = 1;
                using (ClipboardBridge bridge = new ClipboardBridge(delegate(byte operation) {
                    entered.Set(); release.WaitOne(2000); suspendedInput.ClipboardShortcut(operation);
                }, delegate { return Interlocked.CompareExchange(ref authorized, 0, 0) == 1; }, cancelled))
                {
                    bridge.Handle(ClipboardRequestBytes(1, "")); Check(entered.WaitOne(2000));
                    Interlocked.Exchange(ref authorized, 0); Check(suspendedInput.Suspend()); bridge.Cancel(); release.Set();
                    for (int i = 0; i < 250 && bridge.IsBusy; ++i) Thread.Sleep(10);
                    Check(!bridge.IsBusy); Interlocked.Exchange(ref authorized, 1); byte[] ignored;
                    Check(!bridge.TryTake(out ignored) && cancelled.Reads == 0 && cancelled.Writes == 0 && suspendedSink.Events.Count == 0);
                }
                suspendedInput.Close();
            }
            FakeInput sink = new FakeInput();
            InputSession session = new InputSession(sink, new CaptureRectangle(0, 0, 1920, 1080));
            session.ClipboardShortcut(1);
            Check(sink.Events.Count == 4 && sink.Events[0] == "key:29:down" && sink.Events[1] == "key:46:down" && sink.Events[2] == "key:46:up" && sink.Events[3] == "key:29:up");
            session.Close(); Reject(delegate { session.ClipboardShortcut(2); });
            foreach (byte operation in new byte[] { 1, 2 })
                for (int failure = 0; failure <= 4; ++failure) ClipboardInputFailureIsTerminal(operation, failure);
        }
        private sealed class ClipboardFaultInput : IInputSink
        {
            private readonly int failAt;
            internal int KeyCalls, LaterDowns;
            internal ClipboardFaultInput(int failAt) { this.failAt = failAt; }
            public bool Key(ushort scan, bool extended, bool down)
            {
                if (scan == 30 && down) ++LaterDowns;
                return ++KeyCalls < failAt;
            }
            public bool ReleaseUnicode() { return failAt != 0; }
            public bool Text(string text) { return true; }
            public bool Pointer(byte action, ushort x, ushort y, CaptureRectangle rectangle) { return true; }
            public bool ReleaseButton(byte button) { return true; }
            public bool Wheel(int vertical, int horizontal) { return true; }
        }
        private static void ClipboardInputFailureIsTerminal(byte operation, int failAt)
        {
            ClipboardFaultInput sink = new ClipboardFaultInput(failAt);
            InputSession owned = new InputSession(sink, new CaptureRectangle(0, 0, 1920, 1080));
            Reject(delegate { owned.ClipboardShortcut(operation); });
            int before = sink.KeyCalls;
            Reject(delegate { owned.Accept(Key(1, 30)); });
            Check(sink.LaterDowns == 0 && sink.KeyCalls == before);
            owned.Close(); Check(sink.KeyCalls == before);

            using (TerminalStatusMediaFactory media = new TerminalStatusMediaFactory())
            using (HostServer host = new HostServer(IPAddress.Loopback, 0, media, new ClipboardFaultInput(failAt), true,
                null, true, Stopwatch.GetTimestamp, "Synthetic clipboard", syntheticRegisteredDevices: true,
                syntheticClipboard: new SyntheticClipboard()))
            {
                string offer = RecoveryNumberOffer(host); ++tlsFixtures;
                using (TlsClient client = new TlsClient(host, OfferedPin(offer)))
                {
                    try
                    {
                        client.Send(1, Hello(StrictJson.String(InvitationObject(offer), "token")));
                        Check(client.ReadNonHeartbeat().Kind == 2 && media.Entered.WaitOne(3000));
                        client.Send(0x30, ClipboardRequestBytes(operation, operation == 1 ? "" : "fresh"));
                        WaitFor(delegate { return !host.IsActive; });
                        Check(!host.MayResumeRegisteredConnection);
                        media.Continue.Set(); Check(host.WaitStopped(4000));
                        Check(!host.MayResumeRegisteredConnection && media.Closed == 1);
                    }
                    finally { media.Continue.Set(); }
                }
            }
        }
    }
}
