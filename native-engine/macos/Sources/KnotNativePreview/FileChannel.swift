import Foundation
import Network
import KnotNativeCore

struct NativeFileEndpoint: Sendable {
    let address: String, pin: String, token: String
    let port: UInt16
    init(invitation: Invitation, offer: NativeFileOffer) throws {
        guard Invitation.isPrivateIPv4(invitation.address) else { throw NativeFileError.auth }
        address = invitation.address; pin = invitation.certificateSHA256; port = offer.port; token = offer.token
    }
}

protocol NativeFileChannel: AnyObject, Sendable {
    func start() async throws
    func readExactly(_ count: Int, timeout: Duration) async throws -> Data
    func send(_ packet: FilePacket) async throws
    func close()
}

/// File operations own a separate TLS connection; the shared trust evaluator is
/// still exact-DER, offline OS server-purpose/name/validity verification.
final class FileTLSChannel: NativeFileChannel, @unchecked Sendable {
    private let transport: TLSChannel
    init(endpoint: NativeFileEndpoint) throws {
        guard Invitation.isPrivateIPv4(endpoint.address), endpoint.port == 48634,
              let port = NWEndpoint.Port(rawValue: endpoint.port) else { throw NativeFileError.auth }
        transport = TLSChannel(endpoint: .hostPort(host: NWEndpoint.Host(endpoint.address), port: port), pin: endpoint.pin)
    }
    /// Only fresh owned loopback tests use this endpoint seam.
    init(testEndpoint: NWEndpoint, pin: String) { transport = TLSChannel(endpoint: testEndpoint, pin: pin) }
    func start() async throws { try await transport.start() }
    func readExactly(_ count: Int, timeout: Duration) async throws -> Data {
        guard count <= 65_544 else { throw NativeFileError.protocolViolation }
        return try await transport.readExactly(count, timeout: timeout)
    }
    func send(_ packet: FilePacket) async throws { try await transport.sendFilePacket(packet) }
    func close() { transport.close() }
}

/// One current operation; the final synchronous rename and revocation share
/// this lock, so cancellation cannot race a checked-but-not-yet-published file.
final class FileRunGate: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var closed = false
    private var current: UUID?
    private var channel: (any NativeFileChannel)?
    private var reserved: Int64 = 0
    private var reservedNodes = 0
    func begin() throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw NativeFileError.closed }
        guard current == nil else { throw NativeFileError.busy }
        let id = UUID(); current = id; return id
    }
    func check(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw NativeFileError.closed }
        guard current == id else { throw NativeFileError.cancelled }
    }
    func bind(_ value: any NativeFileChannel, id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed, current == id, channel == nil else { value.close(); throw NativeFileError.closed }
        channel = value
    }
    func unbind(_ value: any NativeFileChannel, id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if current == id, channel === value { channel = nil }
        value.close()
    }
    func reserve(_ size: Int64, nodes: Int = 1, id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed, current == id else { throw NativeFileError.closed }
        guard FileWire.validSize(size), size <= FileWire.maximumSize - reserved, nodes >= 1, nodes <= FileWire.maximumRunNodes - reservedNodes else { throw NativeFileError.quota }
        reserved += size; reservedNodes += nodes // cancellations deliberately do not refund the run quota
    }
    func publish<T>(id: UUID, _ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard !closed, current == id else { throw NativeFileError.closed }
        return try operation()
    }
    func end(_ id: UUID) {
        lock.lock()
        guard current == id else { lock.unlock(); return }
        current = nil; let value = channel; channel = nil; lock.unlock(); value?.close()
    }
    func cancel() {
        lock.lock(); current = nil; let value = channel; channel = nil; lock.unlock(); value?.close()
    }
    func cancel(_ id: UUID) {
        lock.lock()
        guard current == id else { lock.unlock(); return }
        current = nil; let value = channel; channel = nil; lock.unlock(); value?.close()
    }
    func close() {
        lock.lock(); closed = true; current = nil; let value = channel; channel = nil; lock.unlock(); value?.close()
    }
}
