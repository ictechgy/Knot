// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Security.Cryptography;

namespace Knot.NativePreview
{
    internal static class EnrollmentProtocol
    {
        internal const int Port = 48632, DiscoveryPort = 48633, Limit = 4096;
        internal static readonly byte[] Preamble = { 75, 78, 79, 84, 80, 50, 0, 0 };
        internal static readonly byte[] DiscoveryPreamble = { 75, 78, 79, 84, 68, 50, 0, 0 };
        internal static byte[] Random(int length)
        {
            byte[] value = new byte[length];
            using (RandomNumberGenerator random = RandomNumberGenerator.Create()) random.GetBytes(value);
            return value;
        }
        internal static byte[] NewCode()
        {
            byte[] code = new byte[8], sample = new byte[32]; int at = 0;
            using (RandomNumberGenerator random = RandomNumberGenerator.Create())
            {
                for (int round = 0; round < 64 && at < code.Length; ++round)
                {
                    random.GetBytes(sample);
                    foreach (byte b in sample) if (b < 250 && at < code.Length) code[at++] = (byte)(48 + b % 10);
                }
            }
            Array.Clear(sample, 0, sample.Length);
            if (at != code.Length) { Array.Clear(code, 0, code.Length); throw new ProtocolException("auth"); }
            return code;
        }
        internal static void ValidName(string name)
        {
            NativeProtocol.ValidDisplayName(name);
        }
        internal static byte[] Identifier(string encoded)
        {
            if (encoded == null || encoded.Length != 22) throw new ProtocolException("protocol");
            foreach (char c in encoded) if (!(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_')) throw new ProtocolException("protocol");
            byte[] result;
            try { result = Convert.FromBase64String(encoded.Replace('-', '+').Replace('_', '/') + "=="); }
            catch (FormatException) { throw new ProtocolException("protocol"); }
            if (result.Length != 16 || NativeProtocol.Base64Url(result) != encoded) throw new ProtocolException("protocol");
            return result;
        }
        internal static byte[] ReadExact(Stream stream, int length)
        {
            if (length < 0 || length > Limit) throw new ProtocolException("protocol");
            byte[] data = new byte[length]; int at = 0;
            while (at < length) { int count = stream.Read(data, at, length - at); if (count <= 0) throw new IOException("Enrollment ended."); at += count; }
            return data;
        }
        internal static Packet Read(Stream stream, byte expected)
        {
            byte[] header = ReadExact(stream, 5);
            uint length = NativeProtocol.U32(header, 1);
            int maximum = expected == 1 || expected == 2 ? 48 : expected == 3 ? 512 : Limit;
            if (header[0] != expected || length < 1 || length > maximum || (expected == 1 || expected == 2) && length != 48) throw new ProtocolException("protocol");
            return new Packet(expected, ReadExact(stream, (int)length));
        }
        internal static void Write(Stream stream, byte kind, byte[] payload)
        {
            if (payload == null || payload.Length < 1 || payload.Length > Limit) throw new ProtocolException("protocol");
            byte[] header = new byte[5]; header[0] = kind; NativeProtocol.Put32(header, 1, (uint)payload.Length);
            stream.Write(header, 0, header.Length); stream.Write(payload, 0, payload.Length); stream.Flush();
        }
        internal static string ConfirmName(byte[] plaintext, byte[] slot)
        { bool files; return ConfirmName(plaintext, slot, out files); }
        internal static string ConfirmName(byte[] plaintext, byte[] slot, out bool files)
        {
            if (plaintext == null || plaintext.Length > 484) throw new ProtocolException("protocol");
            Dictionary<string, object> obj = StrictJson.Parse(plaintext, "v", "slot", "name", "permissions");
            string permissions = StrictJson.String(obj, "permissions");
            files = permissions == "screen,input,files";
            if (StrictJson.Integer(obj, "v", 2, 2) != 2 || !(permissions == "screen,input" || files) ||
                !NativeProtocol.Equal(Identifier(StrictJson.String(obj, "slot")), slot)) throw new ProtocolException("protocol");
            string name = StrictJson.String(obj, "name"); ValidName(name); return name;
        }
        internal static byte[] Offer(byte[] slot, byte[] grant, string invitation, int remainingMilliseconds)
        {
            if (slot.Length != 16 || grant.Length != 16 || remainingMilliseconds < 1 || remainingMilliseconds > 30000 ||
                invitation == null || StrictJson.Utf8.GetByteCount(invitation) > 2048) throw new ProtocolException("protocol");
            byte[] data = StrictJson.Utf8.GetBytes("{\"v\":2,\"slot\":" + StrictJson.Quote(NativeProtocol.Base64Url(slot)) +
                ",\"grant\":" + StrictJson.Quote(NativeProtocol.Base64Url(grant)) + ",\"invitation\":" + StrictJson.Quote(invitation) +
                ",\"ttlMs\":" + remainingMilliseconds.ToString(System.Globalization.CultureInfo.InvariantCulture) + "}");
            if (data.Length > 3072) throw new ProtocolException("protocol");
            return data;
        }
        internal static byte[] Error(string code)
        {
            if (code != "auth" && code != "expired" && code != "busy" && code != "protocol" && code != "closed") code = "auth";
            return StrictJson.Utf8.GetBytes("{\"code\":" + StrictJson.Quote(code) + "}");
        }
        internal static byte[] DiscoveryQuery(byte[] nonce)
        {
            if (nonce == null || nonce.Length != 16) throw new ProtocolException("protocol");
            byte[] query = new byte[24]; Buffer.BlockCopy(DiscoveryPreamble, 0, query, 0, 8); Buffer.BlockCopy(nonce, 0, query, 8, 16); return query;
        }
        internal static byte[] DiscoveryNonce(byte[] query)
        {
            if (query == null || query.Length != 24) throw new ProtocolException("protocol");
            byte[] prefix = new byte[8], nonce = new byte[16]; Buffer.BlockCopy(query, 0, prefix, 0, 8);
            if (!NativeProtocol.Equal(prefix, DiscoveryPreamble)) throw new ProtocolException("protocol");
            Buffer.BlockCopy(query, 8, nonce, 0, 16); return nonce;
        }
        internal static byte[] DiscoveryReply(byte[] nonce, byte[] slot, string name, int port)
        {
            ValidName(name);
            if (nonce.Length != 16 || slot.Length != 16 || port < 1 || port > 65535) throw new ProtocolException("protocol");
            byte[] value = StrictJson.Utf8.GetBytes("{\"v\":2,\"nonce\":" + StrictJson.Quote(NativeProtocol.Base64Url(nonce)) +
                ",\"slot\":" + StrictJson.Quote(NativeProtocol.Base64Url(slot)) + ",\"name\":" + StrictJson.Quote(name) +
                ",\"port\":" + port.ToString(System.Globalization.CultureInfo.InvariantCulture) + "}");
            if (value.Length > 1024) throw new ProtocolException("protocol"); return value;
        }
    }
}
