// The exact production CapturePacer::Pump and MediaTimeline, with fresh fake
// readiness and pixels. No Windows, capture, input, codec, files, or UI APIs.
#include "media_pacing.h"
#include "media_limits.h"
#include <iostream>
#include <vector>

namespace {
using knot::CaptureReadiness;
struct Submission { uint64_t at; uint32_t pixels; bool fresh; };

bool PendingReadback() {
    knot::CapturePacer pacer(60);
    uint32_t pixels = 1, polls = 0;
    std::vector<Submission> submitted;
    const auto submit = [&](uint64_t now, CaptureReadiness readiness) {
        return pacer.Pump(now, true, true, false,
            [&]() { ++polls; if (readiness == CaptureReadiness::Fresh) ++pixels; return readiness; },
            [&](bool fresh) { submitted.push_back({now, pixels, fresh}); return true; });
    };
    if (!submit(0, CaptureReadiness::Fresh)) return false;
    pacer.OutputObserved();
    if (submit(16666, CaptureReadiness::Pending) || submitted.size() != 1) return false;
    if (!submit(17666, CaptureReadiness::Fresh) || submitted.size() != 2 || polls != 3 ||
        submitted.back().at != 17666 || submitted.back().pixels != 3 || !submitted.back().fresh) return false;
    // Pending did not advance the 16.666ms frame period or submit old pixels.
    if (submit(18000, CaptureReadiness::Unchanged) || polls != 3) return false;
    return true;
}

bool VideoBounds() {
    if (!knot::ValidMediaConfig({3840, 2160, 30, 40000000}) ||
        !knot::ValidMediaConfig({3840, 2160, 60, 40000000}) ||
        !knot::ValidMediaConfig({1920, 1080, 60, 20000000})) return false;
    for (const KnMediaConfig invalid : {
        KnMediaConfig{3842, 2160, 30, 40000000}, {3840, 2162, 30, 40000000},
        {3839, 2160, 30, 40000000}, {3840, 2159, 30, 40000000},
        {0xffffffffU, 0xffffffffU, 30, 40000000}, {3840, 2160, 0, 40000000},
        {3840, 2160, 61, 40000000}, {3840, 2160, 30, 40000001}}) {
        if (knot::ValidMediaConfig(invalid)) return false;
    }
    const KnMediaConfig fourK{3840, 2160, 30, 40000000};
    uint32_t width = 0, height = 0;
    if (!knot::ScaleVideoToBounds(3840, 2160, fourK, width, height) || width != 3840 || height != 2160 ||
        !knot::ScaleVideoToBounds(1920, 1080, fourK, width, height) || width != 1920 || height != 1080 ||
        !knot::ScaleVideoToBounds(3840, 2400, fourK, width, height) || width != 3456 || height != 2160 ||
        knot::ScaleVideoToBounds(0xffffffffU, 2160, fourK, width, height)) return false;
    uint32_t capacity = 0;
    const uint32_t wireLimit = static_cast<uint32_t>(knot::kMaxAccessUnit);
    const KnMediaConfig hd{1920, 1080, 60, 20000000};
    if (!knot::CodecOutputScratch(hd, 0, capacity) || capacity != wireLimit ||
        !knot::CodecOutputScratch(hd, wireLimit + 1, capacity) || capacity != wireLimit + 1 ||
        !knot::CodecOutputScratch(hd, 6220800, capacity) || capacity != 6220800 ||
        knot::CodecOutputScratch(hd, 6220801, capacity) ||
        !knot::CodecOutputScratch(fourK, 12441600, capacity) || capacity != 12441600 ||
        !knot::CodecOutputScratch(fourK, 15552000, capacity) || capacity != 15552000 ||
        !knot::CodecOutputScratch(fourK, 24883200, capacity) || capacity != 24883200 ||
        knot::CodecOutputScratch(fourK, 24883201, capacity) ||
        knot::CodecOutputScratch(fourK, 0xffffffffU, capacity) ||
        knot::CodecOutputScratch({0xffffffffU, 0xffffffffU, 30, 40000000}, 0, capacity) || capacity != 0) return false;
    return true;
}

bool StartupAndBackpressure() {
    knot::CapturePacer pacer(60);
    uint32_t polls = 0, submits = 0;
    CaptureReadiness readiness = CaptureReadiness::Fresh;
    bool accept = true, lastFresh = false;
    const auto pump = [&](uint64_t now, bool canSubmit, bool havePixels) {
        return pacer.Pump(now, canSubmit, havePixels, false,
            [&]() { ++polls; return readiness; },
            [&](bool fresh) { ++submits; lastFresh = fresh; return accept; });
    };
    if (pump(0, false, false) || polls != 0 || submits != 0) return false;
    readiness = CaptureReadiness::Unchanged;
    if (pump(1000, true, false) || submits != 0) return false;
    readiness = CaptureReadiness::Fresh; accept = false;
    if (pump(17666, true, false) || submits != 1 || polls != 2 || !lastFresh) return false;
    accept = true; readiness = CaptureReadiness::Failed;
    // A rejected ProcessInput keeps the freshly copied pixels for a prompt
    // retry, without polling/overwriting capture or spending a frame period.
    if (!pump(18666, true, true) || polls != 2 || submits != 2 || !lastFresh) return false;
    readiness = CaptureReadiness::Unchanged;
    if (!pump(35332, true, true) || lastFresh) return false; // encoder startup priming
    pacer.OutputObserved();
    if (pump(51998, true, true)) return false; // static throttle begins after output
    return true;
}

bool PendingLiveness() {
    knot::CapturePacer pacer(60);
    unsigned submissions = 0;
    const auto pending = [&](uint64_t now) {
        return pacer.Pump(now, true, true, true,
            []() { return CaptureReadiness::Pending; },
            [&](bool) { ++submissions; return true; });
    };
    if (pending(1000) || pending(1001000) || pending(2000999) || submissions != 0 ||
        pacer.PendingTimedOut(2000999)) return false;
    if (pending(2001000) || !pacer.PendingTimedOut(2001000) || submissions != 0) return false;
    // Reported pending readiness can be timed out. A wedged OS call still cannot
    // be interrupted by this in-process policy and is not simulated as safe.
    return true;
}

bool StaticCadenceAndTimeline() {
    knot::CapturePacer pacer(60);
    knot::MediaTimeline timeline(60);
    std::vector<uint64_t> submittedAt, keyframes, captureStamps;
    int64_t lastSample = -1;
    bool valid = true;
    uint32_t polls = 0;
    // Only the first poll captures new pixels. Every later poll is unchanged;
    // fake encoder output arrives immediately, enabling the production idle policy.
    for (uint64_t now = 0; now <= 5000000; now += 1000) {
        pacer.Pump(now, true, !submittedAt.empty(), timeline.KeyframeDue(now),
            [&]() { ++polls; return submittedAt.empty() ? CaptureReadiness::Fresh : CaptureReadiness::Unchanged; },
            [&](bool fresh) {
                knot::MediaTiming timing;
                if (!timeline.Plan(now, timing) || timing.sampleTime <= lastSample || timing.duration <= 0 ||
                    (fresh != submittedAt.empty())) { valid = false; return false; }
                timeline.Commit(timing); lastSample = timing.sampleTime;
                submittedAt.push_back(now); captureStamps.push_back(1000000); // actual pixels' timestamp never changes
                if (timing.forceKeyframe) keyframes.push_back(now);
                pacer.OutputObserved();
                return true;
            });
    }
    if (!valid || submittedAt.size() < 5 || submittedAt.size() > 7 || polls < 250 || polls > 310 ||
        keyframes.size() != 3 || submittedAt.front() != 0 || keyframes.front() != 0) return false;
    for (size_t i = 1; i < keyframes.size(); ++i)
        if (keyframes[i] - keyframes[i - 1] > 2020000) return false;
    for (const auto captureStamp : captureStamps) if (captureStamp != 1000000) return false;
    return true;
}

bool KeyframeDeadlineOverridesIdle() {
    knot::CapturePacer pacer(60);
    knot::MediaTimeline timeline(60);
    bool fresh = true, forceAtTwoSeconds = false;
    const auto pump = [&](uint64_t now, bool changed) {
        return pacer.Pump(now, true, true, timeline.KeyframeDue(now),
            [&]() { return changed ? CaptureReadiness::Fresh : CaptureReadiness::Unchanged; },
            [&](bool) {
                knot::MediaTiming timing;
                if (!timeline.Plan(now, timing)) return false;
                timeline.Commit(timing); pacer.OutputObserved();
                fresh = changed;
                forceAtTwoSeconds = now == 2000000 && timing.forceKeyframe;
                return true;
            });
    };
    if (!pump(0, true) || !pump(1900000, true)) return false;
    // An update just before the IDR deadline must not postpone IDR until the
    // next one-second static repeat. At deadline a cached sample is permitted.
    return pump(2000000, false) && !fresh && forceAtTwoSeconds;
}

bool ExplicitFixtureTimeline() {
    knot::MediaTimeline timeline(30);
    uint32_t forced = 0;
    int64_t last = -1;
    int64_t previousEnd = 0;
    for (uint64_t frame = 0; frame < 120; ++frame) {
        knot::MediaTiming timing;
        if (!timeline.Plan(frame * 1000000U / 30U, timing) || timing.sampleTime <= last ||
            timing.duration != 333330 || timing.sampleTime < previousEnd)
            return false;
        if (timing.forceKeyframe) { if (frame != 0 && frame != 60) return false; ++forced; }
        timeline.Commit(timing); last = timing.sampleTime; previousEnd = timing.sampleTime + timing.duration;
    }
    if (forced != 2) return false;
    knot::MediaTiming timing;
    if (timeline.Plan(119U * 1000000U / 30U, timing) || timeline.Plan(0, timing) ||
        timeline.Plan((std::numeric_limits<uint64_t>::max)(), timing)) return false;
    knot::MediaTimeline retry(30);
    if (!retry.Plan(0, timing)) return false;
    retry.Commit(timing);
    if (!retry.Plan(2000000, timing) || !timing.forceKeyframe) return false;
    // Planning an unaccepted sample must not consume its force-keyframe request.
    if (!retry.Plan(2000000, timing) || !timing.forceKeyframe) return false;
    retry.Commit(timing);
    return !retry.Plan(2000000, timing) && retry.Plan(2000001, timing) && !timing.forceKeyframe;
}

bool StaticToActiveDuration() {
    knot::MediaTimeline timeline(60);
    // Two one-second static intervals followed immediately by active 60fps
    // updates. The first fresh frame must not inherit a one-second duration.
    const uint64_t times[]{0, 1000000, 2000000, 2016666, 2033332, 2049998};
    int64_t previousEnd = 0;
    uint32_t forced = 0;
    for (const uint64_t time : times) {
        knot::MediaTiming timing;
        if (!timeline.Plan(time, timing) || timing.duration != 166660 ||
            timing.sampleTime < previousEnd) return false;
        if (timing.forceKeyframe) ++forced;
        timeline.Commit(timing);
        previousEnd = timing.sampleTime + timing.duration;
    }
    return forced == 2;
}
}

int main() {
    if (!VideoBounds() || !PendingReadback() || !StartupAndBackpressure() || !PendingLiveness() || !StaticCadenceAndTimeline() ||
        !KeyframeDeadlineOverridesIdle() || !ExplicitFixtureTimeline() || !StaticToActiveDuration()) {
        std::cerr << "FAIL: production media pacing/timeline policy\n"; return 1;
    }
    std::cout << "PASS: production Pump pending16666us->fresh17666us with no stale submit; static1Hz; "
        "2s IDR target; backpressure/retry; strictPTS/nominal current-frame duration; static->active/120-frame timeline\n";
    return 0;
}
