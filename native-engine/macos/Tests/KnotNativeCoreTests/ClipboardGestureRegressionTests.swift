import Foundation
import CoreVideo
import Testing
import KnotNativeCore
@testable import KnotNativePreview

/// Owns synthetic frames only; no network, AppKit events or clipboard adapter.
private final class ClipboardGestureChannel: NativeChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [Data] = []
    private var waiter: CheckedContinuation<Data, any Error>?
    private var closed = false
    private var sent: [Packet] = []
    func start() async throws {}
    func readExactly(_ count: Int, timeout: Duration) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed { lock.unlock(); continuation.resume(throwing: NativeFailure.transport) }
            else if !reads.isEmpty {
                let value = reads.removeFirst(); lock.unlock()
                if value.count == count { continuation.resume(returning: value) }
                else { continuation.resume(throwing: NativeFailure.malformed) }
            } else { waiter = continuation; lock.unlock() }
        }
    }
    func send(_ packet: Packet) async throws {
        try record(packet)
    }
    private func record(_ packet: Packet) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw NativeFailure.transport }; sent.append(packet)
    }
    func feed(_ bytes: Data) {
        lock.lock(); let pending = waiter; waiter = nil
        if pending == nil { reads.append(bytes) }
        lock.unlock(); pending?.resume(returning: bytes)
    }
    func inputPackets() -> [Packet] {
        lock.lock(); defer { lock.unlock() }; return sent.filter { $0.kind != .hello && $0.kind != .heartbeat }
    }
    func close() {
        lock.lock(); closed = true; let pending = waiter; waiter = nil; reads = []; lock.unlock()
        pending?.resume(throwing: NativeFailure.transport)
    }
}
@MainActor private final class ClipboardGesturePresenter: NativePresenter {
    var onFailure: (() -> Void)?
    var ownsControl = false
    func display(_ image: CVPixelBuffer) -> PresentationResult { .presented }
    func clear() {}
    func forgetHeldKeys() { ownsControl = false }
}
@MainActor private func awaitClipboardGesture(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    try #require(predicate())
}
@MainActor private func clipboardGestureSession(_ channel: ClipboardGestureChannel, _ presenter: ClipboardGesturePresenter) async throws -> SessionModel {
    let model = SessionModel(makeChannel: { _ in channel }); model.surface = presenter
    let token = Invitation.encodeBase64URL(Data(repeating: 17, count: 32))
    let json = "{\"v\":1,\"address\":\"10.0.0.1\",\"port\":48631,\"certificateSHA256\":\"\(String(repeating: "b", count: 64))\",\"token\":\"\(token)\"}"
    model.review("knot-native:v1:" + Invitation.encodeBase64URL(Data(json.utf8))); model.connect()
    try await awaitClipboardGesture { model.phase == .approval }
    let ready = Packet(kind: .ready, payload: Data(#"{"v":1,"codec":"h264-annexb","width":64,"height":64,"fps":60,"bitrate":1000000,"hardwareEncoder":true,"clipboardVersion":1}"#.utf8))
    channel.feed(Data(ready.encoded.prefix(5))); channel.feed(ready.payload)
    try await awaitClipboardGesture { model.phase == .decoding }
    var pixel: CVPixelBuffer?
    try #require(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    model.presentDecodedImage(try #require(pixel)); try #require(model.phase == .streaming)
    return model
}

@Test @MainActor func rejectedClipboardPasteReleasesRemoteControlWithoutPausingTyping() async throws {
    // These correspond to empty-pasteboard, NUL and oversized validation exits.
    for rejected: String? in [nil, "bad\0text", String(repeating: "x", count: ClipboardProtocol.maximumTextBytes + 1)] {
        let channel = ClipboardGestureChannel(), presenter = ClipboardGesturePresenter()
        let model = try await clipboardGestureSession(channel, presenter)
        defer { model.disconnect() }
        let control = try Input.key(down: true, scan: 0x1d, extended: false)
        try #require(model.send(control)); presenter.ownsControl = true
        try await awaitClipboardGesture { channel.inputPackets().count == 1 }
        let clipboard = ClipboardModel(send: { model.sendControl($0) }, readText: { rejected }, writeText: { _ in false })
        try #require(model.prepareClipboardGesture()); clipboard.pasteToRemote()
        #expect(!presenter.ownsControl && !model.inputRecovery && !clipboard.busy)
        // Command-up now has no local ownership. The queued remote release must
        // still clear the accepted Ctrl-down before ordinary lowercase typing.
        try #require(model.sendCommittedText("a"))
        try await awaitClipboardGesture { channel.inputPackets().count >= 3 }
        #expect(channel.inputPackets() == [control, Packet(kind: .releaseAll), try Input.text("a")])
    }
}

@Test @MainActor func clipboardPreparationReleasesKeysOnSendFailureAndPreservesExistingPause() async throws {
    let channel = ClipboardGestureChannel(), presenter = ClipboardGesturePresenter()
    let model = try await clipboardGestureSession(channel, presenter); defer { model.disconnect() }
    try #require(model.send(Input.key(down: true, scan: 0x1d, extended: false))); presenter.ownsControl = true
    try await awaitClipboardGesture { channel.inputPackets().count == 1 }
    let rejected = ClipboardModel(send: { _ in false }, readText: { "valid" }, writeText: { _ in false })
    try #require(model.prepareClipboardGesture()); rejected.copyFromRemote()
    try await awaitClipboardGesture { channel.inputPackets().count == 2 }
    #expect(channel.inputPackets().last?.kind == .releaseAll && !presenter.ownsControl && !model.inputRecovery && !rejected.busy)
    model.releaseInput(); try #require(model.inputRecovery)
    try #require(model.prepareClipboardGesture())
    #expect(model.inputRecovery && !model.sendCommittedText("still paused"))
}

@Test @MainActor func clipboardPreparationCancelsBusyCopyAndOrdersNewCopyAfterRelease() async throws {
    let channel = ClipboardGestureChannel(), presenter = ClipboardGesturePresenter()
    let model = try await clipboardGestureSession(channel, presenter); defer { model.disconnect() }
    let clipboard = try #require(model.clipboard)
    clipboard.copyFromRemote(); try #require(clipboard.busy)
    try await awaitClipboardGesture { channel.inputPackets().count == 1 }
    try #require(model.prepareClipboardGesture())
    #expect(!clipboard.busy && !model.inputRecovery)
    clipboard.copyFromRemote()
    try await awaitClipboardGesture { channel.inputPackets().count >= 3 }
    #expect(channel.inputPackets().map(\.kind) == [.clipboardRequest, .releaseAll, .clipboardRequest])
}
