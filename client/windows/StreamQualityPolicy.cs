// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;

namespace DeskBridge.Reverse
{
    internal sealed class StreamQualityChoice<T>
    {
        internal readonly T Value;
        private readonly string label;
        internal StreamQualityChoice(T value, string label) { Value = value; this.label = label; }
        public override string ToString() { return label; }
    }

    // The native choices and command validation share this policy. The first
    // choice in each immutable list is the unchanged default.
    internal static class StreamQualityPolicy
    {
        internal static readonly ReadOnlyCollection<StreamQualityChoice<string>> Resolutions = Array.AsReadOnly(new[] {
            new StreamQualityChoice<string>("1920x1080", "1920 × 1080 (1080p)"),
            new StreamQualityChoice<string>("2560x1440", "2560 × 1440 (1440p)"),
            new StreamQualityChoice<string>("3840x2160", "3840 × 2160 (4K)"),
            new StreamQualityChoice<string>("1280x720", "1280 × 720 (720p)") });
        internal static readonly ReadOnlyCollection<StreamQualityChoice<int>> FrameRates = Array.AsReadOnly(new[] {
            new StreamQualityChoice<int>(60, "60"), new StreamQualityChoice<int>(30, "30") });
        internal static readonly ReadOnlyCollection<StreamQualityChoice<int>> BitratesKbps = Array.AsReadOnly(new[] {
            new StreamQualityChoice<int>(20000, "20 Mbps"), new StreamQualityChoice<int>(10000, "10 Mbps"),
            new StreamQualityChoice<int>(30000, "30 Mbps"), new StreamQualityChoice<int>(40000, "40 Mbps"),
            new StreamQualityChoice<int>(60000, "60 Mbps"), new StreamQualityChoice<int>(80000, "80 Mbps"),
            new StreamQualityChoice<int>(100000, "100 Mbps") });

        internal static string DefaultResolution { get { return Resolutions[0].Value; } }
        internal static int DefaultFrameRate { get { return FrameRates[0].Value; } }
        internal static int DefaultBitrateKbps { get { return BitratesKbps[0].Value; } }

        internal static void Validate(string resolution, int fps, int bitrateKbps)
        {
            if (!Contains(Resolutions, resolution)) throw new ArgumentException("지원되지 않는 해상도입니다.");
            if (!Contains(FrameRates, fps) || !Contains(BitratesKbps, bitrateKbps)) throw new ArgumentException("지원되지 않는 화면 설정입니다.");
        }

        private static bool Contains<T>(IEnumerable<StreamQualityChoice<T>> choices, T value)
        {
            foreach (StreamQualityChoice<T> choice in choices)
                if (EqualityComparer<T>.Default.Equals(choice.Value, value)) return true;
            return false;
        }
    }
}
