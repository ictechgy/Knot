import AppKit
import AVFoundation
import SwiftUI
import KnotNativeCore

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
    private var observers: [NSObjectProtocol] = []
    private var heldModifiers: Set<UInt16> = []
    private var physicalKeys = PhysicalKeyOwnership()
    private var heldButtons: Set<UInt8> = []
    private var candidateAnchor = CGPoint(x: 24, y: 40)
    private var marked = NSAttributedString(string: "")
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
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers = []
        guard let window else { return }
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.acceptsMouseMovedEvents = true
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in Task { @MainActor in self?.model?.releaseInput() } })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in Task { @MainActor in self?.model?.disconnect() } })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model?.releaseInput() } })
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
    func clear() { video.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil); marked = NSAttributedString(string: "") }
    func forgetHeldKeys() { heldModifiers.removeAll(); physicalKeys.reset(); heldButtons.removeAll(); marked = NSAttributedString(string: "") }
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
        // No event tap/global hook. Control-arrow remains a native macOS Space action.
        if event.modifierFlags.contains(.control), [123,124,125,126].contains(event.keyCode) { model?.releaseInput(); super.keyDown(with: event); return }
        if !physicalKeys.routesDown(event.keyCode, textMode: model?.textMode == true, shortcutModifier: !event.modifierFlags.intersection([.control, .command]).isEmpty), model?.textMode == true {
            interpretKeyEvents([event]); return
        }
        physical(event, down: true)
    }
    override func keyUp(with event: NSEvent) {
        physical(event, down: false)
    }
    private func physical(_ event: NSEvent, down: Bool) {
        guard let mapping = WindowsScanCodes.map[event.keyCode], let packet = try? Input.key(down: down, scan: mapping.0, extended: mapping.1) else { return }
        if !down && !physicalKeys.release(event.keyCode) { return }
        if down { physicalKeys.press(event.keyCode) }
        if model?.send(packet) != true, down { _ = physicalKeys.release(event.keyCode) }
    }
    override func flagsChanged(with event: NSEvent) {
        if event.keyCode == 57 {
            if model?.textMode == true { return }
            for down in [true, false] { if let packet = try? Input.key(down: down, scan: 0x3a, extended: false) { model?.send(packet) } }; return
        }
        if model?.textMode == true, [56,60,58,61].contains(event.keyCode) { return }
        guard let flag = ScanCodes.modifiers[event.keyCode], WindowsScanCodes.map[event.keyCode] != nil else { return }
        let down = event.modifierFlags.contains(flag) && !heldModifiers.contains(event.keyCode)
        if down { heldModifiers.insert(event.keyCode) } else { heldModifiers.remove(event.keyCode) }
        physical(event, down: down)
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        marked = NSAttributedString(string: "")
        if let packet = try? Input.text(text) { model?.send(packet) }
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        guard text.utf8.count <= 4096 else { unmarkText(); return }; marked = NSAttributedString(string: text)
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
        let key: (UInt16,Bool)?
        switch NSStringFromSelector(selector) {
        case "insertNewline:": key = (0x1c, false)
        case "insertTab:": key = (0x0f, false)
        case "deleteBackward:": key = (0x0e, false)
        case "moveLeft:": key = (0x4b, true)
        case "moveRight:": key = (0x4d, true)
        case "moveUp:": key = (0x48, true)
        case "moveDown:": key = (0x50, true)
        case "cancelOperation:": key = (1, false)
        default: key = nil
        }
        if let key { for down in [true, false] { if let packet = try? Input.key(down: down, scan: key.0, extended: key.1) { model?.send(packet) } } }
    }
}

enum ScanCodes {
    static let modifiers: [UInt16:NSEvent.ModifierFlags] = [56:.shift,60:.shift,59:.control,62:.control,58:.option,61:.option,55:.command,54:.command]
}
