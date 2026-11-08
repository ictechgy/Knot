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
    var onFilesDropped: (() -> Void)? = nil
    var inputSuspended = false
    func makeNSView(context: Context) -> DesktopView { let view = DesktopView(); view.model = model; view.onFilesDropped = onFilesDropped; view.inputSuspended = inputSuspended; model.surface = view; return view }
    func updateNSView(_ view: DesktopView, context: Context) { view.imageSize = model.videoSize; view.onFilesDropped = onFilesDropped; view.inputSuspended = inputSuspended }
}

@MainActor
final class DesktopView: NSView, NativePresenter, @MainActor NSTextInputClient, NSDraggingSource {
    weak var model: SessionModel?
    var imageSize = CGSize(width: 1920, height: 1080)
    private let video = AVSampleBufferDisplayLayer()
    private var statusObservation: NSKeyValueObservation?
    var onFailure: (() -> Void)?
    var onFilesDropped: (() -> Void)?
    var inputSuspended = false
    private var fileDragInProgress = false
    private let explorerPromises = NativeFilePromiseOwner()
    private var explorerTask: Task<Void, Never>?
    private var explorerOrigin: CGPoint?
    private var explorerGeneration = UUID()
    private var explorerNonce: String?
    private var explorerProviders: [UUID] = []
    private var localExplorerDragging = false
    private var preserveExplorerDuringRelease = false
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
        registerForDraggedTypes([.fileURL])
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
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard model?.phase == .streaming, let files = model?.files, !files.isBusy,
              sender.draggingPasteboard.availableType(from: [.fileURL]) != nil else { return [] }
        fileDragInProgress = true; model?.releaseInput(); return .copy
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let accepted = model?.phase == .streaming && model?.files?.isBusy == false
        if !accepted { fileDragInProgress = false }
        return accepted
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { fileDragInProgress = false }
        guard model?.phase == .streaming, let files = model?.files else { return false }
        return NativeFileDrop.perform(from: sender.draggingPasteboard, files: files,
            beforeSend: { model?.releaseInput() }, showStatus: { onFilesDropped?() })
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { fileDragInProgress = false }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { fileDragInProgress = false }
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
        if !preserveExplorerDuringRelease, !localExplorerDragging || model?.phase != .streaming {
            cancelExplorerHandoff()
        }
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
        !inputSuspended && !fileDragInProgress && model?.clipboard?.busy != true && focusedForInput && model?.phase == .streaming && model?.inputRecovery == false
    }
    override func resignFirstResponder() -> Bool { model?.releaseInput(); return super.resignFirstResponder() }
    private func pointer(_ event: NSEvent, action: UInt8) {
        guard !inputSuspended, !fileDragInProgress else { return }
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
        guard !inputSuspended, !fileDragInProgress else { return }
        window?.makeFirstResponder(self)
        if model?.inputRecovery == true { model?.recoverInput(); return }
        pointer(event, action: 1)
        explorerOrigin = heldButtons.contains(1) ? convert(event.locationInWindow, from: nil) : nil
    }
    override func mouseUp(with event: NSEvent) {
        explorerOrigin = nil
        if explorerTask != nil { cancelExplorerHandoff(); model?.releaseInput(); return }
        pointer(event, action: 2)
    }
    override func rightMouseDown(with event: NSEvent) { pointer(event, action: 3) }
    override func rightMouseUp(with event: NSEvent) { pointer(event, action: 4) }
    override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { pointer(event, action: 5) } }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { pointer(event, action: 6) } }
    override func mouseMoved(with event: NSEvent) { pointer(event, action: 0) }
    override func mouseDragged(with event: NSEvent) {
        guard explorerTask == nil, !localExplorerDragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        let inside = Input.point(x: point.x, y: point.y, viewWidth: bounds.width, viewHeight: bounds.height,
                                 imageWidth: imageSize.width, imageHeight: imageSize.height) != nil
        if ExplorerDragGesture.shouldHandoff(origin: explorerOrigin, point: point, ownsLeft: heldButtons.contains(1),
            insideImage: inside, available: acceptsInput && model?.files != nil && model?.files?.isBusy == false) {
            beginExplorerHandoff(event); return
        }
        pointer(event, action: 0)
    }
    private func beginExplorerHandoff(_ event: NSEvent) {
        guard let model, let files = model.files else { return }
        let id = UUID(), bytes = withUnsafeBytes(of: UUID().uuid) { Data($0) }
        let nonce = NativeFileClient.hex(bytes)
        explorerGeneration = id; explorerNonce = nonce; fileDragInProgress = true
        explorerTask = Task { @MainActor [weak self, weak model, weak files] in
            guard let self, let model, let files else { return }
            do {
                let entries = try await model.captureExplorerDrag(nonce: bytes)
                guard self.explorerGeneration == id, !Task.isCancelled, model.phase == .streaming,
                      model.files === files, NSEvent.pressedMouseButtons & 1 != 0,
                      self.window?.isKeyWindow == true, NSApp.isActive, !entries.isEmpty else {
                    throw NativeFileError.cancelled
                }
                var items: [NSDraggingItem] = []
                for entry in entries {
                    guard let (providerID, provider) = self.explorerPromises.provider(entry: entry, files: files) else {
                        throw NativeFileError.busy
                    }
                    self.explorerProviders.append(providerID)
                    let item = NSDraggingItem(pasteboardWriter: provider)
                    let p = self.convert(event.locationInWindow, from: nil)
                    item.setDraggingFrame(NSRect(x: p.x - 16, y: p.y - 16, width: 32, height: 32),
                        contents: NSImage(systemSymbolName: entry.isFolder ? "folder" : "doc", accessibilityDescription: nil))
                    items.append(item)
                }
                self.preserveExplorerDuringRelease = true
                model.releaseInput()
                self.preserveExplorerDuringRelease = false
                self.explorerTask = nil; self.localExplorerDragging = true
                self.beginDraggingSession(with: items, event: event, source: self)
            } catch {
                guard self.explorerGeneration == id else { return }
                self.cancelExplorerHandoff(); model.releaseInput(); self.onFilesDropped?()
            }
        }
    }
    private func cancelExplorerHandoff() {
        explorerGeneration = UUID(); explorerTask?.cancel(); explorerTask = nil; explorerOrigin = nil
        if let nonce = explorerNonce { model?.files?.cancelExplorer(nonce: nonce) }
        explorerNonce = nil
        for id in explorerProviders { explorerPromises.finish(id) }
        explorerProviders = []; fileDragInProgress = false; localExplorerDragging = false
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        model?.phase == .streaming && model?.files != nil ? .copy : []
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation.isEmpty { cancelExplorerHandoff() }
        else {
            explorerTask = nil; explorerOrigin = nil; explorerNonce = nil; explorerProviders = []
            fileDragInProgress = false; localExplorerDragging = false
        }
        model?.releaseInput()
    }
    override func rightMouseDragged(with event: NSEvent) { pointer(event, action: 0) }
    override func otherMouseDragged(with event: NSEvent) { pointer(event, action: 0) }
    override func scrollWheel(with event: NSEvent) {
        if let packet = Input.scroll(vertical: event.scrollingDeltaY, horizontal: event.scrollingDeltaX, precise: event.hasPreciseScrollingDeltas) { model?.send(packet) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Intercept only a focused remote presenter's Command edits. App-wide
        // shortcuts and macOS Spaces remain owned by their normal responders.
        let flags = Self.modifiers(event.modifierFlags)
        guard acceptsInput, model?.macShortcuts == true, flags.contains(.command),
              !flags.contains(.control), !flags.contains(.option),
              [UInt16(0), 6, 7, 8, 9, 1, 3, 5, 45, 13, 15].contains(event.keyCode) else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event); return true
    }
    override func keyDown(with event: NSEvent) {
        if !inputSuspended, !fileDragInProgress, focusedForInput, model?.consumeVideoResumeGesture() == true { return }
        let flags = Self.modifiers(event.modifierFlags)
        if acceptsInput, model?.macShortcuts == true, flags == .command,
           heldButtons.isEmpty, model?.clipboard != nil,
           event.keyCode == 8 || event.keyCode == 9 {
            // Release remotely even when an empty/invalid clipboard or failed
            // enqueue prevents the host clipboard helper from ever running.
            model?.performClipboardGesture(paste: event.keyCode == 9)
            return
        }
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
        let desired = localModifiers.desired(flags: Self.modifiers(flags), textMode: model?.textMode == true, physicalCommand: physicalCommand, macShortcuts: model?.macShortcuts == true)
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
        if model.sendCommittedText(text) { textAuthorization.committed() }
        else { cancelComposition() }
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
