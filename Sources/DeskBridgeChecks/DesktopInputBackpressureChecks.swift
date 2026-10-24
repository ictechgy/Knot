// SPDX-License-Identifier: GPL-3.0-only
// Compile alongside the actual engine sources with the standalone flag below.
// Only a fresh in-memory backend is instantiated: no session, device, UI or socket.
#if DESKBRIDGE_DESKTOP_INPUT_BACKPRESSURE_CHECKS
import Foundation
import Darwin

private struct DesktopInputCheckFailure: Error { let message: String }

@main
private struct DesktopInputBackpressureChecks {
    @MainActor static func main() async {
        do { print("Desktop input backpressure checks: \(try await run())") }
        catch { print("FAILED: \(error)"); exit(1) }
    }

    @MainActor static func run() async throws -> Int {
        var checks = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw DesktopInputCheckFailure(message: message) }
            checks += 1
        }
        func ready(_ backend: SyntheticDesktopBackend) -> StreamInput {
            let input = StreamInput(backend: backend, emit: { _ in })
            input.activate(true)
            input.setFocused(true)
            return input
        }
        let backend = SyntheticDesktopBackend(), input = ready(backend)
        defer { input.stop() }
        let a: UInt16 = 0x41, b: UInt16 = 0x42, c: UInt16 = 0x43
        input.setKey(a, pressed: true, capturedAt: ProcessInfo.processInfo.systemUptime)
        input.setKey(b, pressed: true, capturedAt: ProcessInfo.processInfo.systemUptime)
        try require(input.core.releases.held.count == 2, "accepted key downs must be owned")
        backend.blockReleases = true
        input.setKey(a, pressed: false, modifiers: 1, capturedAt: ProcessInfo.processInfo.systemUptime)
        input.setKey(b, pressed: false, modifiers: 2, capturedAt: ProcessInfo.processInfo.systemUptime)
        try require(input.core.releases.pending == [.key(VKScanCode(vk: Int16(a))), .key(VKScanCode(vk: Int16(b)))],
                    "later key up disappeared behind an older rejected release")
        try require(input.reconciliationScheduled, "backpressured releases must schedule reconciliation")
        input.setKey(b, pressed: false, modifiers: 3, capturedAt: ProcessInfo.processInfo.systemUptime)
        try require(input.core.releases.pending.count == 2, "duplicate key up added duplicate release")
        input.setKey(c, pressed: true, capturedAt: ProcessInfo.processInfo.systemUptime)
        try require(input.core.releases.held.count == 2 && backend.accepted.count == 2,
                    "new key down crossed the older release barrier")
        backend.blockReleases = false
        input.reconcile()
        try require(input.core.releases.pending.isEmpty && input.core.releases.held.isEmpty,
                    "accepted retry did not clear both pending and held keys")
        try require(backend.accepted == [.key(a, true, 0), .key(b, true, 0), .key(a, false, 1), .key(b, false, 2)],
                    "release order or original modifiers changed under backpressure")
        input.reconcile()
        input.setKey(c, pressed: false, capturedAt: ProcessInfo.processInfo.systemUptime)
        try require(backend.accepted.count == 4, "reconcile or unmatched key up duplicated accepted releases")
        try require(input.reconciliationTimer == nil && !input.reconciliationScheduled,
                    "drained release queue retained its reconciliation timer")

        // Ownership loss already invalidates the production retry closure by its capture time.
        // Exercise that actual closure rather than assuming pending text can survive refocus.
        for terminal in [false, true] {
            let peer = SyntheticDesktopBackend(), owner = ready(peer)
            peer.blockText = true
            let capturedAt = ProcessInfo.processInfo.systemUptime
            owner.commitText("synthetic preedit", capturedAt: capturedAt)
            owner.setKey(a, pressed: true, capturedAt: capturedAt)
            try require(owner.desktopTextTask != nil && owner.desktopEvents.count == 1,
                        "fixture did not exercise a pending text task and later key")
            let revokedTextTask = owner.desktopTextTask!
            let attemptsBeforeLoss = peer.textAttempts
            if terminal { owner.stop() } else { owner.setFocused(false); owner.setFocused(true) }
            peer.blockText = false
            await revokedTextTask.value
            try require(peer.textAttempts == attemptsBeforeLoss && peer.accepted.isEmpty,
                        "revoked text or key was replayed after focus loss or stop")
            try require(owner.desktopTextTask == nil && owner.desktopEvents.isEmpty,
                        "revoked text task did not finish and clear its continuation FIFO")
            owner.stop()
        }
        return checks
    }
}

/// The full real StreamingBackend protocol; it cannot create a native transport.
private final class SyntheticDesktopBackend: StreamingBackend, @unchecked Sendable {
    enum Event: Equatable {
        case key(UInt16, Bool, UInt8)
        case text(String)
    }
    private let lock = NSLock()
    private var releaseBlocked = false
    private var textBlocked = false
    private var events: [Event] = []
    private var attemptedTexts = 0
    var blockReleases: Bool {
        get { lock.withLock { releaseBlocked } }
        set { lock.withLock { releaseBlocked = newValue } }
    }
    var blockText: Bool {
        get { lock.withLock { textBlocked } }
        set { lock.withLock { textBlocked = newValue } }
    }
    var accepted: [Event] { lock.withLock { events } }
    var textAttempts: Int { lock.withLock { attemptedTexts } }
    func sendKeyboard(keyCode: Int16, action: Int8, modifiers: Int8, flags: Int8) -> Int32 {
        lock.withLock {
            let down = action == Int8(StreamProtocol.KEY_ACTION_DOWN)
            guard down || !releaseBlocked else { return -1 }
            events.append(.key(UInt16(bitPattern: keyCode) & 0xff, down, UInt8(bitPattern: modifiers)))
            return 0
        }
    }
    func sendUtf8Text(_ text: String) -> Int32 {
        lock.withLock {
            attemptedTexts += 1
            guard !textBlocked else { return -1 }
            events.append(.text(text)); return 0
        }
    }
    func startConnection(server: BackendServerInfo, config: BackendStreamConfig) throws {
        throw DesktopInputCheckFailure(message: "synthetic backend cannot connect")
    }
    func stopConnection() {}
    func interruptConnection() {}
    func attachVideoSink(_ sink: VideoSink) {}
    func attachAudioSink(_ sink: NativeAudioSink) {}
    func estimatedRtt() -> (rttMs: Double, varianceMs: Double)? { nil }
    func requestIdrFrame() {}
    func hdrMetadata() -> HdrMetadata? { nil }
    func launchUrlQueryParameters() -> String { "" }
    func stageName(for stage: Int32) -> String { "synthetic" }
    func sendMouseMove(dx: Int16, dy: Int16) -> Int32 { 0 }
    func sendMousePosition(x: Int16, y: Int16, refW: Int16, refH: Int16) -> Int32 { 0 }
    func sendMouseButton(action: Int8, button: Int32) -> Int32 { 0 }
    func sendScroll(_ amount: Int16) -> Int32 { 0 }
    func sendHScroll(_ amount: Int16) -> Int32 { 0 }
    func sendMultiController(num: Int16, mask: Int16, buttons: Int32, analog: GamepadAnalog) -> Int32 { 0 }
    func sendControllerArrival(num: UInt8, mask: UInt16, type: UInt8, supportedButtons: UInt32, caps: UInt16) -> Int32 { 0 }
    func sendControllerTouch(num: UInt8, eventType: UInt8, touchpadIndex: UInt8, pointerId: UInt32,
                             x: Float, y: Float, pressure: Float) -> Int32 { 0 }
    func sendControllerMotion(num: UInt8, motionType: UInt8, x: Float, y: Float, z: Float) -> Int32 { 0 }
}
#endif
