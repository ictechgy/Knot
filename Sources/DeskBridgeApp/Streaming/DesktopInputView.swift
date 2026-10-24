// SPDX-License-Identifier: GPL-3.0-only
// Native adapter for the GlimmerEngine uplink; never reads the system clipboard.
import AppKit
import AVFoundation
import GlimmerEngine
import DeskBridgeCore

enum DesktopKeyboardMode: String, CaseIterable { case localIME = "Mac input method", physicalKeys = "Windows keyboard" }

@MainActor private final class DesktopPreeditField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor private final class DesktopRecoveryCard: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.windowBackgroundColor.setFill(); shape.fill()
        NSColor.separatorColor.setStroke(); shape.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor final class DesktopInputView: NSView, @MainActor NSTextInputClient {
    var input: StreamInput?
    var keyboardMode: DesktopKeyboardMode = .localIME { didSet { releaseInput(); if window?.isKeyWindow == true { input?.setFocused(true) } } }
    var hostSize = CGSize(width: 1920, height: 1080)
    let videoLayer = AVSampleBufferDisplayLayer()
    private var tracking: NSTrackingArea?
    private var held = Set<UInt16>()
    private var composition = DesktopCompositionState()
    private let preedit = DesktopPreeditField(labelWithString: "")
    private let recoveryCard = DesktopRecoveryCard()
    private let recoveryLabel = NSTextField(labelWithString: "")
    private var interpreting: NSEvent?
    private var textEvent = DesktopTextEventState()
    private var composingEvent = false
    private var discardingMarkedText = false
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect
        layer?.addSublayer(videoLayer)
        preedit.font = .systemFont(ofSize: 18)
        preedit.textColor = .labelColor
        preedit.backgroundColor = .windowBackgroundColor
        preedit.drawsBackground = true
        preedit.isSelectable = false
        preedit.isEditable = false
        preedit.usesSingleLineMode = true
        preedit.lineBreakMode = .byTruncatingHead
        preedit.wantsLayer = true
        preedit.layer?.cornerRadius = 6
        preedit.layer?.masksToBounds = true
        preedit.layer?.borderWidth = 1
        preedit.layer?.borderColor = NSColor.separatorColor.cgColor
        preedit.isHidden = true
        addSubview(preedit)
        recoveryLabel.font = .systemFont(ofSize: 15, weight: .medium)
        recoveryLabel.textColor = .labelColor
        recoveryLabel.alignment = .center
        recoveryLabel.isSelectable = false
        recoveryLabel.isEditable = false
        recoveryLabel.maximumNumberOfLines = 3
        recoveryLabel.lineBreakMode = .byWordWrapping
        recoveryCard.addSubview(recoveryLabel)
        recoveryCard.isHidden = true
        addSubview(recoveryCard)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    override func layout() {
        super.layout()
        videoLayer.frame = bounds
        layoutPreedit()
        layoutRecovery()
    }
    func showRecovery(_ message: String?) {
        guard message != (recoveryCard.isHidden ? nil : recoveryLabel.stringValue) else { return }
        recoveryCard.isHidden = message == nil
        recoveryLabel.stringValue = message ?? ""
        recoveryLabel.setAccessibilityLabel(message)
        layoutRecovery()
        if let message, let application = NSApp {
            NSAccessibility.post(element: application, notification: .announcementRequested,
                userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }
    private func layoutRecovery() {
        let width = min(460, max(1, bounds.width - 32))
        let textWidth = max(1, width - 32)
        let measured = recoveryLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 80)).height ?? 40
        let height = max(44, measured + 24)
        recoveryCard.frame = NSRect(x: bounds.midX - width / 2, y: bounds.maxY - height - 24, width: width, height: height)
        recoveryLabel.frame = NSRect(x: 16, y: 12, width: textWidth, height: height - 24)
    }
    private func layoutPreedit() {
        let measured = preedit.attributedStringValue.size().width + 20
        let width = min(max(96, measured), max(1, bounds.width - 32))
        preedit.frame = NSRect(x: bounds.midX - width / 2, y: bounds.minY + 24, width: width, height: 32)
        if composition.isVisible { inputContext?.invalidateCharacterCoordinates() }
    }
    private func refreshPreedit() {
        let text = NSMutableAttributedString(string: composition.text, attributes: [
            .font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.labelColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue])
        if composition.selection.length > 0 {
            text.addAttributes([.backgroundColor: NSColor.selectedTextBackgroundColor,
                .foregroundColor: NSColor.selectedTextColor], range: composition.selection)
        }
        preedit.attributedStringValue = text
        preedit.isHidden = !composition.isVisible
        layoutPreedit()
        inputContext?.invalidateCharacterCoordinates()
    }
    private func cancelComposition() {
        _ = composition.finish(.cancel)
        refreshPreedit()
        discardInputContextMarkedText()
    }
    private func discardInputContextMarkedText() {
        guard !discardingMarkedText else { return }
        discardingMarkedText = true
        defer { discardingMarkedText = false }
        inputContext?.discardMarkedText()
    }
    override func becomeFirstResponder() -> Bool { input?.setFocused(true); return true }
    override func resignFirstResponder() -> Bool { releaseInput(); return true }
    func releaseInput() {
        input?.releaseDesktopInput()
        held.removeAll()
        cancelComposition()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved], owner: self)
        if let tracking { addTrackingArea(tracking) }
    }
    private func reservedForMac(_ e: NSEvent) -> Bool {
        DesktopKeyboardPolicy.reservesSpaceShortcut(keyCode: e.keyCode, control: e.modifierFlags.contains(.control),
            shift: e.modifierFlags.contains(.shift), option: e.modifierFlags.contains(.option))
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.isKeyWindow == true, window?.firstResponder === self,
           event.modifierFlags.contains(.command), let command = editingCommand(event) {
            sendEditingCommand(command, event: event)
            return true
        }
        // Native Command shortcuts, including Control-Command-F, fall through to AppKit.
        guard window?.isKeyWindow == true, window?.firstResponder === self,
              !reservedForMac(event),
              let key = DesktopKeyboardPolicy.commandControlKey(keyCode: event.keyCode,
                  command: event.modifierFlags.contains(.command), control: event.modifierFlags.contains(.control),
                  option: event.modifierFlags.contains(.option)) else {
            return super.performKeyEquivalent(with: event)
        }
        commitPendingPreedit()
        let now = event.timestamp
        let synthetic = DesktopKeyboardPolicy.needsSyntheticControl(heldKeys: held)
        let modifiers = self.modifiers(event.modifierFlags) | 0x02
        if synthetic { input?.setKey(0xA2, pressed: true, modifiers: modifiers, capturedAt: now) }
        input?.setKey(key, pressed: true, modifiers: modifiers, capturedAt: now)
        input?.setKey(key, pressed: false, modifiers: modifiers, capturedAt: now)
        if synthetic { input?.setKey(0xA2, pressed: false, modifiers: modifiers & ~0x02, capturedAt: now) }
        return true
    }
    private func editingCommand(_ event: NSEvent) -> DesktopTextEventState.RemoteCommand? {
        DesktopKeyboardPolicy.editingCommand(keyCode: event.keyCode, command: event.modifierFlags.contains(.command),
            option: event.modifierFlags.contains(.option), control: event.modifierFlags.contains(.control),
            shift: event.modifierFlags.contains(.shift), physicalMode: keyboardMode == .physicalKeys, composing: hasMarkedText())
    }
    private func sendEditingCommand(_ command: DesktopTextEventState.RemoteCommand, event: NSEvent) {
        let modifiers = self.modifiers(event.modifierFlags) | command.additionalModifiers
        let syntheticControl = command.additionalModifiers & 2 != 0 && DesktopKeyboardPolicy.needsSyntheticControl(heldKeys: held)
        if syntheticControl { input?.setKey(0xA2, pressed: true, modifiers: modifiers, capturedAt: event.timestamp) }
        input?.setKey(command.virtualKey, pressed: true, modifiers: modifiers, capturedAt: event.timestamp)
        input?.setKey(command.virtualKey, pressed: false, modifiers: modifiers, capturedAt: event.timestamp)
        if syntheticControl { input?.setKey(0xA2, pressed: false, modifiers: modifiers & ~2, capturedAt: event.timestamp) }
    }
    override func keyDown(with event: NSEvent) {
        guard !reservedForMac(event), !event.modifierFlags.contains(.command) else { return }
        input?.setFocused(true)
        if let command = editingCommand(event) {
            sendEditingCommand(command, event: event)
            return
        }
        let physicalKeyHeld = Self.keys[event.keyCode].map { held.contains($0) } ?? false
        if keyboardMode == .localIME,
           DesktopKeyboardPolicy.shouldInterpretText(isRepeat: event.isARepeat, composing: hasMarkedText(), physicalKeyHeld: physicalKeyHeld),
           event.modifierFlags.isDisjoint(with: [.command, .control]) {
            interpreting = event
            composingEvent = hasMarkedText()
            textEvent.begin(composing: composingEvent)
            interpretKeyEvents([event])
            interpreting = nil
            if let command = textEvent.command {
                commitPendingPreedit()
                let modifiers = self.modifiers(event.modifierFlags) | command.additionalModifiers
                input?.setKey(command.virtualKey, pressed: true, modifiers: modifiers, capturedAt: event.timestamp)
                input?.setKey(command.virtualKey, pressed: false, modifiers: modifiers, capturedAt: event.timestamp)
                return
            }
            if textEvent.consumed || hasMarkedText() { return }
        } else if hasMarkedText() { commitPendingPreedit() }
        guard DesktopKeyboardPolicy.shouldSendPhysicalKeyDown(isRepeat: event.isARepeat, physicalKeyHeld: physicalKeyHeld),
              let key = Self.keys[event.keyCode] else { return }
        held.insert(key)
        input?.setKey(key, pressed: true, modifiers: self.modifiers(event.modifierFlags), capturedAt: event.timestamp)
    }
    override func keyUp(with event: NSEvent) {
        guard let key = Self.keys[event.keyCode], held.remove(key) != nil else { return }
        input?.setKey(key, pressed: false, modifiers: self.modifiers(event.modifierFlags), capturedAt: event.timestamp)
    }
    override func flagsChanged(with event: NSEvent) {
        if [58, 61].contains(event.keyCode),
           !DesktopKeyboardPolicy.forwardsOption(physicalMode: keyboardMode == .physicalKeys, keyCode: event.keyCode) { return }
        if DesktopKeyboardPolicy.forwardsCapsLock(physicalMode: keyboardMode == .physicalKeys, keyCode: event.keyCode) {
            // A Caps Lock flags transition represents one toggle; release immediately to avoid a held lock key.
            input?.setKey(0x14, pressed: true, modifiers: self.modifiers(event.modifierFlags), capturedAt: event.timestamp)
            input?.setKey(0x14, pressed: false, modifiers: self.modifiers(event.modifierFlags), capturedAt: event.timestamp)
            return
        }
        let sides: [UInt16:(UInt16,NSEvent.ModifierFlags)] = [56:(0xA0,.shift),60:(0xA1,.shift),59:(0xA2,.control),62:(0xA3,.control),58:(0xA4,.option),61:(0xA5,.option)]
        guard let (key, flag) = sides[event.keyCode] else { return }
        let pressed = event.modifierFlags.contains(flag) && !held.contains(key)
        if pressed { held.insert(key) } else { held.remove(key) }
        input?.setKey(key, pressed: pressed, modifiers: self.modifiers(event.modifierFlags), capturedAt: event.timestamp)
    }
    private func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt8 {
        DesktopKeyboardPolicy.modifierByte(control: flags.contains(.control),
            shift: flags.contains(.shift), option: flags.contains(.option), physicalMode: keyboardMode == .physicalKeys)
    }
    @discardableResult private func position(_ event: NSEvent) -> Bool {
        guard hostSize.width > 0, hostSize.height > 0 else { return false }
        let scale = min(bounds.width / hostSize.width, bounds.height / hostSize.height)
        guard scale > 0 else { return false }
        let size = CGSize(width: hostSize.width * scale, height: hostSize.height * scale)
        let origin = CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        let p = convert(event.locationInWindow, from: nil)
        guard p.x >= origin.x, p.x <= origin.x + size.width, p.y >= origin.y, p.y <= origin.y + size.height else { return false }
        input?.positionPointer(x: (p.x-origin.x)/scale, y: (origin.y+size.height-p.y)/scale,
            width: Int(hostSize.width), height: Int(hostSize.height), capturedAt: event.timestamp)
        return true
    }
    override func mouseMoved(with event: NSEvent) { position(event) }
    override func mouseDragged(with event: NSEvent) { position(event) }
    override func rightMouseDragged(with event: NSEvent) { position(event) }
    override func otherMouseDragged(with event: NSEvent) { position(event) }
    private func button(_ event: NSEvent, pressed: Bool) {
        window?.makeFirstResponder(self)
        input?.setFocused(true)
        if pressed { commitPendingPreedit() }
        input?.afterDesktopText(capturedAt: event.timestamp) { [weak self] in
            guard let self else { return }
            let inside = self.position(event)
            guard !pressed || inside else { return }
            let buttons: [Int:PointerButton] = [0:.left,1:.right,2:.middle,3:.back,4:.forward]
            if let button = buttons[event.buttonNumber] {
                self.input?.setPointerButton(button, pressed: pressed, capturedAt: event.timestamp)
            }
        }
    }
    override func mouseDown(with event: NSEvent) { button(event, pressed: true) }
    override func mouseUp(with event: NSEvent) { button(event, pressed: false) }
    override func rightMouseDown(with event: NSEvent) { button(event, pressed: true) }
    override func rightMouseUp(with event: NSEvent) { button(event, pressed: false) }
    override func otherMouseDown(with event: NSEvent) { button(event, pressed: true) }
    override func otherMouseUp(with event: NSEvent) { button(event, pressed: false) }
    override func scrollWheel(with event: NSEvent) {
        input?.scroll(x: event.scrollingDeltaX, y: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas, capturedAt: event.timestamp)
        if event.phase == .ended || event.momentumPhase == .ended { input?.endScroll() }
    }

    // NSTextInputClient: macOS owns composition; only committed text reaches Windows.
    func insertText(_ string: Any, replacementRange: NSRange) {
        guard !discardingMarkedText else { return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        let physical = interpreting.map {
            Self.keys[$0.keyCode] != nil && DesktopKeyboardPolicy.usesPhysicalText(text, eventText: $0.characters,
                composing: composingEvent || hasMarkedText(), option: $0.modifierFlags.contains(.option),
                capsLock: $0.modifierFlags.contains(.capsLock))
        } == true
        composition.clear()
        refreshPreedit()
        guard !physical, !text.isEmpty else { return }
        textEvent.didCommitText()
        input?.commitText(text, capturedAt: interpreting?.timestamp ?? ProcessInfo.processInfo.systemUptime)
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard !discardingMarkedText else { return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        composition.setMarked(text, selection: selectedRange)
        textEvent.didUpdateMarkedText()
        refreshPreedit()
    }
    private func commitPendingPreedit() {
        guard hasMarkedText() else { return }
        // Queue the stored preedit once, then end the input method's marked session.
        // Synchronous discard callbacks must not recommit or recreate that preedit.
        unmarkText()
        discardInputContextMarkedText()
    }
    func unmarkText() {
        guard !discardingMarkedText else { return }
        let text = composition.finish(.remoteAction)
        refreshPreedit()
        if !text.isEmpty {
            textEvent.didCommitText()
            input?.commitText(text, capturedAt: ProcessInfo.processInfo.systemUptime)
        }
    }
    func hasMarkedText() -> Bool { composition.isVisible }
    func markedRange() -> NSRange { composition.markedRange }
    func selectedRange() -> NSRange { composition.selection }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let valid = composition.clampedRange(range) else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return nil
        }
        actualRange?.pointee = valid
        return NSAttributedString(string: composition.text).attributedSubstring(from: valid)
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = composition.clampedRange(range) ?? composition.selection
        // Candidates attach to the exact native preedit surface that displays the composing text.
        let anchor = preedit.frame.insetBy(dx: 8, dy: 4)
        return window?.convertToScreen(convert(anchor, to: nil)) ?? .zero
    }
    override func doCommand(by selector: Selector) {
        guard !discardingMarkedText else { return }
        if selector == #selector(cancelOperation(_:)), hasMarkedText() {
            cancelComposition()
            textEvent.cancel()
        } else if interpreting != nil {
            textEvent.didCommand(NSStringFromSelector(selector))
        }
    }

    // Positional Carbon keycode -> Windows VK, from Glimmer KeyboardScanMap.swift (GPLv3).
    private static let keys: [UInt16:UInt16] = [
        0:0x41,1:0x53,2:0x44,3:0x46,4:0x48,5:0x47,6:0x5A,7:0x58,8:0x43,9:0x56,11:0x42,
        12:0x51,13:0x57,14:0x45,15:0x52,16:0x59,17:0x54,18:0x31,19:0x32,20:0x33,21:0x34,
        22:0x36,23:0x35,24:0xBB,25:0x39,26:0x37,27:0xBD,28:0x38,29:0x30,30:0xDD,31:0x4F,
        32:0x55,33:0xDB,34:0x49,35:0x50,36:0x0D,37:0x4C,38:0x4A,39:0xDE,40:0x4B,41:0xBA,
        42:0xDC,43:0xBC,44:0xBF,45:0x4E,46:0x4D,47:0xBE,48:0x09,49:0x20,50:0xC0,51:0x08,53:0x1B,
        65:0x6E,67:0x6A,69:0x6B,71:0x0C,75:0x6F,76:0x0D,78:0x6D,81:0xBB,82:0x60,83:0x61,
        84:0x62,85:0x63,86:0x64,87:0x65,88:0x66,89:0x67,91:0x68,92:0x69,
        96:0x74,97:0x75,98:0x76,99:0x72,100:0x77,101:0x78,103:0x7A,109:0x79,111:0x7B,
        115:0x24,116:0x21,117:0x2E,118:0x73,119:0x23,120:0x71,121:0x22,122:0x70,
        123:0x25,124:0x27,125:0x28,126:0x26]
}
