// SPDX-License-Identifier: GPL-3.0-only
// Fresh in-memory samples only. This never opens an endpoint or plays sound.
#include "audio_convert.h"
#include <iostream>
#include <stdexcept>
#include <vector>

namespace {
unsigned assertions = 0, conversionFixtures = 0;
void Check(bool condition) { ++assertions; if (!condition) throw std::runtime_error("synthetic audio conversion"); }
knot::AudioInputFormat Format(uint32_t rate, uint32_t channels, knot::AudioSample sample, uint32_t mask = 0) {
    knot::AudioInputFormat result; result.rate = rate; result.channels = channels; result.sample = sample; result.channelMask = mask;
    return result;
}
std::vector<uint8_t> Floats(const std::vector<float>& samples) {
    std::vector<uint8_t> result(samples.size() * 4);
    for (size_t i = 0; i < samples.size(); ++i) {
        uint32_t bits; std::memcpy(&bits, &samples[i], 4);
        for (unsigned j = 0; j < 4; ++j) result[i * 4 + j] = static_cast<uint8_t>(bits >> (j * 8));
    }
    return result;
}
int16_t Sample(const std::vector<uint8_t>& bytes, unsigned frame, unsigned channel) {
    const unsigned at = frame * 4 + channel * 2;
    return static_cast<int16_t>(bytes[at] | static_cast<uint16_t>(bytes[at + 1]) << 8U);
}
std::vector<uint8_t> Drain(knot::AudioConverter& converter, uint64_t& first) {
    std::vector<uint8_t> result(converter.PendingFrames() * 4);
    const uint32_t frames = converter.Pop(result.data(), static_cast<uint32_t>(result.size() / 4), first);
    Check(frames * 4 == result.size()); return result;
}
void FormatChecks() {
    for (uint32_t channels = 1; channels <= 8; ++channels)
        for (uint32_t rate : { 8000U, 44100U, 48000U, 96000U, 192000U })
            for (knot::AudioSample sample : { knot::AudioSample::Pcm16, knot::AudioSample::Pcm24, knot::AudioSample::Pcm32, knot::AudioSample::Float32 })
                Check(Format(rate, channels, sample).Valid());
    for (uint32_t rate : { 0U, 7999U, 192001U, UINT32_MAX }) Check(!Format(rate, 2, knot::AudioSample::Float32).Valid());
    for (uint32_t channels : { 0U, 9U, UINT32_MAX }) Check(!Format(48000, channels, knot::AudioSample::Float32).Valid());
    Check(!Format(48000, 2, knot::AudioSample::Float32, 1).Valid());
    Check(!Format(48000, 2, knot::AudioSample::Float32, 0x40001).Valid());
    Check(!Format(48000, 2, static_cast<knot::AudioSample>(100)).Valid());
    knot::AudioConverter invalid(Format(1, 100, knot::AudioSample::Float32));
    Check(!invalid.Feed(nullptr, 1, true)); ++conversionFixtures;
}
void ExactPcm() {
    const std::vector<uint8_t> input = { 0, 0x80, 0xff, 0x7f, 0x34, 0x12, 0xcc, 0xed, 0, 0, 1, 0 };
    knot::AudioConverter converter(Format(48000, 2, knot::AudioSample::Pcm16));
    Check(converter.Feed(input.data(), 3, false)); uint64_t first;
    Check(Drain(converter, first) == input && first == 0); ++conversionFixtures;
}
void FloatingAndMono() {
    std::vector<uint8_t> input = Floats({ 0.5f, -0.5f, 2, -2, std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity() });
    knot::AudioConverter converter(Format(48000, 2, knot::AudioSample::Float32));
    Check(converter.Feed(input.data(), 3, false)); uint64_t first; const auto output = Drain(converter, first);
    Check(Sample(output, 0, 0) == 16384 && Sample(output, 0, 1) == -16384);
    Check(Sample(output, 1, 0) == 32767 && Sample(output, 1, 1) == -32768);
    Check(Sample(output, 2, 0) == 0 && Sample(output, 2, 1) == 0);
    knot::AudioConverter mono(Format(48000, 1, knot::AudioSample::Float32));
    input = Floats({ 0.25f, -0.25f }); Check(mono.Feed(input.data(), 2, false)); const auto doubled = Drain(mono, first);
    Check(Sample(doubled, 0, 0) == 8192 && Sample(doubled, 0, 1) == 8192);
    Check(Sample(doubled, 1, 0) == -8192 && Sample(doubled, 1, 1) == -8192); conversionFixtures += 2;
}
void WiderPcmAndSilence() {
    for (knot::AudioSample format : { knot::AudioSample::Pcm24, knot::AudioSample::Pcm32 }) {
        const unsigned width = format == knot::AudioSample::Pcm24 ? 3 : 4;
        std::vector<uint8_t> input(width * 2, 0); input[width - 1] = 0x40; input[width * 2 - 1] = 0xc0;
        knot::AudioConverter converter(Format(48000, 2, format)); Check(converter.Feed(input.data(), 1, false));
        uint64_t first; auto output = Drain(converter, first);
        Check(Sample(output, 0, 0) == 16384 && Sample(output, 0, 1) == -16384);
        Check(converter.Feed(nullptr, 10, true)); output = Drain(converter, first);
        Check(output == std::vector<uint8_t>(40, 0) && first == 1); ++conversionFixtures;
    }
}
void SurroundDialogue() {
    for (uint32_t channels : { 3U, 6U, 8U }) {
        std::vector<float> input(channels, 0); input[2] = 0.5f;
        auto bytes = Floats(input); knot::AudioConverter converter(Format(48000, channels, knot::AudioSample::Float32));
        Check(converter.Feed(bytes.data(), 1, false)); uint64_t first; auto output = Drain(converter, first);
        Check(Sample(output, 0, 0) > 0 && Sample(output, 0, 0) == Sample(output, 0, 1)); ++conversionFixtures;
    }
}
void StreamingResample() {
    for (uint32_t rate : { 8000U, 44100U, 48000U, 96000U, 192000U }) {
        const uint32_t frames = rate / 10;
        std::vector<float> input(frames * 2);
        for (uint32_t i = 0; i < frames; ++i) { input[i * 2] = static_cast<float>(i % 123) / 250; input[i * 2 + 1] = -input[i * 2]; }
        const auto bytes = Floats(input);
        knot::AudioConverter whole(Format(rate, 2, knot::AudioSample::Float32)), split(Format(rate, 2, knot::AudioSample::Float32));
        Check(whole.Feed(bytes.data(), frames, false));
        for (uint32_t at = 0; at < frames;) {
            const uint32_t count = std::min(131U, frames - at);
            Check(split.Feed(bytes.data() + at * 8, count, false)); at += count;
        }
        uint64_t firstWhole, firstSplit; const auto expected = Drain(whole, firstWhole), actual = Drain(split, firstSplit);
        Check(firstWhole == 0 && firstSplit == 0 && expected == actual);
        Check(actual.size() / 4 >= 4790 && actual.size() / 4 <= 4800); ++conversionFixtures;
    }
}
void BoundedQueueAndGaps() {
    knot::AudioConverter converter(Format(48000, 2, knot::AudioSample::Float32));
    Check(converter.Feed(nullptr, 24000, true)); Check(converter.PendingFrames() == 4800 && converter.GeneratedFrames() == 24000);
    uint64_t first; auto output = Drain(converter, first); Check(first == 19200 && output.size() == 19200);
    Check(converter.Feed(nullptr, 960, true)); converter.DiscardPending(); Check(converter.PendingFrames() == 0);
    Check(converter.Feed(nullptr, 1, true)); output = Drain(converter, first); Check(first == 24960);
    converter.Discontinuity(); Check(converter.Feed(nullptr, 1, true)); output = Drain(converter, first); Check(first == 24962);
    Check(!converter.Feed(nullptr, 24001, true)); Check(!converter.Feed(nullptr, 1, false)); ++conversionFixtures;
}
}
int main() {
    try {
        FormatChecks(); ExactPcm(); FloatingAndMono(); WiderPcmAndSilence(); SurroundDialogue(); StreamingResample(); BoundedQueueAndGaps();
        std::cout << "{\"status\":\"passed\",\"freshSyntheticOnly\":true,\"actualAudioCapture\":false,\"actualAudioPlayback\":false,\"audioConversionFixtures\":" << conversionFixtures << ",\"assertions\":" << assertions << "}\n";
        return 0;
    } catch (...) { std::cout << "{\"status\":\"failed\",\"freshSyntheticOnly\":true,\"actualAudioCapture\":false,\"actualAudioPlayback\":false}\n"; return 1; }
}
