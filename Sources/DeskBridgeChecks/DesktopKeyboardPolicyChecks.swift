// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import DeskBridgeCore
import GlimmerEngine

@discardableResult
func runDesktopKeyboardPolicyChecks() throws -> Int {
    enum Failure: Error { case mapping }
    var count = 0
    func check(_ value: @autoclosure () -> Bool) throws {
        guard value() else { throw Failure.mapping }
        count += 1
    }
    try check(DesktopKeyboardPolicy.modifierByte(control: true, shift: false, option: false) == 2)
    for (mac, windows): (UInt16, UInt16) in [(0, 0x41), (8, 0x43), (9, 0x56), (7, 0x58),
                                           (6, 0x5A), (1, 0x53), (3, 0x46), (37, 0x4C)] {
        try check(DesktopKeyboardPolicy.commandControlKey(keyCode: mac, command: true, control: false, option: false) == windows)
        for (command, control, option) in [(false, false, false), (true, true, false),
                                           (true, false, true), (true, true, true)] {
            try check(DesktopKeyboardPolicy.commandControlKey(keyCode: mac, command: command, control: control, option: option) == nil)
        }
    }
    for key: UInt16 in [12, 13, 48, 49, 123, 124, 125, 126] { // Q/W/Tab/Space/arrows remain outside this remap.
        try check(DesktopKeyboardPolicy.commandControlKey(keyCode: key, command: true, control: false, option: false) == nil)
    }
    for (mac, windows): (UInt16, UInt16) in [(123, 0x25), (124, 0x27), (51, 0x08), (117, 0x2E)] {
        for shift in [false, true] {
            let command = DesktopKeyboardPolicy.editingCommand(keyCode: mac, command: false, option: true,
                control: false, shift: shift, physicalMode: false, composing: false)
            try check(command?.virtualKey == windows && command?.additionalModifiers == (shift ? 3 : 2))
        }
    }
    for (mac, windows, modifiers): (UInt16, UInt16, UInt8) in [(123, 0x24, 0), (124, 0x23, 0), (126, 0x24, 2), (125, 0x23, 2)] {
        let command = DesktopKeyboardPolicy.editingCommand(keyCode: mac, command: true, option: false,
            control: false, shift: true, physicalMode: false, composing: false)
        try check(command?.virtualKey == windows && command?.additionalModifiers == modifiers | 1)
    }
    for (physical, composing, control) in [(true, false, false), (false, true, false), (false, false, true)] {
        try check(DesktopKeyboardPolicy.editingCommand(keyCode: 123, command: false, option: true,
            control: control, shift: false, physicalMode: physical, composing: composing) == nil)
    }
    try check(DesktopKeyboardPolicy.editingCommand(keyCode: 18, command: false, option: true,
        control: false, shift: false, physicalMode: false, composing: false) == nil) // Option-generated symbols stay text.
    try check(DesktopKeyboardPolicy.modifierByte(control: false, shift: true, option: false) == 1)
    try check(DesktopKeyboardPolicy.modifierByte(control: true, shift: true, option: true) == 7)
    for key: UInt16 in [58, 61] {
        try check(!DesktopKeyboardPolicy.forwardsOption(physicalMode: false, keyCode: key))
        try check(DesktopKeyboardPolicy.forwardsOption(physicalMode: true, keyCode: key))
    }
    try check(!DesktopKeyboardPolicy.forwardsOption(physicalMode: true, keyCode: 56))
    try check(DesktopKeyboardPolicy.modifierByte(control: false, shift: false, option: true, physicalMode: false) == 0)
    try check(DesktopKeyboardPolicy.modifierByte(control: true, shift: true, option: true, physicalMode: false) == 3)
    try check(DesktopKeyboardPolicy.modifierByte(control: true, shift: true, option: true, physicalMode: true) == 7)
    for arrow: UInt16 in [123, 124, 125, 126] {
        try check(DesktopKeyboardPolicy.reservesSpaceShortcut(keyCode: arrow, control: true, shift: false, option: false))
        try check(!DesktopKeyboardPolicy.reservesSpaceShortcut(keyCode: arrow, control: true, shift: true, option: false))
        try check(!DesktopKeyboardPolicy.reservesSpaceShortcut(keyCode: arrow, control: true, shift: false, option: true))
    }
    try check(DesktopKeyboardPolicy.usesPhysicalText("a", eventText: "a", composing: false, option: false, capsLock: false))
    for text in ["한", "™", "é", "🦀"] {
        try check(!DesktopKeyboardPolicy.usesPhysicalText(text, eventText: text, composing: false, option: false, capsLock: false))
    }
    try check(!DesktopKeyboardPolicy.usesPhysicalText("@", eventText: "@", composing: false, option: true, capsLock: false))
    try check(!DesktopKeyboardPolicy.usesPhysicalText("A", eventText: "A", composing: false, option: false, capsLock: true))
    try check(!DesktopKeyboardPolicy.usesPhysicalText("a", eventText: "a", composing: true, option: false, capsLock: false))
    try check(DesktopKeyboardPolicy.needsSyntheticControl(heldKeys: []))
    try check(!DesktopKeyboardPolicy.needsSyntheticControl(heldKeys: [0xA2]))
    try check(!DesktopKeyboardPolicy.needsSyntheticControl(heldKeys: [0xA3, 0xA0]))
    try check(DesktopKeyboardPolicy.forwardsCapsLock(physicalMode: true, keyCode: 57))
    try check(!DesktopKeyboardPolicy.forwardsCapsLock(physicalMode: false, keyCode: 57))
    try check(!DesktopKeyboardPolicy.forwardsCapsLock(physicalMode: true, keyCode: 56))
    // Reproduce a held text key through the adapter's interpretation/physical/release decisions.
    // Unicode commits must repeat locally; an ASCII key must remain one remote down/up pair.
    func holdText(_ text: String, option: Bool = false, capsLock: Bool = false) -> [String] {
        var physicalHeld = false
        var output: [String] = []
        for repeated in [false, true, true] {
            if DesktopKeyboardPolicy.shouldInterpretText(isRepeat: repeated, composing: false, physicalKeyHeld: physicalHeld),
               !DesktopKeyboardPolicy.usesPhysicalText(text, eventText: text, composing: false, option: option, capsLock: capsLock) {
                output.append("text:" + text)
                continue
            }
            if DesktopKeyboardPolicy.shouldSendPhysicalKeyDown(isRepeat: repeated, physicalKeyHeld: physicalHeld) {
                physicalHeld = true; output.append("down")
            }
        }
        if physicalHeld { output.append("up") }
        return output
    }
    try check(holdText("a") == ["down", "up"])
    try check(holdText("A", capsLock: true) == ["text:A", "text:A", "text:A"])
    try check(holdText("™", option: true) == ["text:™", "text:™", "text:™"])
    try check(holdText("한") == ["text:한", "text:한", "text:한"])
    try check(DesktopKeyboardPolicy.shouldInterpretText(isRepeat: true, composing: true, physicalKeyHeld: true))
    var composition = DesktopCompositionState()
    try check(!composition.isVisible && composition.markedRange.location == NSNotFound)
    composition.setMarked("ㅎ", selection: NSRange(location: 1, length: 0))
    try check(composition.isVisible && composition.markedRange == NSRange(location: 0, length: 1))
    composition.setMarked("한", selection: NSRange(location: 0, length: 1))
    try check(composition.text == "한" && composition.selection.length == 1)
    composition.setMarked("한🦀e\u{301}", selection: NSRange(location: 1, length: 2))
    try check(composition.utf16Length == 5 && composition.selection == NSRange(location: 1, length: 2))
    let emojiRange = composition.clampedRange(NSRange(location: 1, length: 2))!
    try check((composition.text as NSString).substring(with: emojiRange) == "🦀")
    composition.setMarked("한", selection: NSRange(location: NSNotFound, length: Int.max))
    try check(composition.selection == NSRange(location: 1, length: 0))
    try check(composition.clampedRange(NSRange(location: 0, length: Int.max)) == NSRange(location: 0, length: 1))
    try check(composition.clampedRange(NSRange(location: NSNotFound, length: 1)) == nil)
    try check(composition.clampedRange(NSRange(location: 2, length: 0)) == nil)
    try check(composition.clear() == "한")
    try check(!composition.isVisible && composition.selection == NSRange(location: 0, length: 0))
    composition.setMarked("가", selection: NSRange(location: 1, length: 0))
    composition.clear() // mode/focus/Escape cancellation uses this same state transition without sending text.
    try check(!composition.isVisible && composition.text.isEmpty)
    composition.setMarked("한", selection: NSRange(location: 1, length: 0))
    try check(composition.finish(.remoteAction) == "한" && !composition.isVisible)
    composition.setMarked("한", selection: NSRange(location: 1, length: 0))
    try check(composition.finish(.cancel).isEmpty && !composition.isVisible)
    // Reproduce NSTextInputClient callback sequences without a view, input context, or preferences.
    var callbacks = DesktopTextEventState()
    callbacks.begin(composing: true)
    composition.setMarked("하", selection: NSRange(location: 1, length: 0))
    let syllable = composition.clear() // insertText("하") followed by setMarkedText("ㄴ").
    callbacks.didCommitText()
    composition.setMarked("ㄴ", selection: NSRange(location: 1, length: 0))
    callbacks.didUpdateMarkedText()
    try check(syllable == "하" && composition.text == "ㄴ" && callbacks.consumed && callbacks.command == nil)
    for (selector, key): (String, UInt16) in [
        ("insertNewline:", 0x0D), ("insertTab:", 0x09), ("moveLeft:", 0x25),
        ("moveRight:", 0x27), ("moveUp:", 0x26), ("moveDown:", 0x28)] {
        callbacks.begin(composing: true)
        callbacks.didCommitText() // insertText("한") must not swallow this subsequent command.
        callbacks.didCommand(selector)
        callbacks.didCommand(selector) // One event still produces one down/up pair.
        try check(callbacks.consumed && callbacks.command?.virtualKey == key)
    }
    callbacks.begin(composing: true)
    callbacks.didCommitText()
    callbacks.didCommand("insertBacktab:")
    try check(callbacks.command?.virtualKey == 0x09 && callbacks.command?.additionalModifiers == 1)
    callbacks.begin(composing: true)
    composition.setMarked("", selection: NSRange(location: 0, length: 0)) // Backspace deletes the final jamo.
    callbacks.didUpdateMarkedText()
    callbacks.didCommand("deleteBackward:")
    try check(callbacks.consumed && callbacks.command == nil && !composition.isVisible)
    // IME consumed the initial deletion; holding Backspace must start one remote down after preedit clears.
    var heldAfterIME = false
    callbacks.begin(composing: false); callbacks.didCommand("deleteBackward:")
    try check(!callbacks.consumed && callbacks.command == nil)
    try check(DesktopKeyboardPolicy.shouldInterpretText(isRepeat: true, composing: false, physicalKeyHeld: heldAfterIME))
    if DesktopKeyboardPolicy.shouldSendPhysicalKeyDown(isRepeat: true, physicalKeyHeld: heldAfterIME) { heldAfterIME = true }
    try check(heldAfterIME)
    try check(!DesktopKeyboardPolicy.shouldSendPhysicalKeyDown(isRepeat: true, physicalKeyHeld: heldAfterIME))
    try check(!DesktopKeyboardPolicy.shouldInterpretText(isRepeat: true, composing: false, physicalKeyHeld: heldAfterIME))
    heldAfterIME = false // The matching keyUp releases the single recorded down.
    try check(DesktopKeyboardPolicy.shouldSendPhysicalKeyDown(isRepeat: false, physicalKeyHeld: heldAfterIME))
    for selector in ["moveLeftAndModifySelection:", "moveToEndOfLineAndModifySelection:", "pageDownAndModifySelection:"] {
        callbacks.begin(composing: true); callbacks.didCommitText(); callbacks.didCommand(selector)
        try check(callbacks.command?.additionalModifiers == 1)
    }
    callbacks.begin(composing: true)
    callbacks.didCommand("deleteBackward:") // An IME can consume a deletion without another marked callback.
    try check(callbacks.consumed && callbacks.command == nil)
    callbacks.begin(composing: false)
    callbacks.didCommand("insertNewline:") // Normal physical Return retains the native keydown/keyup path.
    try check(!callbacks.consumed && callbacks.command == nil)
    callbacks.begin(composing: true)
    callbacks.didCommand("moveLeft:")
    callbacks.didUpdateMarkedText() // A later marked update means the IME kept handling this event.
    try check(callbacks.consumed && callbacks.command == nil)
    callbacks.begin(composing: true)
    callbacks.didCommitText()
    callbacks.didCommand("insertNewline:")
    callbacks.cancel()
    try check(callbacks.consumed && callbacks.command == nil)
    for kind in [DesktopInputWire.Kind.keyboard, .mouse, .text] {
        try check(DesktopInputWire.channel(for: kind, desktopOrdering: true) == 2)
    }
    try check(DesktopInputWire.channel(for: .mouse, desktopOrdering: false) == 3)
    try check(DesktopInputWire.channel(for: .text, desktopOrdering: false) == 6)
    // Exercise the exact resumable packet cursor used by InputBatcher with a controlled acceptance failure.
    var submission = DesktopTextSubmission()
    let text = String(repeating: "한", count: 30)
    var attempts = 0
    var accepted: [[UInt8]] = []
    let failed = submission.submit(text) { packet in
        attempts += 1
        if attempts == 2 { return -1 }
        accepted.append(packet)
        return 0
    }
    try check(failed == -1 && accepted.count == 1)
    let retried = submission.submit(text) { packet in accepted.append(packet); return 0 }
    try check(retried == 0 && accepted.count == 3)
    let decoded = accepted.compactMap { String(bytes: $0.dropFirst(8), encoding: .utf8) }.joined()
    try check(decoded == text) // Accepted prefix was not duplicated; UTF8 packet boundaries are intact.
    try check(accepted.allSatisfy { $0.count <= 40 && Array($0[4..<8]) == [0x17, 0, 0, 0] })
    // Focus loss abandons the old cursor. An identical new logical commit starts at packet zero.
    var cancelled = DesktopTextSubmission()
    var oldAccepted: [[UInt8]] = []
    var oldAttempts = 0
    let oldResult = cancelled.submit(text) { packet in
        oldAttempts += 1
        if oldAttempts == 2 { return -1 }
        oldAccepted.append(packet)
        return 0
    }
    try check(oldResult == -1 && oldAccepted.count == 1)
    cancelled.abandon() // The exact transition called by releaseDesktopInput through InputBatcher.
    var newAccepted: [[UInt8]] = []
    let newResult = cancelled.submit(text) { packet in newAccepted.append(packet); return 0 }
    try check(newResult == 0 && newAccepted.count == 3)
    try check(newAccepted.first == oldAccepted.first)
    try check(newAccepted.compactMap { String(bytes: $0.dropFirst(8), encoding: .utf8) }.joined() == text)
    cancelled.abandon() // Starting a new logical commit is also safe after an already successful commit.
    var nextAccepted: [[UInt8]] = []
    let nextResult = cancelled.submit(text) { packet in nextAccepted.append(packet); return 0 }
    try check(nextResult == 0 && nextAccepted == newAccepted)
    // A later remote action is submitted only after the same live acceptance seam returns success.
    var order: [String] = []
    var one = DesktopTextSubmission()
    let result = one.submit("한") { packet in
        order.append(String(bytes: packet.dropFirst(8), encoding: .utf8) ?? "invalid")
        return 0
    }
    if result == 0 { order.append("save/click") }
    try check(order == ["한", "save/click"])
    // The callback-selected command follows the real text packet acceptance, with a balanced tap.
    for (selector, key): (String, UInt16) in [("insertNewline:", 0x0D), ("insertTab:", 0x09), ("moveLeft:", 0x25)] {
        callbacks.begin(composing: true)
        callbacks.didCommitText()
        callbacks.didCommand(selector)
        var packets = DesktopTextSubmission()
        var submitted: [String] = []
        let accepted = packets.submit("한") { packet in
            submitted.append(String(bytes: packet.dropFirst(8), encoding: .utf8) ?? "invalid")
            return 0
        }
        if accepted == 0, let command = callbacks.command {
            submitted.append("down:\(command.virtualKey)")
            submitted.append("up:\(command.virtualKey)")
        }
        try check(submitted == ["한", "down:\(key)", "up:\(key)"])
    }
    return count
}
