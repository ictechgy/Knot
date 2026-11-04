import AppKit
import CoreVideo
import Foundation
import Testing
import KnotNativeCore
@testable import KnotNativePreview

/// Fresh in-memory transport only. Closing deliberately completes a blocked
/// write late, exercising the production session's generation/cancellation gate.
private final class WindowInertChannel: NativeChannel, @unchecked Sendable {
    private let lock = NSLock()
    private let blockedKind: Kind
    private var blockedWrite: CheckedContinuation<Void, any Error>?
    private var reader: CheckedContinuation<Data, any Error>?
    private var queued: [Data] = []
    private var attempts: [Kind] = []
    private var closes = 0
    private var closed = false
    init(blockedKind: Kind) { self.blockedKind = blockedKind }
    func start() async throws {}
    func readExactly(_ count: Int, timeout: Duration) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            lock.lock()
            if closed { lock.unlock(); continuation.resume(throwing: NativeFailure.transport) }
            else if !queued.isEmpty { let bytes = queued.removeFirst(); lock.unlock(); continuation.resume(returning: bytes) }
            else { reader = continuation; lock.unlock() }
        }
    }
    func send(_ packet: Packet) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            guard !closed else { lock.unlock(); continuation.resume(throwing: NativeFailure.transport); return }
            attempts.append(packet.kind)
            if packet.kind == blockedKind { blockedWrite = continuation; lock.unlock() }
            else { lock.unlock(); continuation.resume() }
        }
    }
    func feed(_ bytes: Data) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        let pending = reader; reader = nil
        if pending == nil { queued.append(bytes) }
        lock.unlock(); pending?.resume(returning: bytes)
    }
    func attemptedKinds() -> [Kind] { lock.lock(); defer { lock.unlock() }; return attempts }
    func closeCount() -> Int { lock.lock(); defer { lock.unlock() }; return closes }
    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true; closes += 1
        let pending = reader, blocked = blockedWrite
        reader = nil; blockedWrite = nil; queued = []
        lock.unlock()
        pending?.resume(throwing: NativeFailure.transport)
        blocked?.resume()
    }
}

@MainActor private final class WindowInertPresenter: NativePresenter {
    var onFailure: (() -> Void)?
    private(set) var cleared = 0
    private(set) var forgotten = 0
    func display(_ image: CVPixelBuffer) -> PresentationResult { .presented }
    func clear() { cleared += 1 }
    func forgetHeldKeys() { forgotten += 1 }
}

@MainActor private func freshUnshownWindow() -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                          styleMask: [.titled, .closable], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    return window
}

@MainActor private func beginWindowSession(_ transport: WindowInertChannel) -> SessionModel {
    let model = SessionModel(makeChannel: { _ in transport })
    let token = Invitation.encodeBase64URL(Data(repeating: 7, count: 32))
    let json = "{\"v\":1,\"address\":\"10.0.0.1\",\"port\":48631,\"certificateSHA256\":\"\(String(repeating: "a", count: 64))\",\"token\":\"\(token)\"}"
    model.review("knot-native:v1:" + Invitation.encodeBase64URL(Data(json.utf8)))
    model.connect()
    return model
}

@Suite(.serialized)
struct NativeWindowLifecycleTests {
    @Test @MainActor func owningCloseRevokesBlockedHelloBeforeReturning() async throws {
        let transport = WindowInertChannel(blockedKind: .hello), model = beginWindowSession(transport)
        let enrollment = EnrollmentModel(), state = NativeWindowState(), window = freshUnshownWindow()
        defer { model.disconnect(); window.close() }
        enrollment.code = "12345678"
        state.bindSession(model, enrollment: enrollment); state.attach(window)
        for _ in 0..<100 {
            if transport.attemptedKinds() == [.hello] { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.phase == .connecting && transport.attemptedKinds() == [.hello])
        // A transient probe detachment, as can occur during fullscreen, must
        // not remove the owning window's security close observer.
        state.attach(nil)
        let revision = model.inputRevision
        window.close() // Actual AppKit willClose notification, never ordered on screen.
        #expect(model.phase == .idle && !model.active && transport.closeCount() == 1)
        #expect(model.inputRevision == revision + 1 && enrollment.code.isEmpty)
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.phase == .idle && transport.attemptedKinds() == [.hello])
        // Closing clears the owned handler/observers; stale notifications may
        // neither revoke a later session nor change fullscreen state.
        let closedRevision = model.inputRevision
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        #expect(model.inputRevision == closedRevision && !state.isFullscreen)
    }

    @Test @MainActor func owningCloseAndExistingDesktopFallbackRevokeTransportOnce() async throws {
        let transport = WindowInertChannel(blockedKind: .hello), model = beginWindowSession(transport)
        let enrollment = EnrollmentModel(), state = NativeWindowState(), window = freshUnshownWindow()
        // Mount the real existing presenter solely to install its window
        // notifications. No frames, key events, input context or pixels are
        // delivered; SessionModel.surface stays unset in this fixture.
        let desktop = DesktopView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        desktop.model = model; window.contentView = desktop
        defer { model.disconnect(); desktop.model = nil; window.contentView = nil; window.close() }
        state.bindSession(model, enrollment: enrollment); state.attach(window)
        try #require(desktop.window === window)
        for _ in 0..<100 {
            if transport.attemptedKinds() == [.hello] { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.phase == .connecting && transport.attemptedKinds() == [.hello])
        let revision = model.inputRevision
        window.close()
        // Both production observers can call disconnect. Revocation remains
        // idempotent at the transport boundary, including a late Hello success.
        #expect(model.phase == .idle && !model.active && transport.closeCount() == 1)
        #expect(model.inputRevision >= revision + 2)
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.phase == .idle && transport.attemptedKinds() == [.hello] && transport.closeCount() == 1)
    }

    @Test @MainActor func owningCloseRevokesBlockedInputButOtherWindowAndFullscreenDoNot() async throws {
        let transport = WindowInertChannel(blockedKind: .key), model = beginWindowSession(transport)
        let presenter = WindowInertPresenter(), enrollment = EnrollmentModel(), state = NativeWindowState()
        let window = freshUnshownWindow(), other = freshUnshownWindow()
        defer { model.disconnect(); window.close(); other.close() }
        model.surface = presenter
        state.bindSession(model, enrollment: enrollment); state.attach(window)
        for _ in 0..<100 {
            if model.phase == .approval { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.phase == .approval)
        let ready = Packet(kind: .ready, payload: Data("{\"v\":1,\"codec\":\"h264-annexb\",\"width\":64,\"height\":64,\"fps\":30,\"bitrate\":1000000,\"hardwareEncoder\":true}".utf8))
        transport.feed(Data(ready.encoded.prefix(5))); transport.feed(ready.payload)
        for _ in 0..<100 {
            if model.phase == .decoding { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.phase == .decoding)
        var pixel: CVPixelBuffer?
        try #require(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
        model.presentDecodedImage(try #require(pixel))
        try #require(model.phase == .streaming)
        model.send(try Input.key(down: true, scan: 0x1e, extended: false))
        for _ in 0..<100 {
            if transport.attemptedKinds().contains(.key) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(transport.attemptedKinds() == [.hello, .key])
        model.send(try Input.key(down: true, scan: 0x30, extended: false))
        other.close()
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: other)
        #expect(!state.isFullscreen && model.phase == .streaming && transport.closeCount() == 0)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        #expect(state.isFullscreen && model.phase == .streaming && transport.closeCount() == 0)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        #expect(!state.isFullscreen && model.phase == .streaming && transport.closeCount() == 0)
        let revision = model.inputRevision
        window.close()
        #expect(model.phase == .idle && transport.closeCount() == 1 && model.inputRevision == revision + 1)
        #expect(presenter.cleared == 1 && presenter.forgotten == 1)
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.phase == .idle && transport.attemptedKinds() == [.hello, .key])
    }

    @Test @MainActor func fullscreenControlsRequireActiveOwningFullscreen() {
        let model = SessionModel(), state = NativeWindowState(), window = freshUnshownWindow()
        defer { model.disconnect(); window.close() }
        state.bindSession(model, enrollment: EnrollmentModel()); state.attach(window)
        model.phase = .streaming
        let revision = model.inputRevision
        #expect(!state.canToggleFullscreenControls(for: model))
        state.toggleFullscreenControls(for: model)
        #expect(!model.showFullscreenControls && model.inputRevision == revision)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        #expect(state.canToggleFullscreenControls(for: model))
        state.toggleFullscreenControls(for: model)
        #expect(model.showFullscreenControls && model.inputRevision == revision + 1 && model.inputRecovery)
        state.toggleFullscreenControls(for: model)
        #expect(!model.showFullscreenControls && model.inputRevision == revision + 2)
        model.disconnect()
        let inactiveRevision = model.inputRevision
        #expect(!state.canToggleFullscreenControls(for: model))
        state.toggleFullscreenControls(for: model)
        #expect(!model.showFullscreenControls && model.inputRevision == inactiveRevision)
    }
}
