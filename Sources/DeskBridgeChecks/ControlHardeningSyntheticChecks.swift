// SPDX-License-Identifier: GPL-3.0-only
// Run scripts/tests/test_control_hardening.py. It compiles complete production
// client, endpoint, request, pairing and transport files with offline model/identity fixtures.
#if DESKBRIDGE_CONTROL_SYNTHETIC_CHECKS
import Foundation
import Security
import Darwin
import os

public enum PairStatus: Sendable { case paired, unpaired }
public struct ServerInfo: Sendable {
    var address = "192.0.2.1"
    var uniqueId = "synthetic-PC"
    var serverName = "Synthetic PC"
    var serverCertPEM: String?
    var pairStatus = PairStatus.unpaired
    var appVersion = ""
    var macAddress: String?
    var isRealGFE = false
    var httpPort = 47989
    var httpsPort = 47984
    var maxLumaPixelsHEVC = 0
    var serverCodecSupport: VideoFormats = [.h264]
    var serverCodecModeRaw = 0
    var isBusy = false
    var currentGameID = 0
}
public struct VideoFormats: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let h264 = VideoFormats(rawValue: 1), hevc = VideoFormats(rawValue: 2), hevcMain10 = VideoFormats(rawValue: 4),
        av1 = VideoFormats(rawValue: 8), av1Main10 = VideoFormats(rawValue: 16)
}
package struct StreamRequest: Sendable {
    var width = 1920, height = 1080, fps = 60
    var videoFormats: VideoFormats = [.h264]
    var playAudioOnHost = false
    var audio = SyntheticAudioConfig()
}
package struct SyntheticAudioConfig: Sendable { var surroundAudioInfo = 2 }
public enum StreamError: Error {
    case crypto(String), hostUnreachable(String), truncatedRead(String), pairingRejected, pairingFailed(String),
         sunshineNeedsRestart(String), hostCertChanged(String), launchFailed(String), hostTimedOut, hostRefused(message: String, code: Int)
}
public enum StreamConnection { public enum Failure: Error { case invalidSessionKey } }
public actor IdentityManager {
    public func clientCertPEM() throws -> String { throw StreamError.crypto("identity must not be requested") }
    public func clientKeyPEM() throws -> String { throw StreamError.crypto("identity must not be requested") }
    public func uniqueID() throws -> String { throw StreamError.crypto("identity must not be requested") }
    static func aesKey(forPIN: String, salt: Data) -> Data { fatalError("pairing crypto must not run in transaction fixtures") }
}
extension OSSignposter { static let pairing = OSSignposter(subsystem: "DeskBridge.synthetic", category: "pairing") }

private struct ControlCheckFailure: Error { let message: String }
private actor SyntheticClientSlot {
    var client: NetworkClient?
    func set(_ client: NetworkClient?) { self.client = client }
    func expireDeadline() async { await client?.setRequestDeadline(.distantPast) }
}
private actor SyntheticProbeSignal {
    private var arrived = false
    private var waiter: CheckedContinuation<Void, Never>?
    func mark() { arrived = true; waiter?.resume(); waiter = nil }
    func wait() async {
        if arrived { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
@main
private struct ControlHardeningSyntheticChecks {
    static func main() async throws {
        var count = 0
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw ControlCheckFailure(message: message) }; count += 1
        }
        func rejects(_ body: () throws -> Void) throws {
            var rejected = false
            do { try body() } catch { rejected = true }
            try require(rejected, "malformed input was accepted")
        }
        // Complete production parser and recursive lookups, using only inert bytes.
        let normalXML = try XMLTreeBuilder.parse(data: Data("<root><hostname>Fixture</hostname></root>".utf8))
        try require(normalXML.string(forChild: "hostname") == "Fixture", "normal host XML must remain readable")
        let boundedNesting = String(repeating: "<a>", count: XMLTreeBuilder.maximumDepth) + String(repeating: "</a>", count: XMLTreeBuilder.maximumDepth)
        let boundedTree = try XMLTreeBuilder.parse(data: Data(boundedNesting.utf8))
        try require(boundedTree.firstChild(named: "missing") == nil, "maximum supported nesting remains safe to walk")
        for depth in [XMLTreeBuilder.maximumDepth + 1, 10_000] {
            let nested = Data((String(repeating: "<a>", count: depth) + String(repeating: "</a>", count: depth)).utf8)
            try rejects { _ = try XMLTreeBuilder.parse(data: nested) }
        }
        try rejects { _ = try XMLTreeBuilder.parse(data: Data(("<root>" + String(repeating: "<a/>", count: XMLTreeBuilder.maximumNodes) + "</root>").utf8)) }
        var boundaryXML = Data(repeating: 32, count: XMLTreeBuilder.maximumSourceBytes - 7)
        boundaryXML.append(contentsOf: "<root/>".utf8)
        try require(try XMLTreeBuilder.parse(data: boundaryXML).firstChild(named: "root") != nil,
                    "well-formed XML at the exact source budget must parse")
        boundaryXML.append(32)
        do {
            _ = try XMLTreeBuilder.parse(data: boundaryXML)
            throw ControlCheckFailure(message: "over-budget valid XML was accepted")
        } catch let error as NSError {
            try require(error.domain == "Glimmer.XML" && error.code == -3,
                        "over-budget XML must fail at the source guard")
        }
        for value in ["", " ", "-1", "+1", "no", "1, 1", String(repeating: "9", count: 100)] {
            try rejects { _ = try ControlTransport.contentLengthHeader(in: Data("HTTP/1.1 200 OK\r\nContent-Length: \(value)".utf8)) }
        }
        try rejects { _ = try ControlTransport.contentLengthHeader(in: Data("HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2".utf8)) }
        try rejects { _ = try ControlTransport.contentLengthHeader(in: Data("HTTP/1.1 200 OK\r\nContent-Length : 1".utf8)) }
        try require(try ControlTransport.contentLengthHeader(in: Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\ncontent-length: 4".utf8)) == 4, "identical duplicate length")
        try require(try ControlTransport.contentLengthHeader(in: Data("HTTP/1.1 200 OK".utf8)) == nil, "close-delimited response")
        let header = Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n".utf8)
        var buffer = ControlTransport.ResponseBuffer()
        try require(try !buffer.append(header + Data("ab".utf8)), "split body must wait")
        try rejects { _ = try buffer.finish() }
        try require(try buffer.append(Data("cdTRAILING".utf8)), "complete body must finish")
        try require(try ControlTransport.parse(buffer.bytes).body == Data("abcd".utf8), "trailing bytes must not enter XML body")
        try require(try ControlTransport.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\nignored".utf8)).body.isEmpty, "zero-length body")
        try rejects { _ = try ControlTransport.parse(header + Data("a".utf8)) }
        var closeDelimited = ControlTransport.ResponseBuffer()
        try require(try closeDelimited.receive(Data("HTTP/1.1 200 OK\r\n\r\npartial".utf8), done: false, error: nil) == nil, "close-delimited body waits for clean EOF")
        try rejects { _ = try closeDelimited.receive(nil, done: false, error: StreamError.hostUnreachable("synthetic reset")) }
        try require(try closeDelimited.receive(nil, done: true, error: nil) != nil, "clean close may complete a close-delimited response")
        // A separator can straddle any callback boundary, including one-byte chunks.
        for split in 1..<4 {
            var fragmented = ControlTransport.ResponseBuffer()
            let prefix = Data("HTTP/1.1 200 OK\r\nContent-Length: 2".utf8)
            _ = try fragmented.append(prefix + Data("\r\n\r\n".utf8).prefix(split))
            try require(try fragmented.append(Data("\r\n\r\n".utf8).dropFirst(split) + Data("ok".utf8)),
                        "split header terminator was missed")
        }
        var drip = ControlTransport.ResponseBuffer()
        let dripHeader = Data(("HTTP/1.1 200 OK\r\nX-Padding: " + String(repeating: "x", count: 32 * 1024) + "\r\n\r\n").utf8)
        for byte in dripHeader { _ = try drip.append(Data([byte])) }
        try require(try ControlTransport.parse(drip.finish()).status == 200, "one-byte headers must remain parseable")
        var missingTerminator = ControlTransport.ResponseBuffer()
        try rejects { _ = try missingTerminator.append(Data(repeating: 65, count: ControlTransport.maxHeaderBytes)) }
        var oversizedHeader = ControlTransport.ResponseBuffer()
        try rejects { _ = try oversizedHeader.append(Data(repeating: 65, count: ControlTransport.maxHeaderBytes) + Data("\r\n\r\n".utf8)) }
        var largeBody = ControlTransport.ResponseBuffer()
        let body = Data(repeating: 65, count: 128 * 1024)
        try require(try largeBody.append(Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body),
                    "header ceiling must not cap valid response bodies")
        try require(try ControlTransport.parse(largeBody.bytes).body == body, "large XML body changed")
        var oversizedResponse = ControlTransport.ResponseBuffer()
        try rejects { _ = try oversizedResponse.append(Data(repeating: 65, count: ControlTransport.maxResponseBytes + 1)) }
        let fallback = Data(repeating: 7, count: 16)
        try require(try NetworkClient.sessionKeyField(nil, fallback: fallback) == fallback, "absent legacy key fallback")
        try require(try NetworkClient.sessionKeyField(String(repeating: "a0", count: 16), fallback: fallback) == Data(repeating: 160, count: 16), "valid 128-bit host key")
        for value in ["", " ", "00", String(repeating: "00", count: 15), String(repeating: "00", count: 17), String(repeating: "zz", count: 16)] {
            try rejects { _ = try NetworkClient.sessionKeyField(value, fallback: fallback) }
        }
        try rejects { _ = try NetworkClient.sessionKeyField(nil, fallback: Data()) }

        // A fresh in-memory RSA certificate; no identity store, keychain or file access.
        let cert = try syntheticCertificate()
        let certificate = PEM.certificate(cert)!
        try require(try !ControlTransport.acceptsHostCertificate(certificate, pinnedDER: nil), "TLS without a pin must fail closed")
        try require(try ControlTransport.acceptsHostCertificate(certificate, pinnedDER: PEM.der(cert)), "matching certificate pin")
        try require(try !ControlTransport.acceptsHostCertificate(certificate, pinnedDER: Data([0])), "mismatched certificate pin")
        let weakCertificate = PEM.certificate(try syntheticCertificate(bits: 1024))!
        try require(try !ControlTransport.acceptsHostCertificate(weakCertificate, pinnedDER: PEM.der(cert)), "a changed weak certificate must classify as a pin mismatch")
        let client = NetworkClient(server: ServerInfo(), deviceName: { "fixture" }, transport: { _, _, _, _, _, _, _ in
            throw ControlCheckFailure(message: "no network transport may run")
        }, identity: { throw ControlCheckFailure(message: "no identity lookup may run") })
        for failure in [StreamError.pairingRejected, .hostUnreachable("synthetic TLS failure")] {
            var failed = false
            do {
                _ = try await client.confirmPairing { candidate in
                    try await candidate.setPinnedHostCert(pem: cert)
                    throw failure
                }
            } catch { failed = true }
            let retained = await client.pinnedServerCertPEM()
            try require(failed && retained == nil, "failed proof/identity check must preserve caller trust")
        }
        let cancelled = Task {
            try await client.confirmPairing { candidate in
                try await candidate.setPinnedHostCert(pem: cert)
                withUnsafeCurrentTask { $0?.cancel() }
                var verified = ServerInfo(); verified.serverCertPEM = cert; verified.pairStatus = .paired
                return verified
            }
        }
        do { _ = try await cancelled.value } catch {}
        try require((await client.pinnedServerCertPEM()) == nil, "cancellation after provisional pin must preserve caller trust")
        let result = try await client.confirmPairing { candidate in
            try await candidate.setPinnedHostCert(pem: cert)
            var verified = ServerInfo(); verified.serverCertPEM = cert; verified.pairStatus = .paired
            return verified
        }
        let committed = await client.pinnedServerCertPEM()
        try require(result.serverCertPEM == cert && committed == cert, "successful pairing must publish verified trust")
        let replacementCert = try syntheticCertificate()
        do {
            _ = try await client.confirmPairing { candidate in
                try await candidate.setPinnedHostCert(pem: replacementCert)
                throw StreamError.pairingRejected
            }
        } catch {}
        try require((await client.pinnedServerCertPEM()) == cert, "failed re-pairing must preserve an existing pin")
        var concurrentRejected = false
        do {
            _ = try await client.confirmPairing { candidate in
                try await candidate.setPinnedHostCert(pem: cert)
                try await client.setPinnedHostCert(pem: replacementCert)
                var verified = ServerInfo(); verified.serverCertPEM = cert; verified.pairStatus = .paired
                return verified
            }
        } catch is CancellationError { concurrentRejected = true }
        let concurrentPin = await client.pinnedServerCertPEM()
        try require(concurrentRejected && concurrentPin == replacementCert, "pairing commit must not overwrite a concurrent trust replacement")
        let wrongHost = NetworkClient(server: ServerInfo(), deviceName: { "fixture" }, transport: { _, _, _, _, _, _, _ in
            .init(status: 200, body: Data("<root status_code=\"200\"><uniqueid>different-PC</uniqueid></root>".utf8))
        }, identity: { ("synthetic client cert", "synthetic key", "fixture-id") })
        var identityRejected = false
        do {
            _ = try await wrongHost.confirmPairing { candidate in
                try await candidate.setPinnedHostCert(pem: cert)
                return try await candidate.fetchServerInfo(requiredUniqueId: "synthetic-PC")
            }
        } catch { identityRejected = true }
        let wrongPin = await wrongHost.pinnedServerCertPEM()
        try require(identityRejected && wrongPin == nil, "actual pinned identity mismatch must not publish its provisional pin")

        var pairedServer = ServerInfo(); pairedServer.serverCertPEM = cert; pairedServer.pairStatus = .paired
        for tag in ["gcmkey", "gcmkeyid"] {
            for value in ["", "00", String(repeating: "gg", count: 16)] {
                let response = Data("<root status_code=\"200\"><sessionUrl0>rtspenc://192.0.2.1:48010</sessionUrl0><\(tag)>\(value)</\(tag)></root>".utf8)
                let malformed = NetworkClient(server: pairedServer, deviceName: { "fixture" }, transport: { _, _, _, _, _, _, _ in
                    .init(status: 200, body: response)
                }, identity: { ("synthetic client cert", "synthetic key", "fixture-id") })
                var rejected = false
                do { _ = try await malformed.launch(appID: 1, config: StreamRequest()) } catch { rejected = true }
                try require(rejected, "actual launch endpoint must reject malformed present \(tag)")
            }
        }
        let reply = Data("<root status_code=\"200\"><sessionUrl0>rtspenc://192.0.2.1:48010</sessionUrl0></root>".utf8)
        let slot = SyntheticClientSlot()
        let late = NetworkClient(server: pairedServer, deviceName: { "fixture" }, transport: { _, _, _, _, _, _, _ in
            await slot.expireDeadline() // deterministic deadline race while the transport owns a successful reply
            return .init(status: 200, body: reply)
        }, identity: { ("synthetic client cert", "synthetic key", "fixture-id") })
        await slot.set(late)
        await late.setRequestDeadline(Date().addingTimeInterval(30))
        let resumed = try await late.resume(config: StreamRequest())
        await slot.set(nil)
        try require(resumed.gcmKey.count == 16 && resumed.gcmKeyId.count == 16, "resume must preserve a successful late reply for ownership handling")
        let signal = SyntheticProbeSignal()
        let probing = NetworkClient(server: pairedServer, deviceName: { "fixture" }, transport: { _, _, _, _, tls, _, _ in
            if tls { throw StreamError.hostUnreachable("TLS handshake synthetic failure") }
            await signal.mark()
            try await Task.sleep(for: .seconds(30))
            throw StreamError.hostUnreachable("synthetic probe did not cancel")
        }, identity: { ("synthetic client cert", "synthetic key", "fixture-id") })
        let fetch = Task { try await probing.fetchServerInfo() }
        await signal.wait()
        fetch.cancel()
        var cancelledProbe = false
        do { _ = try await fetch.value } catch is CancellationError { cancelledProbe = true }
        try require(cancelledProbe, "cancelling diagnostic HTTP probe must remain cancellation")
        print("Control hardening: \(count) synthetic checks passed; no sockets, preferences, keychain or UI")
    }

    static func syntheticCertificate(bits: Int = 2048) throws -> String {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: bits]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil), let publicKey = SecKeyCopyPublicKey(key),
              let publicDER = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { throw StreamError.crypto("synthetic key") }
        let name = DER.sequence(DER.set(DER.sequence(DER.commonName, DER.utf8String("Synthetic DeskBridge fixture"))))
        let algorithm = DER.sequence(DER.sha256WithRSA, DER.null)
        let tbs = DER.sequence(DER.encode(0xA0, DER.integer(2)), DER.integer(1), algorithm, name,
            DER.sequence(DER.time(Date()), DER.time(Date().addingTimeInterval(3600))), name,
            DER.sequence(DER.sequence(DER.rsaEncryption, DER.null), DER.bitString([UInt8](publicDER))))
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(tbs) as CFData, nil) as Data? else { throw StreamError.crypto("synthetic signature") }
        return PEM.encode(DER.sequence(tbs, algorithm, DER.bitString([UInt8](signature))), label: "CERTIFICATE")
    }
}
#endif
