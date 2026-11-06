// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Security
import CryptoKit

enum NativeUpdateError: Error { case unconfigured, invalid, signature, expired, downgrade, download, installation }

struct NativeUpdateConfiguration: Sendable {
    let version: String, macFeed: String, windowsFeed: String, modulus: Data, exponent: Data
    var configured: Bool { !macFeed.isEmpty && !windowsFeed.isEmpty && modulus.count == 256 && exponent == Data([1, 0, 1]) }
    static func load(_ url: URL? = Bundle.main.url(forResource: "NativeUpdateConfig", withExtension: "txt")) -> NativeUpdateConfiguration? {
        guard let url, let bytes = try? Data(contentsOf: url), bytes.count <= 16_384,
              let text = String(data: bytes, encoding: .utf8) else { return nil }
        return try? parse(text)
    }
    static func parse(_ text: String) throws -> NativeUpdateConfiguration {
        let lines = text.components(separatedBy: "\n")
        guard lines.count == 6, lines[5].isEmpty else { throw NativeUpdateError.invalid }
        _ = try NativeUpdateManifest.versionBuild(lines[0])
        if lines[1...4].allSatisfy({ $0.isEmpty }) {
            return Self(version: lines[0], macFeed: "", windowsFeed: "", modulus: Data(), exponent: Data())
        }
        _ = try NativeUpdateManifest.https(lines[1]); _ = try NativeUpdateManifest.https(lines[2])
        guard let modulus = Data(base64Encoded: lines[3]), modulus.count == 256, modulus.first! >= 128,
              modulus.last! % 2 == 1, modulus.base64EncodedString() == lines[3],
              let exponent = Data(base64Encoded: lines[4]), exponent == Data([1,0,1]), exponent.base64EncodedString() == lines[4] else { throw NativeUpdateError.invalid }
        return Self(version: lines[0], macFeed: lines[1], windowsFeed: lines[2], modulus: modulus, exponent: exponent)
    }
}

struct NativeUpdateManifest: Sendable {
    let version: String, build: UInt64, platform: String, url: URL, bytes: Int64, sha256: String, expires: Int64
    static let maximumBytes: Int64 = 512 * 1024 * 1024
    static func versionBuild(_ value: String) throws -> UInt64 {
        guard value.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              value.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-native\.([1-9][0-9]*)$"#, options: .regularExpression) != nil else { throw NativeUpdateError.invalid }
        let parts = value.replacingOccurrences(of: "-native.", with: ".").split(separator: ".")
        var result: UInt64 = 0
        for part in parts { guard let n = UInt64(part), n <= 65535 else { throw NativeUpdateError.invalid }; result = (result << 16) | n }
        return result
    }
    static func https(_ value: String) throws -> URL {
        guard !value.isEmpty, value.utf8.allSatisfy({ $0 > 32 && $0 < 127 }), let c = URLComponents(string: value),
              c.scheme == "https", let host = c.host, !host.isEmpty, !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()),
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, c.port == nil || c.port == 443,
              let url = c.url else { throw NativeUpdateError.invalid }
        return url
    }
    private static func der(_ tag: UInt8, _ data: Data) -> Data {
        let n = data.count
        let length = n < 128 ? Data([UInt8(n)]) : n < 256 ? Data([0x81, UInt8(n)]) : Data([0x82, UInt8(n >> 8), UInt8(n & 255)])
        return Data([tag]) + length + data
    }
    static func key(_ c: NativeUpdateConfiguration) throws -> SecKey {
        guard c.configured else { throw NativeUpdateError.unconfigured }
        let raw = der(0x30, der(0x02, Data([0]) + c.modulus) + der(0x02, c.exponent))
        guard let key = SecKeyCreateWithData(raw as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil) else { throw NativeUpdateError.invalid }
        return key
    }
    static func verify(_ envelope: Data, configuration c: NativeUpdateConfiguration, platform: String,
                       now: Int64 = Int64(Date().timeIntervalSince1970), minimumBuild: UInt64 = 0) throws -> NativeUpdateManifest {
        return try verify(envelope, publicKey: key(c), currentVersion: c.version, platform: platform, now: now, minimumBuild: minimumBuild)
    }
    static func verify(_ envelope: Data, publicKey: SecKey, currentVersion: String, platform: String,
                       now: Int64, minimumBuild: UInt64 = 0) throws -> NativeUpdateManifest {
        guard envelope.count <= 16_384, let text = String(data: envelope, encoding: .ascii) else { throw NativeUpdateError.invalid }
        let outer = text.components(separatedBy: "\n")
        guard outer.count == 3, outer[2].isEmpty, let body = Data(base64Encoded: outer[0]), body.base64EncodedString() == outer[0],
              let signature = Data(base64Encoded: outer[1]), signature.count == 256, signature.base64EncodedString() == outer[1],
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, body as CFData, signature as CFData, nil) else { throw NativeUpdateError.signature }
        guard let bodyText = String(data: body, encoding: .ascii) else { throw NativeUpdateError.invalid }
        let a = bodyText.components(separatedBy: "\n")
        guard a.count == 9, a[8].isEmpty, a[0] == "KNOT-NATIVE-UPDATE-1", a[3] == platform,
              ["macos-arm64", "windows-x64"].contains(platform), let build = UInt64(a[2]), String(build) == a[2],
              build == (try versionBuild(a[1])), let size = Int64(a[5]), String(size) == a[5], size > 0, size <= maximumBytes,
              a[6].count == 64, a[6].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let expiry = Int64(a[7]), String(expiry) == a[7] else { throw NativeUpdateError.invalid }
        let url = try https(a[4]), suffix = platform == "macos-arm64" ? "-macos-arm64.zip" : "-windows-x64-setup.exe"
        guard url.lastPathComponent == "Knot-Native-\(a[1])\(suffix)" else { throw NativeUpdateError.invalid }
        guard expiry > now, expiry - now <= 30 * 86400 else { throw NativeUpdateError.expired }
        guard build > (try versionBuild(currentVersion)), build >= minimumBuild else { throw NativeUpdateError.downgrade }
        return Self(version: a[1], build: build, platform: platform, url: url, bytes: size, sha256: a[6], expires: expiry)
    }
    func verifyFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == bytes else { throw NativeUpdateError.download }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256(), count: Int64 = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            count += Int64(chunk.count); guard count <= bytes else { throw NativeUpdateError.download }; hash.update(data: chunk)
        }
        guard count == bytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else { throw NativeUpdateError.download }
    }
}
