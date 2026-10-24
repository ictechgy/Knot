// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import DeskBridgeCore
import Foundation
import Security

/// Fresh, process-memory-only TLS identity. It is never a screen certificate,
/// SSH key, saved identity, keychain item, or a public CA trust exception.
enum EnrollmentIdentity {
    struct Material {
        let identity: SecIdentity
        let fingerprint: String
        let capability: String
    }
    static func create() throws -> Material {
        var failure: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048,
                                          kSecAttrIsPermanent: false]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &failure),
              let publicKey = SecKeyCopyPublicKey(key),
              let publicBytes = SecKeyCopyExternalRepresentation(publicKey, &failure) as Data? else { throw EnrollmentProtocol.Failure.invalid }
        let name = DER.sequence(DER.set(DER.sequence(DER.oid([0x55, 0x04, 0x03]), DER.tag(0x0c, Data("Knot temporary enrollment".utf8)))))
        let algorithm = DER.sequence(DER.oid([0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x0b]), DER.tag(5, Data()))
        let rsa = DER.sequence(DER.oid([0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01]), DER.tag(5, Data()))
        let now = Date()
        var serial = try random(16); serial[0] &= 0x7f; serial[0] |= 1
        let tbs = DER.sequence(DER.tag(0xa0, DER.tag(2, Data([2]))), DER.tag(2, serial), algorithm, name,
                               DER.sequence(DER.time(now.addingTimeInterval(-60)), DER.time(now.addingTimeInterval(600))),
                               name, DER.sequence(rsa, DER.tag(3, Data([0]) + publicBytes)))
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, &failure) as Data? else { throw EnrollmentProtocol.Failure.invalid }
        let certificateBytes = DER.sequence(tbs, algorithm, DER.tag(3, Data([0]) + signature))
        guard let certificate = SecCertificateCreateWithData(nil, certificateBytes as CFData),
              let identity = SecIdentityCreate(nil, certificate, key) else { throw EnrollmentProtocol.Failure.invalid }
        return Material(identity: identity, fingerprint: hex(Data(SHA256.hash(data: certificateBytes))), capability: hex(try random(32)))
    }
    private static func random(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw EnrollmentProtocol.Failure.invalid }
        return Data(bytes)
    }
    private static func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    private enum DER {
        static func tag(_ tag: UInt8, _ body: Data) -> Data {
            var length = body.count
            var bytes: [UInt8] = []
            repeat { bytes.insert(UInt8(length & 255), at: 0); length >>= 8 } while length > 0
            let prefix = body.count < 128 ? [UInt8(body.count)] : [0x80 | UInt8(bytes.count)] + bytes
            return Data([tag] + prefix) + body
        }
        static func sequence(_ items: Data...) -> Data { tag(0x30, items.reduce(Data(), +)) }
        static func set(_ value: Data) -> Data { tag(0x31, value) }
        static func oid(_ bytes: [UInt8]) -> Data { tag(6, Data(bytes)) }
        static func time(_ date: Date) -> Data {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyMMddHHmmss'Z'"
            return tag(0x17, Data(formatter.string(from: date).utf8))
        }
    }
}
