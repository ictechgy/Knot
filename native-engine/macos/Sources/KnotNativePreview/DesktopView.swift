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
final class DesktopView: NSView, @MainActor NSTextInputClient {
    weak var model: SessionModel?
    var imageSize = CGSize(width: 1920, height: 1080)
    private let video = AVSampleBufferDisplayLayer()
    private var observers: [NSObjectProtocol] = []
    private var heldModifiers: Set<UInt16> = []
    private var marked = NSAttributedString(string: "")
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        video.videoGravity = .resizeAspect; layer?.addSublayer(video)
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
    func display(_ image: CVPixelBuffer) -> Bool {
        let renderer = video.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush(removingDisplayedImage: true, completionHandler: nil); return false }
        guard renderer.isReadyForMoreMediaData else { return false }
        var format: CMVideoFormatDescription?, sample: CMSampleBuffer?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format) == noErr, let format else { return false }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return false }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary], let first = attachments.first { first[kCMSampleAttachmentKey_DisplayImmediately] = true }
        renderer.enqueue(sample)
        return true
    }
    func clear() { video.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil); marked = NSAttributedString(string: "") }
    func forgetHeldKeys() { heldModifiers.removeAll(); marked = NSAttributedString(string: "") }
    override func resignFirstResponder() -> Bool { model?.releaseInput(); return super.resignFirstResponder() }
    private func pointer(_ event: NSEvent, action: UInt8) {
        let p = convert(event.locationInWindow, from: nil)
        guard let pair = Input.point(x: p.x, y: p.y, viewWidth: bounds.width, viewHeight: bounds.height, imageWidth: imageSize.width, imageHeight: imageSize.height), let packet = try? Input.pointer(action: action, x: pair.0, y: pair.1) else {
            if [2,4,6].contains(action) { model?.releaseInput() }; return
        }
        model?.send(packet)
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
        let v = Int32(max(-1200, min(1200, event.scrollingDeltaY * 12)).rounded())
        let h = Int32(max(-1200, min(1200, event.scrollingDeltaX * 12)).rounded())
        if let packet = try? Input.wheel(vertical: v, horizontal: h) { model?.send(packet) }
    }
    override func keyDown(with event: NSEvent) {
        // No event tap/global hook. Control-arrow remains a native macOS Space action.
        if event.modifierFlags.contains(.control), [123,124,125,126].contains(event.keyCode) { model?.releaseInput(); super.keyDown(with: event); return }
        if model?.textMode == true, event.modifierFlags.intersection([.control, .command]).isEmpty {
            interpretKeyEvents([event]); return
        }
        physical(event, down: true)
    }
    override func keyUp(with event: NSEvent) {
        if model?.textMode == true, event.modifierFlags.intersection([.control, .command]).isEmpty { return }
        physical(event, down: false)
    }
    private func physical(_ event: NSEvent, down: Bool) {
        guard let mapping = ScanCodes.map[event.keyCode], let packet = try? Input.key(down: down, scan: mapping.0, extended: mapping.1) else { return }
        model?.send(packet)
    }
    override func flagsChanged(with event: NSEvent) {
        if event.keyCode == 57 {
            if model?.textMode == true { return }
            for down in [true, false] { if let packet = try? Input.key(down: down, scan: 0x3a, extended: false) { model?.send(packet) } }; return
        }
        if model?.textMode == true, [56,60,58,61].contains(event.keyCode) { return }
        guard let flag = ScanCodes.modifiers[event.keyCode], ScanCodes.map[event.keyCode] != nil else { return }
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
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { window?.convertToScreen(convert(NSRect(x: 12, y: 12, width: 1, height: 20), to: nil)) ?? .zero }
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
    static let map: [UInt16:(UInt16,Bool)] = {
        var table: [UInt16:(UInt16,Bool)] = [:]
        let plain: [UInt16:UInt16] = [0:0x1e,1:0x1f,2:0x20,3:0x21,4:0x23,5:0x22,6:0x2c,7:0x2d,8:0x2e,9:0x2f,11:0x30,12:0x10,13:0x11,14:0x12,15:0x13,16:0x15,17:0x14,18:2,19:3,20:4,21:5,22:7,23:6,24:0x0d,25:0x0a,26:8,27:0x0c,28:9,29:0x0b,30:0x1b,31:0x18,32:0x16,33:0x1a,34:0x17,35:0x19,36:0x1c,37:0x26,38:0x24,39:0x28,40:0x25,41:0x27,42:0x2b,43:0x33,44:0x35,45:0x31,46:0x32,47:0x34,48:0x0f,49:0x39,50:0x29,51:0x0e,53:1,56:0x2a,60:0x36,59:0x1d,58:0x38,61:0x38,122:0x3b,120:0x3c,99:0x3d,118:0x3e,96:0x3f,97:0x40,98:0x41,100:0x42,101:0x43,109:0x44,103:0x57,111:0x58]
        for (key,scan) in plain { table[key] = (scan, false) }
        for (key,scan): (UInt16,UInt16) in [65:0x53,67:0x37,69:0x4e,71:0x45,78:0x4a,82:0x52,83:0x4f,84:0x50,85:0x51,86:0x4b,87:0x4c,88:0x4d,89:0x47,91:0x48,92:0x49] { table[key] = (scan,false) }
        let extended: [UInt16:UInt16] = [123:0x4b,124:0x4d,125:0x50,126:0x48,115:0x47,119:0x4f,116:0x49,121:0x51,117:0x53,114:0x52,55:0x5b,54:0x5c,62:0x1d,61:0x38]
        for (key,scan) in extended { table[key] = (scan, true) }; return table
    }()
}
