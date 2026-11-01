#pragma once
#include <cstddef>
#include <cstdint>
#include <vector>

namespace knot {
constexpr size_t kMaxAccessUnit = 4194304U - 17U;
constexpr size_t kMaxParameterSets = 65536U;
constexpr size_t kMaxNals = 256U;
bool NormalizeH264(const uint8_t* data, size_t size, std::vector<uint8_t>& out);
bool SequenceHeaderH264(const uint8_t* data, size_t size, std::vector<uint8_t>& out);
bool AnalyzeH264(const std::vector<uint8_t>& bytes, bool& idr, bool& sps,
    bool& pps, std::vector<uint8_t>* parameterSets);
}
