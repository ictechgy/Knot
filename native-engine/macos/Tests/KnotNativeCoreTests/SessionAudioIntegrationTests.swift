import Foundation
import CoreVideo
import Testing
@testable import KnotNativeCore
@testable import KnotNativePreview

private func integrationAudioInvitationCode() throws -> String {
    let bytes = try JSONSerialization.data(withJSONObject: ["v": 1, "address": "192.168.50.12", "port": 48631,
        "certificateSHA256": String(repeating: "b", count: 64),
        "token": Invitation.encodeBase64URL(Data(repeating: 9, count: 32))])
    return "knot-native:v1:" + Invitation.encodeBase64URL(bytes)
}

private func integrationAudioReady() -> Data {
    NativeAudioPacket(kind: .ready,
        payload: Data(#"{"v":1,"codec":"pcm-s16le","sampleRate":48000,"channels":2}"#.utf8)).encoded
}

/// Bounded, authored in-memory bytes only. The same fake stages main Ready and
/// audio Ready independently, without sockets, devices, settings or credentials.
private final class IntegrationAudioChannel: NativeChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data
    private var pending: (Int, CheckedContinuation<Data, any Error>)?
    private var closed = false
    private var sent: [Kind] = []
    init(_ bytes: Data = Data()) { self.bytes = bytes }
    func start() async throws {}
    func readExactly(_ count: Int, timeout: Duration) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed { lock.unlock(); continuation.resume(throwing: NativeFailure.transport) }
            else if bytes.count >= count {
                let result = Data(bytes.prefix(count)); bytes.removeFirst(count)
                lock.unlock(); continuation.resume(returning: result)
            } else { pending = (count, continuation); lock.unlock() }
        }
    }
    func send(_ packet: Packet) async throws { lock.withLock { sent.append(packet.kind) } }
    func feed(_ data: Data) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        precondition(bytes.count + data.count <= 4096)
        bytes.append(data)
        if let (count, continuation) = pending, bytes.count >= count {
            pending = nil
            let result = Data(bytes.prefix(count)); bytes.removeFirst(count)
            lock.unlock(); continuation.resume(returning: result)
        } else { lock.unlock() }
    }
    func close() {
        lock.lock(); closed = true; let waiting = pending; pending = nil; lock.unlock()
        waiting?.1.resume(throwing: NativeFailure.transport)
    }
    var isClosed: Bool { lock.withLock { closed } }
    var waiting: Bool { lock.withLock { pending != nil } }
    var writes: [Kind] { lock.withLock { sent } }
}

private actor IntegrationAudioPlayer: NativeAudioPlaying {
    private(set) var started = false
    private(set) var stopped = false
    func start(muted: Bool) { started = true }
    func enqueue(_ pcm: NativeAudioPCM) {}
    func setMuted(_ muted: Bool) {}
    func stop() { stopped = true }
}

@MainActor private final class IntegrationAudioFactory {
    weak var parent: SessionModel?
    var phases: [SessionModel.Phase] = []
    var child: NativeAudioSession?
    var failCreation = false
    let channel: IntegrationAudioChannel
    let player = IntegrationAudioPlayer()
    init(bytes: Data) { channel = IntegrationAudioChannel(bytes) }
    func make(_ invitation: Invitation) throws -> NativeAudioSession {
        if let parent { phases.append(parent.phase) }
        if failCreation { throw NativeFailure.transport }
        let channel = channel, player = player
        let session = try NativeAudioSession(invitation: invitation,
            makeChannel: { _ in channel }, makePlayer: { player })
        child = session
        return session
    }
}

@MainActor private final class IntegrationAudioPresenter: NativePresenter {
    var onFailure: (() -> Void)?
    func display(_ image: CVPixelBuffer) -> PresentationResult { .presented }
    func clear() {}
    func forgetHeldKeys() {}
}

@MainActor private func integrationAudioWait(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
    try #require(await condition())
}

@MainActor private func integrationAudioApprove(_ channel: IntegrationAudioChannel, _ model: SessionModel) async throws {
    try await integrationAudioWait { model.phase == .approval && channel.waiting }
    let ready = Packet(kind: .ready,
        payload: Data(#"{"v":1,"codec":"h264-annexb","width":64,"height":64,"fps":30,"bitrate":1000000,"hardwareEncoder":true}"#.utf8))
    channel.feed(ready.encoded)
    try await integrationAudioWait { model.phase == .decoding }
}

private func integrationAudioPixel() throws -> CVPixelBuffer {
    var image: CVPixelBuffer?
    try #require(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &image) == kCVReturnSuccess)
    return try #require(image)
}

@Test @MainActor func sessionCreatesAudioOnlyAfterMainReadyAndDisconnectStopsItsChild() async throws {
    let main = IntegrationAudioChannel(), factory = IntegrationAudioFactory(bytes: integrationAudioReady())
    let model = SessionModel(makeChannel: { _ in main }, makeAudioSession: { try factory.make($0) })
    factory.parent = model
    defer { model.disconnect() }
    model.review(try integrationAudioInvitationCode())
    #expect(factory.phases.isEmpty && model.audio == nil)
    model.connect()
    try await integrationAudioWait { model.phase == .approval && main.waiting }
    #expect(factory.phases.isEmpty && model.audio == nil && main.writes == [.hello])
    try await integrationAudioApprove(main, model)
    try await integrationAudioWait { model.audio?.isAvailable == true && factory.channel.waiting }
    let child = try #require(factory.child)
    #expect(factory.phases == [.decoding] && model.audio === child)
    #expect(await factory.player.started)
    model.disconnect()
    #expect(model.audio == nil && model.phase == .idle && main.isClosed)
    // Closing the child's channel is synchronous; its actor sink retires async.
    #expect(child.state == .stopped && !child.isAvailable && factory.channel.isClosed)
    try await integrationAudioWait { await factory.player.stopped }
}

@Test @MainActor func unavailableAudioAndAudioFactoryFailureKeepMainMediaStreaming() async throws {
    for failCreation in [false, true] {
        let error = NativeAudioPacket(kind: .error, payload: Data(#"{"code":"unavailable"}"#.utf8)).encoded
        let main = IntegrationAudioChannel(), factory = IntegrationAudioFactory(bytes: error)
        factory.failCreation = failCreation
        let presenter = IntegrationAudioPresenter()
        let model = SessionModel(makeChannel: { _ in main }, makeAudioSession: { try factory.make($0) })
        factory.parent = model; model.surface = presenter
        defer { model.disconnect() }
        model.review(try integrationAudioInvitationCode()); model.connect()
        try await integrationAudioApprove(main, model)
        if !failCreation { try await integrationAudioWait { model.audio?.state == .unavailable } }
        model.presentDecodedImage(try integrationAudioPixel())
        #expect(factory.phases == [.decoding] && model.phase == .streaming && model.active && !main.isClosed)
        #expect(model.status.hasPrefix("Receiving the host desktop."))
        #expect(!(await factory.player.started))
        if failCreation { #expect(model.audio == nil) }
        else { #expect(model.audio?.isAvailable == false && factory.channel.isClosed) }
        model.disconnect()
    }
}

@Test @MainActor func defaultSessionFactoryLeavesAudioSidecarAbsentAfterMainReady() async throws {
    let main = IntegrationAudioChannel()
    let presenter = IntegrationAudioPresenter()
    let model = SessionModel(makeChannel: { _ in main })
    model.surface = presenter
    defer { model.disconnect() }
    model.review(try integrationAudioInvitationCode()); model.connect()
    try await integrationAudioApprove(main, model)
    model.presentDecodedImage(try integrationAudioPixel())
    #expect(model.phase == .streaming && model.audio == nil && !main.isClosed)
}
