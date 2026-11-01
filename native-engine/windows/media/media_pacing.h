#pragma once
#include <cstdint>
#include <limits>

namespace knot {
enum class CaptureReadiness { Unchanged, Pending, Fresh, Failed };

// DXGI reports pointer-only notifications with all three image-update fields
// zero. v1 does not composite that separate cursor, so cached image pixels are
// still current. Always take the first snapshot, and copy on any image metadata.
inline bool DesktopImageNeedsCopy(bool havePixels, int64_t lastPresentTime,
    uint32_t accumulatedFrames, uint32_t metadataBytes) {
    return !havePixels || lastPresentTime != 0 || accumulatedFrames != 0 || metadataBytes != 0;
}

// Pure production policy. A Pending readback never submits the old pixels or
// consumes the frame period: Pump polls it again on the next caller iteration.
// After first encoder output, unchanged pixels are encoded at one Hz while
// capture readiness is still checked at the negotiated desktop frame rate.
class CapturePacer {
public:
    explicit CapturePacer(uint32_t fps) : periodMicros_(1000000U / fps) {}
    void OutputObserved() { outputObserved_ = true; }
    bool PendingTimedOut(uint64_t nowMicros) const {
        return pending_ && nowMicros >= pendingSinceMicros_ && nowMicros - pendingSinceMicros_ >= 2000000U;
    }

    template<class PollCapture, class SubmitPixels>
    bool Pump(uint64_t nowMicros, bool canSubmit, bool havePixels, bool keyframeDue,
        PollCapture&& pollCapture, SubmitPixels&& submitPixels) {
        if (!canSubmit) return false;
        if (!freshReady_) {
            if (nowMicros < nextPollMicros_) return false;
            const CaptureReadiness readiness = pollCapture();
            if (readiness == CaptureReadiness::Pending) {
                if (!pending_) { pending_ = true; pendingSinceMicros_ = nowMicros; }
                return false;
            }
            if (readiness == CaptureReadiness::Failed) return false;
            pending_ = false;
            nextPollMicros_ = Add(nowMicros, periodMicros_);
            if (readiness == CaptureReadiness::Fresh) freshReady_ = true;
            else if (!havePixels || (outputObserved_ && submitted_ && !keyframeDue &&
                nowMicros - lastSubmitMicros_ < kIdleRepeatMicros)) return false;
        }
        if (!submitPixels(freshReady_)) return false;
        freshReady_ = false;
        submitted_ = true;
        lastSubmitMicros_ = nowMicros;
        nextPollMicros_ = Add(nowMicros, periodMicros_);
        return true;
    }
private:
    static constexpr uint64_t kIdleRepeatMicros = 1000000U;
    static uint64_t Add(uint64_t left, uint64_t right) {
        return left > (std::numeric_limits<uint64_t>::max)() - right ?
            (std::numeric_limits<uint64_t>::max)() : left + right;
    }
    uint64_t periodMicros_, nextPollMicros_ = 0, lastSubmitMicros_ = 0, pendingSinceMicros_ = 0;
    bool outputObserved_ = false, submitted_ = false, freshReady_ = false, pending_ = false;
};

struct MediaTiming {
    uint64_t presentationMicros = 0;
    int64_t sampleTime = 0, duration = 0;
    bool forceKeyframe = false;
};

// Explicit stream time, separate from the original pixels' capture timestamp.
// Tests and the actual codec fixture can advance this without sleeping. State
// commits only after ProcessInput accepts a sample, preserving retry semantics.
class MediaTimeline {
public:
    // Duration belongs to the current frame. Use the configured nominal frame
    // duration, rounded down to our whole-microsecond presentation-time grid;
    // the previous idle gap is not the current frame's future display duration.
    explicit MediaTimeline(uint32_t fps) : nominalDuration_(static_cast<int64_t>(1000000U / fps) * 10) {}
    bool KeyframeDue(uint64_t presentationMicros) const {
        return !started_ || presentationMicros >= nextKeyframeMicros_;
    }
    bool Plan(uint64_t presentationMicros, MediaTiming& timing) const {
        const uint64_t maxMicros = static_cast<uint64_t>((std::numeric_limits<int64_t>::max)()) / 10U;
        if (presentationMicros > maxMicros || (started_ && presentationMicros <= lastMicros_)) return false;
        timing.presentationMicros = presentationMicros;
        timing.sampleTime = static_cast<int64_t>(presentationMicros * 10U);
        timing.duration = nominalDuration_;
        timing.forceKeyframe = KeyframeDue(presentationMicros);
        return true;
    }
    void Commit(const MediaTiming& timing) {
        started_ = true;
        lastMicros_ = timing.presentationMicros;
        if (timing.forceKeyframe) nextKeyframeMicros_ = timing.presentationMicros + 2000000U;
    }
private:
    int64_t nominalDuration_;
    uint64_t lastMicros_ = 0, nextKeyframeMicros_ = 0;
    bool started_ = false;
};
} // namespace knot
