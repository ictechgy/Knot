import Foundation
import Testing
@testable import KnotNativePreview

private func expectPressure(_ window: inout ReceiverPressureWindow, at now: ContinuousClock.Instant,
                            _ expected: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    let actual = window.isOverloaded(at: now)
    #expect(actual == expected, sourceLocation: sourceLocation)
}

@Test func regularPresentationLossSurvivesInterleavedSuccessAndRecovers() {
    let start = ContinuousClock.now
    var pressure = ReceiverPressureWindow()
    for frame in 0..<120 {
        pressure.presentation(accepted: frame % 2 == 0, at: start + .milliseconds(frame * 16))
    }
    expectPressure(&pressure, at: start + .seconds(2), true)
    // A successful frame does not immediately undo a bad recent window.
    pressure.presentation(accepted: true, at: start + .milliseconds(2100))
    expectPressure(&pressure, at: start + .milliseconds(2100), true)
    for frame in 0..<180 {
        pressure.presentation(accepted: true, at: start + .milliseconds(2200 + frame * 16))
    }
    expectPressure(&pressure, at: start + .seconds(6), false)
}

@Test func isolatedPresentationMissDoesNotRequestBackoff() {
    let start = ContinuousClock.now
    var pressure = ReceiverPressureWindow()
    for frame in 0..<120 {
        pressure.presentation(accepted: frame != 30, at: start + .milliseconds(frame * 16))
    }
    expectPressure(&pressure, at: start + .seconds(2), false)
}

@Test func decoderDropsAndRepeatedAdmissionWaitsAreIndependentPressureSources() {
    let start = ContinuousClock.now
    var dropped = ReceiverPressureWindow(), waiting = ReceiverPressureWindow()
    for frame in 0..<20 {
        dropped.decode(.completed(dropped: frame % 3 == 0), at: start + .milliseconds(frame * 16))
        waiting.decode(.completed(dropped: false), at: start + .milliseconds(frame * 16))
    }
    expectPressure(&dropped, at: start + .seconds(1), true)
    for frame in 0..<3 {
        waiting.decode(.admissionWait(.milliseconds(20)), at: start + .milliseconds(500 + frame * 100))
    }
    expectPressure(&waiting, at: start + .seconds(1), true)
    expectPressure(&waiting, at: start + .seconds(4), false)
}

@Test func ordinaryDecoderHandoffsAndAnIsolatedDropDoNotRequestBackoff() {
    let start = ContinuousClock.now
    var pressure = ReceiverPressureWindow()
    for frame in 0..<120 {
        let now = start + .milliseconds(frame * 16)
        pressure.decode(.completed(dropped: frame == 0), at: now)
        pressure.decode(.admissionWait(.milliseconds(1)), at: now)
    }
    expectPressure(&pressure, at: start + .seconds(2), false)
}

@Test func pressureResetDoesNotCarryOverToANewSession() {
    let start = ContinuousClock.now
    var pressure = ReceiverPressureWindow()
    for frame in 0..<20 { pressure.presentation(accepted: false, at: start + .milliseconds(frame * 16)) }
    expectPressure(&pressure, at: start + .seconds(1), true)
    pressure.reset()
    expectPressure(&pressure, at: start + .milliseconds(1100), false)
    for frame in 0..<60 { pressure.presentation(accepted: true, at: start + .milliseconds(1200 + frame * 16)) }
    expectPressure(&pressure, at: start + .seconds(2), false)
}

@MainActor private final class AdmissionClock {
    var now = ContinuousClock.now
}

@Test @MainActor func admissionMeasuresOnlyARealQueuedWaitAndCancellationDoesNotReportOne() async throws {
    let clock = AdmissionClock(), gate = DecodeAdmission(now: { clock.now })
    var waits: [Duration] = []
    gate.onWait = { waits.append($0) }
    let a = try await gate.acquire(), b = try await gate.acquire(), c = try await gate.acquire()
    #expect(waits.isEmpty)
    let fourth = Task { try await gate.acquire() }
    let deadline = ContinuousClock.now + .seconds(1)
    while !gate.waiting, ContinuousClock.now < deadline { await Task.yield() }
    try #require(gate.waiting)
    clock.now += .milliseconds(40)
    gate.release(a)
    let d = try await fourth.value
    #expect(waits == [.milliseconds(40)] && gate.count == 3 && gate.peak == 3)
    let canceled = Task { try await gate.acquire() }
    let cancelDeadline = ContinuousClock.now + .seconds(1)
    while !gate.waiting, ContinuousClock.now < cancelDeadline { await Task.yield() }
    try #require(gate.waiting)
    canceled.cancel()
    do { _ = try await canceled.value; Issue.record("Canceled admission succeeded") } catch {}
    clock.now += .seconds(1)
    gate.release(b)
    #expect(waits == [.milliseconds(40)])
    gate.stop(); gate.release(c); gate.release(d)
    #expect(gate.count == 0 && waits.count == 1)
}
