#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <algorithm>
#include <chrono>
#include <cstdint>

namespace knot {
// One unnamed synchronization timer belongs to the media owner's session. A
// high-resolution timer avoids quantizing every encoder/readback poll to the
// process's ordinary Sleep tick. It never changes a global timer resolution.
class MediaPollWait {
public:
    using Clock = std::chrono::steady_clock;
    MediaPollWait() = default;
    MediaPollWait(const MediaPollWait&) = delete;
    MediaPollWait& operator=(const MediaPollWait&) = delete;
    ~MediaPollWait() { if (timer_) CloseHandle(timer_); }

    HRESULT Start() {
        if (timer_) return S_OK;
        timer_ = CreateWaitableTimerExW(nullptr, nullptr,
            CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_MODIFY_STATE | SYNCHRONIZE);
        return timer_ ? S_OK : LastFailure();
    }

    // The normal poll interval is at most 1ms. The enclosing ABI read still
    // owns its original 450ms deadline; an expired budget never starts a wait.
    HRESULT WaitUntil(Clock::time_point deadline) {
        if (!timer_) return E_HANDLE;
        const auto now = Clock::now();
        if (deadline <= now) return S_FALSE;
        const auto remaining = std::min(deadline - now,
            std::chrono::duration_cast<Clock::duration>(std::chrono::milliseconds(450)));
        if (remaining <= Clock::duration::zero()) return S_FALSE;
        const int64_t nanoseconds = std::chrono::duration_cast<std::chrono::nanoseconds>(remaining).count();
        const int64_t interval = std::min<int64_t>(nanoseconds, 1000000);
        LARGE_INTEGER due{};
        due.QuadPart = -std::max<int64_t>(1, interval / 100); // relative 100ns units
        if (!SetWaitableTimerEx(timer_, &due, 0, nullptr, nullptr, nullptr, 0)) return LastFailure();
        // A failed-to-signal timer cannot turn a bounded read into an infinite
        // wait. Round up only the independent wait's timeout, not its due time.
        const DWORD timeout = static_cast<DWORD>(std::min<int64_t>(450,
            std::max<int64_t>(1, (nanoseconds + 999999) / 1000000)));
        const DWORD result = WaitForSingleObject(timer_, timeout);
        if (result == WAIT_OBJECT_0) return S_OK;
        const HRESULT failure = result == WAIT_TIMEOUT ? S_FALSE :
            (result == WAIT_FAILED ? LastFailure() : E_UNEXPECTED);
        if (!CancelWaitableTimer(timer_)) return LastFailure();
        return failure;
    }

private:
    static HRESULT LastFailure() {
        const DWORD error = GetLastError();
        return HRESULT_FROM_WIN32(error == ERROR_SUCCESS ? ERROR_GEN_FAILURE : error);
    }
    HANDLE timer_ = nullptr;
};
} // namespace knot
