import Foundation
import Testing
@testable import KnotNativeCore
@testable import KnotNativePreview

struct TrustedDeviceTests {
    @Test func trustProofIsBoundToFreshChallengeAndIdentity() throws {
        // Same frozen vector is consumed by the Windows checks. No Keychain,
        // preferences, live sockets, captures or existing files are accessed.
        let key = Data(repeating: 7, count: 32)
        let transcript = Data("KnotNativeTrusted:v1\nconnect\nsynthetic-id\nsynthetic-nonce\nSynthetic Mac\nsynthetic-pin".utf8)
        let proof = NativeTrustedClient.proof(key: key, transcript: transcript)
        #expect(Invitation.encodeBase64URL(proof) == "5mVsd7kvPLtyBsDnCN5Kq4B1Q9wv7v3xbtcTzu8dOd8")
        #expect(proof != NativeTrustedClient.proof(key: Data(repeating: 8, count: 32), transcript: transcript))
        #expect(proof != NativeTrustedClient.proof(key: key, transcript: transcript + Data([1])))
    }
    @Test func savedDeviceRejectsPublicEndpointAndMalformedKeys() throws {
        let base: [String: Any] = ["id": Invitation.encodeBase64URL(Data(repeating: 1, count: 32)), "name": "Synthetic PC",
            "address": "192.168.50.20", "certificateSHA256": String(repeating: "a", count: 64), "secret": Data(repeating: 2, count: 32).base64EncodedString()]
        func decode(_ fields: [String: Any]) throws -> SavedNativeDevice {
            try JSONDecoder().decode(SavedNativeDevice.self, from: JSONSerialization.data(withJSONObject: fields)).validated()
        }
        #expect(try decode(base).address == "192.168.50.20")
        var bad = base; bad["address"] = "8.8.8.8"
        #expect(throws: (any Error).self) { try decode(bad) }
        bad = base; bad["secret"] = Data(repeating: 2, count: 31).base64EncodedString()
        #expect(throws: (any Error).self) { try decode(bad) }
        bad = base; bad["certificateSHA256"] = String(repeating: "A", count: 64)
        #expect(throws: (any Error).self) { try decode(bad) }
    }
}
