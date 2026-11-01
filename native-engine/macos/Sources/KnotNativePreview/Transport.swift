import Foundation
import Network
import Security
import CryptoKit
import KnotNativeCore

protocol NativeChannel: AnyObject, Sendable {
    func start() async throws
    func readExactly(_ count: Int) async throws -> Data
    func send(_ packet: Packet) async throws
    func close()
}

/// Owns one fresh TLS connection. All reads and writes have a wall-clock deadline;
/// the viewer runs exactly one reader and one writer, independently.
final class TLSChannel: NativeChannel, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "KnotNativePreview.tls")

    convenience init(invitation: Invitation) throws {
        guard let port = NWEndpoint.Port(rawValue: invitation.port) else { throw NativeFailure.malformed }
        self.init(endpoint: .hostPort(host: NWEndpoint.Host(invitation.address), port: port), pin: invitation.certificateSHA256)
    }

    /// Internal endpoint injection exists for fresh loopback TLS fixtures only.
    /// Runtime entry always validates the invitation's canonical private IPv4.
    init(endpoint: NWEndpoint, pin: String) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, "knot-native")
        let expected = pin
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let peer = sec_trust_copy_ref(trust).takeRetainedValue()
            complete(Self.evaluate(peer, expectedPin: expected))
        }, queue)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = false
        connection = NWConnection(to: endpoint, using: parameters)
    }

    /// Exact leaf DER pin plus OS validity, server purpose and DNS verification.
    /// No ambient trust anchors, revocation/network fetch or persisted trust.
    static func evaluate(_ trust: SecTrust, expectedPin: String) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return false }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedPin,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, "knot-native" as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = CompletionGate<Void>(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: _ = gate.finish(.success(()))
                case .failed, .cancelled: _ = gate.finish(.failure(NativeFailure.transport))
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + 10) { [self] in
                if gate.finish(.failure(NativeFailure.transport)) { connection.cancel() }
            }
            connection.start(queue: queue)
        }
    }

    func readExactly(_ count: Int) async throws -> Data {
        guard count >= 0, count <= 4_194_304 else { throw NativeFailure.oversized }
        if count == 0 { return Data() }
        let deadline = ContinuousClock.now + .seconds(10)
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
            let gate = CompletionGate<Data>(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, complete, error in
                if let data, !data.isEmpty { _ = gate.finish(.success(data)) }
                else if error != nil || complete { _ = gate.finish(.failure(NativeFailure.transport)) }
                else { _ = gate.finish(.failure(NativeFailure.transport)) }
            }
            queue.asyncAfter(deadline: .now() + max(0.001, timeout)) { [self] in
                if gate.finish(.failure(NativeFailure.transport)) { connection.cancel() }
            }
        }
    }

    func send(_ packet: Packet) async throws {
        guard packet.payload.count <= 4096 else { throw NativeFailure.oversized }
        try await withCheckedThrowingContinuation { continuation in
            let gate = CompletionGate<Void>(continuation)
            connection.send(content: packet.encoded, completion: .contentProcessed { error in
                _ = gate.finish(error == nil ? .success(()) : .failure(NativeFailure.transport))
            })
            queue.asyncAfter(deadline: .now() + 10) { [self] in
                if gate.finish(.failure(NativeFailure.transport)) { connection.cancel() }
            }
        }
    }
    func close() { connection.cancel() }
}

private final class CompletionGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    init(_ continuation: CheckedContinuation<Value, any Error>) { self.continuation = continuation }
    @discardableResult func finish(_ result: Result<Value, any Error>) -> Bool {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        guard let pending else { return false }; pending.resume(with: result); return true
    }
}
