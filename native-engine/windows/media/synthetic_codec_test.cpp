// Separate executable. NEVER links the desktop capture or DLL entry points.
// Explicit --software selects the real inbox software MFT for headless CI.
#include "media_internal.h"
#include <fstream>
#include <iostream>
#include <string>

namespace {
bool ParserChecks() {
    std::vector<uint8_t> out;
    const uint8_t lengthPrefixed[]{0, 0, 0, 2, 0x65, 0x80};
    const uint8_t truncated[]{0, 0, 0, 9, 0x65};
    const uint8_t emptyNal[]{0, 0, 0, 1};
    const uint8_t forbidden[]{0, 0, 1, 0xE5, 0x80};
    if (!knot::NormalizeH264(lengthPrefixed, sizeof(lengthPrefixed), out)) return false;
    bool idr = false, sps = false, pps = false;
    if (!knot::AnalyzeH264(out, idr, sps, pps, nullptr) || !idr || sps || pps) return false;
    if (knot::NormalizeH264(truncated, sizeof(truncated), out) ||
        knot::NormalizeH264(emptyNal, sizeof(emptyNal), out) ||
        knot::NormalizeH264(forbidden, sizeof(forbidden), out)) return false;
    const uint8_t avcc[]{1, 66, 0, 30, 0xFF, 0xE1, 0, 2, 0x67, 0x80, 1, 0, 2, 0x68, 0x80};
    return knot::SequenceHeaderH264(avcc, sizeof(avcc), out) &&
        knot::AnalyzeH264(out, idr, sps, pps, nullptr) && !idr && sps && pps;
}
void Pixels(std::vector<uint8_t>& pixels, const KnMediaConfig& config, uint32_t frame) {
    const size_t lumaSize = static_cast<size_t>(config.width) * config.height;
    pixels.resize(lumaSize * 3U / 2U);
    for (uint32_t y = 0; y < config.height; ++y) {
        for (uint32_t x = 0; x < config.width; ++x) {
            // Fresh moving ramp + bright square: all pixels synthesized in RAM.
            const bool square = x >= (frame * 3U) % 240U && x < (frame * 3U) % 240U + 48U && y >= 40U && y < 88U;
            pixels[static_cast<size_t>(y) * config.width + x] = static_cast<uint8_t>(square ? 220U :
                16U + ((x + y + frame * 2U) % 180U));
        }
    }
    for (size_t i = lumaSize; i < pixels.size(); i += 2) {
        pixels[i] = static_cast<uint8_t>(96U + frame % 48U);
        pixels[i + 1] = static_cast<uint8_t>(160U - frame % 48U);
    }
}
struct Entry { uint64_t offset; uint32_t length; bool idr; uint64_t timestamp; uint32_t epoch; };
struct Segment {
    KnMediaConfig config{};
    uint32_t epoch = 0, frames = 0, firstSequence = 0, peakInFlight = 0, drainInFlight = 0;
    uint32_t peakScratch = 0;
};

HRESULT EmptyDrainCheck(knot::Encoder& encoder, const KnMediaConfig& config) {
    HRESULT hr = encoder.Start(config, true);
    if (FAILED(hr)) return hr;
    hr = encoder.Drain();
    if (FAILED(hr)) return hr;
    const auto deadline = knot::Clock::now() + std::chrono::seconds(2);
    while (!encoder.DrainComplete() && knot::Clock::now() < deadline) {
        hr = encoder.Poll();
        if (FAILED(hr)) return hr;
        knot::AccessUnit unit;
        if (encoder.Receive(unit) != S_FALSE || !unit.bytes.empty()) return E_UNEXPECTED;
    }
    return encoder.DrainComplete() && encoder.InFlight() == 0 && !encoder.CanSubmit() ? S_OK : E_FAIL;
}

// Uses the real MFT with fresh RAM pixels, never the desktop capture or DLL.
// Deliberately begin draining with accepted work still in flight, then require
// the terminal codec signal as well as every submitted AU before restarting.
HRESULT EncodeSegment(knot::Encoder& encoder, const KnMediaConfig& config, bool software,
    uint32_t frames, uint32_t epoch, uint64_t captureBase, std::ofstream& video,
    std::vector<Entry>& entries, Segment& segment) {
    HRESULT hr = encoder.Start(config, software);
    if (FAILED(hr)) return hr;
    if (encoder.Hardware() == software || encoder.Draining() || encoder.DrainComplete() ||
        encoder.InFlight() != 0) return E_UNEXPECTED;
    segment.config = config; segment.epoch = epoch; segment.frames = frames;
    segment.firstSequence = static_cast<uint32_t>(entries.size()) + 1;
    const size_t firstEntry = entries.size();
    uint32_t submitted = 0;
    uint64_t offset = entries.empty() ? 0 : entries.back().offset + entries.back().length;
    std::vector<uint8_t> pixels;
    const auto deadline = knot::Clock::now() + std::chrono::seconds(30);
    while (!encoder.DrainComplete() && knot::Clock::now() < deadline) {
        hr = encoder.Poll();
        if (FAILED(hr)) return hr;
        knot::AccessUnit unit;
        hr = encoder.Receive(unit);
        if (FAILED(hr)) return hr;
        if (hr == S_OK && !unit.bytes.empty()) {
            bool idr = false, sps = false, pps = false, hasSlice = false;
            const size_t received = entries.size() - firstEntry;
            if (received >= frames || !knot::AnalyzeH264(unit.bytes, idr, sps, pps, nullptr, &hasSlice) ||
                !hasSlice || (idr && (!sps || !pps)) || (received == 0 && (!idr || !sps || !pps)) ||
                unit.timestamp != captureBase + received * 1000000ULL / config.fps ||
                (!entries.empty() && unit.timestamp <= entries.back().timestamp)) return MF_E_INVALIDMEDIATYPE;
            video.write(reinterpret_cast<const char*>(unit.bytes.data()), static_cast<std::streamsize>(unit.bytes.size()));
            if (!video) return E_FAIL;
            entries.push_back({offset, static_cast<uint32_t>(unit.bytes.size()), idr, unit.timestamp, epoch});
            offset += unit.bytes.size();
        }
        if (submitted < frames && encoder.CanSubmit()) {
            Pixels(pixels, config, submitted);
            const uint64_t presentationMicros = static_cast<uint64_t>(submitted) * 1000000ULL / config.fps;
            hr = encoder.Submit(pixels, captureBase + presentationMicros, presentationMicros);
            if (FAILED(hr) && hr != MF_E_NOTACCEPTING) return hr;
            if (SUCCEEDED(hr)) {
                ++submitted;
                segment.peakInFlight = std::max(segment.peakInFlight, encoder.InFlight());
                if (segment.peakInFlight > knot::Encoder::Capacity) return E_UNEXPECTED;
            }
        }
        if (submitted == frames && !encoder.Draining()) {
            segment.drainInFlight = encoder.InFlight();
            if (segment.drainInFlight == 0) return E_UNEXPECTED;
            hr = encoder.Drain();
            if (FAILED(hr)) return hr;
            if (!encoder.Draining() || encoder.CanSubmit() || encoder.DrainComplete() ||
                encoder.Submit(pixels, captureBase + 10000000ULL, 10000000ULL) != MF_E_NOTACCEPTING ||
                SUCCEEDED(encoder.SetBitrate(config.bitrate)) || encoder.Drain() != S_OK) return E_UNEXPECTED;
        }
        if (!encoder.DrainComplete()) Sleep(1);
    }
    segment.peakScratch = encoder.PeakOutputScratch();
    if (!encoder.DrainComplete() || encoder.InFlight() != 0 || entries.size() - firstEntry != frames ||
        encoder.CanSubmit() || encoder.Drain() != S_OK) return E_FAIL;
    knot::AccessUnit extra;
    hr = encoder.Poll();
    if (FAILED(hr)) return hr;
    if (encoder.Receive(extra) != S_FALSE || !extra.bytes.empty() || !encoder.DrainComplete()) return E_UNEXPECTED;
    return S_OK;
}

void WriteEntries(std::ofstream& manifest, const std::vector<Entry>& entries, bool epochs) {
    manifest << ",\"accessUnits\":[";
    for (size_t i = 0; i < entries.size(); ++i) {
        const auto& entry = entries[i];
        if (i != 0) manifest << ',';
        manifest << "{\"sequence\":" << i + 1 << ",\"offset\":" << entry.offset << ",\"length\":" << entry.length
            << ",\"flags\":" << (entry.idr ? 1 : 0) << ",\"timestampMicros\":" << entry.timestamp;
        if (epochs) manifest << ",\"epoch\":" << entry.epoch;
        manifest << '}';
    }
    manifest << "]}\n";
}
}

int wmain(int argc, wchar_t** argv) {
    if (argc != 4 || (std::wstring(argv[1]) != L"--software" && std::wstring(argv[1]) != L"--hardware" &&
        std::wstring(argv[1]) != L"--software-4k" && std::wstring(argv[1]) != L"--software-4k60" &&
        std::wstring(argv[1]) != L"--software-reconfigure")) {
        std::cerr << "usage: KnotNativeMediaSynthetic.exe --software|--hardware|--software-4k|--software-4k60|--software-reconfigure fixture.h264 fixture.json\n";
        return 2;
    }
    if (!ParserChecks()) { std::cerr << "H264 parser checks failed\n"; return 1; }
    knot::Runtime runtime;
    if (FAILED(runtime.Start())) { std::cerr << "COM/MF startup failed\n"; return 1; }
    knot::Encoder encoder;
    const bool reconfigure = std::wstring(argv[1]) == L"--software-reconfigure";
    const bool fourK60 = std::wstring(argv[1]) == L"--software-4k60";
    const bool fourK = fourK60 || std::wstring(argv[1]) == L"--software-4k";
    const KnMediaConfig config = fourK ? KnMediaConfig{3840, 2160, fourK60 ? 60U : 30U, 40000000} :
        KnMediaConfig{320, 180, 30, 2000000};
    const bool software = std::wstring(argv[1]) != L"--hardware";
    std::ofstream video(argv[2], std::ios::binary | std::ios::trunc);
    if (!video) { std::cerr << "Cannot create synthetic fixture\n"; return 1; }
    const uint32_t frames = fourK60 ? 12U : (fourK ? 6U : 120U);
    std::vector<Entry> entries;
    std::vector<Segment> segments;
    const auto began = knot::Clock::now();
    HRESULT hr = S_OK;
    if (reconfigure) {
        const KnMediaConfig profiles[]{ {320, 180, 30, 2000000}, {640, 360, 60, 4000000}, {320, 180, 30, 2000000} };
        hr = EmptyDrainCheck(encoder, profiles[0]);
        for (uint32_t epoch = 0; SUCCEEDED(hr) && epoch < 3; ++epoch) {
            segments.push_back({});
            hr = EncodeSegment(encoder, profiles[epoch], true, 12, epoch, 1000000ULL + epoch * 1000000ULL,
                video, entries, segments.back());
            if (FAILED(hr)) break;
        }
    } else {
        segments.push_back({});
        hr = EncodeSegment(encoder, config, software, frames, 0, 1000000ULL, video, entries, segments.back());
    }
    video.close();
    const uint32_t expectedFrames = reconfigure ? 36U : frames;
    if (FAILED(hr) || entries.size() != expectedFrames || entries.empty() || !entries.front().idr) {
        std::cerr << "Synthetic codec incomplete: " << entries.size() << "/" << expectedFrames << " hr="
            << std::hex << static_cast<unsigned long>(hr) << std::dec << " outputMinimum=" << encoder.LastOutputMinimum()
            << " peakScratch=" << encoder.PeakOutputScratch() << '\n'; return 1;
    }
    uint32_t keyframes = 0;
    for (const auto& entry : entries) if (entry.idr) ++keyframes;
    if (keyframes < (reconfigure ? 3U : (fourK ? 1U : 2U))) { std::cerr << "Required IDR missing\n"; return 1; }
    std::ofstream manifest(argv[3], std::ios::trunc);
    manifest << "{\"v\":1,\"synthetic\":true,\"captureInvoked\":false,\"codec\":\"h264-annexb\","
        "\"hardwareEncoder\":" << (encoder.Hardware() ? "true" : "false") << ",\"frames\":" << entries.size()
        << ",\"keyframes\":" << keyframes << ",\"parserChecks\":true";
    if (reconfigure) {
        manifest << ",\"reconfigurationFixture\":true,\"drainChecks\":true,\"emptyDrainChecks\":true,\"segments\":[";
        for (size_t i = 0; i < segments.size(); ++i) {
            if (i != 0) manifest << ',';
            const auto& segment = segments[i];
            manifest << "{\"epoch\":" << segment.epoch << ",\"width\":" << segment.config.width
                << ",\"height\":" << segment.config.height << ",\"fps\":" << segment.config.fps
                << ",\"bitrate\":" << segment.config.bitrate << ",\"firstSequence\":" << segment.firstSequence
                << ",\"frames\":" << segment.frames << ",\"drainComplete\":true,\"drainInFlight\":" << segment.drainInFlight
                << ",\"firstOutputIDR\":true}";
        }
        manifest << ']';
    } else {
        const auto& segment = segments.front();
        manifest << ",\"width\":" << config.width << ",\"height\":" << config.height << ",\"fps\":" << config.fps
            << ",\"bitrate\":" << config.bitrate << ",\"drainComplete\":true,\"drainInFlight\":" << segment.drainInFlight;
        if (fourK) manifest << ",\"peakEncoderInFlight\":" << segment.peakInFlight
            << ",\"encoderCapacity\":" << knot::Encoder::Capacity << ",\"peakOutputScratchBytes\":" << segment.peakScratch
            << ",\"fixtureWallMicros\":" << std::chrono::duration_cast<std::chrono::microseconds>(knot::Clock::now() - began).count();
    }
    WriteEntries(manifest, entries, reconfigure);
    manifest.close();
    if (!manifest) return 1;
    std::cout << "PASS: " << expectedFrames << " fresh synthetic frames through actual " << (software ? "software" : "hardware")
        << " MFT; capture never linked; explicit drain complete; ";
    if (reconfigure) std::cout << "three serial profile epochs; ";
    if (fourK) std::cout << "size=" << config.width << 'x' << config.height << "; ";
    std::cout << "IDR=" << keyframes << '\n';
    return 0;
}
