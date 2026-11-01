#pragma once
#include "kn_media.h"
#include "h264.h"
#include <algorithm>

namespace knot {
constexpr uint32_t MaxVideoWidth = 3840;
constexpr uint32_t MaxVideoHeight = 2160;
constexpr uint64_t MaxVideoPixels = 8294400;

inline bool ValidVideoDimensions(uint32_t width, uint32_t height) {
    return width >= 16 && width <= MaxVideoWidth && height >= 16 && height <= MaxVideoHeight &&
        (width & 1U) == 0 && (height & 1U) == 0 && static_cast<uint64_t>(width) * height <= MaxVideoPixels;
}
inline bool ValidMediaConfig(const KnMediaConfig& config) {
    return ValidVideoDimensions(config.width, config.height) && config.fps >= 1 && config.fps <= 60 &&
        config.bitrate >= 1000000 && config.bitrate <= 40000000;
}
inline bool ScaleVideoToBounds(uint32_t sourceWidth, uint32_t sourceHeight, const KnMediaConfig& bounds,
    uint32_t& width, uint32_t& height) {
    width = height = 0;
    if (!ValidMediaConfig(bounds) || sourceWidth < 16 || sourceHeight < 16 ||
        sourceWidth > 16384 || sourceHeight > 16384) return false;
    const double scale = std::min({1.0, static_cast<double>(bounds.width) / sourceWidth,
        static_cast<double>(bounds.height) / sourceHeight});
    width = static_cast<uint32_t>(sourceWidth * scale) & ~1U;
    height = static_cast<uint32_t>(sourceHeight * scale) & ~1U;
    return ValidVideoDimensions(width, height) && width <= sourceWidth && height <= sourceHeight;
}
// An MFT's minimum output allocation is not an encoded access-unit length.
// The measured Windows 4K software MFT requests 1.25 NV12 frames. Permit a
// finite two-NV12-frame budget (24,883,200 bytes at 4K), not an arbitrary MFT
// allocation. This is our resource policy, not a bound guaranteed by codecs.
// The separate, smaller compressed AU/wire limit remains in h264.h.
inline bool CodecOutputScratch(const KnMediaConfig& config, uint32_t minimum, uint32_t& capacity) {
    capacity = 0;
    if (!ValidMediaConfig(config)) return false;
    // ValidMediaConfig bounds the product before this 64-bit arithmetic.
    const uint64_t twoNV12Frames = static_cast<uint64_t>(config.width) * config.height * 3U;
    const uint64_t maximum = std::max(static_cast<uint64_t>(kMaxAccessUnit), twoNV12Frames);
    if (minimum > maximum) return false;
    capacity = std::max(static_cast<uint32_t>(kMaxAccessUnit), minimum);
    return true;
}
}
