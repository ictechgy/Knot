import Foundation
import CoreVideo
import Testing
import KnotNativeCore
@testable import KnotNativePreview

/// Exclude only transport Hello/heartbeat frames. Releases, errors, capture
/// barriers and every other unexpected packet remain in the asserted sequence.
private func isWriterInputEvidence(_ packet: Packet) -> Bool {
    packet.kind != .hello && packet.kind != .heartbeat
}

/// A stalled synthetic media reader and one explicitly releasable input write.
/// There is no Network connection, capture API, AppKit input or real presenter.
private final class WriterFixtureChannel: NativeChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var queuedReads: [Data] = []
    private var read: CheckedContinuation<Data, any Error>?
    private var blocked: (Packet, CheckedContinuation<Void, any Error>)?
    private var shouldBlockInput: Bool
    private var closed = false
    private var recorded: [Packet] = []
    private var sentAt: [ContinuousClock.Instant] = []
    private var activeWrites = 0
    private var peakWrites = 0

    init(blockFirstInput: Bool = true) { shouldBlockInput = blockFirstInput }
    func start() async throws {}
    func readExactly(_ count: Int, timeout: Duration) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed { lock.unlock(); continuation.resume(throwing: NativeFailure.transport) }
            else if !queuedReads.isEmpty {
                let bytes = queuedReads.removeFirst(); lock.unlock()
                if bytes.count == count { continuation.resume(returning: bytes) }
                else { continuation.resume(throwing: NativeFailure.malformed) }
            } else { read = continuation; lock.unlock() }
        }
    }
    func send(_ packet: Packet) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            guard !closed else { lock.unlock(); continuation.resume(throwing: NativeFailure.transport); return }
            activeWrites += 1; peakWrites = max(peakWrites, activeWrites)
            if isWriterInputEvidence(packet) && shouldBlockInput {
                shouldBlockInput = false; blocked = (packet, continuation); lock.unlock()
            } else {
                recorded.append(packet); sentAt.append(.now); activeWrites -= 1
                lock.unlock(); continuation.resume()
            }
        }
    }
    func feed(_ bytes: Data) {
        lock.lock(); guard !closed else { lock.unlock(); return }
        let pending = read; read = nil
        if pending == nil { queuedReads.append(bytes) }
        lock.unlock(); pending?.resume(returning: bytes)
    }
    func releaseWrite() {
        lock.lock(); let pending = blocked; blocked = nil
        if let pending { recorded.append(pending.0); sentAt.append(.now); activeWrites -= 1 }
        lock.unlock(); pending?.1.resume()
    }
    var writeIsBlocked: Bool { lock.lock(); defer { lock.unlock() }; return blocked != nil }
    var readerIsBlocked: Bool { lock.lock(); defer { lock.unlock() }; return read != nil }
    var maximumConcurrentWrites: Int { lock.lock(); defer { lock.unlock() }; return peakWrites }
    func snapshot() -> [Packet] { lock.lock(); defer { lock.unlock() }; return recorded }
    func inputSnapshot() -> [Packet] {
        lock.lock(); defer { lock.unlock() }; return recorded.filter(isWriterInputEvidence)
    }
    func inputTimestamps() -> [ContinuousClock.Instant] {
        lock.lock(); defer { lock.unlock() }
        return zip(recorded, sentAt).compactMap { isWriterInputEvidence($0.0) ? $0.1 : nil }
    }
    func close() {
        lock.lock(); guard !closed else { lock.unlock(); return }
        closed = true
        let pendingRead = read, pendingWrite = blocked
        read = nil; blocked = nil; queuedReads = []
        if pendingWrite != nil { activeWrites -= 1 }
        lock.unlock()
        pendingRead?.resume(throwing: NativeFailure.transport)
        pendingWrite?.1.resume(throwing: NativeFailure.transport)
    }
}

@MainActor
private final class InputPacingFixture {
    private var continuation: CheckedContinuation<Void, any Error>?
    private(set) var reached = false
    var isWaiting: Bool { continuation != nil }
    private var used = false
    func wait(until deadline: ContinuousClock.Instant) async throws {
        if !used {
            used = true
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation; reached = true
                }
            } onCancel: { [weak self] in Task { @MainActor in self?.cancel() } }
        }
        // The injected gate may hold longer, but cannot shorten production's
        // real minimum spacing when the test releases it before the deadline.
        try await Task.sleep(until: deadline)
    }
    func release() { let pending = continuation; continuation = nil; pending?.resume() }
    func cancel() { let pending = continuation; continuation = nil; pending?.resume(throwing: CancellationError()) }
}

@MainActor
private final class WriterFixturePresenter: NativePresenter {
    var onFailure: (() -> Void)?
    private(set) var forgottenKeys = 0
    func display(_ image: CVPixelBuffer) -> PresentationResult { .presented }
    func clear() {}
    func forgetHeldKeys() { forgottenKeys += 1 }
}

@MainActor
private func waitForWriter(_ predicate: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    try #require(predicate(), sourceLocation: sourceLocation)
}

/// Let the real two-second heartbeat mature while the inert writer gate is
/// still held. This yields MainActor and proves that input assertions must
/// tolerate an actual transport heartbeat, including on a busy CI runner.
@MainActor
private func matureHeartbeatWhileWriterIsHeld(_ isHeld: () -> Bool) async throws {
    try #require(isHeld())
    let began = ContinuousClock.now
    try await Task.sleep(for: .milliseconds(2100))
    try #require(ContinuousClock.now - began > .seconds(2))
    try #require(isHeld())
}

@MainActor
private func streamingWriterFixture(_ channel: WriterFixtureChannel, presenter: WriterFixturePresenter,
                                    pacing: InputPacingFixture? = nil) async throws -> SessionModel {
    let model: SessionModel
    if let pacing {
        model = SessionModel(makeChannel: { _ in channel }, waitForInputDeadline: { deadline in
            // Hold only after the first actual input write. Hello/heartbeat and
            // the initial pointer-down still use ordinary deadline scheduling.
            // The subsequent barrier is deterministic even if2ms have elapsed.
            if channel.inputSnapshot().isEmpty {
                if ContinuousClock.now < deadline { try await Task.sleep(until: deadline) }
            } else { try await pacing.wait(until: deadline) }
        })
    } else { model = SessionModel(makeChannel: { _ in channel }) }
    model.surface = presenter
    let token = Invitation.encodeBase64URL(Data(repeating: 9, count: 32))
    let invitation = "{\"v\":1,\"address\":\"10.0.0.1\",\"port\":48631,\"certificateSHA256\":\"\(String(repeating: "a", count: 64))\",\"token\":\"\(token)\"}"
    model.review("knot-native:v1:" + Invitation.encodeBase64URL(Data(invitation.utf8)))
    model.connect()
    try await waitForWriter { model.phase == .approval }
    let ready = Packet(kind: .ready, payload: Data("{\"v\":1,\"codec\":\"h264-annexb\",\"width\":64,\"height\":64,\"fps\":60,\"bitrate\":1000000,\"hardwareEncoder\":true}".utf8))
    channel.feed(Data(ready.encoded.prefix(5))); channel.feed(ready.payload)
    try await waitForWriter { model.phase == .decoding }
    var pixel: CVPixelBuffer?
    try #require(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    model.presentDecodedImage(try #require(pixel))
    try #require(model.phase == .streaming)
    try await waitForWriter { channel.readerIsBlocked }
    return model
}

@Test @MainActor func qualityControlSaturationImmediatelyRequiresInputRecovery() async throws {
    for kind in [Kind.qualityPreference, .qualityFeedback] {
        let channel = WriterFixtureChannel(), presenter = WriterFixturePresenter()
        let model = try await streamingWriterFixture(channel, presenter: presenter)
        defer { model.disconnect() }
        let down = try Input.key(down: true, scan: 0x1e, extended: false)
        let up = try Input.key(down: false, scan: 0x1e, extended: false)
        try #require(model.send(down))
        try await waitForWriter { channel.writeIsBlocked }
        for _ in 0..<256 { try #require(model.send(down)) }
        let revision = model.inputRevision, forgotten = presenter.forgottenKeys
        #expect(!model.sendControl(Packet(kind: kind, payload: Data([1]))))
        #expect(model.inputRecovery && model.inputRevision == revision + 1)
        #expect(presenter.forgottenKeys == forgotten + 1)
        #expect(model.status == "Input paused after queue saturation. Click the desktop to resume.")
        #expect(!model.send(up))
        channel.releaseWrite()
        try await waitForWriter { channel.inputSnapshot().contains { $0.kind == .releaseAll } }
        #expect(channel.inputSnapshot() == [down, Packet(kind: .releaseAll)])
        model.recoverInput()
        try #require(model.send(up))
        try await waitForWriter { channel.inputSnapshot().count >= 3 }
        #expect(channel.inputSnapshot() == [down, Packet(kind: .releaseAll), up])
        #expect(model.phase == .streaming && !model.inputRecovery)
    }
}

@Test @MainActor func duplicateClipboardControlRejectionDoesNotRevokeInput() async throws {
    let channel = WriterFixtureChannel(), presenter = WriterFixturePresenter()
    let model = try await streamingWriterFixture(channel, presenter: presenter)
    defer { model.disconnect() }
    let down = try Input.key(down: true, scan: 0x1e, extended: false)
    let up = try Input.key(down: false, scan: 0x1e, extended: false)
    try #require(model.send(down))
    try await waitForWriter { channel.writeIsBlocked }
    let request = try ClipboardProtocol.request(.copy, nonce: Data(repeating: 4, count: 16), text: "")
    try #require(model.sendControl(request))
    let revision = model.inputRevision, forgotten = presenter.forgottenKeys, status = model.status
    #expect(!model.sendControl(request))
    #expect(!model.inputRecovery && model.inputRevision == revision)
    #expect(presenter.forgottenKeys == forgotten && model.status == status)
    try #require(model.send(up))
    channel.releaseWrite()
    try await waitForWriter { channel.inputSnapshot().count >= 3 }
    #expect(channel.inputSnapshot() == [down, request, up])
}

@Test @MainActor func writerSelectsNewestDragAfterPacingWait() async throws {
    let channel = WriterFixtureChannel(), pacing = InputPacingFixture(), presenter = WriterFixturePresenter()
    let model = try await streamingWriterFixture(channel, presenter: presenter, pacing: pacing)
    defer { pacing.cancel(); model.disconnect() }
    let down = try Input.pointer(action: 1, x: 10, y: 10)
    let older = try Input.pointer(action: 0, x: 100, y: 100)
    let newest = try Input.pointer(action: 0, x: 200, y: 200)
    try #require(model.send(down))
    try await waitForWriter { channel.writeIsBlocked }
    try #require(model.send(older))
    channel.releaseWrite()
    try await waitForWriter { pacing.reached }
    try await matureHeartbeatWhileWriterIsHeld { pacing.isWaiting }
    try #require(model.send(newest))
    pacing.release()
    try await waitForWriter { channel.snapshot().contains { $0.kind == .heartbeat } }
    try await waitForWriter { channel.inputSnapshot().count >= 2 }
    // Held-button down, then the latest move, across a real heartbeat. A
    // pop-before-wait writer would transmit the obsolete `older` position.
    #expect(channel.inputSnapshot() == [down, newest])
    #expect(channel.snapshot().first?.kind == .hello)
    #expect(channel.snapshot().filter { $0.kind == .hello }.count == 1)
    #expect(channel.readerIsBlocked && channel.maximumConcurrentWrites == 1)
}

@Test @MainActor func blockedWriterCoalescesDragBurstWithoutCrossingActionBarriers() async throws {
    let channel = WriterFixtureChannel(), presenter = WriterFixturePresenter()
    let model = try await streamingWriterFixture(channel, presenter: presenter)
    defer { model.disconnect() }
    let down = try Input.pointer(action: 1, x: 10, y: 10)
    try #require(model.send(down))
    try await waitForWriter { channel.writeIsBlocked }
    for position in 0..<1024 { try #require(model.send(Input.pointer(action: 0, x: UInt16(position), y: 200))) }
    let latest = try Input.pointer(action: 0, x: 1023, y: 200)
    let up = try Input.pointer(action: 2, x: 1023, y: 200)
    let keyDown = try Input.key(down: true, scan: 0x1e, extended: false)
    let keyUp = try Input.key(down: false, scan: 0x1e, extended: false)
    let wheel = try Input.wheel(vertical: 120, horizontal: 0)
    let middle = try Input.pointer(action: 0, x: 2000, y: 200)
    let last = try Input.pointer(action: 0, x: 3000, y: 200)
    for packet in [up, keyDown, middle, keyUp, wheel, last] { try #require(model.send(packet)) }
    #expect(channel.inputSnapshot().isEmpty)
    #expect(channel.snapshot().first?.kind == .hello)
    #expect(channel.snapshot().filter { $0.kind == .hello }.count == 1)
    try await matureHeartbeatWhileWriterIsHeld { channel.writeIsBlocked }
    channel.releaseWrite()
    try await waitForWriter { channel.snapshot().contains { $0.kind == .heartbeat } }
    let expected = [down, latest, up, keyDown, middle, keyUp, wheel, last]
    try await waitForWriter { channel.inputSnapshot().count >= expected.count }
    #expect(channel.inputSnapshot() == expected)
    #expect(!model.inputRecovery && model.phase == .streaming)
    #expect(channel.readerIsBlocked && channel.maximumConcurrentWrites == 1)
    let inputTimes = channel.inputTimestamps()
    for index in 1..<inputTimes.count { #expect(inputTimes[index] - inputTimes[index - 1] >= .milliseconds(2)) }
}

@Test @MainActor func revocationDuringPacingDropsOldMovesAndKeepsReleaseBeforeRecovery() async throws {
    let channel = WriterFixtureChannel(), pacing = InputPacingFixture(), presenter = WriterFixturePresenter()
    let model = try await streamingWriterFixture(channel, presenter: presenter, pacing: pacing)
    defer { pacing.cancel(); model.disconnect() }
    let down = try Input.pointer(action: 1, x: 10, y: 10)
    let revoked = try Input.pointer(action: 0, x: 100, y: 100)
    let recovered = try Input.pointer(action: 0, x: 200, y: 200)
    try #require(model.send(down))
    try await waitForWriter { channel.writeIsBlocked }
    try #require(model.send(revoked))
    channel.releaseWrite()
    try await waitForWriter { pacing.reached }
    let oldRevision = model.inputRevision
    model.releaseInput()
    #expect(model.inputRevision != oldRevision && model.inputRecovery)
    #expect(!model.send(revoked))
    model.recoverInput()
    try #require(model.send(recovered))
    pacing.release()
    try await waitForWriter { channel.inputSnapshot().count >= 3 }
    #expect(channel.inputSnapshot() == [down, Packet(kind: .releaseAll), recovered])
    #expect(channel.snapshot().first?.kind == .hello)
    #expect(channel.snapshot().filter { $0.kind == .hello }.count == 1)
    #expect(channel.readerIsBlocked && channel.maximumConcurrentWrites == 1)
}
