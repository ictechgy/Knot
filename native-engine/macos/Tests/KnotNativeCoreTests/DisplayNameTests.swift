import Foundation
import Testing
@testable import KnotNativeCore

private let displayNameSlot = Data(repeating: 5, count: 16)
private let displayNameNonce = Data(repeating: 6, count: 16)

private func displayNameInvitation() throws -> Invitation {
    let data = try JSONSerialization.data(withJSONObject: ["v": 1, "address": "192.168.50.12", "port": 48631,
        "certificateSHA256": String(repeating: "a", count: 64), "token": Invitation.encodeBase64URL(Data(repeating: 7, count: 32))])
    return try Invitation("knot-native:v1:" + Invitation.encodeBase64URL(data))
}

private func displayNameDiscovery(_ name: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["v": 2, "nonce": Invitation.encodeBase64URL(displayNameNonce),
        "slot": Invitation.encodeBase64URL(displayNameSlot), "name": name, "port": 48632])
}

private func displayNameEscapedDiscovery(_ quotedName: String) -> Data {
    Data("{\"v\":2,\"nonce\":\"\(Invitation.encodeBase64URL(displayNameNonce))\",\"slot\":\"\(Invitation.encodeBase64URL(displayNameSlot))\",\"name\":\(quotedName),\"port\":48632}".utf8)
}

@Suite
struct DisplayNameTests {
    @Test func ordinaryMultilingualNamesAndSupplementaryEmojiRoundTripThroughNameBoundaries() throws {
        let invitation = try displayNameInvitation()
        for name in ["A", "My Mac", "개발 Mac", "مرحبا", "שלום", "e\u{301}", "😀", "A😀Z"] {
            #expect(Invitation.validViewerLabel(name))
            let hello = try invitation.hello(name: name)
            #expect(hello.kind == .hello)
            #expect(try StrictJSON.object(hello.payload, keys: ["v", "token", "name"], limit: 4096).string("name") == name)
            let confirm = try EnrollmentWire.confirm(slot: displayNameSlot, name: name)
            #expect(try StrictJSON.object(confirm, keys: ["v", "slot", "name", "permissions"], limit: 484).string("name") == name)
            let candidate = try EnrollmentWire.discoveryReply(displayNameDiscovery(name), nonce: displayNameNonce, sourceIPv4: "192.168.50.12")
            #expect(candidate.name == name)
        }
    }

    @Test func displayNamesRejectControlFormatAndLineBreakScalarsInEveryNamePath() throws {
        let invitation = try displayNameInvitation()
        let rejected = ["bad\nname", "bad\tname", "bad\0name", "bad\u{85}name", "bad\u{2028}name", "bad\u{2029}name",
                        "bad\u{202E}name", "bad\u{2066}name", "bad\u{200D}name", "bad\u{E0001}name"]
        for name in rejected {
            #expect(!Invitation.validViewerLabel(name))
            #expect(throws: (any Error).self) { try invitation.hello(name: name) }
            #expect(throws: (any Error).self) { try EnrollmentWire.confirm(slot: displayNameSlot, name: name) }
            let reply = try displayNameDiscovery(name)
            #expect(throws: (any Error).self) {
                try EnrollmentWire.discoveryReply(reply, nonce: displayNameNonce, sourceIPv4: "192.168.50.12")
            }
        }
    }

    @Test func nameLengthUsesOneThrough64UTF8BytesRatherThanCharactersOrUTF16Units() throws {
        let invitation = try displayNameInvitation()
        for name in [String(repeating: "a", count: 64), String(repeating: "한", count: 21) + "a",
                     String(repeating: "a", count: 60) + "😀", String(repeating: "😀", count: 16)] {
            #expect(name.utf8.count == 64 && Invitation.validViewerLabel(name))
            _ = try invitation.hello(name: name)
            _ = try EnrollmentWire.confirm(slot: displayNameSlot, name: name)
            _ = try EnrollmentWire.discoveryReply(displayNameDiscovery(name), nonce: displayNameNonce, sourceIPv4: "192.168.50.12")
        }
        for name in ["", String(repeating: "a", count: 65), String(repeating: "한", count: 22),
                     String(repeating: "a", count: 61) + "😀"] {
            #expect(!Invitation.validViewerLabel(name))
            #expect(throws: (any Error).self) { try invitation.hello(name: name) }
            #expect(throws: (any Error).self) { try EnrollmentWire.confirm(slot: displayNameSlot, name: name) }
            let reply = try displayNameDiscovery(name)
            #expect(throws: (any Error).self) {
                try EnrollmentWire.discoveryReply(reply, nonce: displayNameNonce, sourceIPv4: "192.168.50.12")
            }
        }
    }

    @Test func discoveryRejectsMalformedSurrogatesButAcceptsAnEscapedSupplementaryPair() throws {
        // Swift String cannot contain unpaired surrogates, so exercise the
        // actual incoming discovery parser with fresh malformed JSON bytes.
        for quotedName in ["\"\\ud800\"", "\"\\udc00\"", "\"\\ud800x\"", "\"\\udc00\\ud800\""] {
            #expect(throws: (any Error).self) {
                try EnrollmentWire.discoveryReply(displayNameEscapedDiscovery(quotedName), nonce: displayNameNonce, sourceIPv4: "192.168.50.12")
            }
        }
        let candidate = try EnrollmentWire.discoveryReply(displayNameEscapedDiscovery("\"\\ud83d\\ude00\""), nonce: displayNameNonce, sourceIPv4: "192.168.50.12")
        #expect(candidate.name == "😀")
    }
}
