using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Text;

namespace Knot.NativePreview
{
    internal sealed class ProtocolException : Exception
    {
        internal readonly string Code;
        internal ProtocolException(string code) : base(code) { Code = code; }
    }

    internal sealed class Packet
    {
        internal readonly byte Kind;
        internal readonly byte[] Payload;
        internal Packet(byte kind, byte[] payload) { Kind = kind; Payload = payload; }
    }

    // A deliberately small JSON grammar: protocol objects have scalar values only.
    // Duplicate keys, non-integer numbers, invalid escapes and unpaired surrogates fail closed.
    internal static class StrictJson
    {
        internal static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
        internal static Dictionary<string, object> Parse(byte[] bytes, params string[] exactKeys)
        {
            string value;
            try { value = Utf8.GetString(bytes); }
            catch (DecoderFallbackException) { throw new ProtocolException("protocol"); }
            Parser p = new Parser(value);
            Dictionary<string, object> result = p.Object();
            if (result.Count != exactKeys.Length) throw new ProtocolException("protocol");
            foreach (string key in exactKeys) if (!result.ContainsKey(key)) throw new ProtocolException("protocol");
            return result;
        }
        internal static int Integer(Dictionary<string, object> obj, string key, int min, int max)
        {
            object v = obj[key];
            if (!(v is long) || (long)v < min || (long)v > max) throw new ProtocolException("protocol");
            return (int)(long)v;
        }
        internal static string String(Dictionary<string, object> obj, string key)
        {
            string value = obj[key] as string;
            if (value == null) throw new ProtocolException("protocol");
            return value;
        }
        internal static string Quote(string value)
        {
            StringBuilder b = new StringBuilder("\"");
            foreach (char c in value)
            {
                if (c == '"' || c == '\\') b.Append('\\').Append(c);
                else if (c < 32) b.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                else b.Append(c);
            }
            return b.Append('"').ToString();
        }
        internal static void ValidUnicode(string s, bool rejectControls)
        {
            for (int i = 0; i < s.Length; ++i)
            {
                char c = s[i];
                if (c == 0 || (rejectControls && char.IsControl(c))) throw new ProtocolException("protocol");
                if (char.IsHighSurrogate(c))
                {
                    if (++i >= s.Length || !char.IsLowSurrogate(s[i])) throw new ProtocolException("protocol");
                }
                else if (char.IsLowSurrogate(c)) throw new ProtocolException("protocol");
            }
        }
        private sealed class Parser
        {
            private readonly string text;
            private int at;
            internal Parser(string text) { this.text = text; }
            private void White() { while (at < text.Length && (text[at] == ' ' || text[at] == '\t' || text[at] == '\r' || text[at] == '\n')) ++at; }
            private void Take(char c) { White(); if (at >= text.Length || text[at++] != c) throw new ProtocolException("protocol"); }
            private bool Peek(char c) { White(); return at < text.Length && text[at] == c; }
            internal Dictionary<string, object> Object()
            {
                Dictionary<string, object> map = new Dictionary<string, object>(StringComparer.Ordinal);
                Take('{');
                if (!Peek('}'))
                {
                    while (true)
                    {
                        string key = ReadString();
                        Take(':');
                        object value = Value();
                        if (map.ContainsKey(key)) throw new ProtocolException("protocol");
                        map.Add(key, value);
                        if (!Peek(',')) break;
                        Take(',');
                    }
                }
                Take('}'); White();
                if (at != text.Length) throw new ProtocolException("protocol");
                return map;
            }
            private object Value()
            {
                White();
                if (at >= text.Length) throw new ProtocolException("protocol");
                if (text[at] == '"') return ReadString();
                if (Match("true")) return true;
                if (Match("false")) return false;
                int start = at;
                if (text[at] == '-') ++at;
                if (at >= text.Length || text[at] < '0' || text[at] > '9') throw new ProtocolException("protocol");
                if (text[at] == '0') ++at;
                else while (at < text.Length && text[at] >= '0' && text[at] <= '9') ++at;
                long n;
                if (!long.TryParse(text.Substring(start, at - start), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out n)) throw new ProtocolException("protocol");
                return n;
            }
            private bool Match(string s)
            {
                if (at + s.Length > text.Length || string.CompareOrdinal(text, at, s, 0, s.Length) != 0) return false;
                at += s.Length; return true;
            }
            private string ReadString()
            {
                Take('"');
                StringBuilder b = new StringBuilder();
                while (at < text.Length)
                {
                    char c = text[at++];
                    if (c == '"') { string result = b.ToString(); ValidUnicode(result, false); return result; }
                    if (c < 32) throw new ProtocolException("protocol");
                    if (c != '\\') { b.Append(c); continue; }
                    if (at >= text.Length) throw new ProtocolException("protocol");
                    char escaped = text[at++];
                    switch (escaped)
                    {
                        case '"': case '\\': case '/': b.Append(escaped); break;
                        case 'b': b.Append('\b'); break;
                        case 'f': b.Append('\f'); break;
                        case 'n': b.Append('\n'); break;
                        case 'r': b.Append('\r'); break;
                        case 't': b.Append('\t'); break;
                        case 'u':
                            int x = 0;
                            for (int i = 0; i < 4; ++i)
                            {
                                if (at >= text.Length) throw new ProtocolException("protocol");
                                char h = text[at++];
                                int d = h >= '0' && h <= '9' ? h - '0' : h >= 'a' && h <= 'f' ? h - 'a' + 10 : h >= 'A' && h <= 'F' ? h - 'A' + 10 : -1;
                                if (d < 0) throw new ProtocolException("protocol");
                                x = x * 16 + d;
                            }
                            b.Append((char)x); break;
                        default: throw new ProtocolException("protocol");
                    }
                }
                throw new ProtocolException("protocol");
            }
        }
    }

    internal static class NativeProtocol
    {
        internal const int VideoLimit = 4194304;
        internal static bool IsPrivate(IPAddress address)
        {
            if (address == null || address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork) return false;
            byte[] b = address.GetAddressBytes();
            return b[0] == 10 || b[0] == 172 && b[1] >= 16 && b[1] <= 31 || b[0] == 192 && b[1] == 168 || b[0] == 100 && b[1] >= 64 && b[1] <= 127;
        }
        internal static string Base64Url(byte[] bytes) { return Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_'); }
        internal static byte[] DecodeToken(string token)
        {
            if (token.Length != 43) throw new ProtocolException("auth");
            foreach (char c in token) if (!(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_')) throw new ProtocolException("auth");
            byte[] bytes;
            try { bytes = Convert.FromBase64String(token.Replace('-', '+').Replace('_', '/') + "="); }
            catch (FormatException) { throw new ProtocolException("auth"); }
            if (bytes.Length != 32 || Base64Url(bytes) != token) throw new ProtocolException("auth");
            return bytes;
        }
        internal static bool Equal(byte[] a, byte[] b)
        {
            if (a == null || b == null || a.Length != b.Length) return false;
            int result = 0;
            for (int i = 0; i < a.Length; ++i) result |= a[i] ^ b[i];
            return result == 0;
        }
        internal static Packet ReadClient(Stream stream, bool hello)
        {
            byte[] header = ReadExactly(stream, 5);
            uint length = U32(header, 1);
            byte kind = header[0];
            bool valid = hello ? kind == 1 && length >= 1 && length <= 4096 :
                kind == 0x20 && length == 4 || kind == 0x21 && length >= 1 && length <= 1024 ||
                kind == 0x22 && length == 5 || kind == 0x23 && length == 8 || (kind == 0x24 || kind == 0x25) && length == 0;
            if (!valid) throw new ProtocolException("protocol");
            return new Packet(kind, ReadExactly(stream, (int)length));
        }
        internal static byte[] ReadExactly(Stream stream, int count)
        {
            byte[] bytes = new byte[count];
            for (int at = 0; at < count;)
            {
                int n = stream.Read(bytes, at, count - at);
                if (n <= 0) throw new EndOfStreamException();
                at += n;
            }
            return bytes;
        }
        internal static void Write(Stream stream, byte kind, byte[] bytes)
        {
            int cap = kind == 2 ? 4096 : kind == 3 ? VideoLimit : kind == 4 ? 0 : kind == 127 ? 128 : -1;
            if (cap < 0 || bytes.Length > cap || (kind != 4 && bytes.Length == 0)) throw new ProtocolException("protocol");
            byte[] header = new byte[5]; header[0] = kind; Put32(header, 1, (uint)bytes.Length);
            stream.Write(header, 0, header.Length);
            if (bytes.Length != 0) stream.Write(bytes, 0, bytes.Length);
        }
        internal static uint U32(byte[] b, int p) { return ((uint)b[p] << 24) | ((uint)b[p + 1] << 16) | ((uint)b[p + 2] << 8) | b[p + 3]; }
        internal static int I32(byte[] b, int p) { return unchecked((int)U32(b, p)); }
        internal static ushort U16(byte[] b, int p) { return (ushort)(b[p] * 256 + b[p + 1]); }
        internal static void Put32(byte[] b, int p, uint n) { for (int i = 3; i >= 0; --i) { b[p + i] = (byte)n; n >>= 8; } }
        internal static void Put64(byte[] b, int p, ulong n) { for (int i = 7; i >= 0; --i) { b[p + i] = (byte)n; n >>= 8; } }
        internal static string HelloName(byte[] payload, out byte[] token)
        {
            Dictionary<string, object> hello = StrictJson.Parse(payload, "v", "token", "name");
            StrictJson.Integer(hello, "v", 1, 1);
            token = DecodeToken(StrictJson.String(hello, "token"));
            string name = StrictJson.String(hello, "name");
            StrictJson.ValidUnicode(name, true);
            int size = StrictJson.Utf8.GetByteCount(name);
            if (size < 1 || size > 64) throw new ProtocolException("protocol");
            return name;
        }
        internal static byte[] Error(string code)
        {
            switch (code)
            {
                case "auth": case "expired": case "declined": case "busy": case "capture": case "encoder":
                case "input": case "protocol": case "timeout": case "closed": return StrictJson.Utf8.GetBytes("{\"code\":\"" + code + "\"}");
                default: throw new ArgumentException("Invalid authored error code.");
            }
        }
    }
}
