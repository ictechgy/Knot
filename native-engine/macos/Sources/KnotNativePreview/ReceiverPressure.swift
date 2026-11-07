import Foundation

enum DecodePerformanceEvent: Sendable, Equatable {
    case completed(dropped: Bool)
    case admissionWait(Duration)
}

/// Local, bounded quality feedback. This is independent of the UI's sustained
/// stall notice: a periodically successful presentation must not hide regular
/// decoded-frame drops or a decoder whose admission queue is repeatedly full.
struct ReceiverPressureWindow {
    private struct Bucket {
        var ordinal: Int64 = -1
        var presentations = 0, rejected = 0
        var completions = 0, dropped = 0
        var waits = 0
        var wait: Duration = .zero
    }
    private static let bucketCount = 8
    private static let countLimit = 4096
    private var buckets = Array(repeating: Bucket(), count: bucketCount)
    private var origin: ContinuousClock.Instant?
    private var latest: Int64 = 0
    private var overloadedUntil: ContinuousClock.Instant?

    mutating func reset() {
        buckets = Array(repeating: Bucket(), count: Self.bucketCount)
        origin = nil; latest = 0; overloadedUntil = nil
    }
    private mutating func ordinal(at now: ContinuousClock.Instant) -> Int64 {
        guard let origin else { self.origin = now; return 0 }
        let elapsed = max(.zero, now - origin).components
        // ContinuousClock intervals in this connection are small. Saturate a
        // synthetic outlier rather than overflowing the fixed-width counter.
        let seconds = min(elapsed.seconds, (Int64.max - 3) / 4)
        let value = seconds * 4 + elapsed.attoseconds / 250_000_000_000_000_000
        latest = max(latest, value)
        return latest
    }
    private mutating func slot(at now: ContinuousClock.Instant) -> Int {
        let ordinal = ordinal(at: now), index = Int(ordinal % Int64(Self.bucketCount))
        if buckets[index].ordinal != ordinal { buckets[index] = Bucket(ordinal: ordinal) }
        return index
    }
    mutating func presentation(accepted: Bool, at now: ContinuousClock.Instant) {
        let index = slot(at: now)
        buckets[index].presentations = min(Self.countLimit, buckets[index].presentations + 1)
        if !accepted { buckets[index].rejected = min(Self.countLimit, buckets[index].rejected + 1) }
    }
    mutating func decode(_ event: DecodePerformanceEvent, at now: ContinuousClock.Instant) {
        let index = slot(at: now)
        switch event {
        case .completed(let dropped):
            buckets[index].completions = min(Self.countLimit, buckets[index].completions + 1)
            if dropped { buckets[index].dropped = min(Self.countLimit, buckets[index].dropped + 1) }
        case .admissionWait(let duration):
            // Ignore ordinary short handoffs. Only actual queued admission is
            // measured by DecodeAdmission; an immediate acquire is not a wait.
            guard duration >= .milliseconds(16), buckets[index].waits < Self.countLimit else { return }
            buckets[index].waits += 1
            buckets[index].wait += min(duration, .milliseconds(250))
        }
    }
    mutating func isOverloaded(at now: ContinuousClock.Instant) -> Bool {
        let ordinal = ordinal(at: now)
        var presentations = 0, rejected = 0, completions = 0, dropped = 0, waits = 0
        var wait: Duration = .zero
        for bucket in buckets where bucket.ordinal >= 0 && bucket.ordinal > ordinal - Int64(Self.bucketCount) {
            presentations += bucket.presentations; rejected += bucket.rejected
            completions += bucket.completions; dropped += bucket.dropped
            waits += bucket.waits; wait += bucket.wait
        }
        // A few isolated misses are normal. Require repeated pressure in the
        // recent (at most two-second) window, then hold it for one feedback
        // interval instead of alternating healthy/unhealthy on every frame.
        let presentationPressure = presentations >= 12 && rejected >= 4 && rejected * 5 >= presentations
        let decodePressure = completions >= 8 && dropped >= 3 && dropped * 5 >= completions
        let admissionPressure = waits >= 3 && wait >= .milliseconds(60)
        if presentationPressure || decodePressure || admissionPressure {
            overloadedUntil = max(overloadedUntil ?? now, now + .seconds(2))
            return true
        }
        return overloadedUntil.map { now < $0 } ?? false
    }
}
