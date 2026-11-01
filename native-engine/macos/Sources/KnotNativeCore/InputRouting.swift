import Foundation

public struct KeyboardModifiers: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = Self(rawValue: 1)
    public static let control = Self(rawValue: 2)
    public static let option = Self(rawValue: 4)
    public static let command = Self(rawValue: 8)
    public var hasShortcut: Bool { !intersection([.control, .command]).isEmpty }
}

/// Text is interpreted by AppKit; scan codes are reserved for physical commands.
/// Caps Lock belongs to the local input source, including its long-press behavior.
public enum MacKeyboardRouting {
    public enum Route: Equatable, Sendable { case localCapsLock, localSpace, interpretText, physical }
    public static let modifierKeys: [UInt16: KeyboardModifiers] = [
        56: .shift, 60: .shift, 59: .control, 62: .control,
        58: .option, 61: .option, 55: .command, 54: .command
    ]
    private static let commands: Set<UInt16> = [
        36, 48, 51, 53, 76, 114, 115, 116, 117, 119, 121, 123, 124, 125, 126,
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111
    ]
    public static func isCommandKey(_ keyCode: UInt16) -> Bool { commands.contains(keyCode) }
    public static func route(keyCode: UInt16, modifiers: KeyboardModifiers, textMode: Bool,
                             hasMarkedText: Bool, ownsPhysicalDown: Bool) -> Route {
        if keyCode == 57 { return .localCapsLock }
        if ownsPhysicalDown { return .physical }
        if modifiers.contains(.control), (123...126).contains(keyCode) { return .localSpace }
        if !textMode || modifiers.hasShortcut { return .physical }
        // During composition the input method gets editing, commit and cancel keys.
        if hasMarkedText { return .interpretText }
        return commands.contains(keyCode) ? .physical : .interpretText
    }
    /// A local AppKit key-up monitor may compensate only a Command-modified
    /// release already owned by this focused presenter, never a new input.
    public static func compensatesCommandKeyUp(keyCode: UInt16, modifiers: KeyboardModifiers,
                                               ownsPhysicalDown: Bool, focused: Bool, sameWindow: Bool) -> Bool {
        focused && sameWindow && modifiers.contains(.command) && ownsPhysicalDown &&
        keyCode != 57 && modifierKeys[keyCode] == nil && WindowsScanCodes.map[keyCode] != nil
    }
}

/// Tracks local left/right modifiers independently from remotely owned downs.
public struct KeyboardModifierState: Sendable {
    private var local: Set<UInt16> = []
    public init() {}
    public mutating func observe(keyCode: UInt16, flags: KeyboardModifiers) {
        guard let family = MacKeyboardRouting.modifierKeys[keyCode] else { return }
        if !flags.contains(family) {
            local = local.filter { MacKeyboardRouting.modifierKeys[$0] != family }
        } else if local.contains(keyCode) { local.remove(keyCode) }
        else { local.insert(keyCode) }
    }
    public func desired(flags: KeyboardModifiers, textMode: Bool, physicalCommand: Bool = false) -> Set<UInt16> {
        var result: Set<UInt16> = []
        for (family, fallback): (KeyboardModifiers, UInt16) in [(.shift, 56), (.control, 59), (.option, 58), (.command, 55)] {
            guard flags.contains(family) else { continue }
            if textMode && !flags.hasShortcut && !physicalCommand { continue }
            let sides = local.filter { MacKeyboardRouting.modifierKeys[$0] == family }
            if sides.isEmpty { result.insert(fallback) } else { result.formUnion(sides) }
        }
        return result
    }
    public mutating func reset() { local.removeAll() }
}

/// A recovery click alone must not authorize a late commit from revoked preedit.
public struct TextCommitAuthorization: Sendable {
    private var epoch: UInt64?
    private var interpreting = false
    private var composing = false
    public init() {}
    public mutating func begin(epoch: UInt64) { self.epoch = epoch; interpreting = true }
    public mutating func end() { interpreting = false; if !composing { epoch = nil } }
    public mutating func mark() { if epoch != nil { composing = true } }
    public func allows(epoch: UInt64, focused: Bool, streaming: Bool, recovery: Bool) -> Bool {
        self.epoch == epoch && (interpreting || composing) && focused && streaming && !recovery
    }
    public mutating func committed() { composing = false; if !interpreting { epoch = nil } }
    public mutating func revoke() { epoch = nil; interpreting = false; composing = false }
}
