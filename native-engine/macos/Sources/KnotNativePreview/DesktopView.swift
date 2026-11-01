import AppKit
import AVFoundation
import SwiftUI
import KnotNativeCore

/// The monitor belongs only to this presenter's accepted physical-key lifetime.
/// AppKit's local monitor handlers run on the main thread.
private final class LocalKeyUpMonitor: @unchecked Sendable {
    let token: Any
    init(_ token: Any) { self.token = token }
    deinit { NSEvent.removeMonitor(token) }
}

struct NativeDesktop: NSViewRepresentable {
    @ObservedObject var model: SessionModel
    func makeNSView(context: Context) -> DesktopView { let view = DesktopView(); view.model = model; model.surface = view; return view }
    func updateNSView(_ view: DesktopView, context: Context) { view.imageSize = model.videoSize }
}

@MainActor
final class DesktopView: NSView, NativePresenter, @MainActor NSTextInputClient {
    weak var model: SessionModel?
    var imageSize = CGSize(width: 1920, height: 1080)
    private let video = AVSampleBufferDisplayLayer()
    private var statusObservation: NSKeyValueObservation?
    var onFailure: (() -> Void)?
    private var notifications: NativeWindowNotifications?
    private var heldModifiers: Set<UInt16> = []
    private var localModifiers = KeyboardModifierState()
    private var physicalKeys = PhysicalKeyOwnership()
    private var commandKeyUpMonitor: LocalKeyUpMonitor?
    private var heldButtons: Set<UInt8> = []
    private var candidateAnchor = CGPoint(x: 24, y: 40)
    private var marked = NSAttributedString(string: "")
    private var textAuthorization = TextCommitAuthorization()
    private var discardingComposition = false
    private var interpretingEvent: NSEvent?
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        video.videoGravity = .resizeAspect; layer?.addSublayer(video)
        statusObservation = video.sampleBufferRenderer.observe(\.status, options: [.new]) { @Sendable [weak self] _, change in
            guard change.newValue == .failed else { return }
            Task { @MainActor [weak self] in
                guard let self, self.video.sampleBufferRenderer.status == .failed else { return }
                self.onFailure?()
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func layout() { super.layout(); video.frame = bounds }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect], owner: self))
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        commandKeyUpMonitor = nil
        notifications = nil
        guard let window else { model?.releaseInput(); return }
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.acceptsMouseMovedEvents = true
        notifications = NativeWindowNotifications([
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.model?.releaseInput() } },
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.model?.disconnect() } },
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.model?.releaseInput() } }
        ])
    }
    func display(_ image: CVPixelBuffer) -> PresentationResult {
        let renderer = video.sampleBufferRenderer
        guard renderer.status != .failed else { return .failed }
        guard renderer.isReadyForMoreMediaData else { return .backpressure }
        var format: CMVideoFormatDescription?, sample: CMSampleBuffer?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format) == noErr, let format else { return .failed }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return .failed }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary], let first = attachments.first { first[kCMSampleAttachmentKey_DisplayImmediately] = true }
        renderer.enqueue(sample)
        return renderer.status == .failed ? .failed : .presented
    }
    func clear() { video.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil); cancelComposition() }
    func forgetHeldKeys() {
        commandKeyUpMonitor = nil
        heldModifiers.removeAll(); localModifiers.reset(); physicalKeys.reset(); heldButtons.removeAll()
        cancelComposition()
    }
    private func cancelComposition() {
        textAuthorization.revoke(); marked = NSAttributedString(string: "")
        guard !discardingComposition else { return }
        discardingComposition = true
        inputContext?.discardMarkedText()
        discardingComposition = false
    }
    private var focusedForInput: Bool {
        window?.isKeyWindow == true && window?.firstResponder === self && NSApp.isActive
    }
    private var acceptsInput: Bool {
        focusedForInput && model?.phase == .streaming && model?.inputRecovery == false
    }
    override func resignFirstResponder() -> Bool { model?.releaseInput(); return super.resignFirstResponder() }
    private func pointer(_ event: NSEvent, action: UInt8) {
        let p = convert(event.locationInWindow, from: nil)
        candidateAnchor = p
        let isUp = [2,4,6].contains(action)
        let ownedUp = isUp && heldButtons.contains(action - 1)
        if isUp && !ownedUp { return }
        let focused = window?.isKeyWindow == true && window?.firstResponder === self && NSApp.isActive
        guard let pair = Input.point(x: p.x, y: p.y, viewWidth: bounds.width, viewHeight: bounds.height, imageWidth: imageSize.width, imageHeight: imageSize.height, clamp: ownedUp && focused), let packet = try? Input.pointer(action: action, x: pair.0, y: pair.1) else {
            if [2,4,6].contains(action) { model?.releaseInput() }; return
        }
        if isUp { heldButtons.remove(action - 1) }
        if model?.send(packet) == true, [1,3,5].contains(action) { heldButtons.insert(action) }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if model?.inputRecovery == true { model?.recoverInput(); return }
        pointer(event, action: 1)
    }
    override func mouseUp(with event: NSEvent) { pointer(event, action: 2) }
    override func rightMouseDown(with event: NSEvent) { pointer(event, action: 3) }
    override func rightMouseUp(with event: NSEvent) { pointer(event, action: 4) }
    override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { pointer(event, action: 5) } }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { pointer(event, action: 6) } }
    override func mouseMoved(with event: NSEvent) { pointer(event, action: 0) }
    override func mouseDragged(with event: NSEvent) { pointer(event, action: 0) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event, action: 0) }
    override func otherMouseDragged(with event: NSEvent) { pointer(event, action: 0) }
    override func scrollWheel(with event: NSEvent) {
        if let packet = Input.scroll(vertical: event.scrollingDeltaY, horizontal: event.scrollingDeltaX, precise: event.hasPreciseScrollingDeltas) { model?.send(packet) }
    }
    override func keyDown(with event: NSEvent) {
        let route = MacKeyboardRouting.route(keyCode: event.keyCode, modifiers: Self.modifiers(event.modifierFlags),
            textMode: model?.textMode == true, hasMarkedText: hasMarkedText(), ownsPhysicalDown: physicalKeys.owns(event.keyCode))
        switch route {
        case .localCapsLock: return
        case .localSpace:
            model?.releaseInput(); super.keyDown(with: event)
        case .interpretText:
            guard acceptsInput, let revision = model?.inputRevision else { return }
            synchronizeModifiers(event.modifierFlags, physicalCommand: false)
            textAuthorization.begin(epoch: revision); interpretingEvent = event
            interpretKeyEvents([event])
            interpretingEvent = nil; textAuthorization.end()
        case .physical:
            guard acceptsInput else { return }
            synchronizeModifiers(event.modifierFlags, physicalCommand: true)
            physical(event, down: true)
        }
    }
    override func keyUp(with event: NSEvent) {
        // Matching release follows ownership even after modifier/mode changes.
        physical(event, down: false)
        if acceptsInput { synchronizeModifiers(event.modifierFlags, physicalCommand: false) }
        if physicalKeys.count == heldModifiers.count { commandKeyUpMonitor = nil }
    }
    private func physical(_ event: NSEvent, down: Bool) {
        guard let mapping = WindowsScanCodes.map[event.keyCode], let packet = try? Input.key(down: down, scan: mapping.0, extended: mapping.1) else { return }
        if !down && !physicalKeys.release(event.keyCode) { return }
        if down { physicalKeys.press(event.keyCode) }
        if model?.send(packet) != true, down { _ = physicalKeys.release(event.keyCode) }
        else if down, event.modifierFlags.contains(.command), MacKeyboardRouting.modifierKeys[event.keyCode] == nil {
            armCommandKeyUpMonitor()
        }
    }
    private func armCommandKeyUpMonitor() {
        guard commandKeyUpMonitor == nil, acceptsInput else { return }
        // Command key-ups may bypass the responder. A local pre-dispatch
        // compensation handles only our own matching release, once. It never
        // monitors another app or forwards a key-down/menu equivalent.
        if let token = NSEvent.addLocalMonitorForEvents(matching: .keyUp, handler: { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, MacKeyboardRouting.compensatesCommandKeyUp(keyCode: event.keyCode,
                    modifiers: Self.modifiers(event.modifierFlags), ownsPhysicalDown: self.physicalKeys.owns(event.keyCode),
                    focused: self.acceptsInput, sameWindow: event.window != nil && event.window === self.window) else { return false }
                self.keyUp(with: event)
                return true
            }
            return handled ? nil : event
        }) { commandKeyUpMonitor = LocalKeyUpMonitor(token) }
    }
    override func flagsChanged(with event: NSEvent) {
        // macOS owns both short language-switch and long capitals Caps Lock.
        guard event.keyCode != 57 else {
            if !acceptsInput || inputContext?.handleEvent(event) != true { super.flagsChanged(with: event) }
            return
        }
        localModifiers.observe(keyCode: event.keyCode, flags: Self.modifiers(event.modifierFlags))
        guard acceptsInput else { return }
        synchronizeModifiers(event.modifierFlags, physicalCommand: physicalKeys.count > heldModifiers.count)
    }
    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyboardModifiers {
        var value: KeyboardModifiers = []
        if flags.contains(.shift) { value.insert(.shift) }
        if flags.contains(.control) { value.insert(.control) }
        if flags.contains(.option) { value.insert(.option) }
        if flags.contains(.command) { value.insert(.command) }
        return value
    }
    private func synchronizeModifiers(_ flags: NSEvent.ModifierFlags, physicalCommand: Bool) {
        let desired = localModifiers.desired(flags: Self.modifiers(flags), textMode: model?.textMode == true, physicalCommand: physicalCommand)
        for code in heldModifiers.subtracting(desired).sorted() {
            guard let mapping = WindowsScanCodes.map[code] else { continue }
            _ = physicalKeys.release(code); heldModifiers.remove(code)
            if let packet = try? Input.key(down: false, scan: mapping.0, extended: mapping.1) { model?.send(packet) }
        }
        for code in desired.subtracting(heldModifiers).sorted() {
            guard let mapping = WindowsScanCodes.map[code], let packet = try? Input.key(down: true, scan: mapping.0, extended: mapping.1) else { continue }
            if model?.send(packet) == true { physicalKeys.press(code); heldModifiers.insert(code) }
        }
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let model, textAuthorization.allows(epoch: model.inputRevision, focused: focusedForInput,
              streaming: model.phase == .streaming, recovery: model.inputRecovery) else { return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        marked = NSAttributedString(string: "")
        if let packet = try? Input.text(text) { model.send(packet) }
        textAuthorization.committed()
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let model, !discardingComposition,
              textAuthorization.allows(epoch: model.inputRevision, focused: focusedForInput,
                streaming: model.phase == .streaming, recovery: model.inputRecovery) else { return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        guard text.utf8.count <= 4096 else { cancelComposition(); return }
        marked = NSAttributedString(string: text); textAuthorization.mark()
    }
    func unmarkText() { marked = NSAttributedString(string: "") }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { marked.length > 0 ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // Local pointer vicinity is a usable candidate anchor; v1 has no remote
        // caret/preedit coordinates and makes no claim that this is the caret.
        let x = max(8, min(candidateAnchor.x, bounds.width - 16))
        let y = max(8, min(candidateAnchor.y + 20, bounds.height - 28))
        return window?.convertToScreen(convert(NSRect(x: x, y: y, width: 1, height: 20), to: nil)) ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    override func doCommand(by selector: Selector) {
        guard acceptsInput, let event = interpretingEvent, MacKeyboardRouting.isCommandKey(event.keyCode),
              let mapping = WindowsScanCodes.map[event.keyCode] else { return }
        // Only the physical key that AppKit could not consume is forwarded.
        // Navigation/selection/F-keys do not depend on a partial selector table.
        synchronizeModifiers(event.modifierFlags, physicalCommand: true)
        for down in [true, false] {
            if let packet = try? Input.key(down: down, scan: mapping.0, extended: mapping.1) { model?.send(packet) }
        }
        synchronizeModifiers(event.modifierFlags, physicalCommand: false)
    }
}
