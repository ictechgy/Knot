// Portable parser checks: no Windows APIs, desktop capture, or codec invocation.
#include "h264.h"
#include <iostream>
#include <random>
#include <utility>

namespace {
std::vector<uint8_t> Nals(size_t count, uint8_t type, bool lengthPrefixed = false, size_t size = 2) {
    std::vector<uint8_t> bytes;
    for (size_t i = 0; i < count; ++i) {
        if (lengthPrefixed) {
            bytes.push_back(static_cast<uint8_t>(size >> 24U));
            bytes.push_back(static_cast<uint8_t>(size >> 16U));
            bytes.push_back(static_cast<uint8_t>(size >> 8U));
            bytes.push_back(static_cast<uint8_t>(size));
        } else bytes.insert(bytes.end(), {0, 0, 0, 1});
        bytes.push_back(static_cast<uint8_t>(0x60U | type));
        bytes.insert(bytes.end(), size - 1U, 0x80);
    }
    return bytes;
}
std::vector<uint8_t> Avcc(size_t spsCount, size_t ppsCount) {
    std::vector<uint8_t> bytes{1, 66, 0, 30, 0xFF, static_cast<uint8_t>(0xE0U | spsCount)};
    for (size_t i = 0; i < spsCount; ++i) bytes.insert(bytes.end(), {0, 2, 0x67, 0x80});
    bytes.push_back(static_cast<uint8_t>(ppsCount));
    for (size_t i = 0; i < ppsCount; ++i) bytes.insert(bytes.end(), {0, 2, 0x68, 0x80});
    return bytes;
}
bool SharedLimitChecks() {
    static_assert(knot::kMaxNals == 128, "Shared v1 NAL limit");
    static_assert(knot::kMaxParameterSetsPerType == 8, "Shared v1 SPS/PPS count limit");
    static_assert(knot::kMaxParameterSetBytes == 65536, "Shared v1 parameter-set byte limit");
    std::vector<uint8_t> output, sets;
    bool idr = false, sps = false, pps = false;
    for (const bool lengthPrefixed : {false, true}) {
        const auto accepted = Nals(128, 1, lengthPrefixed);
        const auto rejected = Nals(129, 1, lengthPrefixed);
        if (!knot::NormalizeH264(accepted.data(), accepted.size(), output) ||
            !knot::AnalyzeH264(output, idr, sps, pps, nullptr) ||
            knot::NormalizeH264(rejected.data(), rejected.size(), output)) return false;
        for (const uint8_t type : {uint8_t{7}, uint8_t{8}}) {
            const auto eight = Nals(8, type, lengthPrefixed);
            const auto nine = Nals(9, type, lengthPrefixed);
            if (!knot::NormalizeH264(eight.data(), eight.size(), output) ||
                !knot::AnalyzeH264(output, idr, sps, pps, &sets) ||
                knot::NormalizeH264(nine.data(), nine.size(), output)) return false;
            const auto maxSize = Nals(1, type, lengthPrefixed, 65536);
            const auto tooLarge = Nals(1, type, lengthPrefixed, 65537);
            if (!knot::NormalizeH264(maxSize.data(), maxSize.size(), output) ||
                !knot::AnalyzeH264(output, idr, sps, pps, &sets) ||
                knot::NormalizeH264(tooLarge.data(), tooLarge.size(), output)) return false;
        }
    }
    // Analyze enforces limits even when parameter-set extraction is not used.
    const auto nineSPS = Nals(9, 7), ninePPS = Nals(9, 8), tooMany = Nals(129, 1);
    if (knot::AnalyzeH264(nineSPS, idr, sps, pps, nullptr) ||
        knot::AnalyzeH264(ninePPS, idr, sps, pps, nullptr) ||
        knot::AnalyzeH264(tooMany, idr, sps, pps, nullptr) ||
        knot::SequenceHeaderH264(nineSPS.data(), nineSPS.size(), output) ||
        knot::SequenceHeaderH264(ninePPS.data(), ninePPS.size(), output)) return false;
    // All 16 maximum-size sets fit the bounded cache; the cap is per set.
    auto largestSets = Nals(8, 7, false, 65536);
    const auto largestPPS = Nals(8, 8, false, 65536);
    largestSets.insert(largestSets.end(), largestPPS.begin(), largestPPS.end());
    if (!knot::NormalizeH264(largestSets.data(), largestSets.size(), output) ||
        !knot::AnalyzeH264(output, idr, sps, pps, &sets) || !sps || !pps ||
        sets.size() != knot::kMaxParameterSets) return false;
    for (const auto counts : {std::pair<size_t, size_t>{8, 8}, {9, 1}, {1, 9}}) {
        const auto header = Avcc(counts.first, counts.second);
        const bool accepted = counts.first == 8 && counts.second == 8;
        if (knot::SequenceHeaderH264(header.data(), header.size(), output) != accepted) return false;
    }
    // Adding cached SPS/PPS can exceed the AU limit even if both inputs fit.
    auto prepended = Nals(1, 7);
    const auto ppsBytes = Nals(1, 8), vcl = Nals(126, 1);
    prepended.insert(prepended.end(), ppsBytes.begin(), ppsBytes.end());
    prepended.insert(prepended.end(), vcl.begin(), vcl.end());
    if (!knot::AnalyzeH264(prepended, idr, sps, pps, nullptr)) return false;
    const auto oneMore = Nals(1, 1);
    prepended.insert(prepended.end(), oneMore.begin(), oneMore.end());
    return !knot::AnalyzeH264(prepended, idr, sps, pps, nullptr);
}
bool Checks() {
    if (!SharedLimitChecks()) return false;
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
    std::cout << "PASS: H264 shared 128/129 NAL, 8/9 SPS/PPS, 65536/65537-byte boundaries, framing and 20000 synthetic hostile inputs\n";
    return 0;
}
