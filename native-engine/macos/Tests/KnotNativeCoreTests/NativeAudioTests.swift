import Foundation
import Testing
@testable import KnotNativeCore
@testable import KnotNativePreview

private func audioFixtureInvitation() throws -> Invitation {
    let json = try JSONSerialization.data(withJSONObject: ["v": 1, "address": "192.168.50.12", "port": 48631,
        "certificateSHA256": String(repeating: "a", count: 64),
        "token": Invitation.encodeBase64URL(Data(0..<32))])
    return try Invitation("knot-native:v1:" + Invitation.encodeBase64URL(json))
}

private func audioFixtureReady(_ codec: String = "pcm-s16le") throws -> NativeAudioPacket {
    NativeAudioPacket(kind: .ready, payload: try JSONSerialization.data(withJSONObject: [
        "v": 1, "codec": codec, "sampleRate": 48_000, "channels": 2]))
}

private func audioFixturePCM(sequence: UInt64 = 1, first: UInt64 = 0, frames: UInt32 = 960,
                             samples: Data? = nil) -> NativeAudioPacket {
    var payload = Data(); payload.appendBE(sequence); payload.appendBE(first); payload.appendBE(frames)
    payload.append(samples ?? Data(repeating: 0, count: Int(frames) * 4))
    return NativeAudioPacket(kind: .pcm, payload: payload)
}

@Test func audioDomainKeyMatchesWindowsVectorAndHelloContainsOnlyDerivedAuthority() throws {
    let key = try NativeAudioWire.deriveKey(mediaToken: Data(0..<32))
    #expect(key.map { String(format: "%02x", $0) }.joined() == "117cc20e9e55ce053910b304d47279c235c68abf3941bbf34b2a418405bf62bb")
    #expect(Invitation.encodeBase64URL(key) == "EXzCDp5VzgU5ELME1HJ5wjXGir85QbvzSypBhAW_Yrs")
    #expect(throws: NativeFailure.malformed) { try NativeAudioWire.deriveKey(mediaToken: Data(repeating: 0, count: 31)) }
    let invitation = try audioFixtureInvitation(), endpoint = try NativeAudioEndpoint(invitation: invitation)
    let hello = try endpoint.hello()
    let body = try StrictJSON.object(hello.payload, keys: ["v", "token"], limit: 256)
    #expect(hello.kind == .hello && hello.payload.count <= 256 && NativeAudioEndpoint.port == 48636)
    #expect(try body.integer("v") == 1)
    #expect(try body.string("token") == "EXzCDp5VzgU5ELME1HJ5wjXGir85QbvzSypBhAW_Yrs")
    #expect(try body.string("token") != invitation.token)
    #expect(endpoint.address == invitation.address && endpoint.certificateSHA256 == invitation.certificateSHA256)
}

@Test func audioReadyOrderStrictSchemasAndErrorsAreIndependentOfVideo() throws {
    for premature in [audioFixturePCM(), NativeAudioPacket(kind: .heartbeat)] {
        var state = NativeAudioReceiveState()
        #expect(throws: NativeFailure.state) { try state.accept(premature) }
    }
    var state = NativeAudioReceiveState()
    #expect(try state.accept(audioFixtureReady()) == .ready)
    #expect(try state.accept(NativeAudioPacket(kind: .heartbeat)) == .heartbeat)
    #expect(throws: NativeFailure.state) { try state.accept(audioFixtureReady()) }
    #expect(throws: NativeFailure.state) { try state.accept(NativeAudioPacket(kind: .heartbeat, payload: Data([0]))) }
    for payload in [
        Data(#"{"v":1,"codec":"pcm-s16le","sampleRate":48000,"channels":2,"extra":1}"#.utf8),
        Data(#"{"v":1,"v":1,"codec":"pcm-s16le","sampleRate":48000,"channels":2}"#.utf8),
        Data(#"{"v":1,"codec":"pcm-s16le","sampleRate":48000,"channels":2}garbage"#.utf8)
    ] {
        var fresh = NativeAudioReceiveState()
        #expect(throws: NativeFailure.malformed) { try fresh.accept(NativeAudioPacket(kind: .ready, payload: payload)) }
    }
    var unsupported = NativeAudioReceiveState()
    #expect(throws: NativeFailure.unsupported) { try unsupported.accept(audioFixtureReady("aac")) }
    for code in NativeAudioWire.errorCodes {
        var fresh = NativeAudioReceiveState()
        let error = NativeAudioPacket(kind: .error, payload: try JSONSerialization.data(withJSONObject: ["code": code]))
        #expect(try fresh.accept(error) == .failure(code))
        #expect(throws: NativeFailure.state) { try fresh.accept(error) }
    }
    var unknown = NativeAudioReceiveState()
    #expect(throws: NativeFailure.malformed) {
        try unknown.accept(NativeAudioPacket(kind: .error, payload: Data(#"{"code":"capture"}"#.utf8)))
    }
}

@Test func audioPCMValidatesExactSequenceLengthAndSampleTimeline() throws {
    var state = NativeAudioReceiveState(); _ = try state.accept(audioFixtureReady())
    guard case .pcm(let first) = try state.accept(audioFixturePCM(frames: 1, samples: Data([0, 128, 255, 127]))) else {
        Issue.record("PCM was not accepted"); return
    }
    #expect(first.frames == 1 && !first.hasSampleGap)
    #expect(first.sample(frame: 0, channel: 0) == -1)
    #expect(first.sample(frame: 0, channel: 1) == Float(32_767) / 32_768)
    guard case .pcm(let gap) = try state.accept(audioFixturePCM(sequence: 2, first: 10, frames: 1)) else {
        Issue.record("Forward sample gap was not accepted"); return
    }
    #expect(gap.hasSampleGap && state.sequence == 2 && state.endSampleIndex == 11)
    #expect(throws: NativeFailure.malformed) { try state.accept(audioFixturePCM(sequence: 4, first: 11, frames: 1)) }
    #expect(throws: NativeFailure.malformed) { try state.accept(audioFixturePCM(sequence: 3, first: 10, frames: 1)) }
    #expect(throws: NativeFailure.malformed) { try state.accept(audioFixturePCM(sequence: 3, first: UInt64.max, frames: 1)) }
    #expect(throws: NativeFailure.malformed) { try NativeAudioPCM(audioFixturePCM(sequence: 0, frames: 1).payload, after: .max, previousEnd: nil) }
    #expect(throws: NativeFailure.malformed) { try NativeAudioPCM(audioFixturePCM(sequence: 2, frames: 1).payload, after: 0, previousEnd: nil) }
    #expect(throws: NativeFailure.oversized) { try NativeAudioPCM(audioFixturePCM(frames: 0).payload, after: 0, previousEnd: nil) }
    #expect(throws: NativeFailure.oversized) { try NativeAudioPCM(audioFixturePCM(frames: 961).payload, after: 0, previousEnd: nil) }
    #expect(throws: NativeFailure.malformed) { try NativeAudioPCM(audioFixturePCM(frames: 1, samples: Data(repeating: 0, count: 8)).payload, after: 0, previousEnd: nil) }
    #expect(throws: NativeFailure.oversized) { try NativeAudioPCM(audioFixturePCM(frames: 1, samples: Data([0, 0])).payload, after: 0, previousEnd: nil) }
    #expect(try NativeAudioPCM(audioFixturePCM(first: UInt64.max - 1, frames: 1).payload, after: 0, previousEnd: nil).firstSampleIndex == UInt64.max - 1)
}

@Test func audioHeadersRejectOversizedUnknownAndNonemptyHeartbeatBeforeReadingBodies() throws {
    func header(_ kind: UInt8, _ count: UInt32) -> Data { var data = Data([kind]); data.appendBE(count); return data }
    #expect(try NativeAudioPacket.serverHeader(header(3, 3_860)).1 == 3_860)
    #expect(try NativeAudioPacket.serverHeader(header(4, 0)).1 == 0)
    #expect(throws: NativeFailure.oversized) { try NativeAudioPacket.serverHeader(header(3, 3_861)) }
    #expect(throws: NativeFailure.oversized) { try NativeAudioPacket.serverHeader(header(2, 257)) }
    #expect(throws: NativeFailure.oversized) { try NativeAudioPacket.serverHeader(header(127, 129)) }
    #expect(throws: NativeFailure.malformed) { try NativeAudioPacket.serverHeader(header(4, 1)) }
    #expect(throws: NativeFailure.malformed) { try NativeAudioPacket.serverHeader(header(33, UInt32.max)) }
    #expect(throws: NativeFailure.state) { try NativeAudioPacket.serverHeader(header(1, 10)) }
    #expect(throws: NativeFailure.malformed) { try NativeAudioPacket.serverHeader(Data([2, 0])) }
}

@Test func audioQueueFlushesOverflowAndGapsAndIgnoresStaleOrRepeatedCompletions() {
    var queue = NativeAudioQueue()
    let first = queue.reserve(frames: 480, sampleGap: false)
    #expect(!first.flushed && queue.queuedFrames < NativeAudioQueue.prebufferFrames)
    let second = queue.reserve(frames: 480, sampleGap: false)
    #expect(!second.flushed && queue.queuedFrames == NativeAudioQueue.prebufferFrames)
    queue.complete(first.ticket); queue.complete(first.ticket)
    #expect(queue.queuedFrames == 480)
    for _ in 0..<4 { _ = queue.reserve(frames: 960, sampleGap: false) }
    #expect(queue.queuedFrames == 4_320)
    let overflow = queue.reserve(frames: 960, sampleGap: false)
    #expect(overflow.flushed && queue.queuedFrames == 960)
    queue.complete(second.ticket)
    #expect(queue.queuedFrames == 960)
    let gap = queue.reserve(frames: 1, sampleGap: true)
    #expect(gap.flushed && queue.queuedFrames == 1)
    queue.complete(overflow.ticket)
    #expect(queue.queuedFrames == 1)
    queue.flush(); queue.complete(gap.ticket)
    #expect(queue.queuedFrames == 0)
}

/// A finite or deliberately suspended inert stream. It does not instantiate
/// Network, AVAudioEngine, user devices, settings, keys or file authority.
private final class AudioFixtureChannel: NativeChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data
    private let holdAtEnd: Bool
    private let startFailure: Bool
    private var pending: (count: Int, continuation: CheckedContinuation<Data, any Error>)?
    private var writes: [Packet] = []
    private var requests: [(Int, Duration)] = []
    private var closed = false
    init(_ bytes: Data, holdAtEnd: Bool = true, startFailure: Bool = false) {
        self.bytes = bytes; self.holdAtEnd = holdAtEnd; self.startFailure = startFailure
    }
    func start() async throws { if startFailure { throw NativeFailure.transport } }
    func readExactly(_ count: Int, timeout: Duration) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); requests.append((count, timeout))
            if closed { lock.unlock(); continuation.resume(throwing: NativeFailure.transport) }
            else if bytes.count >= count {
                let data = Data(bytes.prefix(count)); bytes.removeFirst(count); lock.unlock(); continuation.resume(returning: data)
            } else if bytes.isEmpty && holdAtEnd { pending = (count, continuation); lock.unlock() }
            else { lock.unlock(); continuation.resume(throwing: NativeFailure.transport) }
        }
    }
    func send(_ packet: Packet) async throws { lock.withLock { writes.append(packet) } }
    func supply(_ data: Data) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        bytes.append(data)
        if let waiting = pending, bytes.count >= waiting.count {
            let result = Data(bytes.prefix(waiting.count)); bytes.removeFirst(waiting.count)
            pending = nil; lock.unlock(); waiting.continuation.resume(returning: result)
        } else { lock.unlock() }
    }
    func close() {
        lock.lock(); closed = true; let waiting = pending; pending = nil; lock.unlock()
        waiting?.continuation.resume(throwing: NativeFailure.transport)
    }
    func snapshot() -> (writes: [Packet], requests: [(Int, Duration)], closed: Bool, waiting: Bool) {
        lock.withLock { (writes, requests, closed, pending != nil) }
    }
}

private actor AudioFixturePlayer: NativeAudioPlaying {
    private(set) var starts = 0
    private(set) var frames = 0
    private(set) var muted = false
    private(set) var stopped = false
    private var failure: (@Sendable () async -> Void)?
    func setFailureHandler(_ handler: @escaping @Sendable () async -> Void) async { failure = handler }
    func failOutput() async { await failure?() }
    func start(muted: Bool) { starts += 1; self.muted = muted }
    func enqueue(_ pcm: NativeAudioPCM) { frames += pcm.frames }
    func setMuted(_ muted: Bool) { self.muted = muted }
    func stop() { stopped = true }
    func snapshot() -> (starts: Int, frames: Int, muted: Bool, stopped: Bool) { (starts, frames, muted, stopped) }
}

private final class AudioFixtureFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let player = AudioFixturePlayer()
    func make() -> any NativeAudioPlaying { lock.withLock { count += 1 }; return player }
    var creations: Int { lock.withLock { count } }
}

/// These fixtures assert lifecycle ordering, not scheduler latency. Yielding
/// in a hot loop can consume the readiness budget while unrelated concurrent
/// codec tests occupy MainActor on a shared CI runner.
@MainActor private func audioEventually(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        do { try await Task.sleep(for: .milliseconds(1)) } catch { return false }
    }
    return await condition()
}

@Test @MainActor func audioSessionAuthenticatesBeforeCreatingOutputAndMuteKeepsDraining() async throws {
    let channel = AudioFixtureChannel(Data())
    let factory = AudioFixtureFactory()
    let session = try NativeAudioSession(invitation: audioFixtureInvitation(), makeChannel: { _ in channel }, makePlayer: { factory.make() })
    defer { session.stop() }
    #expect(factory.creations == 0 && session.state == .idle)
    session.setMuted(true)
    let task = try #require(session.start())
    #expect(session.start() == nil)
    try #require(await audioEventually { channel.snapshot().waiting })
    let authenticating = channel.snapshot()
    #expect(authenticating.writes.count == 1 && authenticating.writes[0].kind == .hello)
    #expect(factory.creations == 0 && session.state == .connecting && !session.isAvailable)
    channel.supply(try audioFixtureReady().encoded + audioFixturePCM().encoded + NativeAudioPacket(kind: .heartbeat).encoded)
    try #require(await audioEventually { channel.snapshot().waiting && session.state == .playing })
    let output = await factory.player.snapshot()
    #expect(session.state == .playing && session.isAvailable && session.muted)
    #expect(output.starts == 1 && output.frames == 960 && output.muted)
    let stream = channel.snapshot()
    #expect(stream.writes.count == 1 && stream.writes[0].kind == .hello)
    #expect(stream.requests.allSatisfy { $0.1 > .zero && $0.1 <= .seconds(5) })
    session.toggleMuted()
    try #require(await audioEventually { !(await factory.player.snapshot()).muted })
    let unmuted = await factory.player.snapshot()
    #expect(!session.muted && !unmuted.muted)
    session.stop(); await task.value
    #expect(session.state == .stopped && !session.isAvailable && channel.snapshot().closed)
    #expect((await factory.player.snapshot()).stopped)
}

@Test @MainActor func optionalAudioFailuresNeverCreateOutputBeforeReady() async throws {
    let errors = [try audioFixtureReady("aac").encoded,
        NativeAudioPacket(kind: .error, payload: Data(#"{"code":"unavailable"}"#.utf8)).encoded,
        NativeAudioPacket(kind: .error, payload: Data(#"{"code":"auth"}"#.utf8)).encoded,
        audioFixturePCM().encoded,
        Data([3, 255, 255, 255, 255]), Data([2, 0, 0]), Data([2, 0, 0, 0, 6, 123, 125])]
    for bytes in errors {
        let channel = AudioFixtureChannel(bytes, holdAtEnd: false), factory = AudioFixtureFactory()
        let session = try NativeAudioSession(invitation: audioFixtureInvitation(), makeChannel: { _ in channel }, makePlayer: { factory.make() })
        let task = try #require(session.start()); await task.value
        #expect(session.state == .unavailable && !session.isAvailable && factory.creations == 0)
        #expect(channel.snapshot().closed)
    }
    let channel = AudioFixtureChannel(Data(), startFailure: true), factory = AudioFixtureFactory()
    let session = try NativeAudioSession(invitation: audioFixtureInvitation(), makeChannel: { _ in channel }, makePlayer: { factory.make() })
    let task = try #require(session.start()); await task.value
    #expect(session.state == .unavailable && factory.creations == 0 && channel.snapshot().writes.isEmpty)
}

@Test func audioReaderRejectsOversizeBeforeBodyRead() async throws {
    let channel = AudioFixtureChannel(Data([3, 0, 0, 15, 21]), holdAtEnd: false)
    await #expect(throws: NativeFailure.oversized) { try await NativeAudioSession.readPacket(channel) }
    #expect(channel.snapshot().requests.map(\.0) == [5])
}

@Test @MainActor func stoppingOptionalAudioCancelsPendingReadAndRejectsLateState() async throws {
    let channel = AudioFixtureChannel(Data()), factory = AudioFixtureFactory()
    let session = try NativeAudioSession(invitation: audioFixtureInvitation(), makeChannel: { _ in channel }, makePlayer: { factory.make() })
    defer { session.stop() }
    let task = try #require(session.start())
    try #require(await audioEventually { channel.snapshot().waiting })
    session.stop(); await task.value
    #expect(task.isCancelled && session.state == .stopped && !session.isAvailable)
    #expect(channel.snapshot().closed && factory.creations == 0 && session.start() == nil)
}

private actor AudioSuspendedFixturePlayer: NativeAudioPlaying {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var started = false
    private(set) var stopped = false
    func start(muted: Bool) async {
        guard !released else { started = true; return }
        await withCheckedContinuation { continuation in self.continuation = continuation; started = true }
    }
    func enqueue(_ pcm: NativeAudioPCM) {}
    func setMuted(_ muted: Bool) {}
    func stop() { stopped = true }
    func finishStart() { released = true; let waiting = continuation; continuation = nil; waiting?.resume() }
}

@Test @MainActor func audioOutputStartingAfterStopCannotRestoreAvailability() async throws {
    let channel = AudioFixtureChannel(try audioFixtureReady().encoded), player = AudioSuspendedFixturePlayer()
    let session = try NativeAudioSession(invitation: audioFixtureInvitation(), makeChannel: { _ in channel }, makePlayer: { player })
    defer { session.stop(); Task { await player.finishStart() } }
    var becameAvailable = false
    session.onChange = { [weak session] in if session?.isAvailable == true { becameAvailable = true } }
    let task = try #require(session.start())
    try #require(await audioEventually { await player.started })
    session.stop()
    await player.finishStart(); await task.value
    #expect(!becameAvailable && session.state == .stopped && !session.isAvailable && channel.snapshot().closed)
    #expect(await player.stopped)
}


@Test @MainActor func ownedOutputFailureBecomesUnavailableEvenWithoutAnotherAudioPacket() async throws {
    let channel = AudioFixtureChannel(try audioFixtureReady().encoded), factory = AudioFixtureFactory()
    let session = try NativeAudioSession(invitation: audioFixtureInvitation(), makeChannel: { _ in channel }, makePlayer: { factory.make() })
    defer { session.stop() }
    let task = try #require(session.start())
    try #require(await audioEventually { session.state == .playing && channel.snapshot().waiting })
    await factory.player.failOutput()
    await task.value
    #expect(session.state == .unavailable && !session.isAvailable && channel.snapshot().closed)
    #expect(session.status.contains("출력 장치"))
    #expect((await factory.player.snapshot()).stopped)
}
