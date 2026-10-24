// SPDX-License-Identifier: GPL-3.0-only
import DeskBridgeCore
import Foundation
import Network
import Security

/// All transport state is confined to queue. Only the explicitly selected
/// Windows address is accepted; TLS pin + random capability authenticate setup.
final class EnrollmentServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.deskbridge.enrollment")
    private let listener: NWListener
    private let address: String
    private let windowsAddress: String
    private let windowsIPv4: IPv4Address
    private let request: SetupExchange.MacRequest
    private let fingerprint: String
    private let capability: String
    private let onReady: @Sendable (EnrollmentProtocol.Link) -> Void
    private let completion: @Sendable (Result<Data, Error>) -> Void
    private var link: EnrollmentProtocol.Link?
    private var gate: EnrollmentProtocol.SessionGate?
    private var startedAt: TimeInterval = 0
    private var connection: NWConnection?
    private var consumed = false
    private var stopped = false
    private var deadline: DispatchWorkItem?
    private var connectionDeadline: DispatchWorkItem?

    init(address: String, windowsAddress: String, request: SetupExchange.MacRequest,
         onReady: @escaping @Sendable (EnrollmentProtocol.Link) -> Void,
         completion: @escaping @Sendable (Result<Data, Error>) -> Void) throws {
        guard try EndpointPolicy.validatedAddress(address) == address,
              try EndpointPolicy.validatedAddress(windowsAddress) == windowsAddress,
              let windowsIPv4 = IPv4Address(windowsAddress),
              request.allowedClientAddresses.contains(address) else { throw EnrollmentProtocol.Failure.invalid }
        let material = try EnrollmentIdentity.create()
        let tls = NWProtocolTLS.Options()
        guard let identity = sec_identity_create(material.identity) else { throw EnrollmentProtocol.Failure.invalid }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: .init(address), port: .any)
        parameters.includePeerToPeer = false
        listener = try NWListener(using: parameters)
        self.address = address; self.windowsAddress = windowsAddress; self.request = request
        self.windowsIPv4 = windowsIPv4
        fingerprint = material.fingerprint; capability = material.capability
        self.onReady = onReady; self.completion = completion
    }
    func start() {
        queue.async { [self] in
            guard !stopped else { return }
            startedAt = ProcessInfo.processInfo.systemUptime
            armDeadline(after: EnrollmentProtocol.lifetime, authenticated: false)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.stopped else { return }
                switch state {
                case .ready:
                    do {
                        guard let port = self.listener.port else { throw EnrollmentProtocol.Failure.invalid }
                        let value = try EnrollmentProtocol.Link(address: self.address, port: port.rawValue,
                            sessionID: self.request.requestID, certificateSHA256: self.fingerprint, capability: self.capability)
                        self.gate = try EnrollmentProtocol.SessionGate(link: value, request: self.request, windowsAddress: self.windowsAddress, now: self.startedAt)
                        self.link = value; self.onReady(value)
                    } catch { self.finish(.failure(error)) }
                case .waiting, .failed: self.finish(.failure(EnrollmentProtocol.Failure.invalid))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] value in self?.accept(value) }
            listener.start(queue: queue)
        }
    }
    func cancel() { queue.async { [self] in stop() } }
    private func accept(_ value: NWConnection) {
        guard !stopped, !consumed, connection == nil, link != nil,
              case .hostPort(let host, _) = value.endpoint,
              Self.matchesPeer(host, expected: windowsIPv4) else { value.cancel(); return }
        connection = value
        let limit = DispatchWorkItem { [weak self, weak value] in
            guard let self, let value, self.connection === value, !self.consumed else { return }
            self.drop(value)
        }
        connectionDeadline = limit; queue.asyncAfter(deadline: .now() + 8, execute: limit)
        value.stateUpdateHandler = { [weak self, weak value] state in
            guard let self, let value, self.connection === value, !self.stopped else { return }
            switch state {
            case .ready: self.readFrame(value) { [weak self] data in self?.authenticate(data, on: value) }
            case .failed, .cancelled:
                if self.consumed { self.finish(.failure(EnrollmentProtocol.Failure.invalid)) }
                else { self.drop(value) }
            default: break
            }
        }
        value.start(queue: queue)
    }
    private func authenticate(_ data: Data, on value: NWConnection) {
        do {
            guard link != nil, gate != nil, !consumed else { throw EnrollmentProtocol.Failure.replay }
            try gate?.authorize(data, peer: windowsAddress, now: ProcessInfo.processInfo.systemUptime)
            consumed = true; connectionDeadline?.cancel(); connectionDeadline = nil
            armDeadline(after: EnrollmentProtocol.authenticatedLifetime, authenticated: true)
            // This capability can fetch exactly one public request and return one reply.
            listener.cancel()
            let outgoing = try EnrollmentProtocol.frame(SetupExchange.encode(request))
            value.send(content: outgoing, completion: .contentProcessed { [weak self] error in
                guard let self, !self.stopped else { return }
                guard error == nil else { self.finish(.failure(EnrollmentProtocol.Failure.invalid)); return }
                self.readFrame(value) { [weak self] reply in self?.received(reply, on: value) }
            })
        } catch { if consumed { finish(.failure(EnrollmentProtocol.Failure.invalid)) } else { drop(value) } }
    }
    private func received(_ bytes: Data, on value: NWConnection) {
        do {
            guard gate != nil else { throw EnrollmentProtocol.Failure.expired }
            _ = try gate?.receive(bytes, now: ProcessInfo.processInfo.systemUptime)
            // Receipt is not SSH trust. The Mac still asks the user to compare fingerprints.
            value.send(content: try EnrollmentProtocol.frame(Data("received".utf8)), completion: .contentProcessed { [weak self] error in
                self?.finish(error == nil ? .success(bytes) : .failure(EnrollmentProtocol.Failure.invalid))
            })
        } catch { finish(.failure(EnrollmentProtocol.Failure.invalid)) }
    }
    private func readFrame(_ value: NWConnection, completion: @escaping @Sendable (Data) -> Void) {
        value.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, complete, error in
            guard let self, !self.stopped, self.connection === value else { return }
            do {
                guard error == nil, !complete, let header else { throw EnrollmentProtocol.Failure.frame }
                let size = try EnrollmentProtocol.length(header)
                value.receive(minimumIncompleteLength: size, maximumLength: size) { [weak self] body, _, complete, error in
                    guard let self, !self.stopped, self.connection === value else { return }
                    guard error == nil, !complete, let body, body.count == size else { self.failedRead(value); return }
                    completion(body)
                }
            } catch { self.failedRead(value) }
        }
    }
    private func failedRead(_ value: NWConnection) {
        if consumed { finish(.failure(EnrollmentProtocol.Failure.frame)) } else { drop(value) }
    }
    /// Network may attach an interface to a literal address. Compare its typed
    /// IPv4 bytes, never a diagnostic description or a hostname spelling.
    static func matchesPeer(_ host: NWEndpoint.Host, expected: IPv4Address) -> Bool {
        guard case .ipv4(let actual) = host else { return false }
        return actual.rawValue == expected.rawValue
    }
    private func armDeadline(after interval: TimeInterval, authenticated: Bool) {
        deadline?.cancel()
        let expiry = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped, self.consumed == authenticated else { return }
            self.finish(.failure(EnrollmentProtocol.Failure.expired))
        }
        deadline = expiry; queue.asyncAfter(deadline: .now() + interval, execute: expiry)
    }
    private func drop(_ value: NWConnection) {
        guard connection === value else { value.cancel(); return }
        connectionDeadline?.cancel(); connectionDeadline = nil
        connection = nil; value.stateUpdateHandler = nil; value.cancel()
    }
    private func finish(_ result: Result<Data, Error>) {
        guard !stopped else { return }
        stop(); completion(result)
    }
    private func stop() {
        guard !stopped else { return }
        stopped = true; gate?.cancel(); gate = nil; link = nil
        deadline?.cancel(); deadline = nil; connectionDeadline?.cancel(); connectionDeadline = nil
        listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil; listener.cancel()
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
    }
}
