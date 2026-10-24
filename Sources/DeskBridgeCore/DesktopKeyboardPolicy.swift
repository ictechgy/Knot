// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Pure routing decisions shared by the native adapter and offline checks.
public struct DesktopKeyboardPolicy {
    /// Local editing gestures must remain usable while Control-arrows belong to Spaces.
    public static func editingCommand(keyCode: UInt16, command: Bool, option: Bool, control: Bool,
                                      shift: Bool, physicalMode: Bool, composing: Bool) -> DesktopTextEventState.RemoteCommand? {
        guard !physicalMode, !composing, !control else { return nil }
        let key: UInt16
        var modifiers: UInt8 = shift ? 1 : 0
        if command && !option {
            switch keyCode {
            case 123: key = 0x24 // Home
            case 124: key = 0x23 // End
            case 126: key = 0x24; modifiers |= 2 // Control-Home
            case 125: key = 0x23; modifiers |= 2 // Control-End
            default: return nil
            }
        } else if option && !command {
            switch keyCode {
            case 123: key = 0x25
            case 124: key = 0x27
            case 51: key = 0x08
            case 117: key = 0x2E
            default: return nil
            }
            modifiers |= 2
        } else { return nil }
        return .init(virtualKey: key, additionalModifiers: modifiers)
    }
    public static func reservesSpaceShortcut(keyCode: UInt16, control: Bool, shift: Bool, option: Bool) -> Bool {
        control && !shift && !option && [123, 124, 125, 126].contains(keyCode)
    }
    /// Only ordinary Command editing shortcuts become remote Control shortcuts.
    /// Additional Control/Option modifiers keep native commands such as Control-Command-F local.
    public static func commandControlKey(keyCode: UInt16, command: Bool, control: Bool, option: Bool) -> UInt16? {
        guard command, !control, !option else { return nil }
        switch keyCode {
        case 0: return 0x41 // A
        case 8: return 0x43 // C
        case 9: return 0x56 // V
        case 7: return 0x58 // X
        case 6: return 0x5A // Z
        case 1: return 0x53 // S
        case 3: return 0x46 // F
        case 37: return 0x4C // L
        default: return nil
        }
    }
    /// Physical keys repeat on Windows. Committed text has no held remote key, so macOS supplies its repeats.
    public static func shouldInterpretText(isRepeat: Bool, composing: Bool, physicalKeyHeld: Bool) -> Bool {
        !isRepeat || composing || !physicalKeyHeld
    }
    public static func shouldSendPhysicalKeyDown(isRepeat: Bool, physicalKeyHeld: Bool) -> Bool {
        !isRepeat || !physicalKeyHeld
    }
    public static func modifierByte(control: Bool, shift: Bool, option: Bool, physicalMode: Bool = true) -> UInt8 {
        (control ? 0x02 : 0) | (shift ? 0x01 : 0) | (option && physicalMode ? 0x04 : 0)
    }
    public static func forwardsOption(physicalMode: Bool, keyCode: UInt16) -> Bool {
        physicalMode && [58, 61].contains(keyCode)
    }
    public static func usesPhysicalText(_ text: String, eventText: String?, composing: Bool,
                                 option: Bool, capsLock: Bool) -> Bool {
        !composing && !option && !capsLock && !text.isEmpty && text.unicodeScalars.allSatisfy(\.isASCII)
            && text == eventText
    }
    public static func forwardsCapsLock(physicalMode: Bool, keyCode: UInt16) -> Bool {
        physicalMode && keyCode == 57
    }
    public static func needsSyntheticControl(heldKeys: Set<UInt16>) -> Bool {
        heldKeys.isDisjoint(with: [0xA2, 0xA3])
    }
}

/// One interpretKeyEvents call may commit a syllable and then request an editing command.
/// Keep those callbacks separate so consuming text does not swallow the following key.
public struct DesktopTextEventState: Sendable {
    public struct RemoteCommand: Equatable, Sendable {
        public let virtualKey: UInt16
        public let additionalModifiers: UInt8
    }
    public private(set) var consumed = false
    public private(set) var command: RemoteCommand?
    private var beganComposing = false
    private var committedText = false
    private var updatedMarkedText = false
    public init() {}
    public mutating func begin(composing: Bool) {
        beganComposing = composing
        consumed = composing
        committedText = false
        updatedMarkedText = false
        command = nil
    }
    public mutating func didCommitText() {
        committedText = true
        consumed = true
    }
    public mutating func didUpdateMarkedText() {
        updatedMarkedText = true
        consumed = true
        command = nil
    }
    public mutating func cancel() { consumed = true; command = nil }
    public mutating func didCommand(_ selector: String) {
        // With no IME callbacks, retain ordinary positional key down/up and host repeat.
        guard consumed else { return }
        let key: UInt16
        var modifiers: UInt8 = 0
        switch selector {
        case "insertNewline:", "insertNewlineIgnoringFieldEditor:", "insertLineBreak:", "insertParagraphSeparator:": key = 0x0D
        case "insertTab:": key = 0x09
        case "insertBacktab:": key = 0x09; modifiers = 0x01
        case "moveLeft:", "moveBackward:", "moveLeftAndModifySelection:", "moveBackwardAndModifySelection:": key = 0x25
        case "moveRight:", "moveForward:", "moveRightAndModifySelection:", "moveForwardAndModifySelection:": key = 0x27
        case "moveUp:", "moveUpAndModifySelection:": key = 0x26
        case "moveDown:", "moveDownAndModifySelection:": key = 0x28
        case "moveToBeginningOfLine:", "moveToBeginningOfLineAndModifySelection:": key = 0x24
        case "moveToEndOfLine:", "moveToEndOfLineAndModifySelection:": key = 0x23
        case "pageUp:", "pageUpAndModifySelection:": key = 0x21
        case "pageDown:", "pageDownAndModifySelection:": key = 0x22
        case "deleteBackward:", "deleteBackwardByDecomposingPreviousCharacter:":
            // An empty setMarkedText callback can mean the final marked jamo was deleted.
            guard !updatedMarkedText, !beganComposing || committedText else { return }
            key = 0x08
        case "deleteForward:":
            guard !updatedMarkedText, !beganComposing || committedText else { return }
            key = 0x2E
        default: return
        }
        if selector.hasSuffix("AndModifySelection:") { modifiers |= 0x01 }
        // A text system may repeat a command callback; one physical event gets one tap.
        if command == nil { command = RemoteCommand(virtualKey: key, additionalModifiers: modifiers) }
    }
}

/// NSTextInputClient ranges count UTF-16 code units, rather than Swift Characters.
public struct DesktopCompositionState: Sendable {
    public private(set) var text = ""
    public private(set) var selection = NSRange(location: 0, length: 0)
    public init() {}
    public var isVisible: Bool { !text.isEmpty }
    public var utf16Length: Int { text.utf16.count }
    public var markedRange: NSRange {
        NSRange(location: isVisible ? 0 : NSNotFound, length: utf16Length)
    }
    public mutating func setMarked(_ value: String, selection proposed: NSRange) {
        text = value
        let start = min(max(0, proposed.location), utf16Length)
        selection = NSRange(location: start, length: min(max(0, proposed.length), utf16Length - start))
    }
    public func clampedRange(_ proposed: NSRange) -> NSRange? {
        guard proposed.location != NSNotFound, proposed.location >= 0,
              proposed.length >= 0, proposed.location <= utf16Length else { return nil }
        return NSRange(location: proposed.location, length: min(proposed.length, utf16Length - proposed.location))
    }
    public enum Completion { case remoteAction, cancel }
    /// Editing/saving/clicking the remote document commits; explicit cancellation discards.
    public mutating func finish(_ completion: Completion) -> String {
        let text = clear()
        switch completion {
        case .remoteAction: return text
        case .cancel: return ""
        }
    }
    /// Returning the former text lets commit and cancellation share one clearing transition.
    @discardableResult public mutating func clear() -> String {
        let previous = text
        text = ""
        selection = NSRange(location: 0, length: 0)
        return previous
    }
}
