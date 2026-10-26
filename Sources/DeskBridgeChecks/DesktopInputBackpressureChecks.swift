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
        func ready(_ backend: SyntheticDesktopBackend, events: DesktopInputEvents? = nil) -> StreamInput {
            let input = StreamInput(backend: backend, emit: { events?.receive($0) })
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
            try require(owner.desktopEventBytes == 0, "revocation retained queued text bytes")
            owner.stop()
        }

        // A replayed commit can open a second wait; following keys/clicks must
        // requeue behind it without duplicating the accepted prefix or actions.
        do {
            let peer = SyntheticDesktopBackend(), owner = ready(peer)
            peer.blockText = true
            owner.commitText("first wait", capturedAt: ProcessInfo.processInfo.systemUptime)
            let first = owner.desktopTextTask!
            owner.setKey(a, pressed: true, capturedAt: ProcessInfo.processInfo.systemUptime)
            owner.setKey(a, pressed: false, capturedAt: ProcessInfo.processInfo.systemUptime)
            owner.commitText("second wait", capturedAt: ProcessInfo.processInfo.systemUptime)
            owner.afterDesktopText(capturedAt: ProcessInfo.processInfo.systemUptime) { peer.recordAction(3) }
            owner.setKey(b, pressed: true, capturedAt: ProcessInfo.processInfo.systemUptime)
            owner.setKey(b, pressed: false, capturedAt: ProcessInfo.processInfo.systemUptime)
            peer.pauseAfterNextAcceptedText = true; peer.blockText = false
            await first.value
            try require(peer.accepted == [.text("first wait"), .key(a, true, 0), .key(a, false, 0)],
                        "later actions overtook a replayed pending text commit")
            try require(owner.desktopTextTask != nil && owner.desktopEvents.count == 3 && owner.desktopEventBytes == 0,
                        "nested text wait lost or duplicated its following continuations")
            let second = owner.desktopTextTask!
            peer.blockText = false
            await second.value
            try require(peer.accepted == [.text("first wait"), .key(a, true, 0), .key(a, false, 0),
                                          .text("second wait"), .action(3), .key(b, true, 0), .key(b, false, 0)],
                        "nested text wait changed replay order or duplicated accepted actions")
            try require(owner.desktopEvents.isEmpty && owner.desktopEventBytes == 0,
                        "nested replay retained its queue")
            owner.stop()
        }

        // Accepted text, keys, caret actions and another commit retain their exact order.
        do {
            let peer = SyntheticDesktopBackend(), owner = ready(peer)
            peer.blockText = true
            owner.commitText("first", capturedAt: ProcessInfo.processInfo.systemUptime)
            let pending = owner.desktopTextTask!
            for _ in 0..<32 {
                owner.setKey(a, pressed: true, capturedAt: ProcessInfo.processInfo.systemUptime)
                owner.setKey(a, pressed: false, capturedAt: ProcessInfo.processInfo.systemUptime)
            }
            owner.afterDesktopText(capturedAt: ProcessInfo.processInfo.systemUptime) { peer.recordAction(1) }
            owner.commitText("second", capturedAt: ProcessInfo.processInfo.systemUptime)
            owner.afterDesktopText(capturedAt: ProcessInfo.processInfo.systemUptime) { peer.recordAction(2) }
            try require(owner.desktopEvents.count == 67 && owner.desktopEventBytes == 6,
                        "mixed continuation accounting changed")
            peer.blockText = false
            await pending.value
            var expected: [SyntheticDesktopBackend.Event] = [.text("first")]
            for _ in 0..<32 { expected += [.key(a, true, 0), .key(a, false, 0)] }
            expected += [.action(1), .text("second"), .action(2)]
            try require(peer.accepted == expected, "bounded replay reordered text, keys or caret actions")
            try require(owner.desktopEvents.isEmpty && owner.desktopEventBytes == 0,
                        "successful replay retained queue storage")
            owner.stop()
        }

        // Count saturation revokes all unsent work, but not accepted-key releases.
        do {
            let peer = SyntheticDesktopBackend(), events = DesktopInputEvents(), owner = ready(peer, events: events)
            owner.setKey(a, pressed: true, capturedAt: ProcessInfo.processInfo.systemUptime)
            peer.blockReleases = true; peer.blockText = true
            owner.commitText("blocked", capturedAt: ProcessInfo.processInfo.systemUptime)
            let pending = owner.desktopTextTask!
            for _ in 0..<StreamInput.desktopEventLimit {
                owner.setKey(b, pressed: true, capturedAt: ProcessInfo.processInfo.systemUptime)
            }
            try require(owner.desktopEvents.count == StreamInput.desktopEventLimit,
                        "count limit refused an admissible continuation")
            owner.setKey(a, pressed: false, capturedAt: ProcessInfo.processInfo.systemUptime)
            try require(owner.desktopInputBlocked && events.blocked == [true], "count saturation did not fail closed once")
            try require(owner.desktopTextTask == nil && owner.desktopEvents.isEmpty && owner.desktopEventBytes == 0,
                        "saturation retained text work or queue storage")
            try require(owner.core.releases.pending == [.key(VKScanCode(vk: Int16(a)))],
                        "saturation lost an accepted down's rejected release")
            for _ in 0..<10000 {
                owner.setFocused(true)
                owner.setKey(b, pressed: true, capturedAt: ProcessInfo.processInfo.systemUptime)
                owner.commitText("discarded", capturedAt: ProcessInfo.processInfo.systemUptime)
                owner.afterDesktopText(capturedAt: ProcessInfo.processInfo.systemUptime) { peer.recordAction(99) }
            }
            try require(owner.desktopEvents.isEmpty && events.blocked == [true],
                        "repeated focus=true bypassed the overflow latch or grew retained work")
            peer.blockReleases = false; peer.blockText = false
            owner.reconcile()
            await pending.value
            try require(peer.accepted == [.key(a, true, 0), .key(a, false, 0)],
                        "revoked work replayed or an owned release did not reconcile")
            owner.setFocused(false); owner.setFocused(true)
            owner.commitText("recovered", capturedAt: ProcessInfo.processInfo.systemUptime)
            try require(!owner.desktopInputBlocked && events.blocked == [true, false] && peer.accepted.last == .text("recovered"),
                        "real focus loss/reacquisition did not restore input")
            owner.stop()
        }

        // UTF-8 bytes have a separate bound even when the action count stays small.
        do {
            let peer = SyntheticDesktopBackend(), owner = ready(peer)
            peer.blockText = true
            owner.commitText("active", capturedAt: ProcessInfo.processInfo.systemUptime)
            let pending = owner.desktopTextTask!
            let text = String(repeating: "🧪", count: InputText.maxBytes / 4)
            for _ in 0..<(StreamInput.desktopTextByteLimit / InputText.maxBytes) {
                owner.commitText(text, capturedAt: ProcessInfo.processInfo.systemUptime)
            }
            try require(owner.desktopEventBytes == StreamInput.desktopTextByteLimit && owner.desktopEvents.count == 4,
                        "queued UTF-8 byte budget accounting changed")
            owner.commitText("x", capturedAt: ProcessInfo.processInfo.systemUptime)
            try require(owner.desktopInputBlocked && owner.desktopEvents.isEmpty && owner.desktopEventBytes == 0,
                        "UTF-8 byte saturation did not revoke the retained queue")
            await pending.value
            try require(peer.accepted.isEmpty, "byte-saturated text replayed after cancellation")
            owner.stop()
        }

        // Revocation releases captured payloads, and a delayed revocation hop cannot cancel new work.
        do {
            let peer = SyntheticDesktopBackend(), owner = ready(peer)
            peer.blockText = true
            owner.commitText("old", capturedAt: ProcessInfo.processInfo.systemUptime)
            let old = owner.desktopTextTask!
            weak var retained: NSObject?
            do {
                let payload = NSObject(); retained = payload
                owner.afterDesktopText(capturedAt: ProcessInfo.processInfo.systemUptime) { _ = payload.description }
            }
            try require(retained != nil, "capture fixture was not retained")
            owner.releaseDesktopInput()
            try require(retained == nil && owner.desktopEvents.isEmpty && owner.desktopEventBytes == 0,
                        "focus release retained a closure payload or queue storage")
            owner.setFocused(true)
            owner.commitText("new", capturedAt: ProcessInfo.processInfo.systemUptime)
            let replacement = owner.desktopTextTask!
            peer.blockText = false
            await old.value; await replacement.value
            try require(peer.accepted == [.text("new")], "a delayed revocation cancelled replacement work or replayed old text")
            owner.stop()
        }
        print("Bounded desktop input: actions=\(StreamInput.desktopEventLimit), queuedUTF8Bytes=\(StreamInput.desktopTextByteLimit), saturation/release/recovery/order=PASS")
        return checks
    }
}

private final class DesktopInputEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    var blocked: [Bool] { lock.withLock { values } }
    func receive(_ event: StreamInput.Event) {
        if case .desktopInputBlocked(let value) = event { lock.withLock { values.append(value) } }
    }
}

/// The full real StreamingBackend protocol; it cannot create a native transport.
private final class SyntheticDesktopBackend: StreamingBackend, @unchecked Sendable {
    enum Event: Equatable {
        case key(UInt16, Bool, UInt8)
        case text(String)
        case action(Int)
    }
    private let lock = NSLock()
    private var releaseBlocked = false
    private var textBlocked = false
    private var pauseAfterText = false
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
    var pauseAfterNextAcceptedText: Bool {
        get { lock.withLock { pauseAfterText } }
        set { lock.withLock { pauseAfterText = newValue } }
    }
    var accepted: [Event] { lock.withLock { events } }
    var textAttempts: Int { lock.withLock { attemptedTexts } }
    func recordAction(_ value: Int) { lock.withLock { events.append(.action(value)) } }
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
            events.append(.text(text))
            if pauseAfterText { pauseAfterText = false; textBlocked = true }
            return 0
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
