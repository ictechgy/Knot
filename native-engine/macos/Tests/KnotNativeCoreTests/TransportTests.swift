import Foundation
import Testing
import Network
import Security
import CryptoKit
import CoreVideo
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
    let pendingRead = Task { try await good.readExactly(1) }
    try await Task.sleep(for: .milliseconds(10))
    let revokedAt = ContinuousClock.now; good.close()
    if case .success = await pendingRead.result { Issue.record("Revoked read unexpectedly completed") }
    #expect(ContinuousClock.now - revokedAt < .milliseconds(500))
    do { try await good.send(Packet(kind: .heartbeat)); Issue.record("Revoked TLS channel accepted a later write") } catch {}
    let bad = TLSChannel(endpoint: .hostPort(host: .ipv4(.loopback), port: port), pin: String(repeating: "0", count: 64))
    defer { bad.close() }
    do { try await bad.start(); Issue.record("Mismatched pin established TLS") } catch {}
}

private final class InertChannel: NativeChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var writes: [Packet] = []
    private var reader: CheckedContinuation<Data, any Error>?
    private var queuedReads: [Data] = []
    private var budgets: [Duration] = []
    private var pendingWrite: (Packet, CheckedContinuation<Void, any Error>)?
    private var attempts: [Kind] = []
    private let blockedKind: Kind?
    private let readRegistrationDelay: Duration
    private var closeCalls = 0
    private var closed = false
    init(blockedKind: Kind? = nil, readRegistrationDelay: Duration = .zero) {
        self.blockedKind = blockedKind; self.readRegistrationDelay = readRegistrationDelay
    }
    func start() async throws {}
    func readExactly(_ count: Int, timeout: Duration) async throws -> Data {
        if readRegistrationDelay > .zero { try await Task.sleep(for: readRegistrationDelay) }
        return try await withCheckedThrowingContinuation { value in
            lock.lock(); budgets.append(timeout)
            if closed { lock.unlock(); value.resume(throwing: NativeFailure.transport) }
            else if !queuedReads.isEmpty { let bytes = queuedReads.removeFirst(); lock.unlock(); value.resume(returning: bytes) }
            else { reader = value; lock.unlock() }
        }
    }
    func send(_ packet: Packet) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            guard !closed else { lock.unlock(); continuation.resume(throwing: NativeFailure.transport); return }
            attempts.append(packet.kind)
            if packet.kind == blockedKind { pendingWrite = (packet, continuation); lock.unlock() }
            else { writes.append(packet); lock.unlock(); continuation.resume() }
        }
    }
    func feed(_ bytes: Data) {
        lock.lock(); guard !closed else { lock.unlock(); return }
        let pending = reader; reader = nil
        if pending == nil { queuedReads.append(bytes) }; lock.unlock(); pending?.resume(returning: bytes)
    }
    func recordedBudgets() -> [Duration] { lock.lock(); defer { lock.unlock() }; return budgets }
    func snapshot() -> [Packet] { lock.lock(); defer { lock.unlock() }; return writes }
    func attemptedKinds() -> [Kind] { lock.lock(); defer { lock.unlock() }; return attempts }
    func closeCount() -> Int { lock.lock(); defer { lock.unlock() }; return closeCalls }
    func close() {
        lock.lock(); guard !closed else { lock.unlock(); return }
        closed = true; closeCalls += 1
        let pending = reader, blocked = pendingWrite; reader = nil; pendingWrite = nil; queuedReads = []
        lock.unlock(); pending?.resume(throwing: NativeFailure.transport)
        // Deliberately deliver late success to prove the model cannot re-admit
        // work after cancellation even if an already submitted write completed.
        blocked?.1.resume()
    }
}

@Test func completedOperationReleasesOwnedDeadlineImmediately() async throws {
    weak var retired: CompletionGate<Int>?
    let value: Int = try await withCheckedThrowingContinuation { continuation in
        let gate = CompletionGate<Int>(continuation); retired = gate
        gate.armDeadline(after: 60, on: DispatchQueue(label: "knot-native.deadline-test")) {}
        #expect(gate.finish(.success(7)))
        #expect(!gate.finish(.failure(NativeFailure.transport)))
    }
    #expect(value == 7)
    // A completed receive must not survive for its former 60-second deadline.
    #expect(retired == nil)
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
    #expect(model.phase == .idle && !model.active)
    #expect(transport.closeCount() == 1)
    #expect(transport.snapshot().filter({ $0.kind == .releaseAll }).count == 1)
}

@MainActor
private final class InertPresenter: NativePresenter {
    var onFailure: (() -> Void)?
    var results: [PresentationResult]
    var cleared = 0
    init(_ results: [PresentationResult]) { self.results = results }
    func display(_ image: CVPixelBuffer) -> PresentationResult { results.isEmpty ? .presented : results.removeFirst() }
    func clear() { cleared += 1 }
    func forgetHeldKeys() {}
}

@MainActor private func beginInert(_ transport: InertChannel, presenter: InertPresenter? = nil) -> SessionModel {
    let model = SessionModel(makeChannel: { _ in transport }); model.surface = presenter
    let token = Invitation.encodeBase64URL(Data(repeating: 4, count: 32))
    let json = "{\"v\":1,\"address\":\"10.0.0.1\",\"port\":48631,\"certificateSHA256\":\"\(String(repeating: "a", count: 64))\",\"token\":\"\(token)\"}"
    model.review("knot-native:v1:" + Invitation.encodeBase64URL(Data(json.utf8))); model.connect(); return model
}
@MainActor private func approveInert(_ transport: InertChannel, _ model: SessionModel) async throws {
    for _ in 0..<100 { if model.phase == .approval { break }; try await Task.sleep(for: .milliseconds(5)) }
    try #require(model.phase == .approval)
    let ready = Packet(kind: .ready, payload: Data("{\"v\":1,\"codec\":\"h264-annexb\",\"width\":64,\"height\":64,\"fps\":30,\"bitrate\":1000000,\"hardwareEncoder\":true}".utf8))
    transport.feed(Data(ready.encoded.prefix(5))); transport.feed(ready.payload)
    for _ in 0..<100 { if model.phase == .decoding { break }; try await Task.sleep(for: .milliseconds(5)) }
    try #require(model.phase == .decoding)
}
private func syntheticPresentationPixel() throws -> CVPixelBuffer {
    var pixel: CVPixelBuffer?
    try #require(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    return try #require(pixel)
}

@Test @MainActor func disconnectRevokesBlockedHelloSynchronously() async throws {
    let transport = InertChannel(blockedKind: .hello)
    let model = beginInert(transport)
    for _ in 0..<100 { if transport.attemptedKinds().contains(.hello) { break }; try await Task.sleep(for: .milliseconds(5)) }
    try #require(transport.attemptedKinds() == [.hello] && model.phase == .connecting)
    let start = ContinuousClock.now
    model.disconnect()
    #expect(ContinuousClock.now - start < .milliseconds(100))
    #expect(transport.closeCount() == 1 && model.phase == .idle)
    try await Task.sleep(for: .milliseconds(20))
    #expect(model.phase == .idle && transport.attemptedKinds() == [.hello])
    #expect(transport.snapshot().isEmpty)
}

@Test @MainActor func disconnectBeforeReaderStartsCannotCreateLateConnection() async throws {
    let transport = InertChannel()
    let model = beginInert(transport)
    model.disconnect() // no suspension: the MainActor reader has not started
    try await Task.sleep(for: .milliseconds(20))
    #expect(model.phase == .idle && transport.closeCount() == 0 && transport.attemptedKinds().isEmpty)
}

@Test @MainActor func disconnectRevokesBlockedWriterAndQueuedInputSynchronously() async throws {
    let transport = InertChannel(blockedKind: .key), presenter = InertPresenter([.presented])
    let model = beginInert(transport, presenter: presenter)
    try await approveInert(transport, model)
    model.presentDecodedImage(try syntheticPresentationPixel())
    try #require(model.phase == .streaming)
    model.send(try Input.key(down: true, scan: 0x1e, extended: false))
    for _ in 0..<100 { if transport.attemptedKinds().contains(.key) { break }; try await Task.sleep(for: .milliseconds(5)) }
    try #require(transport.attemptedKinds() == [.hello, .key])
    model.send(try Input.key(down: true, scan: 0x30, extended: false))
    let start = ContinuousClock.now; model.disconnect()
    #expect(ContinuousClock.now - start < .milliseconds(100) && transport.closeCount() == 1)
    try await Task.sleep(for: .milliseconds(20))
    #expect(model.phase == .idle && transport.attemptedKinds() == [.hello, .key])
    #expect(transport.snapshot().map(\.kind) == [.hello])
}

@Test @MainActor func presentationFailureAfterStreamingRevokesTransportAndInput() async throws {
    let transport = InertChannel(), presenter = InertPresenter([.backpressure, .presented, .failed])
    let model = beginInert(transport, presenter: presenter)
    try await approveInert(transport, model)
    let image = try syntheticPresentationPixel()
    model.presentDecodedImage(image); #expect(model.phase == .decoding)
    model.presentDecodedImage(image); try #require(model.phase == .streaming)
    model.presentDecodedImage(image)
    #expect(model.phase == .failed && !model.active && transport.closeCount() == 1 && presenter.cleared == 1)
    model.send(try Input.key(down: true, scan: 0x1e, extended: false))
    try await Task.sleep(for: .milliseconds(10))
    #expect(transport.attemptedKinds() == [.hello])
}

@Test @MainActor func asynchronousRendererFailureRevokesPriorStreaming() async throws {
    let transport = InertChannel(), presenter = InertPresenter([.presented])
    let model = beginInert(transport, presenter: presenter)
    try await approveInert(transport, model)
    model.presentDecodedImage(try syntheticPresentationPixel()); try #require(model.phase == .streaming)
    presenter.onFailure?()
    #expect(model.phase == .failed && transport.closeCount() == 1 && presenter.onFailure == nil)
}

@Test @MainActor func sustainedPresentationBackpressureReportsAndRecoversWithoutRevoking() async throws {
    let transport = InertChannel()
    let presenter = InertPresenter([.presented, .backpressure, .backpressure, .backpressure, .presented, .backpressure])
    let model = beginInert(transport, presenter: presenter)
    try await approveInert(transport, model)
    let image = try syntheticPresentationPixel(), start = ContinuousClock.now
    model.presentDecodedImage(image, now: start)
    try #require(model.phase == .streaming)
    model.presentDecodedImage(image, now: start + .milliseconds(100))
    model.presentDecodedImage(image, now: start + .seconds(1))
    #expect(!model.status.contains("Display is behind"))
    model.presentDecodedImage(image, now: start + .milliseconds(2100))
    #expect(model.phase == .streaming && model.status.contains("Display is behind"))
    #expect(transport.closeCount() == 0)
    model.releaseInput()
    #expect(model.inputRecovery && model.status.contains("Display is behind") && model.status.contains("click"))
    model.recoverInput()
    #expect(!model.inputRecovery && model.status.contains("Display is behind"))
    model.presentDecodedImage(image, now: start + .milliseconds(2200))
    #expect(model.phase == .streaming && !model.status.contains("Display is behind"))
    model.presentDecodedImage(image, now: start + .seconds(4))
    #expect(!model.status.contains("Display is behind")) // a new short stall gets its own budget
    model.disconnect()
    #expect(model.phase == .idle && transport.closeCount() == 1 && !model.status.contains("Display is behind"))
}

@Test @MainActor func startupUsesStageBudgetsAndSurvivesVirtualElevenSecondInitialization() async throws {
    // A published model phase precedes async read registration. Deliberately
    // delay the latter so this test cannot pass only by scheduler coincidence.
    let transport = InertChannel(readRegistrationDelay: .milliseconds(20)), presenter = InertPresenter([.presented])
    let model = beginInert(transport, presenter: presenter)
    let approvalReadDeadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < approvalReadDeadline,
          model.phase != .approval || transport.recordedBudgets().isEmpty {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(model.phase == .approval)
    try #require(!transport.recordedBudgets().isEmpty)
    #expect(transport.recordedBudgets().first == .seconds(65))
    // Virtual elapsed time exercises the real deadline policy without capture,
    // a real eleven-second delay or a fake claim of hardware startup evidence.
    #expect(model.checkDeadlines(now: .now + .seconds(11)))
    model.releaseInput()
    try await approveInert(transport, model)
    let readyReadDeadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < readyReadDeadline, !transport.recordedBudgets().contains(.seconds(10)) {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(transport.recordedBudgets().contains(.seconds(10)))
    model.presentDecodedImage(try syntheticPresentationPixel())
    #expect(model.phase == .streaming && model.inputRecovery && model.status.contains("click"))
    model.disconnect(); #expect(transport.closeCount() == 1)
}

@Test @MainActor func startupSilenceStillHasBoundedCancellation() async throws {
    let transport = InertChannel(), model = beginInert(transport)
    for _ in 0..<100 { if model.phase == .approval { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(!model.checkDeadlines(now: .now + .seconds(66)))
    #expect(model.phase == .failed && transport.closeCount() == 1)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["KNOT_NATIVE_WINDOWS_FIXTURES"] != nil,
               "Fresh Windows public certificate fixture path not supplied locally."))
func freshWindowsCertificateAcceptsExactExportedPinAndRejectsMismatchOrExpired() throws {
    let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["KNOT_NATIVE_WINDOWS_FIXTURES"]), isDirectory: true)
    let bytes = try Data(contentsOf: root.appendingPathComponent("native-test-public.cer"))
    try #require(bytes.count <= 65_536)
    let exportedPin = try String(contentsOf: root.appendingPathComponent("native-test-public.sha256"), encoding: .utf8).trimmingCharacters(in: .newlines)
    try #require(exportedPin.utf8.count == 64)
    try #require(exportedPin.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
    #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == exportedPin)
    let certificate = try #require(SecCertificateCreateWithData(nil, bytes as CFData))
    func trust(at date: Date? = nil) throws -> SecTrust {
        var trust: SecTrust?
        try #require(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "knot-native" as CFString), &trust) == errSecSuccess)
        let result = try #require(trust)
        if let date { SecTrustSetVerifyDate(result, date as CFDate) }
        return result
    }
    #expect(TLSChannel.evaluate(try trust(), expectedPin: exportedPin))
    #expect(!TLSChannel.evaluate(try trust(), expectedPin: String(repeating: "0", count: 64)))
    #expect(!TLSChannel.evaluate(try trust(at: Date().addingTimeInterval(3 * 86400)), expectedPin: exportedPin))
    #expect(!TLSChannel.evaluate(try trust(at: Date().addingTimeInterval(-3 * 86400)), expectedPin: exportedPin))
}
