#include "h264.h"

namespace knot {
namespace {
struct Nal { size_t begin, end; };
size_t Prefix(const uint8_t* p, size_t size, size_t at) {
    if (at + 3 <= size && p[at] == 0 && p[at + 1] == 0 && p[at + 2] == 1) return 3;
    if (at + 4 <= size && p[at] == 0 && p[at + 1] == 0 && p[at + 2] == 0 && p[at + 3] == 1) return 4;
    return 0;
}
bool Split(const uint8_t* p, size_t size, std::vector<Nal>& nals) {
    if (!p || size == 0 || size > kMaxAccessUnit || Prefix(p, size, 0) == 0) return false;
    size_t at = 0;
    while (at < size) {
        const size_t prefix = Prefix(p, size, at);
        if (prefix == 0 || nals.size() == kMaxNals) return false;
        const size_t begin = at + prefix;
        size_t end = begin;
        while (end < size && Prefix(p, size, end) == 0) ++end;
        at = end;
        while (end > begin && p[end - 1] == 0) --end; // AnnexB trailing_zero_8bits
        if (end == begin || (p[begin] & 0x80U) != 0) return false;
        const uint8_t type = p[begin] & 31U;
        if (type == 0 || type >= 24) return false;
        nals.push_back({begin, end});
    }
    return !nals.empty();
}
void Append(std::vector<uint8_t>& out, const uint8_t* p, size_t size) {
    out.insert(out.end(), {0, 0, 0, 1});
    out.insert(out.end(), p, p + size);
}
}

bool NormalizeH264(const uint8_t* data, size_t size, std::vector<uint8_t>& out) {
    out.clear();
    if (!data || size == 0 || size > kMaxAccessUnit) return false;
    std::vector<Nal> nals;
    if (Prefix(data, size, 0) != 0 && Split(data, size, nals)) {
        for (const auto& n : nals) Append(out, data + n.begin, n.end - n.begin);
    } else {
        size_t at = 0, count = 0;
        while (at < size) {
            if (size - at < 4 || ++count > kMaxNals) return false;
            const uint32_t length = (static_cast<uint32_t>(data[at]) << 24U) |
                (static_cast<uint32_t>(data[at + 1]) << 16U) |
                (static_cast<uint32_t>(data[at + 2]) << 8U) | data[at + 3];
            at += 4;
            if (length == 0 || length > size - at) return false;
            if ((data[at] & 0x80U) != 0 || (data[at] & 31U) == 0 || (data[at] & 31U) >= 24) return false;
            Append(out, data + at, length);
            at += length;
        }
    }
    return !out.empty() && out.size() <= kMaxAccessUnit;
}

bool AnalyzeH264(const std::vector<uint8_t>& bytes, bool& idr, bool& sps,
    bool& pps, std::vector<uint8_t>* parameterSets) {
    idr = sps = pps = false;
    if (parameterSets) parameterSets->clear();
    std::vector<Nal> nals;
    if (!Split(bytes.data(), bytes.size(), nals)) return false;
    for (const auto& n : nals) {
        const uint8_t type = bytes[n.begin] & 31U;
        idr = idr || type == 5;
        sps = sps || type == 7;
        pps = pps || type == 8;
        if (parameterSets && (type == 7 || type == 8)) {
            if (parameterSets->size() + 4 + n.end - n.begin > kMaxParameterSets) return false;
            Append(*parameterSets, bytes.data() + n.begin, n.end - n.begin);
        }
    }
    return true;
}

bool SequenceHeaderH264(const uint8_t* data, size_t size, std::vector<uint8_t>& out) {
    if (!data || size == 0 || size > kMaxParameterSets) return false;
    if (data[0] != 1) return NormalizeH264(data, size, out);
    // AVCDecoderConfigurationRecord: reserved bits, four-byte NAL length size,
    // then SPS/PPS arrays. High-profile extension bytes are unnecessary here.
    if (size < 7 || (data[4] & 0xFCU) != 0xFCU || (data[4] & 3U) != 3U ||
        (data[5] & 0xE0U) != 0xE0U) return false;
    out.clear();
    size_t at = 6;
    const uint32_t spsCount = data[5] & 31U;
    for (uint32_t group = 0; group < 2; ++group) {
        const uint32_t count = group == 0 ? spsCount : (at < size ? data[at++] : 0);
        if (count == 0 || count > 32) return false;
        for (uint32_t i = 0; i < count; ++i) {
            if (size - at < 2) return false;
            const size_t length = (static_cast<size_t>(data[at]) << 8U) | data[at + 1];
            at += 2;
            if (length == 0 || length > size - at || (data[at] & 31U) != (group == 0 ? 7U : 8U)) return false;
            Append(out, data + at, length);
            at += length;
        }
    }
    return out.size() <= kMaxParameterSets;
}
} // namespace knot
