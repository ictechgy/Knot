import Foundation
import Testing
@testable import KnotNativeCore

@Test func macTypingUsesCommittedTextWhileCapsLockRemainsLocal() throws {
    for modifiers: KeyboardModifiers in [[], .shift, .option, [.shift, .option]] {
        #expect(MacKeyboardRouting.route(keyCode: 0, modifiers: modifiers, textMode: true,
            hasMarkedText: false, ownsPhysicalDown: false) == .interpretText)
    }
    for textMode in [true, false] {
        #expect(MacKeyboardRouting.route(keyCode: 57, modifiers: [.control, .shift], textMode: textMode,
            hasMarkedText: false, ownsPhysicalDown: false) == .localCapsLock)
    }
    for text in ["lowercase", "UPPERCASE", "aA", "한글", "가aA"] {
        #expect(String(data: try Input.text(text).payload, encoding: .utf8) == text)
    }
}

@Test func navigationAndFunctionKeysStayPhysicalWithoutStealingComposition() {
    for code: UInt16 in [36, 48, 51, 53, 115, 119, 116, 121, 117, 123, 124, 125, 126, 122, 111] {
        #expect(MacKeyboardRouting.route(keyCode: code, modifiers: .shift, textMode: true,
            hasMarkedText: false, ownsPhysicalDown: false) == .physical)
        #expect(MacKeyboardRouting.route(keyCode: code, modifiers: [], textMode: true,
            hasMarkedText: true, ownsPhysicalDown: false) == .interpretText)
    }
    #expect(MacKeyboardRouting.route(keyCode: 8, modifiers: [.control, .shift], textMode: true,
        hasMarkedText: true, ownsPhysicalDown: false) == .physical)
    #expect(MacKeyboardRouting.route(keyCode: 0, modifiers: [], textMode: false,
        hasMarkedText: false, ownsPhysicalDown: false) == .physical)
}

@Test func ownedPhysicalRepeatsAndMacSpaceCommandsRetainTheirOwners() {
    var keys = PhysicalKeyOwnership()
    keys.press(8)
    #expect(MacKeyboardRouting.route(keyCode: 8, modifiers: [], textMode: true,
        hasMarkedText: false, ownsPhysicalDown: keys.owns(8)) == .physical)
    let firstRelease = keys.release(8), duplicateRelease = keys.release(8)
    #expect(firstRelease)
    #expect(!duplicateRelease)
    #expect(MacKeyboardRouting.route(keyCode: 8, modifiers: [], textMode: true,
        hasMarkedText: false, ownsPhysicalDown: keys.owns(8)) == .interpretText)
    for arrow: UInt16 in [123, 124, 125, 126] {
        #expect(MacKeyboardRouting.route(keyCode: arrow, modifiers: [.control, .shift], textMode: false,
            hasMarkedText: false, ownsPhysicalDown: false) == .localSpace)
    }
}

@Test func physicalShortcutsSynchronizeModifiersHeldBeforeControl() {
    var state = KeyboardModifierState()
    state.observe(keyCode: 56, flags: .shift)
    #expect(state.desired(flags: .shift, textMode: true).isEmpty)
    state.observe(keyCode: 59, flags: [.shift, .control])
    #expect(state.desired(flags: [.shift, .control], textMode: true) == [56, 59])
    state.observe(keyCode: 58, flags: [.shift, .control, .option])
    #expect(state.desired(flags: [.shift, .control, .option], textMode: true) == [56, 58, 59])
    state.observe(keyCode: 59, flags: [.shift, .option])
    #expect(state.desired(flags: [.shift, .option], textMode: true).isEmpty)
    #expect(state.desired(flags: [.shift, .option], textMode: true, physicalCommand: true) == [56, 58])
    #expect(state.desired(flags: [.shift, .option], textMode: false) == [56, 58])
}

@Test func ownedArrowRepeatsStayRemoteWhenControlIsPressedLater() {
    for textMode in [true, false] {
        var keys = PhysicalKeyOwnership()
        keys.press(124)
        #expect(MacKeyboardRouting.route(keyCode: 124, modifiers: [.control], textMode: textMode,
            hasMarkedText: false, ownsPhysicalDown: keys.owns(124)) == .physical)
        let released = keys.release(124)
        #expect(released && keys.count == 0)
        #expect(MacKeyboardRouting.route(keyCode: 124, modifiers: [.control], textMode: textMode,
            hasMarkedText: false, ownsPhysicalDown: keys.owns(124)) == .localSpace)
    }
}

@Test func commandKeyUpCompensationIsScopedOwnedNonmodifierAndExactlyOnce() {
    var keys = PhysicalKeyOwnership()
    keys.press(55); keys.press(15) // Win/Command + R forwarded by this presenter.
    for (focused, sameWindow, flags): (Bool, Bool, KeyboardModifiers) in [
        (false, true, .command), (true, false, .command), (true, true, [])
    ] {
        #expect(!MacKeyboardRouting.compensatesCommandKeyUp(keyCode: 15, modifiers: flags,
            ownsPhysicalDown: keys.owns(15), focused: focused, sameWindow: sameWindow))
    }
    for code: UInt16 in [55, 57, 300] {
        #expect(!MacKeyboardRouting.compensatesCommandKeyUp(keyCode: code, modifiers: .command,
            ownsPhysicalDown: true, focused: true, sameWindow: true))
    }
    #expect(MacKeyboardRouting.compensatesCommandKeyUp(keyCode: 15, modifiers: .command,
        ownsPhysicalDown: keys.owns(15), focused: true, sameWindow: true))
    let rUp = keys.release(15)
    #expect(rUp && keys.count == 1 && keys.owns(55))
    #expect(!MacKeyboardRouting.compensatesCommandKeyUp(keyCode: 15, modifiers: .command,
        ownsPhysicalDown: keys.owns(15), focused: true, sameWindow: true))
    let duplicateUp = keys.release(15), commandUp = keys.release(55)
    #expect(!duplicateUp && commandUp && keys.count == 0)
    var modifiers = KeyboardModifierState()
    modifiers.observe(keyCode: 55, flags: .command)
    modifiers.observe(keyCode: 55, flags: [])
    #expect(modifiers.desired(flags: .shift, textMode: true).isEmpty)
}

@Test func bothModifierSidesAndMissingFlagsEventsRemainBalanced() {
    var state = KeyboardModifierState()
    state.observe(keyCode: 56, flags: .shift)
    state.observe(keyCode: 60, flags: .shift)
    #expect(state.desired(flags: .shift, textMode: false) == [56, 60])
    state.observe(keyCode: 56, flags: .shift)
    #expect(state.desired(flags: .shift, textMode: false) == [60])
    state.observe(keyCode: 60, flags: [])
    #expect(state.desired(flags: [], textMode: false).isEmpty)
    state.reset()
    #expect(state.desired(flags: [.control, .option, .command, .shift], textMode: true) == [56, 58, 59, 55])
}

@Test func compositionAuthorizationRejectsLateCommitsAfterFocusRecovery() {
    var gate = TextCommitAuthorization()
    #expect(!gate.allows(epoch: 1, focused: true, streaming: true, recovery: false))
    gate.begin(epoch: 1)
    #expect(gate.allows(epoch: 1, focused: true, streaming: true, recovery: false))
    gate.mark(); gate.end()
    #expect(gate.allows(epoch: 1, focused: true, streaming: true, recovery: false))
    #expect(!gate.allows(epoch: 1, focused: false, streaming: true, recovery: false))
    #expect(!gate.allows(epoch: 1, focused: true, streaming: false, recovery: false))
    #expect(!gate.allows(epoch: 1, focused: true, streaming: true, recovery: true))
    gate.revoke()
    #expect(!gate.allows(epoch: 2, focused: true, streaming: true, recovery: false))
    gate.begin(epoch: 2)
    #expect(!gate.allows(epoch: 1, focused: true, streaming: true, recovery: false))
    #expect(gate.allows(epoch: 2, focused: true, streaming: true, recovery: false))
    gate.committed(); gate.end()
    #expect(!gate.allows(epoch: 2, focused: true, streaming: true, recovery: false))
}
