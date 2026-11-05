import Foundation
import Testing
@testable import KnotNativeCore

private func invite(_ json: String) -> String { "knot-native:v1:" + Invitation.encodeBase64URL(Data(json.utf8)) }
private let token = Invitation.encodeBase64URL(Data(repeating: 7, count: 32))
private let pin = String(repeating: "a", count: 64)
private func invitationJSON(address: String = "192.168.1.2", port: Int = 48631) -> String { "{\"v\":1,\"address\":\"\(address)\",\"port\":\(port),\"certificateSHA256\":\"\(pin)\",\"token\":\"\(token)\"}" }
private let readyJSON = Data("{\"v\":1,\"codec\":\"h264-annexb\",\"width\":64,\"height\":64,\"fps\":30,\"bitrate\":1000000,\"hardwareEncoder\":true}".utf8)

@Test func invitationRoundTripAndHello() throws {
    let result = try Invitation(invite(invitationJSON()))
    #expect(result.address == "192.168.1.2"); #expect(result.port == 48631)
    let hello = try result.hello()
    #expect(hello.kind == .hello)
    let json = try StrictJSON.object(hello.payload, keys: ["v", "token", "name", "filesVersion"], limit: 4096)
    #expect(try json.string("token") == token)
    #expect(try json.integer("filesVersion") == 1)
}

@Test(arguments: ["8.8.8.8", "127.0.0.1", "169.254.1.1", "192.168.01.2", "192.168.1.2.", "192.168.1.256", "192.168.1.-1", "172.32.1.1", "100.128.0.1", "10.0.0.1evil", "localhost", "::1", " 10.0.0.1"])
func rejectedAddress(_ address: String) { #expect(throws: (any Error).self) { try Invitation(invite(invitationJSON(address: address))) } }

@Test(arguments: ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.0.1", "100.64.0.1", "100.127.255.254"])
func acceptedAddress(_ address: String) { #expect(Invitation.isPrivateIPv4(address)) }

@Test func invitationStrictRejections() {
    let duplicate = invitationJSON().dropLast() + ",\"\\u0076\":1}"
    for json in [String(duplicate), invitationJSON().dropLast() + ",\"extra\":1}", invitationJSON(port: 0), invitationJSON(port: 65536), invitationJSON().replacingOccurrences(of: token, with: token + "="), invitationJSON().replacingOccurrences(of: pin, with: pin.uppercased()), invitationJSON().replacingOccurrences(of: "\"v\":1", with: "\"v\":true"), invitationJSON() + "true"] {
        #expect(throws: (any Error).self) { try Invitation(invite(json)) }
    }
    #expect(throws: (any Error).self) { try Invitation(String(repeating: "x", count: 2049)) }
    #expect(throws: (any Error).self) { try Invitation(invite(invitationJSON()) + "=") }
}

@Test(arguments: ["{\"a\":1,\"a\":2}", "{\"a\":1,\"\\u0061\":2}", "{\"a\":1}x", "{\"a\":01}", "{\"a\":1.0}", "{\"a\":[]}", "{\"a\":null}", "{\"a\":\"\\uD800\"}", "{\"a\":\"bad\nstring\"}", "{\"a\":1,}"])
func strictJSON(_ text: String) { #expect(throws: (any Error).self) { try StrictJSON.object(Data(text.utf8), keys: ["a"], limit: 4096) } }

@Test func wireLengthCapsAndKinds() throws {
    for (kind,size) in [(UInt8(2),UInt32(4097)),(3,4_194_305),(3,17),(4,1),(0xff,0),(0x20,4),(0x7f,129)] {
        var header = Data([kind]); header.appendBE(size)
        #expect(throws: (any Error).self) { try Packet.serverHeader(header) }
    }
    #expect(throws: (any Error).self) { try Packet.serverHeader(Data(repeating: 0, count: 4)) }
    let heartbeat = try Packet.serverHeader(Data([4,0,0,0,0])); #expect(heartbeat.0 == .hostHeartbeat && heartbeat.1 == 0)
    #expect(Packet(kind: .releaseAll).encoded == Data([0x24,0,0,0,0]))
}

@Test func handshakeAndVideoOrdering() throws {
    var state = ReceiveState()
    var payload = Data(); payload.appendBE(UInt64(1)); payload.appendBE(UInt64(10)); payload.append(1); payload.append(contentsOf: [0,0,1,0x65,0x88])
    #expect(throws: (any Error).self) { try state.accept(Packet(kind: .video, payload: payload)) }
    _ = try state.accept(Packet(kind: .hostHeartbeat))
    _ = try state.accept(Packet(kind: .ready, payload: readyJSON))
    #expect(throws: (any Error).self) { try state.accept(Packet(kind: .ready, payload: readyJSON)) }
    #expect(try state.accept(Packet(kind: .video, payload: payload))?.sequence == 1)
    #expect(throws: (any Error).self) { try state.accept(Packet(kind: .video, payload: payload)) }
    var invalidFlag = payload; invalidFlag[16] = 0
    #expect(throws: (any Error).self) { try VideoPacket(invalidFlag, after: 0) }
    for invalid in [readyJSON + Data([0]), Data(String(decoding: readyJSON, as: UTF8.self).replacingOccurrences(of: "true", with: "false").utf8), Data(String(decoding: readyJSON, as: UTF8.self).replacingOccurrences(of: "\"width\":64", with: "\"width\":4096").utf8)] {
        #expect(throws: (any Error).self) { try Ready(invalid) }
    }
}

@Test func readyAccepts4KAndRejectsUnsafeVideoBounds() throws {
    func bytes(_ width: Int, _ height: Int, _ fps: Int = 30, _ bitrate: Int = 40_000_000) -> Data {
        Data("{\"v\":1,\"codec\":\"h264-annexb\",\"width\":\(width),\"height\":\(height),\"fps\":\(fps),\"bitrate\":\(bitrate),\"hardwareEncoder\":true}".utf8)
    }
    let ready = try Ready(bytes(3840, 2160))
    #expect(ready.width == 3840 && ready.height == 2160 && ready.fps == 30 && ready.bitrate == 40_000_000)
    #expect(try Ready(bytes(3840, 2160, 60)).fps == 60)
    for (width, height) in [(3842, 2160), (3840, 2162), (3839, 2160), (3840, 2159), (15, 16), (Int.max, Int.max)] {
        #expect(!VideoLimits.accepts(width: width, height: height))
        #expect(throws: (any Error).self) { try Ready(bytes(width, height)) }
    }
    #expect(throws: (any Error).self) { try Ready(bytes(3840, 2160, 61)) }
    #expect(throws: (any Error).self) { try Ready(bytes(3840, 2160, 30, 40_000_001)) }
}

@Test func annexBConversionAndMalformedNALs() throws {
    let unit = try AccessUnit(annexB: Data([0,0,0,1,0x67,1,2,0,0,1,0x68,3,0,0,1,0x65,4]))
    #expect(unit.isIDR && unit.sps.count == 1 && unit.pps.count == 1)
    #expect(unit.avcc == Data([0,0,0,3,0x67,1,2,0,0,0,2,0x68,3,0,0,0,2,0x65,4]))
    for bytes: [UInt8] in [[],[1,2,3],[0,0,1],[0,0,1,0x80],[0,0,1,0],[0,0,1,0x67,1],[0,0,1,0x65,1,0,0,1]] {
        #expect(throws: (any Error).self) { try AccessUnit(annexB: Data(bytes)) }
    }
    var tooMany = Data(); for _ in 0..<129 { tooMany.append(contentsOf: [0,0,1,0x65,1]) }
    #expect(throws: (any Error).self) { try AccessUnit(annexB: tooMany) }
    var oversizedSPS = Data([0,0,1,0x67]); oversizedSPS.append(Data(repeating: 1, count: 65_537)); oversizedSPS.append(contentsOf: [0,0,1,0x65,1])
    #expect(throws: (any Error).self) { try AccessUnit(annexB: oversizedSPS) }
}

@Test func annexBNonzeroIndexSliceRetainsOwnedNALsAndRejectsMalformedSlices() throws {
    let annexB = Data([0,0,0,1,0x67,1,2,0,0,1,0x68,3,0,0,1,0x65,4])
    let storage = Data([0xee, 0xee]) + annexB + Data([0xdd])
    var slice = storage[2..<(2 + annexB.count)]
    #expect(slice.startIndex == 2)
    let expected = try AccessUnit(annexB: annexB)
    let parsed = try AccessUnit(annexB: slice)
    // Returned NALs must own their bytes after the borrowed source is changed.
    slice.resetBytes(in: slice.startIndex..<slice.endIndex)
    #expect(parsed.nals == expected.nals && parsed.sps == expected.sps && parsed.pps == expected.pps)
    #expect(parsed.isIDR && parsed.avcc == expected.avcc)
    for bytes: [UInt8] in [[1,2,3], [0,0,1], [0,0,1,0x80], [0,0,1,0x65,1,0,0,1]] {
        let backing = Data([0xee, 0xee]) + Data(bytes) + Data([0xdd])
        #expect(throws: (any Error).self) { try AccessUnit(annexB: backing[2..<(2 + bytes.count)]) }
    }
}

@Test func inputCoalescingSaturationAndExplicitRecovery() throws {
    var buffer = InputBuffer()
    for x in 0..<1000 { try buffer.append(Input.pointer(action: 0, x: UInt16(x), y: 0)) }
    #expect(buffer.count == 1)
    #expect(buffer.pop()?.payload.readBE(UInt16.self, at: 1) == 999)
    for _ in 0..<256 { try buffer.append(Input.key(down: true, scan: 0x1e, extended: false)) }
    #expect(throws: (any Error).self) { try buffer.append(Input.key(down: false, scan: 0x1e, extended: false)) }
    #expect(buffer.needsRecovery && buffer.count == 1 && buffer.byteCount == 5)
    #expect(buffer.pop()?.kind == .releaseAll)
    #expect(throws: (any Error).self) { try buffer.append(Input.key(down: true, scan: 1, extended: false)) }
    buffer.recover(); try buffer.append(Input.key(down: true, scan: 1, extended: false))
    buffer.revoke(); #expect(buffer.pop()?.kind == .releaseAll); #expect(buffer.pop() == nil)
    var byteBound = InputBuffer()
    for _ in 0..<15 { try byteBound.append(Input.text(String(repeating: "é", count: 512))) }
    #expect(throws: (any Error).self) { try byteBound.append(Input.text(String(repeating: "é", count: 512))) }
    #expect(byteBound.needsRecovery)
}

@Test func inputValidationAndAspectFit() throws {
    #expect(throws: (any Error).self) { try Input.key(down: true, scan: 0, extended: false) }
    #expect(throws: (any Error).self) { try Input.text("a\0b") }
    #expect(throws: (any Error).self) { try Input.text(String(repeating: "a", count: 1025)) }
    #expect(throws: (any Error).self) { try Input.wheel(vertical: 1201, horizontal: 0) }
    let korean = try Input.text("한글 😀"); #expect(String(data: korean.payload, encoding: .utf8) == "한글 😀")
    #expect(Input.point(x: 0, y: 0, viewWidth: 100, viewHeight: 100, imageWidth: 200, imageHeight: 100) == nil)
    let center = Input.point(x: 50, y: 50, viewWidth: 100, viewHeight: 100, imageWidth: 200, imageHeight: 100)
    #expect(center?.0 == 32768 && center?.1 == 32768)
    #expect(Input.point(x: .nan, y: 50, viewWidth: 100, viewHeight: 100, imageWidth: 200, imageHeight: 100) == nil)
}
