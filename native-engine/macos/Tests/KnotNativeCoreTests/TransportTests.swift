import Foundation
import Testing
import Network
import Security
import CryptoKit
import KnotNativeCore
@testable import KnotNativePreview

/// Owns only freshly generated test files and an in-memory imported identity.
private final class CertificateFixture: @unchecked Sendable {
    let directory: URL
    let certificate: SecCertificate
    let identity: SecIdentity
    let pin: String
    init(name: String = "knot-native", purpose: String = "serverAuth") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("knot-native-tls-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let configuration = directory.appendingPathComponent("fixture.cnf")
            try Data("[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=\(name)\n".utf8).write(to: configuration)
            func run(_ arguments: [String]) throws {
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
                process.arguments = arguments; process.environment = ["PATH":"/usr/bin:/bin"]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw NativeFailure.trust }
            }
            let key = directory.appendingPathComponent("key.pem").path, pem = directory.appendingPathComponent("cert.pem").path
            let der = directory.appendingPathComponent("cert.der"), p12 = directory.appendingPathComponent("identity.p12")
            try run(["req","-x509","-newkey","rsa:2048","-nodes","-sha256","-days","1","-config",configuration.path,"-keyout",key,"-out",pem,"-addext","subjectAltName=DNS:\(name)","-addext","extendedKeyUsage=\(purpose)","-addext","basicConstraints=critical,CA:FALSE"])
            try run(["x509","-in",pem,"-outform","DER","-out",der.path])
            try run(["pkcs12","-export","-inkey",key,"-in",pem,"-out",p12.path,"-passout","pass:synthetic-fixture-only"])
            let bytes = try Data(contentsOf: der)
            guard let certificate = SecCertificateCreateWithData(nil, bytes as CFData) else { throw NativeFailure.trust }
            self.certificate = certificate
            self.pin = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            var imported: CFArray?
            let options = [kSecImportExportPassphrase: "synthetic-fixture-only", kSecImportToMemoryOnly: true] as CFDictionary
            guard SecPKCS12Import(try Data(contentsOf: p12) as CFData, options, &imported) == errSecSuccess,
                  let first = (imported as? [[String:Any]])?.first,
                  let identity = first[kSecImportItemIdentity as String] else { throw NativeFailure.trust }
            self.identity = identity as! SecIdentity
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func trust(at date: Date? = nil) throws -> SecTrust {
        var result: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "knot-native" as CFString), &result) == errSecSuccess, let result else { throw NativeFailure.trust }
        if let date { SecTrustSetVerifyDate(result, date as CFDate) }
        return result
    }
}

private final class LoopbackHost: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "knot-native.fresh-tls-test")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    init(identity: SecIdentity) throws {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, try #require(sec_identity_create(identity)))
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { continuation in
            let gate = PortGate(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state, let port = self?.listener.port { gate.finish(.success(port)) }
                if case .failed = state { gate.finish(.failure(NativeFailure.transport)) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.lock.lock(); self.connections.append(connection); self.lock.unlock()
                connection.stateUpdateHandler = { state in
                    if case .ready = state {
                        // Deliberately fragmented framed message exercises exact reads.
                        connection.send(content: Data([4,0]), completion: .contentProcessed { _ in
                            connection.send(content: Data([0,0,0]), completion: .contentProcessed { _ in })
                        })
                    }
                }
                connection.start(queue: self.queue)
            }
            queue.asyncAfter(deadline: .now() + 5) { gate.finish(.failure(NativeFailure.transport)) }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel(); lock.lock(); let owned = connections; connections = []; lock.unlock(); for item in owned { item.cancel() } }
}
private final class PortGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NWEndpoint.Port, any Error>?
    init(_ value: CheckedContinuation<NWEndpoint.Port, any Error>) { continuation = value }
    func finish(_ result: Result<NWEndpoint.Port, any Error>) { lock.lock(); let value = continuation; continuation = nil; lock.unlock(); value?.resume(with: result) }
}

@Test func freshPinnedCertificateValidityNameAndPurpose() throws {
    let fixture = try CertificateFixture()
    #expect(TLSChannel.evaluate(try fixture.trust(), expectedPin: fixture.pin))
    #expect(!TLSChannel.evaluate(try fixture.trust(), expectedPin: String(repeating: "0", count: 64)))
    #expect(!TLSChannel.evaluate(try fixture.trust(at: Date().addingTimeInterval(3 * 86400)), expectedPin: fixture.pin))
    #expect(!TLSChannel.evaluate(try fixture.trust(at: Date().addingTimeInterval(-3 * 86400)), expectedPin: fixture.pin))
    let wrongName = try CertificateFixture(name: "wrong.invalid")
    #expect(!TLSChannel.evaluate(try wrongName.trust(), expectedPin: wrongName.pin))
    let wrongPurpose = try CertificateFixture(purpose: "clientAuth")
    #expect(!TLSChannel.evaluate(try wrongPurpose.trust(), expectedPin: wrongPurpose.pin))
}

@Test func freshLoopbackTLSCorrectAndMismatchedPin() async throws {
    let fixture = try CertificateFixture()
    let server = try LoopbackHost(identity: fixture.identity)
    defer { server.stop() }
    let port = try await server.start()
    let good = TLSChannel(endpoint: .hostPort(host: .ipv4(.loopback), port: port), pin: fixture.pin)
    defer { good.close() }
    try await good.start()
    try await good.send(Packet(kind: .heartbeat))
    #expect(try await good.readExactly(5) == Data([4,0,0,0,0]))
    let bad = TLSChannel(endpoint: .hostPort(host: .ipv4(.loopback), port: port), pin: String(repeating: "0", count: 64))
    defer { bad.close() }
    do { try await bad.start(); Issue.record("Mismatched pin established TLS") } catch {}
}

private final class InertChannel: NativeChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var writes: [Packet] = []
    private var reader: CheckedContinuation<Data, any Error>?
    private var closed = false
    func start() async throws {}
    func readExactly(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { value in
            lock.lock()
            if closed { lock.unlock(); value.resume(throwing: NativeFailure.transport) }
            else { reader = value; lock.unlock() }
        }
    }
    func send(_ packet: Packet) async throws { record(packet) }
    private func record(_ packet: Packet) { lock.lock(); writes.append(packet); lock.unlock() }
    func snapshot() -> [Packet] { lock.lock(); defer { lock.unlock() }; return writes }
    func close() { lock.lock(); closed = true; let pending = reader; reader = nil; lock.unlock(); pending?.resume(throwing: NativeFailure.transport) }
}

@Test @MainActor func lifecycleUsesInertTransportAndNeverStreamsOnHello() async throws {
    let transport = InertChannel()
    let model = SessionModel(makeChannel: { _ in transport })
    let token = Invitation.encodeBase64URL(Data(repeating: 3, count: 32))
    let json = "{\"v\":1,\"address\":\"10.0.0.1\",\"port\":48631,\"certificateSHA256\":\"\(String(repeating: "a", count: 64))\",\"token\":\"\(token)\"}"
    model.review("knot-native:v1:" + Invitation.encodeBase64URL(Data(json.utf8)))
    #expect(transport.snapshot().isEmpty) // review cannot implicitly connect
    model.connect()
    for _ in 0..<50 { if model.phase == .approval { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.phase == .approval)
    #expect(transport.snapshot().map(\.kind) == [.hello])
    #expect(model.invitation == nil)
    model.releaseInput()
    for _ in 0..<50 { if transport.snapshot().contains(where: { $0.kind == .releaseAll }) { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(transport.snapshot().contains(where: { $0.kind == .releaseAll }))
    model.disconnect()
    for _ in 0..<50 { if transport.snapshot().filter({ $0.kind == .releaseAll }).count >= 2 { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.phase == .idle && !model.active)
    #expect(transport.snapshot().filter({ $0.kind == .releaseAll }).count >= 2)
}
