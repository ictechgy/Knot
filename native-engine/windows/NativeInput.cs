using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Knot.NativePreview
{
    internal struct CaptureRectangle
    {
        internal int Left, Top, Width, Height;
        internal CaptureRectangle(int left, int top, int width, int height) { Left = left; Top = top; Width = width; Height = height; }
    }

    internal interface IInputSink
    {
        bool Key(ushort scanCode, bool extended, bool down);
        bool Text(string text);
        bool ReleaseUnicode();
        bool Pointer(byte action, ushort x, ushort y, CaptureRectangle rectangle);
        bool ReleaseButton(byte button);
        bool Wheel(int vertical, int horizontal);
    }

    // Input runs synchronously: there is no pending action queue and no stale replay.
    // Only successfully injected downs are retained, and unowned ups are ignored.
    internal sealed class InputSession
    {
        private readonly object gate = new object();
        private readonly IInputSink sink;
        private readonly CaptureRectangle rectangle;
        private readonly HashSet<ushort> keys = new HashSet<ushort>();
        private readonly HashSet<byte> buttons = new HashSet<byte>();
        private bool closed;
        internal InputSession(IInputSink sink, CaptureRectangle rectangle) { this.sink = sink; this.rectangle = rectangle; }
        internal void Accept(Packet packet)
        {
            lock (gate)
            {
                if (closed) throw new ProtocolException("closed");
                byte[] p = packet.Payload;
                switch (packet.Kind)
                {
                    case 0x20:
                        if (p.Length != 4 || p[0] > 1 || p[3] > 1) throw new ProtocolException("protocol");
                        ushort scan = NativeProtocol.U16(p, 1);
                        if (scan < 1 || scan > 255) throw new ProtocolException("protocol");
                        ushort id = (ushort)(scan | (p[3] == 1 ? 256 : 0));
                        bool down = p[0] == 1;
                        if (!down && !keys.Contains(id)) return;
                        if (down && !keys.Contains(id) && keys.Count >= 128) throw new ProtocolException("input");
                        if (!sink.Key(scan, p[3] == 1, down)) throw new ProtocolException("input");
                        if (down) keys.Add(id); else keys.Remove(id);
                        break;
                    case 0x21:
                        if (p.Length < 1 || p.Length > 1024) throw new ProtocolException("protocol");
                        string text;
                        try { text = StrictJson.Utf8.GetString(p); }
                        catch (System.Text.DecoderFallbackException) { throw new ProtocolException("protocol"); }
                        StrictJson.ValidUnicode(text, false);
                        if (text.Length > 512) throw new ProtocolException("protocol");
                        if (!sink.Text(text)) throw new ProtocolException("input");
                        break;
                    case 0x22:
                        if (p.Length != 5 || p[0] > 6) throw new ProtocolException("protocol");
                        byte action = p[0];
                        ushort x = NativeProtocol.U16(p, 1), y = NativeProtocol.U16(p, 3);
                        byte button = (byte)((action + 1) / 2);
                        bool buttonDown = action % 2 == 1;
                        if (action != 0 && !buttonDown && !buttons.Contains(button)) return;
                        if (!sink.Pointer(action, x, y, rectangle)) throw new ProtocolException("input");
                        if (action != 0) { if (buttonDown) buttons.Add(button); else buttons.Remove(button); }
                        break;
                    case 0x23:
                        if (p.Length != 8) throw new ProtocolException("protocol");
                        int vertical = NativeProtocol.I32(p, 0), horizontal = NativeProtocol.I32(p, 4);
                        if (vertical < -1200 || vertical > 1200 || horizontal < -1200 || horizontal > 1200) throw new ProtocolException("protocol");
                        if (!sink.Wheel(vertical, horizontal)) throw new ProtocolException("input");
                        break;
                    case 0x24:
                        if (p.Length != 0) throw new ProtocolException("protocol");
                        // A failed revocation must end input delivery. Retained
                        // owned downs are retried by Close during host teardown.
                        if (!Release()) throw new ProtocolException("input");
                        break;
                    case 0x25:
                        if (p.Length != 0) throw new ProtocolException("protocol");
                        break;
                    default: throw new ProtocolException("protocol");
                }
            }
        }
        private bool Release()
        {
            // Failed releases remain owned and are retried on session teardown.
            bool unicodeReleased = sink.ReleaseUnicode();
            foreach (ushort key in new List<ushort>(keys))
                if (sink.Key((ushort)(key & 255), (key & 256) != 0, false)) keys.Remove(key);
            foreach (byte button in new List<byte>(buttons))
                if (sink.ReleaseButton(button)) buttons.Remove(button);
            return unicodeReleased && keys.Count == 0 && buttons.Count == 0;
        }
        internal void Close()
        {
            lock (gate)
            {
                if (closed) return;
                closed = true;
                // SendInput can fail during a desktop transition. Bound retries and never
                // release physical inputs that were not accepted by this session.
                for (int i = 0; i < 3; ++i) if (Release()) break;
            }
        }
    }

    internal sealed class WindowsInputSink : IInputSink
    {
        private const uint KeyUp = 2, Unicode = 4, ScanCode = 8, Extended = 1;
        [StructLayout(LayoutKind.Sequential)] internal struct MouseInput
        { internal int dx, dy; internal uint data, flags, time; internal UIntPtr extra; }
        [StructLayout(LayoutKind.Sequential)] internal struct KeyboardInput
        { internal ushort virtualKey, scan; internal uint flags, time; internal UIntPtr extra; }
        [StructLayout(LayoutKind.Explicit)] internal struct InputUnion
        { [FieldOffset(0)] internal MouseInput mouse; [FieldOffset(0)] internal KeyboardInput keyboard; }
        [StructLayout(LayoutKind.Sequential)] internal struct Input
        { internal uint type; internal InputUnion value; }
        internal delegate uint InputSender(uint count, Input[] inputs, int size);
        private readonly InputSender sender;
        private readonly HashSet<ushort> unicodeDown = new HashSet<ushort>();
        [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, Input[] inputs, int size);
        [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
        internal WindowsInputSink() : this(SendInput) { }
        internal WindowsInputSink(InputSender sender)
        {
            if (sender == null) throw new ArgumentNullException("sender");
            this.sender = sender;
        }
        private static Input Keyboard(ushort scan, uint flags)
        {
            Input i = new Input(); i.type = 1; i.value.keyboard.scan = scan; i.value.keyboard.flags = flags; return i;
        }
        private bool Send(Input value) { return sender(1, new Input[] { value }, Marshal.SizeOf(typeof(Input))) == 1; }
        public bool Key(ushort scanCode, bool extended, bool down)
        { return Send(Keyboard(scanCode, ScanCode | (extended ? Extended : 0) | (down ? 0 : KeyUp))); }
        public bool Text(string text)
        {
            // A failed pair ends input delivery. Do not accept more text while an
            // earlier successfully injected Unicode down still belongs to us.
            if (unicodeDown.Count != 0) return false;
            foreach (char c in text)
            {
                Input up = Keyboard(c, Unicode | KeyUp);
                uint accepted = sender(2, new Input[] { Keyboard(c, Unicode), up }, Marshal.SizeOf(typeof(Input)));
                if (accepted != 2)
                {
                    if (accepted == 1)
                    {
                        unicodeDown.Add(c);
                        for (int retry = 0; retry < 3; ++retry) if (ReleaseUnicode()) break;
                    }
                    return false;
                }
            }
            return true;
        }
        public bool ReleaseUnicode()
        {
            foreach (ushort unit in new List<ushort>(unicodeDown))
                if (Send(Keyboard(unit, Unicode | KeyUp))) unicodeDown.Remove(unit);
            return unicodeDown.Count == 0;
        }
        internal static int Normalize(int physical, int origin, int extent)
        {
            if (extent <= 1) return 0;
            long offset = Math.Max(0L, Math.Min((long)extent - 1, (long)physical - origin));
            return (int)((offset * 65535 + (extent - 1) / 2) / (extent - 1));
        }
        public bool Pointer(byte action, ushort x, ushort y, CaptureRectangle rectangle)
        {
            int virtualLeft = GetSystemMetrics(76), virtualTop = GetSystemMetrics(77);
            int virtualWidth = GetSystemMetrics(78), virtualHeight = GetSystemMetrics(79);
            if (rectangle.Width < 1 || rectangle.Height < 1 || virtualWidth < 1 || virtualHeight < 1) return false;
            int px = rectangle.Left + (int)(((long)x * (rectangle.Width - 1) + 32767) / 65535);
            int py = rectangle.Top + (int)(((long)y * (rectangle.Height - 1) + 32767) / 65535);
            uint[] buttonFlags = { 0, 0x0002, 0x0004, 0x0008, 0x0010, 0x0020, 0x0040 };
            Input i = new Input();
            i.value.mouse.dx = Normalize(px, virtualLeft, virtualWidth);
            i.value.mouse.dy = Normalize(py, virtualTop, virtualHeight);
            i.value.mouse.flags = 0x0001 | 0x8000 | 0x4000 | buttonFlags[action];
            return Send(i);
        }
        public bool Wheel(int vertical, int horizontal)
        {
            if (vertical != 0) { Input i = new Input(); i.value.mouse.flags = 0x0800; i.value.mouse.data = unchecked((uint)vertical); if (!Send(i)) return false; }
            if (horizontal != 0) { Input i = new Input(); i.value.mouse.flags = 0x1000; i.value.mouse.data = unchecked((uint)horizontal); if (!Send(i)) return false; }
            return true;
        }
        public bool ReleaseButton(byte button)
        {
            uint[] flags = { 0, 0x0004, 0x0010, 0x0040 };
            if (button < 1 || button > 3) return false;
            Input i = new Input(); i.value.mouse.flags = flags[button];
            return Send(i);
        }
    }
}
