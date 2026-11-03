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
struct Entry { uint64_t offset; uint32_t length; bool idr; uint64_t timestamp; };
}

int wmain(int argc, wchar_t** argv) {
    if (argc != 4 || (std::wstring(argv[1]) != L"--software" && std::wstring(argv[1]) != L"--hardware" &&
        std::wstring(argv[1]) != L"--software-4k" && std::wstring(argv[1]) != L"--software-4k60")) {
        std::cerr << "usage: KnotNativeMediaSynthetic.exe --software|--hardware|--software-4k|--software-4k60 fixture.h264 fixture.json\n";
        return 2;
    }
    if (!ParserChecks()) { std::cerr << "H264 parser checks failed\n"; return 1; }
    knot::Runtime runtime;
    if (FAILED(runtime.Start())) { std::cerr << "COM/MF startup failed\n"; return 1; }
    knot::Encoder encoder;
    const bool fourK60 = std::wstring(argv[1]) == L"--software-4k60";
    const bool fourK = fourK60 || std::wstring(argv[1]) == L"--software-4k";
    const KnMediaConfig config = fourK ? KnMediaConfig{3840, 2160, fourK60 ? 60U : 30U, 40000000} :
        KnMediaConfig{320, 180, 30, 2000000};
    const bool software = std::wstring(argv[1]) != L"--hardware";
    HRESULT hr = encoder.Start(config, software);
    if (FAILED(hr)) { std::cerr << "Synthetic MFT initialization failed: " << std::hex << static_cast<unsigned long>(hr) << '\n'; return 1; }
    if (encoder.Hardware() == software) return 1;
    std::ofstream video(argv[2], std::ios::binary | std::ios::trunc);
    if (!video) { std::cerr << "Cannot create synthetic fixture\n"; return 1; }
    const uint32_t frames = fourK60 ? 12U : (fourK ? 6U : 120U);
    uint32_t submitted = 0;
    uint32_t peakInFlight = 0;
    uint64_t offset = 0;
    std::vector<Entry> entries;
    std::vector<uint8_t> pixels;
    bool drained = false;
    const auto began = knot::Clock::now();
    const auto deadline = began + std::chrono::seconds(30);
    while (entries.size() < frames && knot::Clock::now() < deadline) {
        hr = encoder.Poll();
        if (FAILED(hr)) break;
        knot::AccessUnit unit;
        hr = encoder.Receive(unit);
        if (FAILED(hr)) break;
        if (hr == S_OK && !unit.bytes.empty()) {
            bool idr = false, sps = false, pps = false;
            if (!knot::AnalyzeH264(unit.bytes, idr, sps, pps, nullptr) || (idr && (!sps || !pps))) {
                hr = MF_E_INVALIDMEDIATYPE; break;
            }
            video.write(reinterpret_cast<const char*>(unit.bytes.data()), static_cast<std::streamsize>(unit.bytes.size()));
            if (!video) { hr = E_FAIL; break; }
            entries.push_back({offset, static_cast<uint32_t>(unit.bytes.size()), idr, unit.timestamp});
            offset += unit.bytes.size();
        }
        if (submitted < frames && encoder.CanSubmit()) {
            Pixels(pixels, config, submitted);
            const uint64_t presentationMicros = static_cast<uint64_t>(submitted) * 1000000ULL / config.fps;
            hr = encoder.Submit(pixels, 1000000ULL + presentationMicros, presentationMicros);
            if (FAILED(hr) && hr != MF_E_NOTACCEPTING) break;
            if (SUCCEEDED(hr)) {
                ++submitted; peakInFlight = std::max(peakInFlight, encoder.InFlight());
                if (peakInFlight > knot::Encoder::Capacity) { hr = E_UNEXPECTED; break; }
            }
        }
        if (submitted == frames && !drained) {
            hr = encoder.Drain(); if (FAILED(hr)) break; drained = true;
        }
        Sleep(1);
    }
    video.close();
    if (FAILED(hr) || entries.size() != frames || entries.empty() || !entries.front().idr) {
        std::cerr << "Synthetic codec incomplete: " << entries.size() << "/" << frames << " hr="
            << std::hex << static_cast<unsigned long>(hr) << std::dec << " outputMinimum=" << encoder.LastOutputMinimum()
            << " peakScratch=" << encoder.PeakOutputScratch() << '\n'; return 1;
    }
    uint32_t keyframes = 0;
    for (const auto& entry : entries) if (entry.idr) ++keyframes;
    if (keyframes < (fourK ? 1U : 2U)) { std::cerr << "Required IDR missing\n"; return 1; }
    std::ofstream manifest(argv[3], std::ios::trunc);
    manifest << "{\"v\":1,\"synthetic\":true,\"captureInvoked\":false,\"codec\":\"h264-annexb\","
        "\"width\":" << config.width << ",\"height\":" << config.height << ",\"fps\":" << config.fps
        << ",\"bitrate\":" << config.bitrate << ",\"hardwareEncoder\":"
        << (encoder.Hardware() ? "true" : "false") << ",\"frames\":" << entries.size()
        << ",\"keyframes\":" << keyframes << ",\"parserChecks\":true";
    if (fourK) manifest << ",\"peakEncoderInFlight\":" << peakInFlight << ",\"encoderCapacity\":" << knot::Encoder::Capacity
        << ",\"peakOutputScratchBytes\":" << encoder.PeakOutputScratch()
        << ",\"fixtureWallMicros\":" << std::chrono::duration_cast<std::chrono::microseconds>(knot::Clock::now() - began).count();
    manifest << ",\"accessUnits\":[";
    for (size_t i = 0; i < entries.size(); ++i) {
        const auto& entry = entries[i];
        if (i != 0) manifest << ',';
        manifest << "{\"sequence\":" << i + 1 << ",\"offset\":" << entry.offset << ",\"length\":" << entry.length
            << ",\"flags\":" << (entry.idr ? 1 : 0) << ",\"timestampMicros\":" << entry.timestamp << '}';
    }
    manifest << "]}\n";
    manifest.close();
    if (!manifest) return 1;
    std::cout << "PASS: " << frames << " fresh synthetic frames through actual " << (software ? "software" : "hardware")
        << " MFT; capture never linked; ";
    if (fourK) std::cout << "size=" << config.width << 'x' << config.height << "; ";
    std::cout << "IDR=" << keyframes << '\n';
    return 0;
}
