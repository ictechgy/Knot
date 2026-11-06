// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace Knot.NativePreview
{
    internal sealed class FileTransferException : Exception
    {
        internal readonly string Code;
        internal readonly string Operation;
        internal readonly int NativeError;
        internal readonly int? NativeNtStatus, NativeIoStatus;
        internal FileTransferException(string code) : this(code, "", 0) { }
        internal FileTransferException(string code, string operation, int nativeError) : base(code)
        {
            Code = FileProtocol.IsError(code) ? code : "protocol";
            Operation = operation == "file-open" || operation == "file-info" || operation == "file-path" || operation == "file-rename" || operation == "file-basic" ? operation : "";
            NativeError = nativeError;
        }
        internal FileTransferException(string code, string operation, int nativeError, int ntStatus, int ioStatus)
            : this(code, operation, nativeError) { NativeNtStatus = ntStatus; NativeIoStatus = ioStatus; }
    }

    internal sealed class FilePacket
    {
        internal readonly byte Kind;
        internal readonly byte[] Payload;
        internal FilePacket(byte kind, byte[] payload) { Kind = kind; Payload = payload; }
    }

    // This protocol never widens the media/input packet grammar or its limits.
    internal static class FileProtocol
    {
        internal const int Port = 48634, ChunkSize = 65536, EntryLimit = 256;
        internal const int TreeNodeLimit = 4096, TreeDepthLimit = 16, TreeMetadataLimit = 1048576, RunNodeLimit = 8192;
        internal const long MaximumSize = 8589934592L, RateBytesPerSecond = 2097152;
        internal static bool IsError(string code)
        { return code == "auth" || code == "busy" || code == "protocol" || code == "timeout" || code == "denied" || code == "missing" || code == "changed" || code == "quota" || code == "io"; }
        internal static void ValidName(string name)
        {
            if (string.IsNullOrEmpty(name) || name == "." || name == ".." ||
                name.EndsWith(".", StringComparison.Ordinal) || name.EndsWith(" ", StringComparison.Ordinal) ||
                name.StartsWith(".knot-", StringComparison.OrdinalIgnoreCase)) throw new FileTransferException("protocol");
            try { StrictJson.ValidUnicode(name, true); } catch (ProtocolException) { throw new FileTransferException("protocol"); }
            if (StrictJson.Utf8.GetByteCount(name) > 255) throw new FileTransferException("protocol");
            foreach (char c in name)
            {
                UnicodeCategory category = CharUnicodeInfo.GetUnicodeCategory(c);
                if (c == '/' || c == '\\' || c == ':' || c == '<' || c == '>' || c == '"' || c == '|' || c == '?' || c == '*' ||
                    category == UnicodeCategory.Control || category == UnicodeCategory.Format || category == UnicodeCategory.LineSeparator || category == UnicodeCategory.ParagraphSeparator)
                    throw new FileTransferException("protocol");
            }
            string stem = name.Split('.')[0].TrimEnd(' ').ToUpperInvariant();
            if (stem == "CON" || stem == "PRN" || stem == "AUX" || stem == "NUL" || stem == "CLOCK$" ||
                stem == "CONIN$" || stem == "CONOUT$" ||
                stem.Length == 4 && (stem.StartsWith("COM", StringComparison.Ordinal) || stem.StartsWith("LPT", StringComparison.Ordinal)) &&
                (stem[3] >= '0' && stem[3] <= '9' || stem[3] == '\u00b9' || stem[3] == '\u00b2' || stem[3] == '\u00b3')) throw new FileTransferException("protocol");
        }
        internal static ulong U64(byte[] bytes, int offset)
        {
            if (bytes == null || offset < 0 || offset > bytes.Length - 8) throw new FileTransferException("protocol");
            ulong result = 0;
            for (int index = 0; index < 8; ++index) result = (result << 8) | bytes[offset + index];
            return result;
        }
        internal static long Size(Dictionary<string, object> obj, string key)
        {
            object value;
            if (!obj.TryGetValue(key, out value) || !(value is long) || (long)value < 0 || (long)value > MaximumSize) throw new FileTransferException("protocol");
            return (long)value;
        }
        internal static string Text(Dictionary<string, object> obj, string key)
        {
            object value;
            if (!obj.TryGetValue(key, out value) || !(value is string)) throw new FileTransferException("protocol");
            return (string)value;
        }
        internal static Dictionary<string, object> Object(byte[] bytes, params string[] keys)
        { try { return StrictJson.Parse(bytes, keys); } catch (ProtocolException) { throw new FileTransferException("protocol"); } }
        internal static bool Hex(string value, int length)
        {
            if (value == null || value.Length != length) return false;
            foreach (char c in value) if (!(c >= '0' && c <= '9' || c >= 'a' && c <= 'f')) return false;
            return true;
        }
        internal static string Hex(byte[] data)
        { return BitConverter.ToString(data).Replace("-", "").ToLowerInvariant(); }
        internal static byte[] Json(string json) { return StrictJson.Utf8.GetBytes(json); }
        internal static byte[] Hello(byte[] token)
        {
            if (token == null || token.Length != 32) throw new FileTransferException("protocol");
            return Json("{\"v\":2,\"token\":" + StrictJson.Quote(NativeProtocol.Base64Url(token)) + "}");
        }
        internal static byte[] Error(string code)
        {
            if (!IsError(code)) code = "io";
            return Json("{\"code\":" + StrictJson.Quote(code) + "}");
        }
        internal static byte[] Metadata(string name, long size)
        {
            ValidName(name); if (size < 0 || size > MaximumSize) throw new FileTransferException("protocol");
            return Json("{\"name\":" + StrictJson.Quote(name) + ",\"size\":" + size.ToString(CultureInfo.InvariantCulture) + "}");
        }
        internal static int Count(Dictionary<string, object> obj, string key, int maximum)
        {
            object value;
            if (!obj.TryGetValue(key, out value) || !(value is long) || (long)value < 0 || (long)value > maximum)
                throw new FileTransferException("protocol");
            return (int)(long)value;
        }
        internal static string Kind(Dictionary<string, object> obj)
        { string value = Text(obj, "kind"); if (value != "file" && value != "folder") throw new FileTransferException("protocol"); return value; }
        internal static byte[] Accepted(string name, long size, string kind, int count)
        {
            ValidName(name);
            if (size < 0 || size > MaximumSize || (kind != "file" && kind != "folder") || count < 0 || count > TreeNodeLimit || kind == "file" && count != 0)
                throw new FileTransferException("protocol");
            return Json("{\"name\":" + StrictJson.Quote(name) + ",\"size\":" + size.ToString(CultureInfo.InvariantCulture) + ",\"kind\":" + StrictJson.Quote(kind) + ",\"count\":" + count.ToString(CultureInfo.InvariantCulture) + "}");
        }
        internal static byte[] Entry(FileEntrySnapshot value)
        { return Json("{\"entry\":" + StrictJson.Quote(value.Id) + ",\"name\":" + StrictJson.Quote(value.Name) + ",\"size\":" + value.Size.ToString(CultureInfo.InvariantCulture) + ",\"kind\":" + StrictJson.Quote(value.Kind) + "}"); }
        internal static byte[] TreeOffer(string name, long size, int count)
        {
            ValidName(name); if (size < 0 || size > MaximumSize || count < 0 || count > TreeNodeLimit) throw new FileTransferException("protocol");
            return Json("{\"name\":" + StrictJson.Quote(name) + ",\"size\":" + size.ToString(CultureInfo.InvariantCulture) + ",\"count\":" + count.ToString(CultureInfo.InvariantCulture) + "}");
        }
        internal static byte[] TreeEnd(int count, long size, byte[] hash)
        {
            if (count < 0 || count > TreeNodeLimit || size < 0 || size > MaximumSize || hash == null || hash.Length != 32) throw new FileTransferException("protocol");
            return Json("{\"count\":" + count.ToString(CultureInfo.InvariantCulture) + ",\"size\":" + size.ToString(CultureInfo.InvariantCulture) + ",\"sha256\":" + StrictJson.Quote(Hex(hash)) + "}");
        }
        internal static byte[] Complete(string name, long size, byte[] hash)
        {
            ValidName(name); if (size < 0 || size > MaximumSize || hash == null || hash.Length != 32) throw new FileTransferException("protocol");
            return Json("{\"name\":" + StrictJson.Quote(name) + ",\"size\":" + size.ToString(CultureInfo.InvariantCulture) + ",\"sha256\":" + StrictJson.Quote(Hex(hash)) + "}");
        }
        internal static byte[] Finish(long size, byte[] hash)
        {
            if (size < 0 || size > MaximumSize || hash == null || hash.Length != 32) throw new FileTransferException("protocol");
            byte[] result = new byte[40]; NativeProtocol.Put64(result, 0, (ulong)size); Buffer.BlockCopy(hash, 0, result, 8, 32); return result;
        }
        internal static void Validate(byte kind, uint length)
        {
            bool valid = kind == 0x42 ? length == 0 : kind == 0x48 ? length >= 9 && length <= ChunkSize + 8 :
                kind == 0x49 ? length == 40 : kind == 0x7f ? length >= 1 && length <= 128 :
                kind >= 0x40 && kind <= 0x4f && length >= 1 && length <= 4096;
            if (!valid) throw new FileTransferException("protocol");
        }
        internal static FilePacket Read(Stream stream)
        {
            byte[] header = NativeProtocol.ReadExactly(stream, 5); uint length = NativeProtocol.U32(header, 1);
            Validate(header[0], length); return new FilePacket(header[0], NativeProtocol.ReadExactly(stream, (int)length));
        }
        internal static void Write(Stream stream, byte kind, byte[] payload)
        {
            if (payload == null) throw new FileTransferException("protocol");
            Validate(kind, (uint)payload.Length);
            byte[] header = new byte[5]; header[0] = kind; NativeProtocol.Put32(header, 1, (uint)payload.Length);
            stream.Write(header, 0, header.Length); if (payload.Length != 0) stream.Write(payload, 0, payload.Length); stream.Flush();
        }
        internal static byte[] WithOffer(byte[] ready, string token, string rootName)
        {
            byte[] decoded = NativeProtocol.DecodeToken(token); Array.Clear(decoded, 0, decoded.Length);
            EnrollmentProtocol.ValidName(rootName);
            // Ready itself was already validated by MediaInfo.Ready().
            string text = StrictJson.Utf8.GetString(ready);
            if (!text.EndsWith("}", StringComparison.Ordinal)) throw new FileTransferException("protocol");
            return Json(text.Substring(0, text.Length - 1) + ",\"filesVersion\":2,\"filePort\":48634,\"fileToken\":" + StrictJson.Quote(token) + ",\"fileRootName\":" + StrictJson.Quote(rootName) + "}");
        }
    }
}
