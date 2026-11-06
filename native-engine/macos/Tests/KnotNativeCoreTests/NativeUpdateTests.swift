// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import Foundation
import Security
import CryptoKit
@testable import KnotNativePreview

final class NativeUpdateTests: XCTestCase {
    private func key() throws -> SecKey {
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048,
                          kSecPrivateKeyAttrs: [kSecAttrIsPermanent: false]] as CFDictionary
        return try XCTUnwrap(SecKeyCreateRandomKey(attributes, nil))
    }
    private func envelope(_ body: String, key: SecKey) throws -> Data {
        let bytes = Data(body.utf8)
        let signature = try XCTUnwrap(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, bytes as CFData, nil)) as Data
        return Data((bytes.base64EncodedString() + "\n" + signature.base64EncodedString() + "\n").utf8)
    }
    private func body(version: String = "0.1.0-native.11", platform: String = "macos-arm64", size: Int = 5,
                      hash: String = String(repeating: "a", count: 64), expiry: Int = 200) throws -> String {
        let build = try NativeUpdateManifest.versionBuild(version)
        return "KNOT-NATIVE-UPDATE-1\n\(version)\n\(build)\n\(platform)\nhttps://example.com/Knot-Native-\(version)-macos-arm64.zip\n\(size)\n\(hash)\n\(expiry)\n"
    }
    func testActualFreshRsaSignatureAndPolicy() throws {
        let privateKey = try key(), publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let data = try envelope(body(), key: privateKey)
        let result = try NativeUpdateManifest.verify(data, publicKey: publicKey, currentVersion: "0.1.0-native.10", platform: "macos-arm64", now: 100)
        XCTAssertEqual(result.version, "0.1.0-native.11"); XCTAssertEqual(result.bytes, 5)
        XCTAssertThrowsError(try NativeUpdateManifest.verify(data, publicKey: publicKey, currentVersion: "0.1.0-native.11", platform: "macos-arm64", now: 100))
        XCTAssertThrowsError(try NativeUpdateManifest.verify(data, publicKey: publicKey, currentVersion: "0.1.0-native.10", platform: "windows-x64", now: 100))
        XCTAssertThrowsError(try NativeUpdateManifest.verify(data, publicKey: publicKey, currentVersion: "0.1.0-native.10", platform: "macos-arm64", now: 200))
        XCTAssertThrowsError(try NativeUpdateManifest.verify(data, publicKey: publicKey, currentVersion: "0.1.0-native.10", platform: "macos-arm64", now: 100, minimumBuild: result.build + 1))
        var changed = data; changed[30] ^= 1
        XCTAssertThrowsError(try NativeUpdateManifest.verify(changed, publicKey: publicKey, currentVersion: "0.1.0-native.10", platform: "macos-arm64", now: 100))
        let wrongKey = try XCTUnwrap(SecKeyCopyPublicKey(key()))
        XCTAssertThrowsError(try NativeUpdateManifest.verify(data, publicKey: wrongKey, currentVersion: "0.1.0-native.10", platform: "macos-arm64", now: 100))
    }
    func testSignedInvalidSizeAndExpiryStillRejected() throws {
        let privateKey = try key(), publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        for b in [try body(size: 0), try body(size: 536870913), try body(hash: String(repeating: "A", count: 64)), try body(expiry: 100 + 30*86400 + 1)] {
            let data = try envelope(b, key: privateKey)
            XCTAssertThrowsError(try NativeUpdateManifest.verify(data, publicKey: publicKey, currentVersion: "0.1.0-native.10", platform: "macos-arm64", now: 100))
        }
    }
    func testArtifactDigestAndExactLength() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knot-update-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("fresh.bin"), bytes = Data("hello".utf8)
        try bytes.write(to: path, options: .withoutOverwriting)
        let hash = SHA256.hash(data: bytes).map { String(format:"%02x",$0) }.joined()
        let privateKey = try key(), publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let data = try envelope(body(hash: hash), key: privateKey)
        let m = try NativeUpdateManifest.verify(data, publicKey: publicKey, currentVersion: "0.1.0-native.10", platform: "macos-arm64", now: 100)
        XCTAssertNoThrow(try m.verifyFile(path)); try Data("HELLO".utf8).write(to: path)
        XCTAssertThrowsError(try m.verifyFile(path)); try bytes.write(to: path)
        let link = root.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        XCTAssertThrowsError(try m.verifyFile(link))
    }
    func testUnconfiguredAndMalformedConfiguration() throws {
        let c = try NativeUpdateConfiguration.parse("0.1.0-native.11\n\n\n\n\n")
        XCTAssertFalse(c.configured); XCTAssertThrowsError(try NativeUpdateManifest.key(c))
        XCTAssertThrowsError(try NativeUpdateConfiguration.parse("0.1.0-native.11\nhttps://example.com/feed\n\n\n\n"))
        for version in ["0.1.0", "0.1.0-native.0", "0.1.0-native.01", "0.1.0-native.65536", "0.1.0-native.11\n"] {
            XCTAssertThrowsError(try NativeUpdateManifest.versionBuild(version))
        }
    }
}
