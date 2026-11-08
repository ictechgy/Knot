#include "media_internal.h"

namespace knot {
HRESULT Encoder::SetBitrate(uint32_t bitrate) {
    if (draining_ || bitrate < 1000000U || bitrate > 40000000U || !codec_) return E_INVALIDARG;
    // A capture-FPS-only adaptation must not depend on the codec accepting a
    // redundant live bitrate assignment (some hardware rejects that setter).
    if (bitrate == config_.bitrate) return S_OK;
    const HRESULT result = SetUInt(CODECAPI_AVEncCommonMeanBitRate, bitrate, true);
    if (SUCCEEDED(result)) config_.bitrate = bitrate;
    return result;
}
namespace {
struct Activations {
    IMFActivate** values = nullptr;
    UINT32 count = 0;
    ~Activations() {
        for (UINT32 i = 0; i < count; ++i) {
            // Every attempted candidate is transferred to Encoder before it is
            // activated. Remaining entries have never created a transform.
            ReleaseUnactivated(values[i]);
        }
        CoTaskMemFree(values);
    }
};
}
HRESULT Runtime::Start() {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr)) return hr;
    com_ = true; // S_FALSE also requires CoUninitialize.
    hr = MFStartup(MF_VERSION, MFSTARTUP_FULL);
    if (SUCCEEDED(hr)) mf_ = true;
    return hr;
}
Runtime::~Runtime() { if (mf_) MFShutdown(); if (com_) CoUninitialize(); }

Encoder::~Encoder() { Reset(); }
void Encoder::Reset() {
    if (transform_) {
        transform_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
        transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
    }
    // The activation owns shutdown, including partially configured candidates.
    // Keep all transform interfaces alive until that shutdown has completed.
    activation_.Reset();
    events_.Reset(); codec_.Reset(); outputType_.Reset(); transform_.Reset();
    async_ = hardware_ = draining_ = drainSignaled_ = false;
    drainResult_ = S_OK;
    inputReady_ = outputReady_ = inFlight_ = 0;
    peakOutputScratch_ = outputMinimum_ = 0;
    timeline_ = MediaTimeline(1); stamps_.clear(); parameterSets_.clear();
    outputFraming_ = H264Framing::Unknown;
}
HRESULT Encoder::SetUInt(const GUID& key, ULONG value, bool required) {
    if (!codec_) return required ? E_NOINTERFACE : S_OK;
    VARIANT v; VariantInit(&v); v.vt = VT_UI4; v.ulVal = value;
    const HRESULT hr = codec_->SetValue(&key, &v);
    return required ? (hr == S_OK ? S_OK : (FAILED(hr) ? hr : E_FAIL)) : S_OK;
}
HRESULT Encoder::SetBool(const GUID& key, bool value, bool required) {
    if (!codec_) return required ? E_NOINTERFACE : S_OK;
    VARIANT v; VariantInit(&v); v.vt = VT_BOOL; v.boolVal = value ? VARIANT_TRUE : VARIANT_FALSE;
    const HRESULT hr = codec_->SetValue(&key, &v);
    return required ? (hr == S_OK ? S_OK : (FAILED(hr) ? hr : E_FAIL)) : S_OK;
}

HRESULT Encoder::Start(const KnMediaConfig& config, bool softwareOnly) {
    Reset();
    if (!ValidMediaConfig(config)) return E_INVALIDARG;
    MFT_REGISTER_TYPE_INFO input{MFMediaType_Video, MFVideoFormat_NV12};
    MFT_REGISTER_TYPE_INFO output{MFMediaType_Video, MFVideoFormat_H264};
    Activations activations;
    const UINT32 flags = MFT_ENUM_FLAG_SORTANDFILTER |
        (softwareOnly ? MFT_ENUM_FLAG_SYNCMFT : MFT_ENUM_FLAG_HARDWARE);
    HRESULT hr = MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER, flags, &input, &output,
        &activations.values, &activations.count);
    if (FAILED(hr)) return hr;
    hr = MF_E_TOPO_CODEC_NOT_FOUND;
    for (UINT32 i = 0; i < activations.count; ++i) {
        Reset();
        activation_.Take(activations.values[i]);
        hr = Configure(activation_.Get(), config, !softwareOnly);
        if (SUCCEEDED(hr)) break;
    }
    if (FAILED(hr)) Reset();
    return hr;
}

HRESULT Encoder::Configure(IMFActivate* activation, const KnMediaConfig& config, bool hardware) {
    HRESULT hr = activation->ActivateObject(IID_PPV_ARGS(&transform_));
    if (FAILED(hr)) return hr;
    config_ = config; hardware_ = hardware; timeline_ = MediaTimeline(config.fps);
    ComPtr<IMFAttributes> attrs;
    hr = transform_->GetAttributes(&attrs);
    if (FAILED(hr)) return hr;
    UINT32 asynchronous = 0;
    attrs->GetUINT32(MF_TRANSFORM_ASYNC, &asynchronous);
    async_ = asynchronous != 0;
    if (hardware && !async_) return MF_E_INVALIDMEDIATYPE;
    if (async_) {
        hr = attrs->SetUINT32(MF_TRANSFORM_ASYNC_UNLOCK, TRUE);
        if (FAILED(hr)) return hr;
        hr = transform_.As(&events_);
        if (FAILED(hr)) return hr;
    }
    attrs->SetUINT32(MF_LOW_LATENCY, TRUE);
    transform_.As(&codec_);
    // Fail explicitly if a hardware codec cannot promise low latency or a
    // bounded GOP. There is no software or high-delay production fallback.
    hr = SetBool(CODECAPI_AVLowLatencyMode, true, hardware);
    if (FAILED(hr)) return hr;
    hr = SetUInt(CODECAPI_AVEncMPVGOPSize, config.fps * 2U, true);
    if (FAILED(hr)) return hr;
    SetBool(CODECAPI_AVEncCommonRealTime, true);
    SetUInt(CODECAPI_AVEncMPVDefaultBPictureCount, 0);
    SetUInt(CODECAPI_AVEncCommonRateControlMode, eAVEncCommonRateControlMode_CBR);
    SetUInt(CODECAPI_AVEncCommonMeanBitRate, config.bitrate);

    DWORD inputCount = 0, outputCount = 0;
    hr = transform_->GetStreamCount(&inputCount, &outputCount);
    if (FAILED(hr) || inputCount != 1 || outputCount != 1) return MF_E_INVALIDSTREAMNUMBER;
    hr = transform_->GetStreamIDs(1, &inputId_, 1, &outputId_);
    if (hr == E_NOTIMPL) { inputId_ = outputId_ = 0; } else if (FAILED(hr)) return hr;
    hr = MFCreateMediaType(&outputType_);
    if (FAILED(hr)) return hr;
    outputType_->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    outputType_->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
    outputType_->SetUINT32(MF_MT_AVG_BITRATE, config.bitrate);
    outputType_->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    outputType_->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Base);
    outputType_->SetUINT32(MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709);
    outputType_->SetUINT32(MF_MT_VIDEO_PRIMARIES, MFVideoPrimaries_BT709);
    outputType_->SetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235);
    MFSetAttributeSize(outputType_.Get(), MF_MT_FRAME_SIZE, config.width, config.height);
    MFSetAttributeRatio(outputType_.Get(), MF_MT_FRAME_RATE, config.fps, 1);
    MFSetAttributeRatio(outputType_.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    hr = transform_->SetOutputType(outputId_, outputType_.Get(), 0);
    if (FAILED(hr)) return hr;
    ComPtr<IMFMediaType> inputType;
    hr = MFCreateMediaType(&inputType);
    if (FAILED(hr)) return hr;
    inputType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    inputType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
    inputType->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    inputType->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);
    inputType->SetUINT32(MF_MT_DEFAULT_STRIDE, config.width);
    inputType->SetUINT32(MF_MT_SAMPLE_SIZE, config.width * config.height * 3U / 2U);
    inputType->SetUINT32(MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709);
    inputType->SetUINT32(MF_MT_VIDEO_PRIMARIES, MFVideoPrimaries_BT709);
    inputType->SetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235);
    MFSetAttributeSize(inputType.Get(), MF_MT_FRAME_SIZE, config.width, config.height);
    MFSetAttributeRatio(inputType.Get(), MF_MT_FRAME_RATE, config.fps, 1);
    MFSetAttributeRatio(inputType.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    hr = transform_->SetInputType(inputId_, inputType.Get(), 0);
    if (FAILED(hr)) return hr;
    hr = transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    if (FAILED(hr)) return hr;
    hr = transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    if (FAILED(hr)) return hr;
    return ReadSequenceHeader();
}

HRESULT Encoder::ReadSequenceHeader() {
    ComPtr<IMFMediaType> current;
    HRESULT hr = transform_->GetOutputCurrentType(outputId_, &current);
    if (FAILED(hr)) return hr;
    UINT32 size = 0;
    hr = current->GetBlobSize(MF_MT_MPEG_SEQUENCE_HEADER, &size);
    if (hr == MF_E_ATTRIBUTENOTFOUND) return S_OK;
    if (FAILED(hr) || size > kMaxParameterSets) return MF_E_INVALIDMEDIATYPE;
    if (size == 0) return S_OK;
    std::vector<uint8_t> header(size);
    hr = current->GetBlob(MF_MT_MPEG_SEQUENCE_HEADER, header.data(), size, nullptr);
    if (FAILED(hr)) return hr;
    std::vector<uint8_t> normalized;
    // The sequence-header blob has its own configuration representation. It
    // does not establish how this MFT frames actual output samples.
    if (!SequenceHeaderH264(header.data(), header.size(), normalized)) return MF_E_INVALIDMEDIATYPE;
    bool idr = false, sps = false, pps = false;
    if (!AnalyzeH264(normalized, idr, sps, pps, &parameterSets_)) return MF_E_INVALIDMEDIATYPE;
    return S_OK;
}

HRESULT Encoder::Poll() {
    if (!async_) return S_OK;
    // Nonblocking bounded event consumption: never wait in GetEvent.
    for (unsigned i = 0; i < 16; ++i) {
        ComPtr<IMFMediaEvent> event;
        HRESULT hr = events_->GetEvent(MF_EVENT_FLAG_NO_WAIT, &event);
        if (hr == MF_E_NO_EVENTS_AVAILABLE) return S_OK;
        if (FAILED(hr)) return hr;
        HRESULT status = S_OK;
        hr = event->GetStatus(&status);
        if (FAILED(hr)) return hr;
        if (FAILED(status)) return status;
        MediaEventType type = MEUnknown;
        hr = event->GetType(&type);
        if (FAILED(hr)) return hr;
        if (type == MEError) return E_FAIL;
        // NeedInput events queued before END_OF_STREAM can still be observed.
        // They grant no permission to submit once this owner begins draining.
        if (type == METransformNeedInput && !draining_) {
            if (inputReady_ == 8) return E_FAIL;
            ++inputReady_;
        }
        if (type == METransformHaveOutput) {
            if (drainSignaled_ || outputReady_ == 8) return E_FAIL;
            ++outputReady_;
        }
        if (type == METransformDrainComplete) {
            if (!draining_ || drainSignaled_) return E_FAIL;
            UINT32 stream = 0;
            hr = event->GetUINT32(MF_EVENT_MFT_INPUT_STREAM_ID, &stream);
            if (FAILED(hr) || stream != inputId_) return E_FAIL;
            // This follows the final HaveOutput event, which may still be
            // pending in outputReady_. Do not announce completion yet.
            drainSignaled_ = true;
        }
    }
    return S_OK;
}

HRESULT Encoder::Submit(const std::vector<uint8_t>& nv12, uint64_t captureMicros, uint64_t presentationMicros) {
    if (!CanSubmit() || draining_) return MF_E_NOTACCEPTING;
    const DWORD size = config_.width * config_.height * 3U / 2U;
    if (nv12.size() != size) return E_INVALIDARG;
    MediaTiming timing;
    if (!timeline_.Plan(presentationMicros, timing)) return E_INVALIDARG;
    ComPtr<IMFSample> sample;
    ComPtr<IMFMediaBuffer> buffer;
    HRESULT hr = MFCreateSample(&sample);
    if (FAILED(hr)) return hr;
    MFT_INPUT_STREAM_INFO inputInfo{};
    hr = transform_->GetInputStreamInfo(inputId_, &inputInfo);
    if (FAILED(hr)) return hr;
    const DWORD alignment = std::max<DWORD>(16, inputInfo.cbAlignment);
    if (alignment > 65536U || (alignment & (alignment - 1U)) != 0 || inputInfo.cbSize > size) return E_FAIL;
    hr = MFCreateAlignedMemoryBuffer(size, alignment - 1U, &buffer);
    if (FAILED(hr)) return hr;
    BYTE* p = nullptr;
    hr = buffer->Lock(&p, nullptr, nullptr);
    if (FAILED(hr)) return hr;
    std::memcpy(p, nv12.data(), size);
    hr = buffer->Unlock();
    if (FAILED(hr)) return hr;
    hr = buffer->SetCurrentLength(size);
    if (FAILED(hr)) return hr;
    hr = sample->AddBuffer(buffer.Get());
    if (FAILED(hr)) return hr;
    hr = sample->SetSampleTime(timing.sampleTime);
    if (FAILED(hr)) return hr;
    hr = sample->SetSampleDuration(timing.duration);
    if (FAILED(hr)) return hr;
    if (timing.forceKeyframe) {
        hr = SetUInt(CODECAPI_AVEncVideoForceKeyFrame, 1, hardware_);
        if (FAILED(hr)) return hr;
    }
    hr = transform_->ProcessInput(inputId_, sample.Get(), 0);
    if (FAILED(hr)) return hr;
    if (async_) --inputReady_;
    timeline_.Commit(timing);
    ++inFlight_;
    stamps_.push_back({timing.sampleTime, captureMicros});
    return S_OK;
}

HRESULT Encoder::Receive(AccessUnit& output) {
    output = {};
    if (DrainComplete()) return S_FALSE;
    if (async_ && outputReady_ == 0) {
        // A complete NV12 frame was submitted for each stamp. A transform
        // which loses one must fail rather than hide a missing predictive AU.
        if (drainSignaled_ && (inFlight_ != 0 || !stamps_.empty())) return E_FAIL;
        return S_FALSE;
    }
    MFT_OUTPUT_STREAM_INFO info{};
    HRESULT hr = transform_->GetOutputStreamInfo(outputId_, &info);
    if (FAILED(hr)) return hr;
    outputMinimum_ = info.cbSize;
    ComPtr<IMFSample> owned;
    if ((info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) == 0) {
        ComPtr<IMFMediaBuffer> buffer;
        uint32_t scratchCapacity = 0;
        if (!CodecOutputScratch(config_, info.cbSize, scratchCapacity) || info.cbAlignment > 65536U ||
            (info.cbAlignment != 0 && (info.cbAlignment & (info.cbAlignment - 1U)) != 0)) return E_FAIL;
        hr = MFCreateSample(&owned);
        if (FAILED(hr)) return hr;
        hr = MFCreateAlignedMemoryBuffer(scratchCapacity,
            info.cbAlignment == 0 ? 0 : info.cbAlignment - 1U, &buffer);
        if (FAILED(hr)) return hr;
        peakOutputScratch_ = std::max(peakOutputScratch_, scratchCapacity);
        hr = owned->AddBuffer(buffer.Get());
        if (FAILED(hr)) return hr;
    }
    MFT_OUTPUT_DATA_BUFFER result{};
    result.dwStreamID = outputId_; result.pSample = owned.Get();
    DWORD status = 0;
    hr = transform_->ProcessOutput(0, 1, &result, &status);
    if (result.pEvents) result.pEvents->Release();
    // MFT owns a new reference only when it supplies a different sample.
    ComPtr<IMFSample> supplied;
    if (result.pSample && result.pSample != owned.Get()) supplied.Attach(result.pSample);
    if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) {
        // Async transforms advertise every output by event and must not use
        // NEED_MORE_INPUT. For sync transforms it is the terminal drain signal.
        if (async_) return E_FAIL;
        if (draining_) {
            if (inFlight_ != 0 || !stamps_.empty()) return E_FAIL;
            drainSignaled_ = true;
        }
        return S_FALSE;
    }
    if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
        ComPtr<IMFMediaType> type;
        hr = transform_->GetOutputAvailableType(outputId_, 0, &type);
        if (FAILED(hr)) return hr;
        GUID subtype{};
        UINT32 width = 0, height = 0;
        if (FAILED(type->GetGUID(MF_MT_SUBTYPE, &subtype)) || subtype != MFVideoFormat_H264 ||
            FAILED(MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &width, &height)) ||
            width != config_.width || height != config_.height) return MF_E_INVALIDMEDIATYPE;
        hr = transform_->SetOutputType(outputId_, type.Get(), 0);
        if (FAILED(hr)) return hr;
        outputFraming_ = H264Framing::Unknown;
        parameterSets_.clear();
        hr = ReadSequenceHeader();
        return FAILED(hr) ? hr : S_FALSE;
    }
    if (FAILED(hr)) return hr;
    if (async_) --outputReady_;
    IMFSample* sample = supplied ? supplied.Get() : owned.Get();
    if (!sample || inFlight_ == 0 || stamps_.empty()) return E_FAIL;
    ComPtr<IMFMediaBuffer> buffer;
    hr = sample->ConvertToContiguousBuffer(&buffer);
    if (FAILED(hr)) return hr;
    BYTE* data = nullptr; DWORD length = 0;
    hr = buffer->Lock(&data, nullptr, &length);
    if (FAILED(hr)) return hr;
    bool normalized = false;
    try { normalized = NormalizeH264(data, length, output.bytes, outputFraming_); }
    catch (...) { buffer->Unlock(); throw; }
    const HRESULT unlock = buffer->Unlock();
    if (FAILED(unlock)) return unlock;
    if (!normalized) return MF_E_INVALIDMEDIATYPE;
    bool sps = false, pps = false, hasSlice = false;
    std::vector<uint8_t> freshSets;
    if (!AnalyzeH264(output.bytes, output.idr, sps, pps, &freshSets, &hasSlice) || !hasSlice)
        return MF_E_INVALIDMEDIATYPE;
    if (sps && pps) parameterSets_ = std::move(freshSets);
    if (output.idr && (!sps || !pps)) {
        if (parameterSets_.empty()) { hr = ReadSequenceHeader(); if (FAILED(hr)) return hr; }
        if (parameterSets_.size() + output.bytes.size() > kMaxAccessUnit) return E_FAIL;
        output.bytes.insert(output.bytes.begin(), parameterSets_.begin(), parameterSets_.end());
        // Cached sets are additional NALs. Validate the final wire AU against
        // the same limits as the normalizer and both language consumers.
        if (!AnalyzeH264(output.bytes, output.idr, sps, pps, nullptr)) return MF_E_INVALIDMEDIATYPE;
    }
    LONGLONG time = 0;
    hr = sample->GetSampleTime(&time);
    if (FAILED(hr) || time != stamps_.front().sampleTime) return E_FAIL; // no reorder permitted
    output.timestamp = stamps_.front().captureMicros;
    stamps_.pop_front(); --inFlight_;
    return S_OK;
}

HRESULT Encoder::Drain() {
    if (!transform_) return E_UNEXPECTED;
    if (draining_) return drainResult_;
    draining_ = true;
    inputReady_ = 0;
    drainResult_ = transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, inputId_);
    if (FAILED(drainResult_)) return drainResult_;
    return drainResult_ = transform_->ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, inputId_);
}
} // namespace knot
