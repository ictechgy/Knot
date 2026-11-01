import Foundation
import CKnotPairing

/// A single enrollment attempt. The C context owns and zeroizes derived keys;
/// this bridge serializes native use and never exports those keys to Swift.
public final class PairingCryptoSession: @unchecked Sendable {
    private let gate = NSLock()
    private var handle: OpaquePointer?
    public let message: Data

    public init(server: Bool, password: Data, slot: Data) throws {
        guard password.count == 8, password.allSatisfy({ (48...57).contains($0) }),
              slot.count == 16, kn_pair_abi_version() == 2 else { throw NativeFailure.malformed }
        let created = password.withUnsafeBytes { pass in
            slot.withUnsafeBytes { id in
                kn_pair_create(server ? 1 : 0, pass.bindMemory(to: UInt8.self).baseAddress, 8,
                               id.bindMemory(to: UInt8.self).baseAddress, 16)
            }
        }
        guard let created else { throw NativeFailure.transport }
        var bytes = [UInt8](repeating: 0, count: 32), written: UInt32 = 0
        let status = bytes.withUnsafeMutableBufferPointer {
            kn_pair_message(created, $0.baseAddress, UInt32($0.count), &written)
        }
        guard status == 0, written == 32 else { kn_pair_close(created); throw NativeFailure.malformed }
        handle = created
        message = Data(bytes)
    }
    public func process(_ peer: Data) throws {
        gate.lock(); defer { gate.unlock() }
        guard let handle else { throw NativeFailure.malformed }
        guard peer.count == 32 else { try fail(-1) }
        let status = peer.withUnsafeBytes {
            kn_pair_process(handle, $0.bindMemory(to: UInt8.self).baseAddress, UInt32($0.count))
        }
        if status != 0 { try fail(status) }
    }
    public func seal(kind: UInt8, plaintext: Data) throws -> Data {
        try crypt(encrypt: true, kind: kind, input: plaintext)
    }
    public func open(kind: UInt8, sealed: Data) throws -> Data {
        try crypt(encrypt: false, kind: kind, input: sealed)
    }
    private func crypt(encrypt: Bool, kind: UInt8, input: Data) throws -> Data {
        gate.lock(); defer { gate.unlock() }
        guard let handle else { throw NativeFailure.malformed }
        let maximum = kind == 3 ? 484 : kind == 4 ? 3072 : 0
        guard maximum > 0,
              encrypt ? (1...maximum).contains(input.count) : (29...(maximum + 28)).contains(input.count)
        else { try fail(-1) }
        let expected = encrypt ? input.count + 28 : input.count - 28
        var output = [UInt8](repeating: 0, count: expected), written: UInt32 = 0
        let status = input.withUnsafeBytes { bytes in
            output.withUnsafeMutableBufferPointer { out in
                if encrypt {
                    return kn_pair_seal(handle, kind, bytes.bindMemory(to: UInt8.self).baseAddress,
                        UInt32(bytes.count), out.baseAddress, UInt32(out.count), &written)
                }
                return kn_pair_open(handle, kind, bytes.bindMemory(to: UInt8.self).baseAddress,
                    UInt32(bytes.count), out.baseAddress, UInt32(out.count), &written)
            }
        }
        guard status == 0, written == expected else {
            _ = output.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
            try fail(status == 0 ? -1 : status)
        }
        return Data(output)
    }
    // Caller holds gate. Any failure destroys the attempt; there is no retry of
    // an authenticated-encryption direction or a partially processed context.
    private func fail(_ status: Int32) throws -> Never {
        if let handle { kn_pair_close(handle); self.handle = nil }
        throw status == -4 ? NativeFailure.transport : NativeFailure.malformed
    }
    public func close() {
        gate.lock(); defer { gate.unlock() }
        if let handle { kn_pair_close(handle); self.handle = nil }
    }
    deinit { if let handle { kn_pair_close(handle) } }
}
