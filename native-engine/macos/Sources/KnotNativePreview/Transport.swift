import Foundation
import Network
import Security
import CryptoKit
import KnotNativeCore

protocol NativeChannel: AnyObject, Sendable {
    func start() async throws
    func readExactly(_ count: Int, timeout: Duration) async throws -> Data
    func send(_ packet: Packet) async throws
    func close()
}
extension NativeChannel {
    func readExactly(_ count: Int) async throws -> Data { try await readExactly(count, timeout: .seconds(10)) }
}

/// Owns one fresh TLS connection. All reads and writes have a wall-clock deadline;
/// the viewer runs exactly one reader and one writer, independently.
final class TLSChannel: NativeChannel, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "KnotNativePreview.tls")
    private let helloDeadline = ContinuousClock.now + .seconds(10)
    private let lifetime = ChannelLifetime()
    private let verification: VerificationFailureCapture

    convenience init(invitation: Invitation) throws {
        guard let port = NWEndpoint.Port(rawValue: invitation.port) else { throw NativeFailure.malformed }
        self.init(endpoint: .hostPort(host: NWEndpoint.Host(invitation.address), port: port), pin: invitation.certificateSHA256)
    }

    /// Typed media/file entrypoints validate their authenticated private IPv4.
    /// The raw endpoint is also used by fresh owned loopback TLS fixtures.
    init(endpoint: NWEndpoint, pin: String) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, "knot-native")
        let expected = pin
        let verification = VerificationFailureCapture()
        self.verification = verification
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let peer = sec_trust_copy_ref(trust).takeRetainedValue()
            let failure = Self.verificationFailure(peer, expectedPin: expected)
            verification.record(failure)
            complete(failure == nil)
            verification.finishIfRejected()
        }, queue)
        let tcp = NWProtocolTCP.Options()
        // Input envelopes are small and time-sensitive; do not wait for a
        // previous packet's ACK before transmitting the next pointer action.
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        connection = NWConnection(to: endpoint, using: parameters)
    }

    /// Exact leaf DER pin plus OS validity, server purpose and DNS verification.
    /// No ambient trust anchors, revocation/network fetch or persisted trust.
    static func evaluate(_ trust: SecTrust, expectedPin: String) -> Bool {
        verificationFailure(trust, expectedPin: expectedPin) == nil
    }

    /// A matching pin does not override macOS's certificate policy. Keep that
    /// rejection distinct from an identity change; no private trust-result keys
    /// or raw OS diagnostics are used to decide the user-facing recovery path.
    static func verificationFailure(_ trust: SecTrust, expectedPin: String) -> NativeFailure? {
        // Policy replacement must precede the offline option: the latter lives
        // in those policy options. Copying the chain can itself evaluate trust.
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, "knot-native" as CFString)) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else { return .certificatePolicy }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return .certificatePolicy }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedPin else { return .certificatePinMismatch }
        guard SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { return .certificatePolicy }
        return SecTrustEvaluateWithError(trust, nil) ? nil : .certificatePolicy
    }

    static func startFailure(_ error: NWError, verificationFailure: NativeFailure? = nil) -> NativeFailure {
        // A TLS alert alone can also mean a protocol/peer/network failure. Only
        // our verification callback can establish a local certificate failure.
        verificationFailure ?? .transport
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            let gate = CompletionGate<Void>(continuation) { [lifetime, verification] in
                lifetime.remove(id); verification.clearObserver()
            }
            guard lifetime.perform(id: id, cancel: { gate.finish(.failure(NativeFailure.transport)) }, operation: {
                verification.observe { [weak self] failure in
                    // Network can remain in .waiting after local verification
                    // rejects a peer. Do not let its deadline erase the cause.
                    if gate.finish(.failure(failure)) { self?.close() }
                }
                connection.stateUpdateHandler = { [verification] state in
                    switch state {
                    case .ready: _ = gate.finish(.success(()))
                    case .failed(let error): _ = gate.finish(.failure(Self.startFailure(error, verificationFailure: verification.failure)))
                    case .cancelled: _ = gate.finish(.failure(NativeFailure.transport))
                    default: break
                    }
                }
                gate.armDeadline(after: 10, on: queue) { [weak self] in self?.close() }
                connection.start(queue: queue)
            }) else { gate.finish(.failure(NativeFailure.transport)); return }
        }
    }

    func readExactly(_ count: Int, timeout: Duration) async throws -> Data {
        guard count >= 0, count <= 4_194_304, timeout > .zero, timeout <= .seconds(65) else { throw NativeFailure.oversized }
        if count == 0 { return Data() }
        let deadline = ContinuousClock.now + timeout
        var bytes = Data(); bytes.reserveCapacity(count)
        while bytes.count < count {
            guard ContinuousClock.now < deadline else { close(); throw NativeFailure.transport }
            let remaining = deadline - ContinuousClock.now
            let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
            let part = try await receive(maximum: min(65_536, count - bytes.count), timeout: seconds)
            guard !part.isEmpty else { throw NativeFailure.transport }
            bytes.append(part)
        }
        return bytes
    }

    private func receive(maximum: Int, timeout: Double) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            let gate = CompletionGate<Data>(continuation) { [lifetime] in lifetime.remove(id) }
            guard lifetime.perform(id: id, cancel: { gate.finish(.failure(NativeFailure.transport)) }, operation: {
                connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, _, _ in
                    if let data, !data.isEmpty { _ = gate.finish(.success(data)) }
                    else { _ = gate.finish(.failure(NativeFailure.transport)) }
                }
                gate.armDeadline(after: max(0.001, timeout), on: queue) { [weak self] in self?.close() }
            }) else { gate.finish(.failure(NativeFailure.transport)); return }
        }
    }

    func send(_ packet: Packet) async throws {
        if packet.kind == .clipboardRequest { try ClipboardProtocol.validateRequest(packet.payload) }
        else { guard packet.payload.count <= 4096 else { throw NativeFailure.oversized } }
        var timeout = 10.0
        if packet.kind == .hello {
            let remaining = helloDeadline - ContinuousClock.now
            timeout = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
            guard timeout > 0 else { close(); throw NativeFailure.transport }
        }
        try await sendEncoded(packet.encoded, timeout: timeout)
    }

    // File channels use an independent connection and packet type. The media
    // NativeChannel.send retains its ordinary 4096-byte cap, with one strictly
    // parsed, bounded clipboard request exception.
    func sendFilePacket(_ packet: FilePacket) async throws {
        var budget = 30.0
        if packet.kind == .hello {
            let remaining = helloDeadline - ContinuousClock.now
            budget = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
            guard budget > 0 else { close(); throw NativeFileError.timeout }
        }
        try await sendEncoded(packet.encoded, timeout: budget)
    }

    private func sendEncoded(_ data: Data, timeout budget: Double) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            let gate = CompletionGate<Void>(continuation) { [lifetime] in lifetime.remove(id) }
            guard lifetime.perform(id: id, cancel: { gate.finish(.failure(NativeFailure.transport)) }, operation: {
                connection.send(content: data, completion: .contentProcessed { error in
                    _ = gate.finish(error == nil ? .success(()) : .failure(NativeFailure.transport))
                })
                gate.armDeadline(after: budget, on: queue) { [weak self] in self?.close() }
            }) else { gate.finish(.failure(NativeFailure.transport)); return }
        }
    }
    func close() { lifetime.revoke { connection.cancel() } }
}

private final class VerificationFailureCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: NativeFailure?
    private var observer: (@Sendable (NativeFailure) -> Void)?
    var failure: NativeFailure? { lock.withLock { recorded } }
    func record(_ failure: NativeFailure?) {
        lock.withLock { if recorded == nil { recorded = failure } }
    }
    func observe(_ observer: @escaping @Sendable (NativeFailure) -> Void) {
        lock.withLock { self.observer = observer }
        finishIfRejected()
    }
    func finishIfRejected() {
        lock.lock()
        let failure = recorded, callback = failure == nil ? nil : observer
        if failure != nil { observer = nil }
        lock.unlock()
        if let failure { callback?(failure) }
    }
    func clearObserver() { lock.withLock { observer = nil } }
}

/// Serializes submission against permanent revocation. At most a handshake,
/// reader and writer can be pending; close cancels their continuations/timers
/// synchronously and all later submissions fail before reaching Network.
final class ChannelLifetime: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var closed = false
    private var pending: [UUID: @Sendable () -> Void] = [:]
    func perform(id: UUID, cancel: @escaping @Sendable () -> Void, operation: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, pending.count < 3 else { return false }
        pending[id] = cancel; operation(); return true
    }
    func remove(_ id: UUID) { lock.lock(); pending.removeValue(forKey: id); lock.unlock() }
    func revoke(_ cancelConnection: () -> Void) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true; let operations = Array(pending.values); pending.removeAll(); lock.unlock()
        cancelConnection()
        for cancel in operations { cancel() }
    }
}

final class CompletionGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var timer: DispatchSourceTimer?
    private let onFinish: @Sendable () -> Void
    init(_ continuation: CheckedContinuation<Value, any Error>, onFinish: @escaping @Sendable () -> Void = {}) { self.continuation = continuation; self.onFinish = onFinish }
    /// Only the pending operation owns a timer. Completion clears and cancels it,
    /// so fragmented reads cannot retain ten seconds of obsolete deadline work.
    func armDeadline(after seconds: Double, on queue: DispatchQueue, timeout: @escaping @Sendable () -> Void) {
        lock.lock()
        guard continuation != nil, timer == nil else { lock.unlock(); return }
        let deadline = DispatchSource.makeTimerSource(queue: queue)
        deadline.schedule(deadline: .now() + seconds)
        deadline.setEventHandler { [weak self] in
            if self?.finish(.failure(NativeFailure.transport)) == true { timeout() }
        }
        timer = deadline; deadline.resume(); lock.unlock()
    }
    @discardableResult func finish(_ result: Result<Value, any Error>) -> Bool {
        lock.lock(); let pending = continuation; continuation = nil; let deadline = timer; timer = nil; lock.unlock()
        deadline?.cancel()
        guard let pending else { return false }; onFinish(); pending.resume(with: result); return true
    }
}
