import Foundation
import Network
import KnotNativeCore

protocol EnrollmentSocket: AnyObject, Sendable {
    func start() async throws
    func readExactly(_ count: Int) async throws -> Data
    func send(_ data: Data) async throws
    func close()
}

protocol EnrollmentCryptography: AnyObject, Sendable {
    var message: Data { get }
    func process(_ peer: Data) throws
    func seal(kind: UInt8, plaintext: Data) throws -> Data
    func open(kind: UInt8, sealed: Data) throws -> Data
    func close()
}
extension PairingCryptoSession: EnrollmentCryptography {}

/// One fresh plain provisioning socket, never promoted to the media TLS socket.
final class EnrollmentTCPSocket: EnrollmentSocket, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "KnotNativePreview.enrollment")
    private let lifetime = ChannelLifetime()
    private let deadline = ContinuousClock.now + .seconds(10)
    init(candidate: EnrollmentCandidate) throws {
        guard Invitation.isPrivateIPv4(candidate.address), let port = NWEndpoint.Port(rawValue: candidate.port) else {
            throw EnrollmentFailure.invalidTarget
        }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        connection = NWConnection(host: NWEndpoint.Host(candidate.address), port: port, using: parameters)
    }
    private func secondsRemaining() throws -> Double {
        let remaining = deadline - .now
        let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
        guard seconds > 0 else { close(); throw EnrollmentFailure.transport }
        return seconds
    }
    func start() async throws {
        let seconds = try secondsRemaining()
        try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            let gate = CompletionGate<Void>(continuation) { [lifetime] in lifetime.remove(id) }
            guard lifetime.perform(id: id, cancel: { gate.finish(.failure(EnrollmentFailure.cancelled)) }, operation: {
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: gate.finish(.success(()))
                    case .failed, .cancelled: gate.finish(.failure(EnrollmentFailure.transport))
                    default: break
                    }
                }
                gate.armDeadline(after: seconds, on: queue) { [weak self] in self?.close() }
                connection.start(queue: queue)
            }) else { gate.finish(.failure(EnrollmentFailure.cancelled)); return }
        }
    }
    func readExactly(_ count: Int) async throws -> Data {
        guard (1...4096).contains(count) else { throw EnrollmentFailure.invalidMessage }
        var result = Data(); result.reserveCapacity(count)
        while result.count < count {
            let seconds = try secondsRemaining()
            let maximum = count - result.count
            let part: Data = try await withCheckedThrowingContinuation { continuation in
                let id = UUID()
                let gate = CompletionGate<Data>(continuation) { [lifetime] in lifetime.remove(id) }
                guard lifetime.perform(id: id, cancel: { gate.finish(.failure(EnrollmentFailure.cancelled)) }, operation: {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { bytes, _, _, _ in
                        if let bytes, !bytes.isEmpty { gate.finish(.success(bytes)) }
                        else { gate.finish(.failure(EnrollmentFailure.transport)) }
                    }
                    gate.armDeadline(after: seconds, on: queue) { [weak self] in self?.close() }
                }) else { gate.finish(.failure(EnrollmentFailure.cancelled)); return }
            }
            result.append(part)
        }
        return result
    }
    func send(_ data: Data) async throws {
        guard !data.isEmpty, data.count <= 4101 else { throw EnrollmentFailure.invalidMessage }
        let seconds = try secondsRemaining()
        try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            let gate = CompletionGate<Void>(continuation) { [lifetime] in lifetime.remove(id) }
            guard lifetime.perform(id: id, cancel: { gate.finish(.failure(EnrollmentFailure.cancelled)) }, operation: {
                connection.send(content: data, completion: .contentProcessed { error in
                    gate.finish(error == nil ? .success(()) : .failure(EnrollmentFailure.transport))
                })
                gate.armDeadline(after: seconds, on: queue) { [weak self] in self?.close() }
            }) else { gate.finish(.failure(EnrollmentFailure.cancelled)); return }
        }
    }
    func close() { lifetime.revoke { connection.cancel() } }
}

struct AuthenticatedEnrollment: Sendable {
    let offer: EnrollmentOffer
    let viewerName: String
    let expiresAt: ContinuousClock.Instant
}

protocol EnrollmentAuthenticating: AnyObject, Sendable {
    func authenticate(name: String) async throws -> AuthenticatedEnrollment
    func close()
}

/// Owns a single PAKE context and socket. Process success is not authorization;
/// only authenticated, strictly validated ServerOffer can leave this object.
final class EnrollmentClient: EnrollmentAuthenticating, @unchecked Sendable {
    private let candidate: EnrollmentCandidate
    private let socket: any EnrollmentSocket
    private let crypto: any EnrollmentCryptography
    private let lock = NSLock()
    private var closed = false
    private var started = false
    private let created = ContinuousClock.now
    init(candidate: EnrollmentCandidate, password: Data,
         makeSocket: @Sendable (EnrollmentCandidate) throws -> any EnrollmentSocket = { try EnrollmentTCPSocket(candidate: $0) },
         makeCrypto: @Sendable (Data, Data) throws -> any EnrollmentCryptography = {
             try PairingCryptoSession(server: false, password: $0, slot: $1)
         }) throws {
        guard password.count == 8, password.allSatisfy({ (48...57).contains($0) }) else { throw EnrollmentFailure.invalidCode }
        self.candidate = candidate
        socket = try makeSocket(candidate)
        do { crypto = try makeCrypto(password, candidate.slot) }
        catch { socket.close(); throw error }
    }
    private func begin() throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !started else { throw EnrollmentFailure.cancelled }
        started = true
    }
    private func check() throws {
        lock.lock(); let valid = !closed; lock.unlock()
        guard valid, !Task.isCancelled else { throw EnrollmentFailure.cancelled }
        guard ContinuousClock.now - created < .seconds(10) else { close(); throw EnrollmentFailure.transport }
    }
    private func frame(_ expected: EnrollmentFrame.Kind) async throws -> Data {
        try check()
        let (kind, length) = try EnrollmentFrame.header(await socket.readExactly(5))
        let bytes = try await socket.readExactly(length)
        try check()
        if kind == .error { throw try EnrollmentWire.serverError(bytes) }
        guard kind == expected else { throw EnrollmentFailure.invalidMessage }
        return bytes
    }
    func authenticate(name: String) async throws -> AuthenticatedEnrollment {
        try await withTaskCancellationHandler { try await exchange(name: name) }
            onCancel: { self.close() }
    }
    private func exchange(name: String) async throws -> AuthenticatedEnrollment {
        try begin()
        defer { close() }
        guard Invitation.validViewerLabel(name) else { throw EnrollmentFailure.invalidMessage }
        try check(); try await socket.start(); try check()
        try await socket.send(EnrollmentWire.preamble)
        try await socket.send(EnrollmentFrame(kind: .clientHello,
            payload: EnrollmentWire.hello(slot: candidate.slot, message: crypto.message)).encoded)
        let message = try EnrollmentWire.serverMessage(await frame(.serverHello), slot: candidate.slot)
        do { try crypto.process(message) } catch { throw EnrollmentFailure.authentication }
        try check()
        let confirmation = try EnrollmentWire.confirm(slot: candidate.slot, name: name)
        let sealed: Data
        do { sealed = try crypto.seal(kind: 3, plaintext: confirmation) }
        catch { throw EnrollmentFailure.authentication }
        try await socket.send(EnrollmentFrame(kind: .clientConfirm, payload: sealed).encoded)
        let offerBytes = try await frame(.serverOffer)
        let plaintext: Data
        do { plaintext = try crypto.open(kind: 4, sealed: offerBytes) }
        catch { throw EnrollmentFailure.authentication }
        try check()
        let offer = try EnrollmentOffer(plaintext, candidate: candidate)
        // Conservative local lifetime: provisioning time cannot extend T2's lease.
        let expires = created + .milliseconds(offer.ttlMilliseconds)
        guard .now < expires else { throw EnrollmentFailure.expired }
        return AuthenticatedEnrollment(offer: offer, viewerName: name, expiresAt: expires)
    }
    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true; lock.unlock()
        socket.close(); crypto.close()
    }
    deinit { close() }
}
