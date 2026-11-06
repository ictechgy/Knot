import Foundation

/// Explicit gesture protocol. No clipboard observation or background synchronization.
public enum ClipboardOperation: UInt8, Sendable { case copy = 1, paste = 2 }
public enum ClipboardStatus: UInt8, Sendable { case success = 0, unavailable = 1, denied = 2, busy = 3 }
public struct ClipboardResponse: Sendable, Equatable {
    public let operation: ClipboardOperation
    public let status: ClipboardStatus
    public let nonce: Data
    public let text: String
    public init(_ bytes: Data) throws {
        guard (18...ClipboardProtocol.maximumTextBytes + 18).contains(bytes.count),
              let operation = ClipboardOperation(rawValue: bytes[bytes.startIndex]),
              let status = ClipboardStatus(rawValue: bytes[bytes.startIndex + 1]) else { throw NativeFailure.malformed }
        let text = try ClipboardProtocol.text(Data(bytes.dropFirst(18)))
        guard status == .success || text.isEmpty,
              operation != .paste || text.isEmpty else { throw NativeFailure.malformed }
        self.operation = operation; self.status = status
        self.nonce = Data(bytes.dropFirst(2).prefix(16)); self.text = text
    }
}
public enum ClipboardProtocol {
    public static let maximumTextBytes = 1_048_576
    public static func text(_ bytes: Data) throws -> String {
        guard bytes.count <= maximumTextBytes, let value = String(data: bytes, encoding: .utf8),
              !value.unicodeScalars.contains(where: { $0.value == 0 }) else { throw NativeFailure.malformed }
        return value
    }
    public static func request(_ operation: ClipboardOperation, nonce: Data, text: String = "") throws -> Packet {
        guard nonce.count == 16 else { throw NativeFailure.malformed }
        let bytes = Data(text.utf8); _ = try self.text(bytes)
        guard operation != .copy || bytes.isEmpty else { throw NativeFailure.malformed }
        var payload = Data([operation.rawValue]); payload.append(nonce); payload.append(bytes)
        return Packet(kind: .clipboardRequest, payload: payload)
    }
    public static func validateRequest(_ payload: Data) throws {
        guard (17...maximumTextBytes + 17).contains(payload.count),
              let operation = ClipboardOperation(rawValue: payload[payload.startIndex]) else { throw NativeFailure.malformed }
        let text = try self.text(Data(payload.dropFirst(17)))
        guard operation != .copy || text.isEmpty else { throw NativeFailure.malformed }
    }
}
