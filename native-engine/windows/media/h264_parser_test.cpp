// Portable parser checks: no Windows APIs, desktop capture, or codec invocation.
#include "h264.h"
#include <iostream>
#include <random>

namespace {
bool Checks() {
    std::vector<uint8_t> output;
    bool idr = false, sps = false, pps = false;
    const std::vector<uint8_t> annex{0, 0, 1, 0x67, 0x80, 0, 0, 0, 1, 0x68, 0x80, 0, 0, 1, 0x65, 0x80};
    if (!knot::NormalizeH264(annex.data(), annex.size(), output) ||
        !knot::AnalyzeH264(output, idr, sps, pps, nullptr) || !idr || !sps || !pps) return false;
    const std::vector<uint8_t> length{0, 0, 0, 2, 0x65, 0x80};
    if (!knot::NormalizeH264(length.data(), length.size(), output) || output.size() != 6) return false;
    // 256-byte AVCC NAL begins like a three-byte start code. Failed AnnexB
    // interpretation must still allow valid four-byte length-prefix parsing.
    std::vector<uint8_t> ambiguous(260, 0x80);
    ambiguous[0] = ambiguous[1] = ambiguous[3] = 0; ambiguous[2] = 1; ambiguous[4] = 0x65;
    if (!knot::NormalizeH264(ambiguous.data(), ambiguous.size(), output)) return false;
    const std::vector<std::vector<uint8_t>> rejected{
        {}, {0, 0, 0, 1}, {0, 0, 0, 9, 0x65}, {0, 0, 1, 0xE5, 0x80},
        {0, 0, 1, 0x78, 0x80}, {0, 0, 0, 2, 0x65, 0x80, 0}, {0x65, 0x80}
    };
    for (const auto& bytes : rejected)
        if (knot::NormalizeH264(bytes.data(), bytes.size(), output)) return false;
    std::vector<uint8_t> many;
    for (size_t i = 0; i < knot::kMaxNals + 1; ++i) many.insert(many.end(), {0, 0, 1, 0x61, 0x80});
    if (knot::NormalizeH264(many.data(), many.size(), output)) return false;
    const std::vector<uint8_t> avcc{1, 66, 0, 30, 0xFF, 0xE1, 0, 2, 0x67, 0x80, 1, 0, 2, 0x68, 0x80};
    if (!knot::SequenceHeaderH264(avcc.data(), avcc.size(), output) ||
        !knot::AnalyzeH264(output, idr, sps, pps, nullptr) || idr || !sps || !pps) return false;
    for (size_t size = 0; size < avcc.size(); ++size)
        if (knot::SequenceHeaderH264(avcc.data(), size, output)) return false;
    std::vector<uint8_t> oversized(knot::kMaxAccessUnit + 1, 0x80);
    if (knot::NormalizeH264(oversized.data(), oversized.size(), output)) return false;
    // Bounded deterministic hostile bytes exercise size arithmetic under ASan
    // and UBSan without using any existing media as an input.
    std::mt19937 generator(0x4B4E4F54U);
    for (unsigned iteration = 0; iteration < 20000; ++iteration) {
        std::vector<uint8_t> random(generator() % 2048U);
        for (auto& byte : random) byte = static_cast<uint8_t>(generator());
        if (knot::NormalizeH264(random.data(), random.size(), output)) {
            if (output.size() > knot::kMaxAccessUnit || !knot::AnalyzeH264(output, idr, sps, pps, nullptr)) return false;
        }
    }
    return true;
}
}
int main() {
    if (!Checks()) { std::cerr << "H264 parser checks failed\n"; return 1; }
    std::cout << "PASS: H264 boundaries, framing, parameter sets and 20000 synthetic hostile inputs\n";
    return 0;
}
