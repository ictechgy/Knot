// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum UpdateConfigurationError: Error, Equatable { case incomplete, invalidFeed, invalidKey }

public struct UpdatePublisherConfiguration: Equatable, Sendable {
    public let feedURL: URL
    public let publicEDKey: String
    public init(feed: String?, publicEDKey: String?) throws {
        guard let feed, let publicEDKey, !feed.isEmpty, !publicEDKey.isEmpty else { throw UpdateConfigurationError.incomplete }
        guard let url = URL(string: feed), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.port == nil || parts.port == 443,
              !feed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              !["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) else { throw UpdateConfigurationError.invalidFeed }
        guard let key = Data(base64Encoded: publicEDKey), key.count == 32,
              key.base64EncodedString() == publicEDKey, key.contains(where: { $0 != 0 }) else { throw UpdateConfigurationError.invalidKey }
        self.feedURL = url; self.publicEDKey = publicEDKey
    }
}

public enum UpdateInstallAdmission: Equatable, Sendable {
    case ready, busy, publisherUnconfigured
    public static func evaluate(configured: Bool, desktopActive: Bool, transferActive: Bool, hostActive: Bool, setupActive: Bool) -> Self {
        guard configured else { return .publisherUnconfigured }
        return desktopActive || transferActive || hostActive || setupActive ? .busy : .ready
    }
}
