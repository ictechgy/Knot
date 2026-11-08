import Foundation
import CoreVideo
import AppKit
import Testing
@testable import KnotNativeCore
@testable import KnotNativePreview

/// Only fresh authored frames and in-memory sidecars. No devices or sockets.
private final class Video18Channel: NativeChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var waiter: (Int, CheckedContinuation<Data, any Error>)?
    private var closed = false
    private var sent: [Packet] = []
    func start() async throws {}
    func readExactly(_ count: Int, timeout: Duration) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed { lock.unlock(); continuation.resume(throwing: NativeFailure.transport) }
            else if bytes.count >= count {
                let value = Data(bytes.prefix(count)); bytes.removeFirst(count); lock.unlock(); continuation.resume(returning: value)
            } else { waiter = (count, continuation); lock.unlock() }
        }
    }
    func send(_ packet: Packet) async throws { lock.withLock { sent.append(packet) } }
    func feed(_ data: Data) {
        lock.lock(); guard !closed else { lock.unlock(); return }
        precondition(bytes.count + data.count <= 8192); bytes.append(data)
        if let (count, continuation) = waiter, bytes.count >= count {
            waiter = nil; let value = Data(bytes.prefix(count)); bytes.removeFirst(count)
            lock.unlock(); continuation.resume(returning: value)
        } else { lock.unlock() }
    }
    func close() {
        lock.lock(); closed = true; let pending = waiter; waiter = nil; lock.unlock()
        pending?.1.resume(throwing: NativeFailure.transport)
    }
    var waiting: Bool { lock.withLock { waiter != nil } }
    var isClosed: Bool { lock.withLock { closed } }
    var writes: [Packet] { lock.withLock { sent } }
}
@MainActor private final class Video18Presenter: NativePresenter {
    var onFailure: (() -> Void)?
    var clears = 0, presentations = 0
    func display(_ image: CVPixelBuffer) -> PresentationResult { presentations += 1; return .presented }
    func clear() { clears += 1 }
    func forgetHeldKeys() {}
}
private actor Video18AudioSink: NativeAudioPlaying {
    func start(muted: Bool) {}
    func enqueue(_ pcm: NativeAudioPCM) {}
    func setMuted(_ muted: Bool) {}
    func stop() {}
}
private func video18SessionStatus(_ operation: VideoControlOperation, id: UInt64 = 1, epoch: UInt64 = 0,
                                  outcome: VideoControlOutcome = .applied, paused: Bool = true, next: UInt64 = 0) -> Packet {
    var bytes = Data([1, operation.rawValue]); bytes.appendBE(id); bytes.appendBE(epoch)
    bytes.append(contentsOf: [outcome.rawValue, 0, paused ? 1 : 0])
    bytes.appendBE(UInt32(64)); bytes.appendBE(UInt32(64)); bytes.appendBE(UInt32(30)); bytes.appendBE(UInt32(1_000_000)); bytes.appendBE(next)
    return Packet(kind: .videoControlStatus, payload: bytes)
}
@MainActor private func video18Wait(_ predicate: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
    try #require(predicate())
}
@MainActor private func video18Start(channel: Video18Channel, audio: Video18Channel? = nil,
                                             makeDecoder: @escaping @MainActor (VideoProfile) -> any NativeVideoDecoding = { NativeDecoder(width: $0.width, height: $0.height) }) async throws -> (SessionModel, Video18Presenter) {
    let presenter = Video18Presenter()
    let audioFactory: (@MainActor @Sendable (Invitation) throws -> NativeAudioSession)?
    if let audio {
        audioFactory = { invitation in
            try NativeAudioSession(invitation: invitation, makeChannel: { _ in audio }, makePlayer: { Video18AudioSink() })
        }
    } else { audioFactory = nil }
    let model = SessionModel(makeDecoder: makeDecoder, makeChannel: { _ in channel }, makeAudioSession: audioFactory,
                             makeClipboard: { ClipboardModel(send: $0, readText: { nil }, writeText: { _ in false }) })
    model.surface = presenter
    let json = try JSONSerialization.data(withJSONObject: ["v": 1, "address": "192.168.50.12", "port": 48631,
        "certificateSHA256": String(repeating: "a", count: 64), "token": Invitation.encodeBase64URL(Data(repeating: 5, count: 32))])
    model.review("knot-native:v1:" + Invitation.encodeBase64URL(json)); model.connect()
    try await video18Wait { model.phase == .approval && channel.waiting }
    let token = Invitation.encodeBase64URL(Data(repeating: 8, count: 32))
    let ready = Data((#"{"v":1,"codec":"h264-annexb","width":64,"height":64,"fps":30,"bitrate":1000000,"hardwareEncoder":true,"qualityVersion":1,"videoControlVersion":1,"clipboardVersion":1,"filesVersion":2,"filePort":48634,"fileToken":""# + token + #"","fileRootName":"Fresh fixture"}"#).utf8)
    channel.feed(Packet(kind: .ready, payload: ready).encoded)
    try await video18Wait { model.phase == .decoding }
    var pixel: CVPixelBuffer?
    try #require(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    model.presentDecodedImage(try #require(pixel))
    try #require(model.phase == .streaming)
    return (model, presenter)
}

@Test @MainActor func sessionVideoPauseKeepsStreamingIdentityImageFilesAudioAndControlWriter() async throws {
    let channel = Video18Channel(), audioChannel = Video18Channel()
    let (model, presenter) = try await video18Start(channel: channel, audio: audioChannel)
    defer { model.disconnect() }
    let control = try #require(model.videoControl), files = try #require(model.files), audio = try #require(model.audio), clipboard = try #require(model.clipboard)
    let revision = model.inputRevision
    let hello = try #require(channel.writes.first)
    #expect(try StrictJSON.object(hello.payload, keys: ["v", "token", "name", "filesVersion", "videoControlVersion"], limit: 4096).integer("videoControlVersion") == 1)
    control.pause()
    let key = try Input.key(down: true, scan: 0x1e, extended: false)
    #expect(control.isApplying && !model.send(key))
    #expect(!model.prepareClipboardGesture())
    try await video18Wait { channel.writes.contains { $0.kind == .videoControl } }
    let nonHeartbeat = channel.writes.filter { $0.kind != .heartbeat }.map(\.kind)
    #expect(nonHeartbeat.suffix(2) == [.releaseAll, .videoControl])
    channel.feed(video18SessionStatus(.pause, outcome: .preparing, paused: false).encoded + video18SessionStatus(.pause).encoded)
    try await video18Wait { control.isPaused && !control.isApplying }
    #expect(model.phase == .streaming && model.active && model.inputRevision > revision)
    #expect(model.files === files && model.audio === audio && model.clipboard === clipboard)
    #expect(!channel.isClosed && !audioChannel.isClosed && presenter.clears == 0 && presenter.presentations == 1)
    #expect(!model.sendCommittedText("never replay"))
    model.recoverInput(); #expect(control.isPaused && !control.isApplying)
    model.setFileUIInputSuspended(true); model.setFileUIInputSuspended(false)
    #expect(model.files === files && control.isPaused)
}

@Test @MainActor func sessionIdlePauseConsumesReturnGestureQueuesResumeAndDisconnectRetiresIntent() async throws {
    let channel = Video18Channel()
    let (model, presenter) = try await video18Start(channel: channel)
    defer { model.disconnect() }
    let control = try #require(model.videoControl)
    let now = ContinuousClock.now
    model.idleVideoMinutes = 1
    model.setApplicationActive(false, now: now - .seconds(61))
    model.acceptedLocalInteraction(now: now - .seconds(61))
    #expect(model.checkDeadlines(now: now))
    try await video18Wait { channel.writes.contains { $0.kind == .videoControl } }
    #expect(control.isApplying)
    model.setApplicationActive(true)
    model.recoverInput()
    #expect(!model.send(try Input.pointer(action: 1, x: 42, y: 42)))
    channel.feed(video18SessionStatus(.pause, outcome: .preparing, paused: false).encoded + video18SessionStatus(.pause).encoded)
    try await video18Wait { control.isPaused }
    #expect(control.isAutomaticallyPaused && model.phase == .streaming && presenter.clears == 0)
    let writesBefore = channel.writes.count
    model.disconnect()
    control.tick(); control.resumeAfterLocalUse()
    #expect(model.phase == .idle && model.videoControl == nil && channel.isClosed && channel.writes.count == writesBefore)
}

@Test @MainActor func sessionPendingVideoHasThirtySecondCapAndResetImageHasFifteenSecondCap() async throws {
    for reset in [false, true] {
        let channel = Video18Channel()
        let (model, presenter) = try await video18Start(channel: channel)
        defer { model.disconnect() }
        let control = try #require(model.videoControl)
        #expect(control.requestProfile(width: 1920, height: 1080, fps: 30, bitrate: 5_000_000))
        try await video18Wait { channel.writes.contains { $0.kind == .videoControl } }
        if reset {
            channel.feed(video18SessionStatus(.profile, outcome: .preparing, paused: false).encoded + video18SessionStatus(.profile, epoch: 1, paused: false, next: 1).encoded)
            try await video18Wait { control.resetBegan != nil }
            #expect(model.phase == .streaming && control.isApplying && presenter.clears == 0)
            #expect(!model.checkDeadlines(now: try #require(control.resetBegan) + .seconds(15)))
        } else {
            channel.feed(video18SessionStatus(.profile, outcome: .preparing, paused: false).encoded)
            try await video18Wait { channel.waiting }
            #expect(!model.checkDeadlines(now: try #require(control.pendingBegan) + .seconds(30)))
        }
        #expect(model.phase == .failed && channel.isClosed && model.videoControl == nil)
        #expect(model.diagnostics.firstIssue?.issue == (reset ? .firstImageDeadline : .protocolFailure))
    }
}

@Test(arguments: [0, 1, 2, 3]) @MainActor
func activeApplicationIdlePauseConsumesLocalUseAndResumesWithoutReplaying(_ gesture: Int) async throws {
    let channel = Video18Channel()
    let (model, _) = try await video18Start(channel: channel)
    defer { model.disconnect() }
    let control = try #require(model.videoControl)
    model.idleVideoMinutes = 1; model.idleVideoBackgroundOnly = false
    let now = ContinuousClock.now
    model.setApplicationActive(true, now: now - .seconds(61))
    model.acceptedLocalInteraction(now: now - .seconds(61))
    #expect(model.checkDeadlines(now: now))
    try await video18Wait { channel.writes.contains { $0.kind == .videoControl } }
    channel.feed(video18SessionStatus(.pause, outcome: .preparing, paused: false).encoded + video18SessionStatus(.pause).encoded)
    try await video18Wait { control.isPaused && !control.isApplying }
    #expect(control.isAutomaticallyPaused)
    switch gesture {
    case 0: #expect(model.consumeVideoResumeGesture()) // key/overlay entry
    case 1: #expect(!model.send(try Input.pointer(action: 1, x: 12, y: 12)))
    case 2: #expect(!model.sendCommittedText("consume, never replay"))
    default: #expect(!model.prepareClipboardGesture())
    }
    // The production cooldown is real; no app/system focus adapter is invoked.
    try await Task.sleep(for: .milliseconds(2050))
    control.tick()
    try await video18Wait { channel.writes.filter { $0.kind == .videoControl }.count == 2 }
    let requests = try channel.writes.filter { $0.kind == .videoControl }.map { try VideoControlRequest($0.payload).operation }
    #expect(requests == [.pause, .resume])
    #expect(channel.writes.allSatisfy { [.hello, .heartbeat, .releaseAll, .videoControl].contains($0.kind) })
}

@Test @MainActor func idleMonitorUsesOnlyInjectedApplicationNotificationsAndNeverStartsAConnection() {
    let model = SessionModel(), center = NotificationCenter(), monitor = NativeVideoIdleMonitor()
    monitor.bind(model, notificationCenter: center, initiallyActive: true)
    center.post(name: NSApplication.didResignActiveNotification, object: nil)
    center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    #expect(model.phase == .idle && model.videoControl == nil && !model.active)
    model.idleVideoMinutes = 2
    #expect(model.idleVideoMinutes == 10 && model.idleVideoBackgroundOnly)
}

@Test @MainActor func legacyHostRejectingNewHelloShowsBothAppsUpdateGuidanceWithoutReusingGrant() async throws {
    let channel = Video18Channel()
    let model = SessionModel(makeChannel: { _ in channel })
    defer { model.disconnect() }
    let json = try JSONSerialization.data(withJSONObject: ["v": 1, "address": "192.168.50.12", "port": 48631,
        "certificateSHA256": String(repeating: "a", count: 64), "token": Invitation.encodeBase64URL(Data(repeating: 6, count: 32))])
    model.review("knot-native:v1:" + Invitation.encodeBase64URL(json)); model.connect()
    try await video18Wait { model.phase == .approval && channel.waiting }
    channel.feed(Packet(kind: .error, payload: Data(#"{"code":"protocol"}"#.utf8)).encoded)
    try await video18Wait { model.phase == .failed }
    #expect(model.status.contains("Mac") && model.status.contains("Windows") && model.status.contains("Native.18"))
    #expect(channel.writes.filter { $0.kind == .hello }.count == 1 && model.invitation == nil && !model.hasPendingReconnect)
}

@MainActor private final class Video18FakeDecoder: NativeVideoDecoding {
    var onImage: ((CVPixelBuffer) -> Void)?
    var onFailure: (() -> Void)?
    var onPerformanceEvent: ((DecodePerformanceEvent) -> Void)?
    var holdDrain = false
    private var drain: CheckedContinuation<Void, any Error>?
    private(set) var stopped = false
    var waiting: Bool { drain != nil }
    let record: (String) -> Void
    let name: String
    init(_ name: String, record: @escaping (String) -> Void = { _ in }) { self.name = name; self.record = record }
    func decode(_ unit: AccessUnit) async throws {}
    func waitForPendingFrames() async throws {
        try Task.checkCancellation()
        guard holdDrain else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                drain = continuation
            }
        } onCancel: { [weak self] in Task { @MainActor in self?.cancelDrain() } }
    }
    func completeDrain() { let pending = drain; drain = nil; pending?.resume() }
    private func cancelDrain() { let pending = drain; drain = nil; pending?.resume(throwing: CancellationError()) }
    func stop() { stopped = true; record("stop:" + name); cancelDrain() }
}
@MainActor private final class Video18DecoderFactory {
    var decoders: [Video18FakeDecoder] = []
    var events: [String] = []
    func make(_ profile: VideoProfile) -> any NativeVideoDecoding {
        let name = String(decoders.count)
        let decoder = Video18FakeDecoder(name, record: { [weak self] in self?.events.append($0) })
        events.append("create:" + name); decoders.append(decoder); return decoder
    }
}
@MainActor private final class Video18VirtualDeadline {
    private(set) var duration: Duration?
    private var continuation: CheckedContinuation<Void, any Error>?
    var waiting: Bool { continuation != nil }
    func wait(_ duration: Duration) async throws {
        self.duration = duration
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
            }
        } onCancel: { [weak self] in Task { @MainActor in self?.finish(cancelled: true) } }
    }
    func finish(cancelled: Bool = false) {
        let pending = continuation; continuation = nil
        if cancelled { pending?.resume(throwing: CancellationError()) } else { pending?.resume() }
    }
}

@Test @MainActor func videoControlDrainsBeforeSerialDecoderReplacementAndRejectsStaleEpochCallbacks() async throws {
    let channel = Video18Channel(), factory = Video18DecoderFactory()
    let (model, presenter) = try await video18Start(channel: channel, makeDecoder: { factory.make($0) })
    defer { model.disconnect() }
    let control = try #require(model.videoControl), old = try #require(factory.decoders.first)
    old.holdDrain = true
    let staleImage = old.onImage, staleFailure = old.onFailure, stalePerformance = old.onPerformanceEvent
    #expect(control.requestProfile(width: 1920, height: 1080, fps: 60, bitrate: 10_000_000))
    try await video18Wait { channel.writes.contains { $0.kind == .videoControl } }
    channel.feed(video18SessionStatus(.profile, outcome: .preparing, paused: false).encoded + video18SessionStatus(.profile, epoch: 1, paused: false, next: 1).encoded)
    try await video18Wait { old.waiting }
    #expect(factory.decoders.count == 1 && !old.stopped && presenter.clears == 0 && model.phase == .streaming)
    old.completeDrain()
    try await video18Wait { factory.decoders.count == 2 && control.resetBegan != nil }
    #expect(factory.events == ["create:0", "stop:0", "create:1"] && old.stopped)
    var pixel: CVPixelBuffer?
    try #require(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    let image = try #require(pixel)
    staleImage?(image); staleFailure?(); stalePerformance?(.completed(dropped: false))
    #expect(presenter.presentations == 1 && model.phase == .streaming && control.isApplying)
    factory.decoders[1].onImage?(image)
    #expect(presenter.presentations == 2 && !control.isApplying && presenter.clears == 0)
    model.disconnect()
    factory.decoders[1].onImage?(image); factory.decoders[1].onFailure?()
    #expect(model.phase == .idle && presenter.presentations == 2 && factory.decoders.count == 2)
}

@Test @MainActor func videoControlDisconnectDuringDecoderDrainCannotResurrectVideoOrSession() async throws {
    let channel = Video18Channel(), factory = Video18DecoderFactory()
    let (model, presenter) = try await video18Start(channel: channel, makeDecoder: { factory.make($0) })
    let control = try #require(model.videoControl), old = try #require(factory.decoders.first)
    old.holdDrain = true
    #expect(control.requestProfile(width: 1920, height: 1080, fps: 30, bitrate: 5_000_000))
    try await video18Wait { channel.writes.contains { $0.kind == .videoControl } }
    channel.feed(video18SessionStatus(.profile, outcome: .preparing, paused: false).encoded + video18SessionStatus(.profile, epoch: 1, paused: false, next: 1).encoded)
    try await video18Wait { old.waiting }
    model.systemWillSleep()
    old.completeDrain(); control.resumeAfterLocalUse()
    for _ in 0..<20 { await Task.yield() }
    #expect(model.phase == .idle && model.isSystemSleeping && model.videoControl == nil && channel.isClosed)
    #expect(factory.decoders.count == 1 && old.stopped && presenter.clears == 1)
    model.systemDidWake()
    #expect(model.phase == .idle && !model.hasPendingReconnect && factory.decoders.count == 1)
}

@Test @MainActor func videoControlDecoderDrainUsesFiveSecondInjectedDeadlineAndCancelsWaiter() async throws {
    let decoder = Video18FakeDecoder("held"), deadline = Video18VirtualDeadline()
    decoder.holdDrain = true
    let task = Task { try await NativeVideoDecoderDrain.wait(decoder, waitForDeadline: { try await deadline.wait($0) }) }
    try await video18Wait { decoder.waiting && deadline.waiting }
    #expect(deadline.duration == .seconds(5))
    deadline.finish()
    do { try await task.value; Issue.record("Overdue decoder drain completed") }
    catch { #expect(error as? NativeFailure == .decoder) }
    #expect(!decoder.waiting && !deadline.waiting)
    let nextDeadline = Video18VirtualDeadline()
    let cancelled = Task { try await NativeVideoDecoderDrain.wait(decoder, waitForDeadline: { try await nextDeadline.wait($0) }) }
    try await video18Wait { decoder.waiting && nextDeadline.waiting }
    cancelled.cancel()
    do { try await cancelled.value; Issue.record("Cancelled decoder drain completed") } catch {}
    #expect(!decoder.waiting && !nextDeadline.waiting)
}
