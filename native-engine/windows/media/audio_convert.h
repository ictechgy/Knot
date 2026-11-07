// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <deque>
#include <limits>

namespace knot {
enum class AudioSample { Pcm16, Pcm24, Pcm32, Float32 };
struct AudioInputFormat {
    uint32_t rate = 0, channels = 0, channelMask = 0;
    AudioSample sample = AudioSample::Float32;
    uint32_t BytesPerSample() const { return sample == AudioSample::Pcm16 ? 2U : sample == AudioSample::Pcm24 ? 3U : 4U; }
    bool Valid() const {
        if (rate < 8000 || rate > 192000 || channels < 1 || channels > 8 ||
            (sample != AudioSample::Pcm16 && sample != AudioSample::Pcm24 &&
             sample != AudioSample::Pcm32 && sample != AudioSample::Float32)) return false;
        if (channelMask != 0) {
            uint32_t bits = 0; for (uint32_t mask = channelMask; mask != 0; mask >>= 1U) bits += mask & 1U;
            if (bits != channels || (channelMask & ~0x3ffffU) != 0) return false;
        }
        return true;
    }
};

// Portable, bounded conversion used by the real WASAPI capture path and fresh
// synthetic checks. Common stereo48k input takes the exact no-resample path.
// Other rates use linear interpolation, not a studio mastering resampler.
class AudioConverter {
public:
    static constexpr uint32_t OutputRate = 48000, CapacityFrames = 4800;
    explicit AudioConverter(const AudioInputFormat& format) : format_(format) { if (format_.Valid()) BuildWeights(); }
    bool Valid() const { return format_.Valid(); }
    uint32_t PendingFrames() const { return static_cast<uint32_t>(samples_.size() / 2); }
    uint64_t GeneratedFrames() const { return generated_; }
    void DiscardPending() { samples_.clear(); first_ = generated_; }
    void Discontinuity() {
        DiscardPending(); havePrevious_ = false; inputPosition_ = 0; nextPosition_ = 0;
        // A gap signals that queued sound must not bridge a device discontinuity.
        if (generated_ != std::numeric_limits<uint64_t>::max()) ++generated_;
        first_ = generated_;
    }
    bool Feed(const uint8_t* bytes, uint32_t frames, bool silent) {
        if (!Valid() || (!silent && bytes == nullptr) || frames > format_.rate / 2U) return false;
        const uint32_t stride = format_.channels * format_.BytesPerSample();
        for (uint32_t frame = 0; frame < frames; ++frame) {
            float left = 0, right = 0;
            if (!silent) for (uint32_t channel = 0; channel < format_.channels; ++channel) {
                const float value = Decode(bytes + static_cast<size_t>(frame) * stride + channel * format_.BytesPerSample());
                left += value * left_[channel]; right += value * right_[channel];
            }
            if (!std::isfinite(left) || !std::isfinite(right)) { left = right = 0; }
            if (format_.rate == OutputRate) {
                if (!Emit(left, right)) return false;
            } else if (!havePrevious_) {
                havePrevious_ = true; previousLeft_ = left; previousRight_ = right;
                if (!Emit(left, right)) return false;
                inputPosition_ = 0; nextPosition_ = static_cast<double>(format_.rate) / OutputRate;
            } else {
                ++inputPosition_;
                while (nextPosition_ <= static_cast<double>(inputPosition_)) {
                    const double fraction = nextPosition_ - static_cast<double>(inputPosition_ - 1);
                    if (!Emit(static_cast<float>(previousLeft_ + (left - previousLeft_) * fraction),
                              static_cast<float>(previousRight_ + (right - previousRight_) * fraction))) return false;
                    nextPosition_ += static_cast<double>(format_.rate) / OutputRate;
                }
                previousLeft_ = left; previousRight_ = right;
            }
        }
        return true;
    }
    uint32_t Pop(uint8_t* output, uint32_t capacity, uint64_t& firstSample) {
        firstSample = first_;
        const uint32_t count = std::min(capacity, PendingFrames());
        for (uint32_t frame = 0; frame < count; ++frame) {
            for (uint32_t channel = 0; channel < 2; ++channel) {
                const uint16_t value = static_cast<uint16_t>(samples_.front()); samples_.pop_front();
                output[frame * 4 + channel * 2] = static_cast<uint8_t>(value);
                output[frame * 4 + channel * 2 + 1] = static_cast<uint8_t>(value >> 8U);
            }
        }
        first_ += count; return count;
    }
private:
    AudioInputFormat format_;
    float left_[8] = {}, right_[8] = {};
    bool havePrevious_ = false;
    float previousLeft_ = 0, previousRight_ = 0;
    uint64_t generated_ = 0, first_ = 0, inputPosition_ = 0;
    double nextPosition_ = 0;
    std::deque<int16_t> samples_;
    float Decode(const uint8_t* p) const {
        if (format_.sample == AudioSample::Pcm16) {
            const uint16_t bits = static_cast<uint16_t>(p[0] | (static_cast<uint16_t>(p[1]) << 8U));
            return static_cast<int16_t>(bits) / 32768.0f;
        }
        if (format_.sample == AudioSample::Pcm24) {
            uint32_t bits = p[0] | (static_cast<uint32_t>(p[1]) << 8U) | (static_cast<uint32_t>(p[2]) << 16U);
            if ((bits & 0x800000U) != 0) bits |= 0xff000000U;
            return static_cast<int32_t>(bits) / 8388608.0f;
        }
        uint32_t bits = p[0] | (static_cast<uint32_t>(p[1]) << 8U) | (static_cast<uint32_t>(p[2]) << 16U) | (static_cast<uint32_t>(p[3]) << 24U);
        if (format_.sample == AudioSample::Pcm32) return static_cast<int32_t>(bits) / 2147483648.0f;
        float value; std::memcpy(&value, &bits, sizeof(value));
        return std::isfinite(value) ? value : 0;
    }
    static int16_t Pcm(float value) {
        const double bounded = std::max(-1.0, std::min(1.0, static_cast<double>(value)));
        const long scaled = std::lrint(bounded * 32768.0);
        return static_cast<int16_t>(std::max(-32768L, std::min(32767L, scaled)));
    }
    bool Emit(float left, float right) {
        if (generated_ == std::numeric_limits<uint64_t>::max()) return false;
        if (samples_.empty()) first_ = generated_;
        samples_.push_back(Pcm(left)); samples_.push_back(Pcm(right)); ++generated_;
        if (PendingFrames() > CapacityFrames) { samples_.pop_front(); samples_.pop_front(); ++first_; }
        return true;
    }
    void BuildWeights() {
        if (format_.channels == 1) { left_[0] = right_[0] = 1; return; }
        // Standard WAVE channel order. A missing mask uses the conventional
        // layout rather than dropping a surround centre/dialogue channel.
        uint32_t mask = format_.channelMask;
        if (mask == 0) {
            const uint32_t defaults[] = { 0, 4, 3, 7, 0x33, 0x37, 0x3f, 0x13f, 0x63f };
            if (format_.channels <= 8) mask = defaults[format_.channels];
        }
        uint32_t channel = 0;
        for (uint32_t bit = 1; bit <= 0x20000U && channel < format_.channels; bit <<= 1U) {
            if ((mask & bit) == 0) continue;
            float l = 0.5f, r = 0.5f;
            if (bit == 1 || bit == 0x40) { l = 1; r = 0; }
            else if (bit == 2 || bit == 0x80) { l = 0; r = 1; }
            else if (bit == 4) { l = r = 0.70710678f; }
            else if (bit == 0x10 || bit == 0x200) { l = 0.70710678f; r = 0; }
            else if (bit == 0x20 || bit == 0x400) { l = 0; r = 0.70710678f; }
            left_[channel] = l; right_[channel] = r; ++channel;
        }
        float lsum = 0, rsum = 0;
        for (uint32_t i = 0; i < format_.channels; ++i) { lsum += left_[i]; rsum += right_[i]; }
        for (uint32_t i = 0; i < format_.channels; ++i) {
            left_[i] /= std::max(1.0f, lsum); right_[i] /= std::max(1.0f, rsum);
        }
    }
};
} // namespace knot
