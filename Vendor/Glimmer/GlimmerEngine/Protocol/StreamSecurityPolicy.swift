// SPDX-License-Identifier: GPL-3.0-only
// DeskBridge additions to Glimmer rc.12. No plaintext streaming fallback.
import Foundation

public enum StreamSecurityPolicy {
    public static let requiredFeatures: UInt32 = 0x07 // control V2, video GCM, audio CBC
    public enum Failure: Error, LocalizedError, Sendable, Equatable {
        case plaintextSignalling, missingEncryption(UInt32)
        public var errorDescription: String? {
            switch self {
            case .plaintextSignalling: "The PC did not offer encrypted streaming signalling. Update Sunshine and enable encryption."
            case .missingEncryption: "The PC does not support all required stream encryption channels. Update Sunshine."
            }
        }
    }
    public static func validateSignalling(url: String) throws {
        guard URLComponents(string: url)?.scheme?.lowercased() == "rtspenc" else {
            throw Failure.plaintextSignalling
        }
    }
    public static func negotiatedFeatures(supported: UInt32) throws -> UInt32 {
        let missing = requiredFeatures & ~supported
        guard missing == 0 else { throw Failure.missingEncryption(missing) }
        return requiredFeatures
    }
}
