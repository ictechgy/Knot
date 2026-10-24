// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// An update may restore transport intent, never pairing authority. The caller must
/// still authenticate the endpoint against its existing certificate before connecting.
public struct UpdateReconnectIntent: Codable, Equatable, Sendable {
    public let endpoint: String
    public let hostUniqueID: String
    public let certificateSHA256: String
    public let issuedAt: Date
    public let expiresAt: Date

    public init?(endpoint: String, hostUniqueID: String, certificateSHA256: String,
                 now: Date, lifetime: TimeInterval = 600) {
        guard !endpoint.isEmpty, endpoint.utf8.count <= 255,
              !endpoint.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !hostUniqueID.isEmpty, hostUniqueID.utf8.count <= 256,
              certificateSHA256.count == 64,
              certificateSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              lifetime > 0, lifetime <= 600, now.timeIntervalSince1970.isFinite else { return nil }
        self.endpoint = endpoint; self.hostUniqueID = hostUniqueID
        self.certificateSHA256 = certificateSHA256; issuedAt = now
        expiresAt = now.addingTimeInterval(lifetime)
    }

    public func permits(endpoint: String, hostUniqueID: String, certificateSHA256: String, now: Date) -> Bool {
        // Reject malformed decoded receipts as strictly as newly constructed ones.
        guard let checked = Self(endpoint: self.endpoint, hostUniqueID: self.hostUniqueID,
                                 certificateSHA256: self.certificateSHA256, now: issuedAt,
                                 lifetime: expiresAt.timeIntervalSince(issuedAt)), checked == self,
              now >= issuedAt, now < expiresAt else { return false }
        return endpoint == self.endpoint && hostUniqueID == self.hostUniqueID && certificateSHA256 == self.certificateSHA256
    }
}

/// A receipt is consumed before validation: a failed, expired, or changed-identity
/// attempt must never become a deferred connection or a silent PIN re-pair.
public struct UpdateReconnectGate: Sendable {
    private var pending: UpdateReconnectIntent?
    public init(_ pending: UpdateReconnectIntent? = nil) { self.pending = pending }
    public mutating func arm(_ intent: UpdateReconnectIntent) { pending = intent }
    public mutating func cancel() { pending = nil }
    public mutating func consume(endpoint: String, hostUniqueID: String, certificateSHA256: String, now: Date) -> UpdateReconnectIntent? {
        let intent = pending; pending = nil
        guard let intent, intent.permits(endpoint: endpoint, hostUniqueID: hostUniqueID,
                                        certificateSHA256: certificateSHA256, now: now) else { return nil }
        return intent
    }
}
