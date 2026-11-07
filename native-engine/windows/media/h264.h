#pragma once
#include <cstddef>
#include <cstdint>
#include <vector>

namespace knot {
constexpr size_t kMaxAccessUnit = 4194304U - 17U;
constexpr size_t kMaxParameterSetBytes = 65536U;
constexpr size_t kMaxParameterSetsPerType = 8U;
// Cache bound includes a four-byte AnnexB prefix for each of 8 SPS and 8 PPS.
constexpr size_t kMaxParameterSets = 2U * kMaxParameterSetsPerType * (kMaxParameterSetBytes + 4U);
constexpr size_t kMaxNals = 128U;
// Framing belongs to a negotiated encoder stream, not an individual access unit.
// Four-byte AVCC lengths can themselves begin with an AnnexB start-code prefix.
enum class H264Framing { Unknown, AnnexB, Avcc4 };
bool NormalizeH264(const uint8_t* data, size_t size, std::vector<uint8_t>& out);
// Unknown locks only after exactly one framing parses the complete sample.
// A known framing never falls back to the other interpretation. On failure the
// caller retains its previous framing and receives no partially normalized AU.
bool NormalizeH264(const uint8_t* data, size_t size, std::vector<uint8_t>& out,
    H264Framing& framing);
bool SequenceHeaderH264(const uint8_t* data, size_t size, std::vector<uint8_t>& out);
bool AnalyzeH264(const std::vector<uint8_t>& bytes, bool& idr, bool& sps,
    bool& pps, std::vector<uint8_t>* parameterSets, bool* hasSlice = nullptr);
}
