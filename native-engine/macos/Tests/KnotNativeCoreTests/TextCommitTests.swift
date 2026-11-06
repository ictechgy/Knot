import Foundation
import CoreVideo
import Testing
import KnotNativeCore
@testable import KnotNativePreview

/// Fresh in-memory transport only: no Network connection, certificate, window,
/// user text, clipboard, capture, or AppKit input source is consulted.
private final class TextCommitChannel: NativeChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [Data] = []
    private var reader: CheckedContinuation<Data, any Error>?
    private var blocked: (Packet, CheckedContinuation<Void, any Error>)?
    private var blockInput: Bool
    private var closed = false
    private var sent: [Packet] = []
    init(blockInput: Bool = false) { self.blockInput = blockInput }
    func start() async throws {}
    func readExactly(_ count: Int, timeout: Duration) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed { lock.unlock(); continuation.resume(throwing: NativeFailure.transport) }
            else if !reads.isEmpty {
                let data = reads.removeFirst(); lock.unlock()
                if data.count == count { continuation.resume(returning: data) }
                else { continuation.resume(throwing: NativeFailure.malformed) }
            } else { reader = continuation; lock.unlock() }
        }
    }
    func send(_ packet: Packet) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            if closed { lock.unlock(); continuation.resume(throwing: NativeFailure.transport) }
            else if packet.kind != .hello && packet.kind != .heartbeat && blockInput {
                blockInput = false; blocked = (packet, continuation); lock.unlock()
            } else { sent.append(packet); lock.unlock(); continuation.resume() }
        }
    }
    func feed(_ data: Data) {
        lock.lock(); let pending = reader; reader = nil
        if pending == nil { reads.append(data) }
        lock.unlock(); pending?.resume(returning: data)
    }
    var writeBlocked: Bool { lock.lock(); defer { lock.unlock() }; return blocked != nil }
    // Heartbeats share the production writer but are not input. They must not
    // satisfy an input-count wait or consume the deliberately blocked input.
    func snapshot() -> [Packet] {
        lock.lock(); defer { lock.unlock() }
        return sent.filter { $0.kind != .heartbeat }
    }
    func releaseWrite() {
        lock.lock(); let pending = blocked; blocked = nil
        if let pending { sent.append(pending.0) }
        lock.unlock(); pending?.1.resume()
    }
    func close() {
        lock.lock(); guard !closed else { lock.unlock(); return }
        closed = true
        let read = reader, write = blocked; reader = nil; blocked = nil; reads = []
        lock.unlock()
        read?.resume(throwing: NativeFailure.transport)
        write?.1.resume(throwing: NativeFailure.transport)
    }
}

@MainActor private final class TextCommitPresenter: NativePresenter {
    var onFailure: (() -> Void)?
    private(set) var releases = 0
    func display(_ image: CVPixelBuffer) -> PresentationResult { .presented }
    func clear() {}
    func forgetHeldKeys() { releases += 1 }
}

@MainActor private func waitForTextCommit(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    try #require(predicate())
}

@MainActor private func streamingTextCommit(_ channel: TextCommitChannel,
                                            presenter: TextCommitPresenter) async throws -> SessionModel {
    let model = SessionModel(makeChannel: { _ in channel }); model.surface = presenter
    let token = Invitation.encodeBase64URL(Data(repeating: 23, count: 32))
    let json = "{\"v\":1,\"address\":\"10.0.0.1\",\"port\":48631,\"certificateSHA256\":\"\(String(repeating: "a", count: 64))\",\"token\":\"\(token)\"}"
    model.review("knot-native:v1:" + Invitation.encodeBase64URL(Data(json.utf8))); model.connect()
    try await waitForTextCommit { model.phase == .approval }
    let ready = Packet(kind: .ready, payload: Data("{\"v\":1,\"codec\":\"h264-annexb\",\"width\":64,\"height\":64,\"fps\":60,\"bitrate\":1000000,\"hardwareEncoder\":true}".utf8))
    channel.feed(Data(ready.encoded.prefix(5))); channel.feed(ready.payload)
    try await waitForTextCommit { model.phase == .decoding }
    var pixel: CVPixelBuffer?
    try #require(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    model.presentDecodedImage(try #require(pixel))
    try #require(model.phase == .streaming)
    // Exercise the same protocol noise that can precede input on a busy CI
    // executor, without depending on the real two-second heartbeat timer.
    try await channel.send(Packet(kind: .heartbeat))
    return model
}

@Test(arguments: [String(repeating: "a", count: 513), String(repeating: "한", count: 342),
                  String(repeating: "😀", count: 257), "fresh\0synthetic"])
@MainActor func committedTextRejectsOversizeAndNulWithVisibleRecovery(_ text: String) async throws {
    let channel = TextCommitChannel(), presenter = TextCommitPresenter()
    let model = try await streamingTextCommit(channel, presenter: presenter)
    defer { model.disconnect() }
    let revision = model.inputRevision
    #expect(!model.sendCommittedText(text))
    #expect(model.inputRecovery && model.inputRevision != revision && presenter.releases == 1)
    #expect(NativeCopy.status(model.status) == "긴 글이나 지원하지 않는 문자는 전달하지 못했어요. 화면을 클릭한 뒤 글을 나누어 입력해주세요.")
    try await waitForTextCommit { channel.snapshot().count == 2 }
    #expect(channel.snapshot().map(\.kind) == [.hello, .releaseAll])
    #expect(!model.sendCommittedText("fresh retry without click"))
}

@Test @MainActor func committedTextAccepts256EmojiAndTreatsEmptyAsNoop() async throws {
    let channel = TextCommitChannel(), presenter = TextCommitPresenter()
    let model = try await streamingTextCommit(channel, presenter: presenter)
    defer { model.disconnect() }
    let revision = model.inputRevision, status = model.status
    #expect(model.sendCommittedText(""))
    #expect(model.inputRevision == revision && model.status == status && !model.inputRecovery && presenter.releases == 0)
    let text = String(repeating: "😀", count: 256)
    #expect(model.sendCommittedText(text))
    try await waitForTextCommit { channel.snapshot().count == 2 }
    #expect(channel.snapshot().last == Packet(kind: .text, payload: Data(text.utf8)))
    #expect(!model.inputRecovery && model.inputRevision == revision && presenter.releases == 0)
}

@Test @MainActor func committedTextRejectionDropsQueuedTextAndReleasesBeforeClickRecovery() async throws {
    let channel = TextCommitChannel(blockInput: true), presenter = TextCommitPresenter()
    let model = try await streamingTextCommit(channel, presenter: presenter)
    defer { model.disconnect() }
    let held = try Input.key(down: true, scan: 0x1e, extended: false)
    try #require(model.send(held))
    try await waitForTextCommit { channel.writeBlocked }
    try #require(model.sendCommittedText("queued synthetic text"))
    #expect(!model.sendCommittedText(String(repeating: "a", count: 513)))
    let revision = model.inputRevision, reason = model.status
    #expect(!model.sendCommittedText("retry") && !model.sendCommittedText("\0"))
    #expect(model.inputRevision == revision && model.status == reason && presenter.releases == 1)
    #expect(model.sendCommittedText(""))
    #expect(model.inputRecovery && model.status == reason)
    model.recoverInput()
    try #require(model.sendCommittedText("다시"))
    channel.releaseWrite()
    try await waitForTextCommit { channel.snapshot().count == 4 }
    #expect(Array(channel.snapshot().dropFirst()) == [held, Packet(kind: .releaseAll), try Input.text("다시")])
    #expect(!model.inputRecovery && model.phase == .streaming)
}

@Test @MainActor func committedTextSaturationKeepsExistingPauseAndBoundedRelease() async throws {
    let channel = TextCommitChannel(blockInput: true), presenter = TextCommitPresenter()
    let model = try await streamingTextCommit(channel, presenter: presenter)
    defer { model.disconnect() }
    let held = try Input.key(down: true, scan: 0x1e, extended: false)
    try #require(model.send(held))
    try await waitForTextCommit { channel.writeBlocked }
    var accepted = 0
    for _ in 0..<512 { if model.sendCommittedText(String(repeating: "a", count: 512)) { accepted += 1 } }
    #expect(accepted == 31 && model.inputRecovery && presenter.releases == 1)
    let reason = model.status, revision = model.inputRevision
    #expect(reason == "Input paused after queue saturation. Click the desktop to resume.")
    #expect(!model.sendCommittedText("\0") && model.sendCommittedText(""))
    #expect(model.status == reason && model.inputRevision == revision)
    channel.releaseWrite()
    try await waitForTextCommit { channel.snapshot().count == 3 }
    #expect(Array(channel.snapshot().dropFirst()) == [held, Packet(kind: .releaseAll)])
}

@Test @MainActor func committedTextOutsideStreamingCannotChangeGuidanceOrAuthorizeInput() {
    let model = SessionModel(makeChannel: { _ in throw NativeFailure.transport })
    let status = model.status, revision = model.inputRevision
    #expect(!model.sendCommittedText(String(repeating: "a", count: 513)))
    #expect(!model.sendCommittedText("fresh valid text"))
    #expect(model.sendCommittedText(""))
    #expect(model.status == status && model.inputRevision == revision && !model.inputRecovery && !model.active)
}
