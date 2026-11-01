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
bool NormalizeH264(const uint8_t* data, size_t size, std::vector<uint8_t>& out);
bool SequenceHeaderH264(const uint8_t* data, size_t size, std::vector<uint8_t>& out);
bool AnalyzeH264(const std::vector<uint8_t>& bytes, bool& idr, bool& sps,
    bool& pps, std::vector<uint8_t>* parameterSets);
}
