import Foundation
import Testing
@testable import KnotNativeCore

private let enrollmentSlot = Data(repeating: 1, count: 16)
private let enrollmentNonce = Data(0..<16)

private func candidateJSON(_ changes: [String: Any] = [:]) throws -> Data {
    var values: [String: Any] = ["v": 2, "nonce": Invitation.encodeBase64URL(enrollmentNonce),
        "slot": Invitation.encodeBase64URL(enrollmentSlot), "name": "Synthetic Windows", "port": 48632]
    for (key, value) in changes { values[key] = value }
    return try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
}
private func testInvitation(address: String) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: ["v": 1, "address": address, "port": 48631,
        "certificateSHA256": String(repeating: "a", count: 64), "token": Invitation.encodeBase64URL(Data(repeating: 3, count: 32))])
    return "knot-native:v1:" + Invitation.encodeBase64URL(data)
}
private func offerJSON(_ changes: [String: Any] = [:]) throws -> Data {
    var values: [String: Any] = ["v": 2, "slot": Invitation.encodeBase64URL(enrollmentSlot),
        "grant": Invitation.encodeBase64URL(Data(repeating: 2, count: 16)),
        "invitation": try testInvitation(address: "192.168.50.12"), "ttlMs": 30000]
    for (key, value) in changes { values[key] = value }
    return try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
}

@Test func enrollmentCodeAndDiscoveryQueryHaveExactPublicBounds() throws {
    #expect(try EnrollmentWire.password("00001234") == Data("00001234".utf8))
    for invalid in ["1234567", "123456789", "1234 5678", "１２３４５６７８", "1234567\n", "abcdefgh"] {
        #expect(throws: (any Error).self) { try EnrollmentWire.password(invalid) }
    }
    #expect(try EnrollmentWire.discoveryQuery(nonce: enrollmentNonce) == Data([75,78,79,84,68,50,0,0]) + enrollmentNonce)
    #expect(throws: (any Error).self) { try EnrollmentWire.discoveryQuery(nonce: Data(repeating: 0, count: 15)) }
}

@Test func discoveryBindsNonceAndObservedPrivateAddressWithoutTrustingNames() throws {
    let data = try candidateJSON()
    let peer = try EnrollmentWire.discoveryReply(data, nonce: enrollmentNonce, sourceIPv4: "100.64.0.5")
    #expect(peer.address == "100.64.0.5" && peer.slot == enrollmentSlot && peer.name == "Synthetic Windows")
    #expect(throws: (any Error).self) { try EnrollmentWire.discoveryReply(data, nonce: Data(repeating: 9, count: 16), sourceIPv4: "100.64.0.5") }
    for address in ["1.1.1.1", "127.0.0.1", "192.168.050.12", "https://192.168.50.12"] {
        #expect(throws: (any Error).self) { try EnrollmentWire.discoveryReply(data, nonce: enrollmentNonce, sourceIPv4: address) }
    }
    for mutation: [String: Any] in [["port": 0], ["port": 48631], ["name": ""], ["name": "bad\nname"], ["token": "forbidden"], ["slot": Invitation.encodeBase64URL(Data(repeating: 1, count: 17))]] {
        let invalid = try candidateJSON(mutation)
        #expect(throws: (any Error).self) { try EnrollmentWire.discoveryReply(invalid, nonce: enrollmentNonce, sourceIPv4: "192.168.50.12") }
    }
    #expect(throws: (any Error).self) { try EnrollmentWire.discoveryReply(Data(repeating: 0, count: 1025), nonce: enrollmentNonce, sourceIPv4: "192.168.50.12") }
}

@Test func enrollmentFramesRejectUnknownLengthsAndWrongPublicSlotBeforeCrypto() throws {
    let body = try EnrollmentWire.hello(slot: enrollmentSlot, message: Data(repeating: 4, count: 32))
    let frame = try EnrollmentFrame(kind: .clientHello, payload: body)
    let header = try EnrollmentFrame.header(Data(frame.encoded.prefix(5)))
    #expect(header.0 == .clientHello && header.1 == 48)
    #expect(try EnrollmentWire.serverMessage(body, slot: enrollmentSlot) == Data(repeating: 4, count: 32))
    #expect(throws: (any Error).self) { try EnrollmentWire.serverMessage(body, slot: Data(repeating: 2, count: 16)) }
    for invalid in [Data([255,0,0,0,1]), Data([2,0,0,0,49]), Data([4,0,0,16,1]), Data([3,0,0,0,28]), Data([0x7f,0,0,0,0])] {
        #expect(throws: (any Error).self) { try EnrollmentFrame.header(invalid) }
    }
    #expect(throws: (any Error).self) { try EnrollmentFrame(kind: .clientConfirm, payload: Data(repeating: 0, count: 513)) }
}

@Test func authenticatedOfferRequiresExactSlotGrantSchemaAddressAndTTL() throws {
    let candidate = try EnrollmentCandidate(address: "192.168.50.12", port: 48632, slot: enrollmentSlot, name: "Unverified PC")
    let parsed = try EnrollmentOffer(offerJSON(), candidate: candidate)
    #expect(parsed.invitation.address == candidate.address && parsed.invitation.certificateSHA256 == String(repeating: "a", count: 64))
    #expect(parsed.ttlMilliseconds == 30000 && parsed.grant.count == 16)
    let shortest = try EnrollmentOffer(offerJSON(["ttlMs": 1]), candidate: candidate)
    #expect(shortest.ttlMilliseconds == 1)
    for mutation: [String: Any] in [["v": 1], ["ttlMs": 0], ["ttlMs": 30001], ["ttlMs": true],
        ["slot": Invitation.encodeBase64URL(Data(repeating: 7, count: 16))],
        ["grant": Invitation.encodeBase64URL(Data(repeating: 7, count: 15))],
        ["invitation": try testInvitation(address: "192.168.50.13")], ["unexpected": "value"]] {
        let invalid = try offerJSON(mutation)
        #expect(throws: (any Error).self) { try EnrollmentOffer(invalid, candidate: candidate) }
    }
    let valid = try offerJSON()
    var duplicate = Data("{\"v\":2,".utf8); duplicate.append(valid.dropFirst())
    #expect(throws: (any Error).self) { try EnrollmentOffer(duplicate, candidate: candidate) }
}

@Test func enrollmentConfirmationAndErrorsNeverAdmitArbitraryPermissionsOrRawMessages() throws {
    let confirmation = try EnrollmentWire.confirm(slot: enrollmentSlot, name: "My Mac")
    let object = try StrictJSON.object(confirmation, keys: ["v", "slot", "name", "permissions"], limit: 484)
    #expect(try object.string("permissions") == "screen,input,files")
    #expect(try object.string("name") == "My Mac")
    #expect(throws: (any Error).self) { try EnrollmentWire.confirm(slot: enrollmentSlot, name: "bad\rname") }
    #expect(try EnrollmentWire.serverError(Data("{\"code\":\"auth\"}".utf8)) == .authentication)
    #expect(throws: (any Error).self) { try EnrollmentWire.serverError(Data("{\"code\":\"raw OS exception\"}".utf8)) }
    #expect(throws: (any Error).self) { try EnrollmentWire.serverError(Data("{\"code\":\"auth\",\"token\":\"no\"}".utf8)) }
}
