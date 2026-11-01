#include "media_internal.h"

namespace knot {
namespace {
// Ensures ReleaseFrame on every path, including exceptions. Never retain a
// duplication surface beyond this scope; the copied NV12 texture is owned.
class AcquiredFrame {
public:
    explicit AcquiredFrame(IDXGIOutputDuplication* duplication) : duplication_(duplication) {}
    ~AcquiredFrame() { if (acquired_) duplication_->ReleaseFrame(); }
    void Acquired() { acquired_ = true; }
private:
    IDXGIOutputDuplication* duplication_;
    bool acquired_ = false;
};
}

HRESULT DesktopCapture::CheckDisplay() {
    // A secure/locked/alternate input desktop is outside this prototype. Check
    // metadata only; never open its windows or attempt to capture it.
    HDESK inputDesktop = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
    if (!inputDesktop) return E_ACCESSDENIED;
    wchar_t desktopName[64]{};
    DWORD needed = 0;
    const BOOL named = GetUserObjectInformationW(inputDesktop, UOI_NAME,
        desktopName, static_cast<DWORD>(sizeof(desktopName)), &needed);
    CloseDesktop(inputDesktop);
    if (!named || std::wcscmp(desktopName, L"Default") != 0) return E_ACCESSDENIED;
    DXGI_OUTPUT_DESC now{};
    HRESULT hr = output_->GetDesc(&now);
    if (FAILED(hr)) return hr;
    if (!now.AttachedToDesktop || now.Rotation != DXGI_MODE_ROTATION_IDENTITY ||
        !EqualRect(&now.DesktopCoordinates, &display_.DesktopCoordinates)) return DXGI_ERROR_UNSUPPORTED;
    ComPtr<IDXGIOutput6> output6;
    hr = output_.As(&output6);
    if (FAILED(hr)) return DXGI_ERROR_UNSUPPORTED;
    DXGI_OUTPUT_DESC1 advanced{};
    hr = output6->GetDesc1(&advanced);
    if (FAILED(hr)) return hr;
    // DuplicateOutput converts HDR to BGRA without our owning tone mapping.
    // Reject advanced color rather than claim that clipped data is SDR.
    if (advanced.ColorSpace != DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709) return DXGI_ERROR_UNSUPPORTED;
    return S_OK;
}

HRESULT DesktopCapture::Start(const KnMediaConfig& bounds, KnMediaInfo& info, KnMediaConfig& actual) {
    if (GetSystemMetrics(SM_REMOTESESSION) != 0) return DXGI_ERROR_UNSUPPORTED;
    ComPtr<IDXGIFactory1> factory;
    HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
    if (FAILED(hr)) return hr;
    const POINT origin{0, 0};
    const HMONITOR primary = MonitorFromPoint(origin, MONITOR_DEFAULTTOPRIMARY);
    ComPtr<IDXGIAdapter1> adapter;
    bool found = false;
    for (UINT a = 0; !found; ++a) {
        ComPtr<IDXGIAdapter1> candidate;
        hr = factory->EnumAdapters1(a, &candidate);
        if (hr == DXGI_ERROR_NOT_FOUND) break;
        if (FAILED(hr)) return hr;
        DXGI_ADAPTER_DESC1 adapterDesc{};
        if (FAILED(candidate->GetDesc1(&adapterDesc))) continue;
        if ((adapterDesc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0) continue;
        for (UINT o = 0; ; ++o) {
            ComPtr<IDXGIOutput> candidateOutput;
            hr = candidate->EnumOutputs(o, &candidateOutput);
            if (hr == DXGI_ERROR_NOT_FOUND) break;
            if (FAILED(hr)) return hr;
            DXGI_OUTPUT_DESC desc{};
            hr = candidateOutput->GetDesc(&desc);
            if (FAILED(hr)) return hr;
            if (desc.AttachedToDesktop && desc.Monitor == primary) {
                adapter = candidate; output_ = candidateOutput; display_ = desc; found = true; break;
            }
        }
    }
    if (!found) return DXGI_ERROR_UNSUPPORTED;
    hr = CheckDisplay();
    if (FAILED(hr)) return hr;
    const LONG sourceWidth = display_.DesktopCoordinates.right - display_.DesktopCoordinates.left;
    const LONG sourceHeight = display_.DesktopCoordinates.bottom - display_.DesktopCoordinates.top;
    if (sourceWidth < 16 || sourceHeight < 16 || sourceWidth > 16384 || sourceHeight > 16384)
        return DXGI_ERROR_UNSUPPORTED;
    const double scale = std::min({1.0, static_cast<double>(bounds.width) / sourceWidth,
        static_cast<double>(bounds.height) / sourceHeight});
    width_ = static_cast<uint32_t>(sourceWidth * scale) & ~1U;
    height_ = static_cast<uint32_t>(sourceHeight * scale) & ~1U;
    if (width_ < 16 || height_ < 16) return DXGI_ERROR_UNSUPPORTED;
    actual = {width_, height_, bounds.fps, bounds.bitrate};
    info = {width_, height_, bounds.fps, bounds.bitrate,
        display_.DesktopCoordinates.left, display_.DesktopCoordinates.top, sourceWidth, sourceHeight, 0};
    const D3D_FEATURE_LEVEL levels[]{D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0};
    D3D_FEATURE_LEVEL level{};
    hr = D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
        levels, static_cast<UINT>(ARRAYSIZE(levels)), D3D11_SDK_VERSION, &device_, &level, &context_);
    if (FAILED(hr)) return hr;
    hr = device_.As(&videoDevice_);
    if (FAILED(hr)) return hr;
    hr = context_.As(&videoContext_);
    if (FAILED(hr)) return hr;
    ComPtr<IDXGIOutput1> output1;
    hr = output_.As(&output1);
    if (FAILED(hr)) return hr;
    hr = output1->DuplicateOutput(device_.Get(), &duplication_);
    if (FAILED(hr)) return hr;
    DXGI_OUTDUPL_DESC duplicated{};
    duplication_->GetDesc(&duplicated);
    if (duplicated.ModeDesc.Format != DXGI_FORMAT_B8G8R8A8_UNORM ||
        duplicated.Rotation != DXGI_MODE_ROTATION_IDENTITY ||
        duplicated.ModeDesc.Width != static_cast<UINT>(sourceWidth) ||
        duplicated.ModeDesc.Height != static_cast<UINT>(sourceHeight)) return DXGI_ERROR_UNSUPPORTED;

    D3D11_VIDEO_PROCESSOR_CONTENT_DESC content{};
    content.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
    content.InputFrameRate = {bounds.fps, 1};
    content.InputWidth = static_cast<UINT>(sourceWidth); content.InputHeight = static_cast<UINT>(sourceHeight);
    content.OutputFrameRate = {bounds.fps, 1}; content.OutputWidth = width_; content.OutputHeight = height_;
    content.Usage = D3D11_VIDEO_USAGE_OPTIMAL_SPEED;
    hr = videoDevice_->CreateVideoProcessorEnumerator(&content, &enumerator_);
    if (FAILED(hr)) return hr;
    UINT support = 0;
    hr = enumerator_->CheckVideoProcessorFormat(DXGI_FORMAT_B8G8R8A8_UNORM, &support);
    if (FAILED(hr) || (support & D3D11_VIDEO_PROCESSOR_FORMAT_SUPPORT_INPUT) == 0) return DXGI_ERROR_UNSUPPORTED;
    hr = enumerator_->CheckVideoProcessorFormat(DXGI_FORMAT_NV12, &support);
    if (FAILED(hr) || (support & D3D11_VIDEO_PROCESSOR_FORMAT_SUPPORT_OUTPUT) == 0) return DXGI_ERROR_UNSUPPORTED;
    hr = videoDevice_->CreateVideoProcessor(enumerator_.Get(), 0, &processor_);
    if (FAILED(hr)) return hr;
    D3D11_TEXTURE2D_DESC texture{};
    texture.Width = static_cast<UINT>(sourceWidth); texture.Height = static_cast<UINT>(sourceHeight);
    texture.MipLevels = 1; texture.ArraySize = 1;
    texture.Format = DXGI_FORMAT_B8G8R8A8_UNORM; texture.SampleDesc.Count = 1;
    texture.Usage = D3D11_USAGE_DEFAULT; texture.BindFlags = D3D11_BIND_RENDER_TARGET;
    // Duplication resources need not have the VP input bind flags. Copy into an
    // owned compatible surface and create the input view once.
    hr = device_->CreateTexture2D(&texture, nullptr, &captured_);
    if (FAILED(hr)) return hr;
    D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC inputDesc{};
    inputDesc.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
    hr = videoDevice_->CreateVideoProcessorInputView(captured_.Get(), enumerator_.Get(), &inputDesc, &inputView_);
    if (FAILED(hr)) return hr;
    texture.Width = width_; texture.Height = height_; texture.Format = DXGI_FORMAT_NV12;
    hr = device_->CreateTexture2D(&texture, nullptr, &converted_);
    if (FAILED(hr)) return hr;
    texture.Usage = D3D11_USAGE_STAGING; texture.BindFlags = 0; texture.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    hr = device_->CreateTexture2D(&texture, nullptr, &staging_);
    if (FAILED(hr)) return hr;
    D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC view{};
    view.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
    hr = videoDevice_->CreateVideoProcessorOutputView(converted_.Get(), enumerator_.Get(), &view, &outputView_);
    if (FAILED(hr)) return hr;
    const RECT src{0, 0, sourceWidth, sourceHeight};
    const RECT dst{0, 0, static_cast<LONG>(width_), static_cast<LONG>(height_)};
    videoContext_->VideoProcessorSetStreamFrameFormat(processor_.Get(), 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
    videoContext_->VideoProcessorSetStreamSourceRect(processor_.Get(), 0, TRUE, &src);
    videoContext_->VideoProcessorSetStreamDestRect(processor_.Get(), 0, TRUE, &dst);
    videoContext_->VideoProcessorSetOutputTargetRect(processor_.Get(), TRUE, &dst);
    videoContext_->VideoProcessorSetStreamAutoProcessingMode(processor_.Get(), 0, FALSE);
    D3D11_VIDEO_PROCESSOR_COLOR_SPACE rgb{};
    rgb.Usage = 1; rgb.RGB_Range = 0;
    D3D11_VIDEO_PROCESSOR_COLOR_SPACE yuv{};
    yuv.Usage = 1; yuv.YCbCr_Matrix = 1; yuv.Nominal_Range = D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_16_235;
    videoContext_->VideoProcessorSetStreamColorSpace(processor_.Get(), 0, &rgb);
    videoContext_->VideoProcessorSetOutputColorSpace(processor_.Get(), &yuv);
    return S_OK;
}

DesktopCapture::Result DesktopCapture::Read(std::vector<uint8_t>& nv12, uint64_t& timestamp, Deadline deadline) {
    const auto failure = [](HRESULT status) { return Result{status, CaptureReadiness::Failed}; };
    HRESULT hr = CheckDisplay();
    if (FAILED(hr)) return failure(hr);
    hr = device_->GetDeviceRemovedReason();
    if (FAILED(hr)) return failure(hr);
    if (!copyPending_) {
        AcquiredFrame acquired(duplication_.Get());
        DXGI_OUTDUPL_FRAME_INFO frame{};
        ComPtr<IDXGIResource> resource;
        // Poll: the enclosing read function owns the entire wall-clock budget.
        hr = duplication_->AcquireNextFrame(0, &frame, &resource);
        if (hr == DXGI_ERROR_WAIT_TIMEOUT) return {S_OK, CaptureReadiness::Unchanged};
        if (FAILED(hr)) return failure(hr);
        acquired.Acquired();
        if (frame.ProtectedContentMaskedOut) return failure(E_ACCESSDENIED);
        ComPtr<ID3D11Texture2D> texture;
        hr = resource.As(&texture);
        if (FAILED(hr)) return failure(hr);
        context_->CopyResource(captured_.Get(), texture.Get());
        D3D11_VIDEO_PROCESSOR_STREAM stream{};
        stream.Enable = TRUE; stream.pInputSurface = inputView_.Get();
        hr = videoContext_->VideoProcessorBlt(processor_.Get(), outputView_.Get(), 0, 1, &stream);
        if (FAILED(hr)) return failure(hr);
        context_->CopyResource(staging_.Get(), converted_.Get());
        context_->Flush();
        pendingTimestamp_ = MonotonicMicros();
        copyPending_ = true;
    } // ReleaseFrame occurs here, AFTER conversion/copy commands were submitted.
    if (Clock::now() >= deadline) return {S_OK, CaptureReadiness::Pending};
    D3D11_MAPPED_SUBRESOURCE mapped{};
    hr = context_->Map(staging_.Get(), 0, D3D11_MAP_READ, D3D11_MAP_FLAG_DO_NOT_WAIT, &mapped);
    if (hr == DXGI_ERROR_WAS_STILL_DRAWING) return {S_OK, CaptureReadiness::Pending};
    if (FAILED(hr)) return failure(hr);
    if (mapped.RowPitch < width_) { context_->Unmap(staging_.Get(), 0); return failure(E_FAIL); }
    // Allocate BEFORE mapping in future optimizations; catch also unmaps here.
    try {
        nv12.resize(static_cast<size_t>(width_) * height_ * 3U / 2U);
        const auto* src = static_cast<const uint8_t*>(mapped.pData);
        for (uint32_t y = 0; y < height_ + height_ / 2U; ++y)
            std::memcpy(nv12.data() + static_cast<size_t>(y) * width_, src + static_cast<size_t>(y) * mapped.RowPitch, width_);
    } catch (...) { context_->Unmap(staging_.Get(), 0); throw; }
    context_->Unmap(staging_.Get(), 0);
    copyPending_ = false; timestamp = pendingTimestamp_;
    return {S_OK, CaptureReadiness::Fresh};
}
} // namespace knot
