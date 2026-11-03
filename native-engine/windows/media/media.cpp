#ifndef KN_MEDIA_EXPORTS
#define KN_MEDIA_EXPORTS
#endif
#include "media_internal.h"
#include "media_wait.h"

namespace {
struct Session {
    // Destruction order is encoder, capture, runtime; COM outlives interfaces.
    knot::Runtime runtime;
    knot::MediaPollWait pollWait;
    knot::DesktopCapture capture;
    knot::Encoder encoder;
    KnMediaConfig config{};
    DWORD owner = GetCurrentThreadId();
    std::vector<uint8_t> latest;
    uint64_t captureTime = 0;
    knot::CapturePacer pacer{1};
    uint64_t streamStartMicros = 0;
    knot::Clock::time_point lastProgress = knot::Clock::now();
    int32_t failure = 0;
};
int32_t CaptureStatus(HRESULT hr) {
    if (hr == DXGI_ERROR_UNSUPPORTED || hr == E_ACCESSDENIED || hr == DXGI_ERROR_NOT_CURRENTLY_AVAILABLE ||
        hr == DXGI_ERROR_SESSION_DISCONNECTED) return KN_MEDIA_UNSUPPORTED_DISPLAY;
    return KN_MEDIA_DEVICE_FAILURE;
}
}

extern "C" KN_MEDIA_API void* KN_MEDIA_CALL kn_media_create(const KnMediaConfig* config,
    KnMediaInfo* info, int32_t* error) {
    if (error) *error = KN_MEDIA_INVALID_ARGUMENT;
    if (info) *info = {};
    if (!config || !info || !error || !knot::ValidMediaConfig(*config)) return nullptr;
    try {
        auto session = std::make_unique<Session>();
        HRESULT hr = session->runtime.Start();
        if (FAILED(hr)) { *error = KN_MEDIA_ERROR; return nullptr; }
        hr = session->pollWait.Start();
        if (FAILED(hr)) { *error = KN_MEDIA_ERROR; return nullptr; }
        KnMediaInfo result{};
        hr = session->capture.Start(*config, result, session->config);
        if (FAILED(hr)) { *error = CaptureStatus(hr); return nullptr; }
        // This hardcoded false is intentional: there is no runtime software flag.
        hr = session->encoder.Start(session->config, false);
        if (FAILED(hr) || !session->encoder.Hardware()) {
            *error = KN_MEDIA_NO_HARDWARE_ENCODER; return nullptr;
        }
        result.hardwareEncoder = 1;
        session->pacer = knot::CapturePacer(session->config.fps);
        session->streamStartMicros = knot::MonotonicMicros();
        *info = result; *error = KN_MEDIA_SAMPLE;
        return session.release();
    } catch (...) { *error = KN_MEDIA_ERROR; return nullptr; }
}

extern "C" KN_MEDIA_API int32_t KN_MEDIA_CALL kn_media_read(void* opaque, uint8_t* buffer,
    uint32_t capacity, uint32_t* written, uint32_t* flags, uint64_t* timestampMicros) {
    if (written) *written = 0;
    if (flags) *flags = 0;
    if (timestampMicros) *timestampMicros = 0;
    auto* session = static_cast<Session*>(opaque);
    if (!session || !buffer || capacity == 0 || !written || !flags || !timestampMicros ||
        session->owner != GetCurrentThreadId()) return KN_MEDIA_INVALID_ARGUMENT;
    if (session->failure != 0) return session->failure;
    try {
        const auto deadline = knot::Clock::now() + std::chrono::milliseconds(450);
        while (knot::Clock::now() < deadline) {
            HRESULT hr = session->encoder.Poll();
            if (FAILED(hr)) return session->failure = KN_MEDIA_DEVICE_FAILURE;
            knot::AccessUnit unit;
            hr = session->encoder.Receive(unit);
            if (FAILED(hr)) return session->failure = KN_MEDIA_DEVICE_FAILURE;
            if (hr == S_OK && !unit.bytes.empty()) {
                session->lastProgress = knot::Clock::now();
                if (unit.bytes.size() > capacity) return session->failure = KN_MEDIA_INVALID_ARGUMENT;
                // Every flagged IDR must contain its decoder configuration.
                bool idr = false, sps = false, pps = false, hasSlice = false;
                if (!knot::AnalyzeH264(unit.bytes, idr, sps, pps, nullptr, &hasSlice) || !hasSlice ||
                    (idr && (!sps || !pps))) return session->failure = KN_MEDIA_DEVICE_FAILURE;
                std::memcpy(buffer, unit.bytes.data(), unit.bytes.size());
                *written = static_cast<uint32_t>(unit.bytes.size()); *flags = idr ? 1U : 0U;
                *timestampMicros = unit.timestamp;
                session->pacer.OutputObserved();
                return KN_MEDIA_SAMPLE;
            }
            const auto now = knot::Clock::now();
            if (session->encoder.InFlight() != 0 && now - session->lastProgress > std::chrono::seconds(2))
                return session->failure = KN_MEDIA_DEVICE_FAILURE;
            HRESULT captureStatus = S_OK, submitStatus = S_OK;
            const uint64_t pacingNow = knot::MonotonicMicros();
            session->pacer.Pump(pacingNow, session->encoder.CanSubmit(), !session->latest.empty(),
                session->encoder.KeyframeDue(pacingNow - session->streamStartMicros),
                [&]() {
                    const auto result = session->capture.Read(session->latest, session->captureTime, deadline);
                    captureStatus = result.status;
                    return result.readiness;
                },
                [&](bool) {
                    const bool wasEmpty = session->encoder.InFlight() == 0;
                    // Cached pixels keep their real capture timestamp. Media
                    // time advances independently for pacing and IDR requests.
                    submitStatus = session->encoder.Submit(session->latest, session->captureTime,
                        knot::MonotonicMicros() - session->streamStartMicros);
                    if (SUCCEEDED(submitStatus) && wasEmpty) session->lastProgress = knot::Clock::now();
                    return SUCCEEDED(submitStatus);
                });
            if (FAILED(captureStatus)) return session->failure = CaptureStatus(captureStatus);
            if (session->pacer.PendingTimedOut(knot::MonotonicMicros()))
                return session->failure = KN_MEDIA_DEVICE_FAILURE;
            if (FAILED(submitStatus) && submitStatus != MF_E_NOTACCEPTING)
                return session->failure = KN_MEDIA_DEVICE_FAILURE;
            if (FAILED(session->pollWait.WaitUntil(deadline)))
                return session->failure = KN_MEDIA_DEVICE_FAILURE;
        }
        return KN_MEDIA_TRY_AGAIN;
    } catch (...) { return session->failure = KN_MEDIA_ERROR; }
}

extern "C" KN_MEDIA_API void KN_MEDIA_CALL kn_media_close(void* opaque) {
    auto* session = static_cast<Session*>(opaque);
    if (session && session->owner == GetCurrentThreadId()) delete session;
}
