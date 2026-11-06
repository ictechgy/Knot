import Foundation
import Testing
@testable import KnotNativeCore
@testable import KnotNativePreview

@Test func clipboardFramesAreBoundedStrictAndGestureScoped() throws {
    let nonce = Data(repeating: 7, count: 16)
    for text in ["", "한글\ncode ⌘", String(repeating: "a", count: ClipboardProtocol.maximumTextBytes)] {
        let packet = try ClipboardProtocol.request(.paste, nonce: nonce, text: text)
        try ClipboardProtocol.validateRequest(packet.payload)
        #expect(packet.kind == .clipboardRequest)
    }
    for text in ["bad\0text", String(repeating: "a", count: ClipboardProtocol.maximumTextBytes + 1)] {
        #expect(throws: (any Error).self) { try ClipboardProtocol.request(.paste, nonce: nonce, text: text) }
    }
    #expect(throws: (any Error).self) { try ClipboardProtocol.request(.copy, nonce: nonce, text: "stale") }
    #expect(throws: (any Error).self) { try ClipboardProtocol.validateRequest(Data([2]) + nonce + Data([0xff])) }
    let good = Data([1, 0]) + nonce + Data("fresh".utf8)
    #expect(try ClipboardResponse(good).text == "fresh")
    #expect(throws: (any Error).self) { try ClipboardResponse(Data([1, 1]) + nonce + Data("stale".utf8)) }
    #expect(throws: (any Error).self) { try ClipboardResponse(Data([2, 0]) + nonce + Data("unexpected".utf8)) }
    var state = ReceiveState()
    #expect(throws: (any Error).self) { try state.accept(Packet(kind: .clipboardResponse, payload: good)) }
    let ready = Data(#"{"v":1,"codec":"h264-annexb","width":1920,"height":1080,"fps":60,"bitrate":20000000,"hardwareEncoder":true,"clipboardVersion":1,"qualityVersion":1}"#.utf8)
    _ = try state.accept(Packet(kind: .ready, payload: ready))
    _ = try state.accept(Packet(kind: .clipboardResponse, payload: good))
    #expect(try Ready(ready).clipboardVersion == 1)
    #expect(throws: (any Error).self) { try Ready(Data(String(decoding: ready, as: UTF8.self).replacingOccurrences(of: "\"clipboardVersion\":1", with: "\"clipboardVersion\":2").utf8)) }
}

@Test func explicitClipboardControlRetainsReleaseBarrierWithoutResumingInput() throws {
    var input = InputBuffer(); input.revoke()
    let request = try ClipboardProtocol.request(.paste, nonce: Data(repeating: 1, count: 16), text: String(repeating: "x", count: 1_048_576))
    try input.append(request)
    #expect(input.needsRecovery && input.count == 2)
    #expect(throws: (any Error).self) { try input.append(request) }
    #expect(throws: (any Error).self) { try input.append(Input.key(down: true, scan: 30, extended: false)) }
    #expect(input.pop()?.kind == .releaseAll)
    #expect(input.pop() == request)
    input.recover()
    try input.append(Input.key(down: true, scan: 30, extended: false))
    #expect(input.count == 1)
}

@Test func macShortcutProfileUsesControlWithoutChangingPhysicalFallbackOrSpaces() {
    var modifiers = KeyboardModifierState()
    modifiers.observe(keyCode: 55, flags: .command)
    #expect(modifiers.desired(flags: .command, textMode: true, physicalCommand: true) == [55])
    #expect(modifiers.desired(flags: .command, textMode: true, physicalCommand: true, macShortcuts: true) == [59])
    modifiers.observe(keyCode: 55, flags: [])
    #expect(modifiers.desired(flags: [], textMode: true, macShortcuts: true).isEmpty)
    #expect(MacKeyboardRouting.route(keyCode: 126, modifiers: .control, textMode: false,
        hasMarkedText: false, ownsPhysicalDown: false) == .localSpace)
}

@Test @MainActor func clipboardModelNeverPollsAndRejectsStaleOrCancelledReplies() throws {
    var reads = 0, writes: [String] = [], sent: [Packet] = []
    let clipboard = ClipboardModel(send: { sent.append($0); return true }, readText: { reads += 1; return "local" }, writeText: { writes.append($0); return true })
    #expect(reads == 0 && writes.isEmpty)
    clipboard.copyFromRemote()
    #expect(reads == 0 && clipboard.busy && sent.count == 1)
    let nonce = Data(sent[0].payload.dropFirst().prefix(16))
    clipboard.accept(try ClipboardResponse(Data([1, 0]) + Data(repeating: 99, count: 16) + Data("wrong".utf8)))
    #expect(writes.isEmpty && clipboard.busy)
    clipboard.cancel()
    clipboard.accept(try ClipboardResponse(Data([1, 0]) + nonce + Data("late".utf8)))
    #expect(writes.isEmpty && !clipboard.busy)
    clipboard.pasteToRemote()
    #expect(reads == 1 && sent.count == 2)
    let pasteNonce = Data(sent[1].payload.dropFirst().prefix(16))
    clipboard.accept(try ClipboardResponse(Data([2, 0]) + pasteNonce))
    #expect(writes.isEmpty && !clipboard.busy)
    clipboard.copyFromRemote()
    let current = Data(sent[2].payload.dropFirst().prefix(16))
    clipboard.accept(try ClipboardResponse(Data([1, 0]) + current + Data("fresh".utf8)))
    #expect(writes == ["fresh"] && reads == 1 && !clipboard.busy)
}
