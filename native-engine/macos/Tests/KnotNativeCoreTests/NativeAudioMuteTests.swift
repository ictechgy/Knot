import Foundation
import Testing
@testable import KnotNativeCore
@testable import KnotNativePreview

private func muteFixtureInvitation() throws -> Invitation {
    let json = try JSONSerialization.data(withJSONObject: ["v": 1, "address": "192.168.50.12", "port": 48631,
        "certificateSHA256": String(repeating: "a", count: 64),
        "token": Invitation.encodeBase64URL(Data(0..<32))])
    return try Invitation("knot-native:v1:" + Invitation.encodeBase64URL(json))
}

private func muteFixtureReady() throws -> Data {
    NativeAudioPacket(kind: .ready, payload: try JSONSerialization.data(withJSONObject: [
        "v": 1, "codec": "pcm-s16le", "sampleRate": 48_000, "channels": 2])).encoded
}

/// Only explicitly supplied bytes and continuations; no network or device I/O.
private final class MuteFixtureChannel: NativeChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data
    private var pending: (count: Int, continuation: CheckedContinuation<Data, any Error>)?
    private var closed = false
    init(_ bytes: Data = Data()) { self.bytes = bytes }
    func start() async throws {}
    func send(_ packet: Packet) async throws {}
    func readExactly(_ count: Int, timeout: Duration) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed { lock.unlock(); continuation.resume(throwing: NativeFailure.transport) }
            else if bytes.count >= count {
                let value = Data(bytes.prefix(count)); bytes.removeFirst(count)
                lock.unlock(); continuation.resume(returning: value)
            } else { pending = (count, continuation); lock.unlock() }
        }
    }
    func feed(_ value: Data) {
        lock.lock(); bytes.append(value)
        guard let waiting = pending, bytes.count >= waiting.count, !closed else { lock.unlock(); return }
        pending = nil
        let result = Data(bytes.prefix(waiting.count)); bytes.removeFirst(waiting.count)
        lock.unlock(); waiting.continuation.resume(returning: result)
    }
    func close() {
        lock.lock(); closed = true; let waiting = pending; pending = nil; lock.unlock()
        waiting?.continuation.resume(throwing: NativeFailure.transport)
    }
    var isWaiting: Bool { lock.withLock { pending != nil } }
    var isClosed: Bool { lock.withLock { closed } }
}

/// Deliberately reentrant awaits expose overlapping and stale mute deliveries.
private actor SlowMutePlayer: NativeAudioPlaying {
    struct Snapshot: Sendable {
        let startValues: [Bool]
        let muteValues: [Bool]
        let activeMuteCalls: Int
        let maximumActiveMuteCalls: Int
        let completedCancelled: [Bool]
        let muted: Bool
        let startWaiting: Bool
        let stopWaiting: Bool
        let stops: Int
    }
    private let holdStart: Bool
    private let holdStop: Bool
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var muteContinuations: [CheckedContinuation<Void, Never>] = []
    private var stopContinuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var startValues: [Bool] = []
    private var muteValues: [Bool] = []
    private var activeMuteCalls = 0
    private var maximumActiveMuteCalls = 0
    private var completedCancelled: [Bool] = []
    private var muted = false
    private var stops = 0
    init(holdStart: Bool = false, holdStop: Bool = false) { self.holdStart = holdStart; self.holdStop = holdStop }
    func start(muted: Bool) async {
        startValues.append(muted)
        if holdStart && !released { await withCheckedContinuation { startContinuation = $0 } }
        self.muted = muted
    }
    func enqueue(_ pcm: NativeAudioPCM) {}
    func setMuted(_ value: Bool) async {
        activeMuteCalls += 1
        maximumActiveMuteCalls = max(maximumActiveMuteCalls, activeMuteCalls)
        muteValues.append(value)
        if !released { await withCheckedContinuation { muteContinuations.append($0) } }
        self.muted = value
        completedCancelled.append(Task.isCancelled)
        activeMuteCalls -= 1
    }
    func stop() async {
        stops += 1
        if holdStop && !released { await withCheckedContinuation { stopContinuations.append($0) } }
    }
    func releaseStart() { let waiting = startContinuation; startContinuation = nil; waiting?.resume() }
    func releaseMute() {
        guard !muteContinuations.isEmpty else { return }
        muteContinuations.removeFirst().resume()
    }
    func releaseStop() {
        guard !stopContinuations.isEmpty else { return }
        stopContinuations.removeFirst().resume()
    }
    func releaseAll() {
        released = true
        releaseStart()
        let waiting = muteContinuations; muteContinuations.removeAll()
        for continuation in waiting { continuation.resume() }
        let stopping = stopContinuations; stopContinuations.removeAll()
        for continuation in stopping { continuation.resume() }
    }
    func snapshot() -> Snapshot {
        Snapshot(startValues: startValues, muteValues: muteValues, activeMuteCalls: activeMuteCalls,
                 maximumActiveMuteCalls: maximumActiveMuteCalls, completedCancelled: completedCancelled,
                 muted: muted, startWaiting: startContinuation != nil, stopWaiting: !stopContinuations.isEmpty, stops: stops)
    }
}

private final class MuteFixtureFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let player: SlowMutePlayer
    init(_ player: SlowMutePlayer) { self.player = player }
    func make() -> any NativeAudioPlaying { lock.withLock { count += 1 }; return player }
    var creations: Int { lock.withLock { count } }
}

private final class MuteRetryFixtures: @unchecked Sendable {
    private let lock = NSLock()
    private let channels: [MuteFixtureChannel]
    private let players: [SlowMutePlayer]
    private var channelCount = 0, playerCount = 0
    init(channels: [MuteFixtureChannel], players: [SlowMutePlayer]) { self.channels = channels; self.players = players }
    func makeChannel() throws -> any NativeChannel {
        try lock.withLock {
            guard channelCount < channels.count else { throw NativeFailure.state }
            defer { channelCount += 1 }; return channels[channelCount]
        }
    }
    func makePlayer() -> any NativeAudioPlaying {
        lock.withLock {
            defer { playerCount += 1 }; return players[min(playerCount, players.count - 1)]
        }
    }
    var counts: (channels: Int, players: Int) { lock.withLock { (channelCount, playerCount) } }
}

@MainActor private func muteEventually(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}

@Test @MainActor func rapidAudioMuteChangesHaveOneInFlightCallAndConvergeToLatest() async throws {
    let channel = MuteFixtureChannel(try muteFixtureReady()), player = SlowMutePlayer()
    let session = try NativeAudioSession(invitation: muteFixtureInvitation(), makeChannel: { _ in channel }, makePlayer: { player })
    defer { session.stop(); Task { await player.releaseAll() } }
    let operation = try #require(session.start())
    try #require(await muteEventually { session.isAvailable })
    session.setMuted(true)
    try #require(await muteEventually { (await player.snapshot()).activeMuteCalls == 1 })
    for index in 0..<1_000 { session.setMuted(index.isMultiple(of: 2)) }
    session.setMuted(false)
    #expect(!session.muted)
    let blocked = await player.snapshot()
    #expect(blocked.muteValues == [true] && blocked.maximumActiveMuteCalls == 1)
    await player.releaseMute()
    try #require(await muteEventually { (await player.snapshot()).muteValues == [true, false] })
    #expect((await player.snapshot()).maximumActiveMuteCalls == 1)
    await player.releaseMute()
    try #require(await muteEventually {
        let value = await player.snapshot()
        return value.activeMuteCalls == 0 && !value.muted
    })
    #expect(!session.muted && session.state == .playing)
    session.stop(); await operation.value
    #expect((await player.snapshot()).stops > 0)
}

@Test @MainActor func stoppingAudioMuteDeliveryCancelsWorkerAndRejectsPendingLatestValue() async throws {
    let channel = MuteFixtureChannel(try muteFixtureReady()), player = SlowMutePlayer()
    let session = try NativeAudioSession(invitation: muteFixtureInvitation(), makeChannel: { _ in channel }, makePlayer: { player })
    defer { session.stop(); Task { await player.releaseAll() } }
    var stopped = false, lateAvailability = false
    session.onChange = { [weak session] in if stopped && session?.isAvailable == true { lateAvailability = true } }
    let operation = try #require(session.start())
    try #require(await muteEventually { session.isAvailable })
    session.setMuted(true)
    try #require(await muteEventually { (await player.snapshot()).activeMuteCalls == 1 })
    session.setMuted(false)
    stopped = true; session.stop(); await operation.value
    await player.releaseMute()
    try #require(await muteEventually { (await player.snapshot()).activeMuteCalls == 0 })
    session.setMuted(true)
    for _ in 0..<20 { await Task.yield() }
    let result = await player.snapshot()
    #expect(result.muteValues == [true] && result.maximumActiveMuteCalls == 1)
    #expect(result.completedCancelled == [true] && result.stops > 0)
    #expect(!lateAvailability && !session.muted && session.state == .stopped && !session.isAvailable && channel.isClosed)
}

@Test @MainActor func audioMuteBeforeReadyAndDuringSlowStartUsesLatestDesiredState() async throws {
    let channel = MuteFixtureChannel(), player = SlowMutePlayer(holdStart: true), factory = MuteFixtureFactory(player)
    let session = try NativeAudioSession(invitation: muteFixtureInvitation(), makeChannel: { _ in channel }, makePlayer: { factory.make() })
    defer { session.stop(); Task { await player.releaseAll() } }
    session.setMuted(true)
    let operation = try #require(session.start())
    try #require(await muteEventually { channel.isWaiting })
    #expect(factory.creations == 0 && session.muted)
    channel.feed(try muteFixtureReady())
    try #require(await muteEventually { (await player.snapshot()).startWaiting })
    #expect(factory.creations == 1 && !session.isAvailable)
    session.setMuted(false)
    let starting = await player.snapshot()
    #expect(starting.startValues == [true] && starting.muteValues.isEmpty && !session.muted)
    await player.releaseStart()
    try #require(await muteEventually { (await player.snapshot()).muteValues == [false] })
    #expect(session.isAvailable && session.state == .playing)
    await player.releaseMute()
    try #require(await muteEventually {
        let value = await player.snapshot()
        return !value.muted && value.activeMuteCalls == 0
    })
    #expect((await player.snapshot()).maximumActiveMuteCalls == 1)
    session.stop(); await operation.value
}

@Test @MainActor func stoppingAudioDuringSlowStartCannotBeginMuteDeliveryOrRestoreAvailability() async throws {
    let channel = MuteFixtureChannel(try muteFixtureReady()), player = SlowMutePlayer(holdStart: true)
    let session = try NativeAudioSession(invitation: muteFixtureInvitation(), makeChannel: { _ in channel }, makePlayer: { player })
    defer { session.stop(); Task { await player.releaseAll() } }
    session.setMuted(true)
    let operation = try #require(session.start())
    try #require(await muteEventually { (await player.snapshot()).startWaiting })
    session.setMuted(false); session.stop()
    await player.releaseStart(); await operation.value
    let result = await player.snapshot()
    #expect(result.startValues == [true] && result.muteValues.isEmpty && result.stops > 0)
    #expect(session.state == .stopped && !session.isAvailable && channel.isClosed)
}

@Test @MainActor func explicitAudioRetryUsesFreshChildrenAndIgnoresLatePreviousCleanup() async throws {
    let failure = NativeAudioPacket(kind: .error, payload: Data(#"{"code":"unavailable"}"#.utf8)).encoded
    let oldChannel = MuteFixtureChannel(try muteFixtureReady()), newChannel = MuteFixtureChannel(try muteFixtureReady())
    let oldPlayer = SlowMutePlayer(holdStop: true), newPlayer = SlowMutePlayer()
    let fixtures = MuteRetryFixtures(channels: [oldChannel, newChannel], players: [oldPlayer, newPlayer])
    let session = try NativeAudioSession(invitation: muteFixtureInvitation(), makeChannel: { _ in try fixtures.makeChannel() }, makePlayer: { fixtures.makePlayer() })
    defer { session.stop(); Task { await oldPlayer.releaseAll(); await newPlayer.releaseAll() } }
    #expect(session.retry() == nil)
    let previous = try #require(session.start())
    try #require(await muteEventually { session.isAvailable })
    session.setMuted(true)
    try #require(await muteEventually { (await oldPlayer.snapshot()).activeMuteCalls == 1 })
    oldChannel.feed(failure)
    try #require(await muteEventually {
        let previous = await oldPlayer.snapshot()
        return session.state == .unavailable && previous.stopWaiting
    })
    #expect(oldChannel.isClosed && fixtures.counts.channels == 1 && fixtures.counts.players == 1)
    session.setMuted(true)
    let replacement = try #require(session.retry())
    #expect(session.state == .connecting && session.retry() == nil)
    try #require(await muteEventually { session.state == .playing && session.isAvailable })
    #expect((await newPlayer.snapshot()).startValues == [true])
    session.setMuted(false)
    try #require(await muteEventually { (await newPlayer.snapshot()).muteValues == [false] })
    await oldPlayer.releaseMute()
    await oldPlayer.releaseStop(); await previous.value
    try #require(await muteEventually { (await oldPlayer.snapshot()).activeMuteCalls == 0 })
    session.setMuted(true)
    for _ in 0..<20 { await Task.yield() }
    let stillBlocked = await newPlayer.snapshot()
    #expect(stillBlocked.muteValues == [false] && stillBlocked.maximumActiveMuteCalls == 1)
    await newPlayer.releaseMute()
    try #require(await muteEventually { (await newPlayer.snapshot()).muteValues == [false, true] })
    await newPlayer.releaseMute()
    try #require(await muteEventually {
        let replacement = await newPlayer.snapshot()
        return replacement.activeMuteCalls == 0 && replacement.muted
    })
    #expect(session.state == .playing && session.isAvailable && session.muted)
    let replacementPlayer = await newPlayer.snapshot(), previousPlayer = await oldPlayer.snapshot()
    #expect(replacementPlayer.stops == 0 && replacementPlayer.maximumActiveMuteCalls == 1)
    #expect(previousPlayer.muteValues == [true] && previousPlayer.completedCancelled == [true])
    #expect(fixtures.counts.channels == 2 && fixtures.counts.players == 2)
    session.stop(); await replacement.value
    #expect(session.retry() == nil && session.state == .stopped && !session.isAvailable && newChannel.isClosed)
}

@Test @MainActor func explicitAudioRetryAfterFailureBeforeReadyCreatesOnlyReplacementPlayer() async throws {
    let failure = NativeAudioPacket(kind: .error, payload: Data(#"{"code":"unavailable"}"#.utf8)).encoded
    let oldChannel = MuteFixtureChannel(failure), newChannel = MuteFixtureChannel(try muteFixtureReady()), player = SlowMutePlayer()
    let fixtures = MuteRetryFixtures(channels: [oldChannel, newChannel], players: [player])
    let session = try NativeAudioSession(invitation: muteFixtureInvitation(), makeChannel: { _ in try fixtures.makeChannel() }, makePlayer: { fixtures.makePlayer() })
    defer { session.stop(); Task { await player.releaseAll() } }
    let previous = try #require(session.start()); await previous.value
    #expect(session.state == .unavailable && fixtures.counts.players == 0 && oldChannel.isClosed)
    let replacement = try #require(session.retry())
    #expect(session.retry() == nil)
    try #require(await muteEventually { session.isAvailable })
    #expect(session.state == .playing && fixtures.counts.channels == 2 && fixtures.counts.players == 1)
    session.stop(); await replacement.value
    #expect(session.retry() == nil && newChannel.isClosed)
}
