// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace Knot.NativePreview
{
    internal sealed class NativeAudioException : Exception
    {
        internal readonly string Code;
        internal NativeAudioException(string code) : base("Audio session failed.") { Code = code; }
    }

    // Separate audio connection. It has no input/file authority and never adds
    // fields to the media-v1 Hello/Ready schemas understood by older clients.
    internal static class NativeAudioProtocol
    {
        internal const int Port = 48636, SampleRate = 48000, Channels = 2;
        internal const int BytesPerFrame = 4, MaximumFrames = 960, MaximumPcmBytes = MaximumFrames * BytesPerFrame;
        internal const int MaximumPayload = 20 + MaximumPcmBytes;
        internal static byte[] DeriveKey(byte[] mediaToken)
        {
            if (mediaToken == null || mediaToken.Length != 32) throw new ArgumentException("Invalid session key.");
            using (HMACSHA256 hmac = new HMACSHA256(mediaToken))
                return hmac.ComputeHash(Encoding.ASCII.GetBytes("knot-audio-v1"));
        }
        internal static byte[] Hello(byte[] key)
        {
            if (key == null || key.Length != 32) throw new ArgumentException("Invalid session key.");
            return StrictJson.Utf8.GetBytes("{\"v\":1,\"token\":" + StrictJson.Quote(NativeProtocol.Base64Url(key)) + "}");
        }
        internal static bool Authenticate(byte[] payload, byte[] expected)
        {
            if (payload == null || payload.Length < 1 || payload.Length > 256 || expected == null || expected.Length != 32)
                throw new NativeAudioException("auth");
            byte[] offered = null;
            try
            {
                Dictionary<string, object> value = StrictJson.Parse(payload, "v", "token");
                StrictJson.Integer(value, "v", 1, 1);
                offered = NativeProtocol.DecodeToken(StrictJson.String(value, "token"));
                return NativeProtocol.Equal(offered, expected);
            }
            catch (ProtocolException) { throw new NativeAudioException("auth"); }
            finally { if (offered != null) Array.Clear(offered, 0, offered.Length); }
        }
        internal static byte[] Ready()
        { return StrictJson.Utf8.GetBytes("{\"v\":1,\"codec\":\"pcm-s16le\",\"sampleRate\":48000,\"channels\":2}"); }
        internal static byte[] Pcm(ulong sequence, ulong firstSampleIndex, byte[] samples, int frames)
        {
            if (sequence == 0 || samples == null || frames < 1 || frames > MaximumFrames ||
                samples.Length < frames * BytesPerFrame || firstSampleIndex > ulong.MaxValue - (ulong)frames)
                throw new NativeAudioException("protocol");
            byte[] bytes = new byte[20 + frames * BytesPerFrame];
            NativeProtocol.Put64(bytes, 0, sequence); NativeProtocol.Put64(bytes, 8, firstSampleIndex);
            NativeProtocol.Put32(bytes, 16, (uint)frames); Buffer.BlockCopy(samples, 0, bytes, 20, frames * BytesPerFrame);
            return bytes;
        }
        internal static void ValidatePcm(byte[] bytes, ulong previousSequence, ulong previousEnd)
        {
            if (bytes == null || bytes.Length < 24 || bytes.Length > MaximumPayload || previousSequence == ulong.MaxValue)
                throw new NativeAudioException("protocol");
            ulong sequence = U64(bytes, 0), start = U64(bytes, 8);
            uint frames = NativeProtocol.U32(bytes, 16);
            if (sequence != previousSequence + 1 || frames < 1 || frames > MaximumFrames ||
                bytes.Length != 20 + (int)frames * BytesPerFrame || start < previousEnd || start > ulong.MaxValue - frames)
                throw new NativeAudioException("protocol");
        }
        internal static ulong U64(byte[] bytes, int offset)
        {
            if (bytes == null || offset < 0 || offset > bytes.Length - 8) throw new NativeAudioException("protocol");
            ulong value = 0; for (int i = 0; i < 8; ++i) value = (value << 8) | bytes[offset + i]; return value;
        }
        internal static Packet ReadHello(Stream stream)
        {
            byte[] header = NativeProtocol.ReadExactly(stream, 5);
            uint count = NativeProtocol.U32(header, 1);
            if (header[0] != 1 || count < 1 || count > 256) throw new NativeAudioException("auth");
            return new Packet(1, NativeProtocol.ReadExactly(stream, (int)count));
        }
        internal static void Write(Stream stream, byte kind, byte[] payload)
        {
            if (payload == null || kind == 2 && (payload.Length < 1 || payload.Length > 256) ||
                kind == 3 && (payload.Length < 24 || payload.Length > MaximumPayload) ||
                kind == 4 && payload.Length != 0 || kind == 127 && (payload.Length < 1 || payload.Length > 128) ||
                kind != 2 && kind != 3 && kind != 4 && kind != 127)
                throw new NativeAudioException("protocol");
            NativeProtocol.Write(stream, kind, payload);
        }
        internal static byte[] Error(string code)
        {
            if (code != "auth" && code != "unavailable" && code != "closed" && code != "protocol" && code != "timeout")
                throw new ArgumentException("Invalid audio error.");
            return StrictJson.Utf8.GetBytes("{\"code\":" + StrictJson.Quote(code) + "}");
        }
    }
}
