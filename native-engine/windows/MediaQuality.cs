// SPDX-License-Identifier: GPL-3.0-only
using System;

namespace Knot.NativePreview
{
    internal static class MediaLimits
    {
        internal const uint MaximumWidth = 3840, MaximumHeight = 2160;
        internal const ulong MaximumPixels = 8294400;
        internal static bool ValidDimensions(uint width, uint height)
        {
            return width >= 16 && width <= MaximumWidth && height >= 16 && height <= MaximumHeight &&
                width % 2 == 0 && height % 2 == 0 && (ulong)width * height <= MaximumPixels;
        }
        internal static bool ValidConfig(MediaConfig config)
        {
            return ValidDimensions(config.Width, config.Height) && config.Fps >= 1 && config.Fps <= 60 &&
                config.Bitrate >= 1000000 && config.Bitrate <= 40000000;
        }
    }

    // Immutable, local preferences are captured before a sharing run starts.
    // Bounds are not a request to change Windows' physical display topology.
    internal sealed class MediaQualityProfile
    {
        internal static readonly MediaQualityProfile Sharp4K = new MediaQualityProfile("최대 4K · 30fps · 40Mbps", 3840, 2160, 30, 40000000);
        internal static readonly MediaQualityProfile Smooth4K = new MediaQualityProfile("최대 4K · 60fps · 40Mbps", 3840, 2160, 60, 40000000);
        internal static readonly MediaQualityProfile Compatible1080 = new MediaQualityProfile("호환 모드 · 1080p · 60fps · 20Mbps", 1920, 1080, 60, 20000000);
        private readonly string label;
        private readonly MediaConfig config;
        private MediaQualityProfile(string label, uint width, uint height, uint fps, uint bitrate)
        {
            config = new MediaConfig { Width = width, Height = height, Fps = fps, Bitrate = bitrate };
            if (!MediaLimits.ValidConfig(config)) throw new ArgumentException("Unsupported native media profile.");
            this.label = label;
        }
        internal MediaConfig Config { get { return config; } }
        public override string ToString() { return label; }
    }
}
