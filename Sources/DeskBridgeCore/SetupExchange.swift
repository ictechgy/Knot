// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Public setup data only. Import is a preview, never permission to connect or trust a key.
public enum SetupExchange {
    public struct MacRequest: Codable, Sendable {
        public let kind: String
        public let version: Int
        public let requestID: String
        public let clientPublicKey: String
        public let allowedClientAddresses: [String]
    }
    public struct WindowsReply: Codable, Sendable {
        public let kind: String
        public let version: Int
        public let requestID: String
        public let clientPublicKey: String
        public let address: String
        public let port: UInt16
        public let username: String
        public let serverPublicKey: String
    }
    public struct Preview: Sendable {
        public let reply: WindowsReply
        public let fingerprint: String
    }
    public struct AddressSuggestions: Sendable, Equatable {
        public let addresses: [String]
        public let omittedCount: Int
    }
    /// Suggestions fit the export contract; manual link-local addresses remain supported.
    public static func suggestAddresses(_ candidates: [String]) -> AddressSuggestions {
        let eligible = Set(candidates.compactMap { try? EndpointPolicy.validatedAddress($0) }
            .filter { !$0.hasPrefix("169.254.") })
        let selected = LocalDiscoveryPolicy.selectedAddresses(Array(eligible))
        return AddressSuggestions(addresses: selected, omittedCount: eligible.count - selected.count)
    }
    public enum Failure: Error, LocalizedError {
        case invalid
        case wrongClient
        case addressCount
        case duplicateAddress
        case invalidClientKey
        public var errorDescription: String? {
            switch self {
            case .invalid: "Knot 설정 파일의 버전·주소·공개 키를 확인하세요."
            case .wrongClient: "현재 선택한 Mac 키로 만든 설정 파일이 아닙니다. 해당 Mac 키를 선택하세요."
            case .addressCount: "Windows에서 허용할 Mac 주소를 1개 이상, 8개 이하로 선택하세요."
            case .duplicateAddress: "Windows에서 허용할 Mac 주소가 중복되었습니다. 같은 주소는 한 번만 입력하세요."
            case .invalidClientKey: "Mac 설정 파일에는 Ed25519 공개 키가 필요합니다. Mac 전용 키를 새로 만들거나 Ed25519 키를 선택하세요."
            }
        }
    }
    public static func canonicalKey(_ key: String) throws -> String {
        do {
            return try SFTPConnectionConfiguration(host: "192.168.1.1", username: "deskbridge-transfer",
                identityFile: URL(fileURLWithPath: "/synthetic-not-opened/key"),
                pinnedHostPublicKey: key).pinnedHostPublicKey
        } catch { throw Failure.invalidClientKey }
    }
    public static func request(clientPublicKey: String, addresses: [String]) throws -> MacRequest {
        guard (1...8).contains(addresses.count) else { throw Failure.addressCount }
        let normalized = try addresses.map { try EndpointPolicy.validatedAddress($0) }
        guard Set(normalized).count == normalized.count else { throw Failure.duplicateAddress }
        return MacRequest(kind: "deskbridge.mac-setup", version: 1, requestID: UUID().uuidString.lowercased(),
                          clientPublicKey: try canonicalKey(clientPublicKey), allowedClientAddresses: normalized)
    }
    public static func encode(_ request: MacRequest) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(request)
    }
    public static func preview(_ data: Data, clientPublicKey: String) throws -> Preview {
        let fields: Set<String> = ["kind", "version", "requestID", "clientPublicKey", "address", "port", "username", "serverPublicKey"]
        guard data.count <= 16_384,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == fields else { throw Failure.invalid }
        let reply = try JSONDecoder().decode(WindowsReply.self, from: data)
        guard reply.kind == "deskbridge.windows-connection", reply.version == 1,
              UUID(uuidString: reply.requestID) != nil, reply.port == 22,
              reply.username == "deskbridge-transfer",
              try EndpointPolicy.validatedAddress(reply.address) == reply.address else { throw Failure.invalid }
        guard try canonicalKey(reply.clientPublicKey) == canonicalKey(clientPublicKey) else { throw Failure.wrongClient }
        let config = try SFTPConnectionConfiguration(host: reply.address, port: reply.port, username: reply.username,
            identityFile: URL(fileURLWithPath: "/synthetic-not-opened/key"), pinnedHostPublicKey: reply.serverPublicKey)
        return Preview(reply: reply, fingerprint: config.hostKeyFingerprint)
    }
}
