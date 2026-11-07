import Foundation
import Testing
@testable import KnotNativeCore
@testable import KnotNativePreview

/// Deliberately retains cancelled callbacks so tests can deliver them late.
/// There is no wall-clock sleep, audio engine, device or network in this suite.
private final class ManualAudioPrebufferClock: NativeAudioPrebufferClock, @unchecked Sendable {
    private struct Wait {
        let delay: Duration
        let action: @Sendable () async -> Void
        var cancelled = false
        var fired = false
    }
    private let lock = NSLock()
    private var waits: [Wait] = []

    func schedule(after delay: Duration, _ action: @escaping @Sendable () async -> Void) -> @Sendable () -> Void {
        let id = lock.withLock { waits.append(Wait(delay: delay, action: action)); return waits.count - 1 }
        return { [weak self] in self?.cancel(id) }
    }
    private func cancel(_ id: Int) { lock.withLock { waits[id].cancelled = true } }
    func fire(_ id: Int) async {
        let action: (@Sendable () async -> Void)? = lock.withLock {
            guard waits.indices.contains(id) else { return nil }
            waits[id].fired = true; return waits[id].action
        }
        await action?()
    }
    var delays: [Duration] { lock.withLock { waits.map(\.delay) } }
    var activeCount: Int { lock.withLock { waits.filter { !$0.cancelled && !$0.fired }.count } }
}

private final class FakeAudioOutputSink: NativeAudioOutputSink, @unchecked Sendable {
    struct Snapshot: Sendable {
        var starts = 0
        var plays = 0
        var pauses = 0
        var flushes = 0
        var stops = 0
        var muted = false
        var scheduledFrames: [Int] = []
        var pendingFrames = 0
    }
    private let lock = NSLock()
    private var state = Snapshot()
    private var completions: [@Sendable () async -> Void] = []
    private var pending: [Int: Int] = [:]
    private var rejectNextSchedule = false

    func start(muted: Bool) { lock.withLock { state.starts += 1; state.muted = muted } }
    func schedule(_ pcm: NativeAudioPCM, completion: @escaping @Sendable () async -> Void) throws {
        try lock.withLock {
            if rejectNextSchedule { rejectNextSchedule = false; throw NativeFailure.state }
            let id = completions.count
            completions.append(completion); pending[id] = pcm.frames
            state.scheduledFrames.append(pcm.frames)
        }
    }
    func play() { lock.withLock { state.plays += 1 } }
    func pause() { lock.withLock { state.pauses += 1 } }
    func flush() { lock.withLock { state.flushes += 1; pending.removeAll() } }
    func setMuted(_ muted: Bool) { lock.withLock { state.muted = muted } }
    func stop() { lock.withLock { state.stops += 1; pending.removeAll() } }
    func failNextSchedule() { lock.withLock { rejectNextSchedule = true } }
    func complete(_ id: Int) async {
        let action = lock.withLock { pending.removeValue(forKey: id); return completions[id] }
        await action()
    }
    func snapshot() -> Snapshot {
        lock.withLock { var copy = state; copy.pendingFrames = pending.values.reduce(0, +); return copy }
    }
}

private final class AudioPlayerFixture: @unchecked Sendable {
    let output = FakeAudioOutputSink()
    let clock = ManualAudioPrebufferClock()
    private let lock = NSLock()
    private var creations = 0
    func makePlayer() -> NativeAudioPlayer {
        NativeAudioPlayer(makeOutput: { [self] in
            lock.withLock { creations += 1 }; return output
        }, prebufferClock: clock)
    }
    var outputCreations: Int { lock.withLock { creations } }
}

private func playerPCM(frames: Int, gap: Bool = false) throws -> NativeAudioPCM {
    var payload = Data()
    payload.appendBE(UInt64(1)); payload.appendBE(UInt64(gap ? 1 : 0)); payload.appendBE(UInt32(frames))
    payload.append(Data(repeating: 0, count: frames * 4))
    return try NativeAudioPCM(payload, after: 0, previousEnd: gap ? 0 : nil)
}

@Test(arguments: [1, 480, 959])
func audioPlayerShortBurstPlaysAtDeadlineWithoutAnyLaterPCM(frames: Int) async throws {
    let fixture = AudioPlayerFixture(), player = fixture.makePlayer()
    #expect(fixture.outputCreations == 0)
    try await player.start(muted: false)
    try await player.enqueue(playerPCM(frames: frames))
    #expect(fixture.outputCreations == 1)
    #expect(fixture.output.snapshot().scheduledFrames == [frames])
    #expect(fixture.output.snapshot().plays == 0)
    #expect(fixture.clock.delays == [.milliseconds(20)] && fixture.clock.activeCount == 1)
    await fixture.clock.fire(0)
    #expect(fixture.output.snapshot().plays == 1)
    #expect(fixture.output.snapshot().scheduledFrames == [frames])
    #expect(fixture.clock.activeCount == 0)
    await player.stop()
}

@Test func audioPlayerFrameThresholdStartsEarlyAndCancelsItsSingleDeadline() async throws {
    let fixture = AudioPlayerFixture(), player = fixture.makePlayer()
    try await player.start(muted: false)
    try await player.enqueue(playerPCM(frames: 240))
    try await player.enqueue(playerPCM(frames: 240))
    try await player.enqueue(playerPCM(frames: 480))
    #expect(fixture.output.snapshot().plays == 1)
    #expect(fixture.clock.delays == [.milliseconds(20)] && fixture.clock.activeCount == 0)
    await fixture.clock.fire(0)
    #expect(fixture.output.snapshot().plays == 1)
    await player.stop()
}

@Test func audioPlayerGapReprimesAndRejectsOldTimerAndCompletion() async throws {
    let fixture = AudioPlayerFixture(), player = fixture.makePlayer()
    try await player.start(muted: false)
    try await player.enqueue(playerPCM(frames: 480))
    try await player.enqueue(playerPCM(frames: 240, gap: true))
    #expect(fixture.output.snapshot().flushes == 1 && fixture.output.snapshot().pendingFrames == 240)
    #expect(fixture.clock.activeCount == 1 && fixture.clock.delays.count == 2)
    await fixture.clock.fire(0)
    await fixture.output.complete(0)
    #expect(fixture.output.snapshot().plays == 0 && fixture.output.snapshot().pauses == 0)
    #expect(fixture.clock.activeCount == 1)
    await fixture.clock.fire(1)
    #expect(fixture.output.snapshot().plays == 1)
    await player.stop()
}

@Test func audioPlayerOverflowKeepsHundredMillisecondCapAndTimesShortReprime() async throws {
    let fixture = AudioPlayerFixture(), player = fixture.makePlayer()
    try await player.start(muted: false)
    for _ in 0..<5 { try await player.enqueue(playerPCM(frames: 960)) }
    #expect(fixture.output.snapshot().pendingFrames == 4_800 && fixture.output.snapshot().plays == 1)
    try await player.enqueue(playerPCM(frames: 480))
    #expect(fixture.output.snapshot().pendingFrames == 480 && fixture.output.snapshot().flushes == 1)
    #expect(fixture.output.snapshot().plays == 1 && fixture.clock.activeCount == 1)
    await fixture.output.complete(0)
    #expect(fixture.output.snapshot().pauses == 0)
    await fixture.clock.fire(0)
    #expect(fixture.output.snapshot().plays == 2)
    await player.stop()
}

@Test func audioPlayerUnderflowReprimesAndTimerIdentityRejectsOldSameGenerationCallback() async throws {
    let fixture = AudioPlayerFixture(), player = fixture.makePlayer()
    try await player.start(muted: false)
    try await player.enqueue(playerPCM(frames: 480))
    await fixture.clock.fire(0)
    await fixture.output.complete(0)
    #expect(fixture.output.snapshot().pauses == 1)
    try await player.enqueue(playerPCM(frames: 240))
    #expect(fixture.clock.activeCount == 1)
    // Underflow does not flush the queue generation: only timer identity can
    // prevent this old deadline from starting the newly priming buffer early.
    await fixture.clock.fire(0)
    #expect(fixture.output.snapshot().plays == 1 && fixture.clock.activeCount == 1)
    await fixture.output.complete(0)
    #expect(fixture.output.snapshot().pauses == 1)
    await fixture.clock.fire(1)
    #expect(fixture.output.snapshot().plays == 2)
    await fixture.output.complete(1)
    #expect(fixture.output.snapshot().pauses == 2)
    await player.stop()
}

@Test func audioPlayerStopCancelsDeadlineAndMakesLateCallbacksAndCommandsInert() async throws {
    let fixture = AudioPlayerFixture(), player = fixture.makePlayer()
    try await player.start(muted: false)
    try await player.enqueue(playerPCM(frames: 480))
    await player.stop()
    await fixture.clock.fire(0)
    await fixture.output.complete(0)
    await player.setMuted(true)
    await player.stop()
    await #expect(throws: NativeFailure.state) { try await player.enqueue(playerPCM(frames: 480)) }
    await #expect(throws: NativeFailure.state) { try await player.start(muted: false) }
    let state = fixture.output.snapshot()
    #expect(state.stops == 1 && state.plays == 0 && state.pauses == 0 && !state.muted)
    #expect(fixture.clock.activeCount == 0 && fixture.outputCreations == 1)
}

@Test func audioPlayerMutedShortBurstStillPlaysAndDrains() async throws {
    let fixture = AudioPlayerFixture(), player = fixture.makePlayer()
    try await player.start(muted: true)
    try await player.enqueue(playerPCM(frames: 480))
    await fixture.clock.fire(0)
    #expect(fixture.output.snapshot().plays == 1 && fixture.output.snapshot().muted)
    await player.setMuted(false)
    #expect(!fixture.output.snapshot().muted)
    await player.setMuted(true)
    await fixture.output.complete(0)
    #expect(fixture.output.snapshot().pendingFrames == 0 && fixture.output.snapshot().pauses == 1)
    await player.stop()
}

@Test func audioPlayerFailedScheduleCancelsOldDeadlineBeforeReprime() async throws {
    let fixture = AudioPlayerFixture(), player = fixture.makePlayer()
    try await player.start(muted: false)
    try await player.enqueue(playerPCM(frames: 480))
    fixture.output.failNextSchedule()
    await #expect(throws: NativeFailure.state) { try await player.enqueue(playerPCM(frames: 240)) }
    #expect(fixture.output.snapshot().pendingFrames == 0 && fixture.clock.activeCount == 0)
    await fixture.clock.fire(0)
    #expect(fixture.output.snapshot().plays == 0)
    try await player.enqueue(playerPCM(frames: 240))
    await fixture.clock.fire(1)
    #expect(fixture.output.snapshot().plays == 1 && fixture.output.snapshot().pendingFrames == 240)
    await player.stop()
}

@Test func audioPlayerStoppedBeforeStartNeverCreatesAnOutput() async throws {
    let fixture = AudioPlayerFixture(), player = fixture.makePlayer()
    await player.stop()
    await #expect(throws: NativeFailure.state) { try await player.start(muted: false) }
    #expect(fixture.outputCreations == 0 && fixture.clock.delays.isEmpty)
}
