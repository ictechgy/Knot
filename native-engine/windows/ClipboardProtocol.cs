using System;
using System.Text;

namespace Knot.NativePreview
{
    internal sealed class ClipboardRequest
    {
        internal readonly byte Operation;
        internal readonly byte[] Nonce;
        internal readonly string Text;
        internal ClipboardRequest(byte operation, byte[] nonce, string text) { Operation = operation; Nonce = nonce; Text = text; }
    }
    internal static class ClipboardProtocol
    {
        internal const int MaximumTextBytes = 1048576;
        internal static string Text(byte[] bytes, int offset, int count)
        {
            if (count < 0 || count > MaximumTextBytes) throw new ProtocolException("protocol");
            string value;
            try { value = StrictJson.Utf8.GetString(bytes, offset, count); }
            catch (DecoderFallbackException) { throw new ProtocolException("protocol"); }
            StrictJson.ValidUnicode(value, false); return value;
        }
        internal static ClipboardRequest Request(byte[] payload)
        {
            if (payload == null || payload.Length < 17 || payload.Length > MaximumTextBytes + 17 ||
                payload[0] < 1 || payload[0] > 2) throw new ProtocolException("protocol");
            string text = Text(payload, 17, payload.Length - 17);
            if (payload[0] == 1 && text.Length != 0) throw new ProtocolException("protocol");
            byte[] nonce = new byte[16]; Buffer.BlockCopy(payload, 1, nonce, 0, 16);
            return new ClipboardRequest(payload[0], nonce, text);
        }
        internal static byte[] Response(ClipboardRequest request, byte status, string text)
        {
            if (status > 3 || (status != 0 || request.Operation == 2) && text.Length != 0) throw new ProtocolException("protocol");
            byte[] bytes = StrictJson.Utf8.GetBytes(text); Text(bytes, 0, bytes.Length);
            byte[] result = new byte[18 + bytes.Length]; result[0] = request.Operation; result[1] = status;
            Buffer.BlockCopy(request.Nonce, 0, result, 2, 16); Buffer.BlockCopy(bytes, 0, result, 18, bytes.Length); return result;
        }
        internal static byte[] WithOffer(byte[] ready)
        {
            string value = StrictJson.Utf8.GetString(ready);
            if (!value.EndsWith("}", StringComparison.Ordinal)) throw new ProtocolException("protocol");
            return StrictJson.Utf8.GetBytes(value.Substring(0, value.Length - 1) + ",\"clipboardVersion\":1}");
        }
    }
}
