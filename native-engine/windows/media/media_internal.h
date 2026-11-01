#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include "kn_media.h"
#include "h264.h"
#include "media_pacing.h"
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_6.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>
#include <mferror.h>
#include <codecapi.h>
#include <icodecapi.h>
#include <wrl/client.h>
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <cwchar>
#include <deque>
#include <memory>
#include <vector>

namespace knot {
using Microsoft::WRL::ComPtr;
using Clock = std::chrono::steady_clock;
using Deadline = Clock::time_point;
inline uint64_t MonotonicMicros() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
        Clock::now().time_since_epoch()).count());
}

// Own the apartment and MF in a scope OUTSIDE all COM interface members.
class Runtime {
public:
    Runtime() = default;
    Runtime(const Runtime&) = delete;
    Runtime& operator=(const Runtime&) = delete;
    HRESULT Start();
    ~Runtime();
private:
    bool com_ = false, mf_ = false;
};

struct AccessUnit {
    std::vector<uint8_t> bytes;
    uint64_t timestamp = 0;
    bool idr = false;
};
// Both AnnexB and four-byte length-prefix streams are normalized, validated and
// bounded. Sequence headers also accept AVCDecoderConfigurationRecord.

class Encoder {
public:
    Encoder() = default;
    Encoder(const Encoder&) = delete;
    Encoder& operator=(const Encoder&) = delete;
    ~Encoder();
    // softwareOnly is reachable only by the separately linked synthetic test.
    HRESULT Start(const KnMediaConfig& config, bool softwareOnly);
    HRESULT Poll();
    bool CanSubmit() const { return inFlight_ < 2 && (!async_ || inputReady_ != 0); }
    bool KeyframeDue(uint64_t presentationMicros) const { return timeline_.KeyframeDue(presentationMicros); }
    HRESULT Submit(const std::vector<uint8_t>& nv12, uint64_t captureMicros, uint64_t presentationMicros);
    HRESULT Receive(AccessUnit& output); // S_FALSE = no output yet
    HRESULT Drain();
    bool Hardware() const { return hardware_; }
    uint32_t InFlight() const { return inFlight_; }
private:
    HRESULT Configure(IMFActivate* activation, const KnMediaConfig& config, bool hardware);
    HRESULT ReadSequenceHeader();
    HRESULT SetUInt(const GUID& key, ULONG value, bool required = false);
    HRESULT SetBool(const GUID& key, bool value, bool required = false);
    void Reset();
    ComPtr<IMFTransform> transform_;
    ComPtr<IMFMediaEventGenerator> events_;
    ComPtr<ICodecAPI> codec_;
    ComPtr<IMFMediaType> outputType_;
    KnMediaConfig config_{};
    bool async_ = false, hardware_ = false, draining_ = false;
    uint32_t inputReady_ = 0, outputReady_ = 0, inFlight_ = 0;
    MediaTimeline timeline_{1};
    DWORD inputId_ = 0, outputId_ = 0;
    struct Stamp { LONGLONG sampleTime; uint64_t captureMicros; };
    std::deque<Stamp> stamps_;
    std::vector<uint8_t> parameterSets_;
};

class DesktopCapture {
public:
    HRESULT Start(const KnMediaConfig& bounds, KnMediaInfo& info, KnMediaConfig& actual);
    struct Result { HRESULT status; CaptureReadiness readiness; };
    Result Read(std::vector<uint8_t>& nv12, uint64_t& timestamp, Deadline deadline);
private:
    HRESULT CheckDisplay();
    ComPtr<IDXGIOutput> output_;
    ComPtr<IDXGIOutputDuplication> duplication_;
    ComPtr<ID3D11Device> device_;
    ComPtr<ID3D11DeviceContext> context_;
    ComPtr<ID3D11VideoDevice> videoDevice_;
    ComPtr<ID3D11VideoContext> videoContext_;
    ComPtr<ID3D11VideoProcessorEnumerator> enumerator_;
    ComPtr<ID3D11VideoProcessor> processor_;
    ComPtr<ID3D11Texture2D> captured_, converted_, staging_;
    ComPtr<ID3D11VideoProcessorInputView> inputView_;
    ComPtr<ID3D11VideoProcessorOutputView> outputView_;
    DXGI_OUTPUT_DESC display_{};
    uint32_t width_ = 0, height_ = 0;
    bool copyPending_ = false;
    uint64_t pendingTimestamp_ = 0;
};
} // namespace knot
