// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

/// A short-lived update receipt is separate from credentials and consumed before
/// any decoding or network work. A normal restart cannot restore connection intent.
public struct UpdateReconnectStore: Sendable {
    public let directory: URL
    private static let name = "update-reconnect.json"
    private static let maximumBytes = 4096
    private struct Receipt: Codable {
        let schema: Int
        let previousBuild: UInt64
        let intent: UpdateReconnectIntent
    }
    public init(directory: URL) { self.directory = directory }

    public func save(_ intent: UpdateReconnectIntent, previousBuild: String) throws {
        guard let build = Self.build(previousBuild),
              intent.permits(endpoint: intent.endpoint, hostUniqueID: intent.hostUniqueID,
                             certificateSHA256: intent.certificateSHA256, now: intent.issuedAt)
        else { throw CorePrivateStorage.unsafe }
        let data = try JSONEncoder().encode(Receipt(schema: 1, previousBuild: build, intent: intent))
        guard let root = try CorePrivateStorage.directory(directory, create: true) else { throw CorePrivateStorage.unsafe }
        defer { close(root) }
        try CorePrivateStorage.replace(root, name: Self.name, data: data, maximumBytes: Self.maximumBytes)
    }

    public func consume(currentBuild: String, endpoint: String, hostUniqueID: String,
                        certificateSHA256: String, now: Date) throws -> UpdateReconnectIntent? {
        guard let root = try CorePrivateStorage.directory(directory, create: false) else { return nil }
        defer { close(root) }
        guard let data = try CorePrivateStorage.read(root, name: Self.name, maximumBytes: Self.maximumBytes),
              !data.isEmpty else { return nil }
        // Empty the validated app-owned receipt before parsing. Malformed, expired,
        // downgraded and same-build attempts are terminal, never retried on launch.
        try CorePrivateStorage.replace(root, name: Self.name, data: Data(), maximumBytes: Self.maximumBytes)
        guard let build = Self.build(currentBuild),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.schema == 1, build > receipt.previousBuild,
              receipt.intent.permits(endpoint: endpoint, hostUniqueID: hostUniqueID,
                                    certificateSHA256: certificateSHA256, now: now) else { return nil }
        return receipt.intent
    }

    public func clear() throws {
        guard let root = try CorePrivateStorage.directory(directory, create: false) else { return }
        defer { close(root) }
        guard try CorePrivateStorage.read(root, name: Self.name, maximumBytes: Self.maximumBytes) != nil else { return }
        try CorePrivateStorage.replace(root, name: Self.name, data: Data(), maximumBytes: Self.maximumBytes)
    }
    private static func build(_ value: String) -> UInt64? {
        guard !value.isEmpty, value.count <= 16, value.first != "0",
              value.utf8.allSatisfy({ (48...57).contains($0) }), let result = UInt64(value) else { return nil }
        return result
    }
}
