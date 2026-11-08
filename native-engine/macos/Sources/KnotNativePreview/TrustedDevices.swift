import Foundation
import Security
import LocalAuthentication
import CryptoKit
import Network
import KnotNativeCore

struct SavedNativeDevice: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let address: String
    let certificateSHA256: String
    fileprivate let secret: Data
    /// A fresh authenticated number may select another private route to this
    /// exact pinned host. This copy changes session routing, never credentials.
    func atAuthenticatedEndpoint(_ invitation: Invitation) throws -> SavedNativeDevice {
        guard invitation.certificateSHA256 == certificateSHA256,
              Invitation.isPrivateIPv4(invitation.address) else { throw NativeFailure.trust }
        return try SavedNativeDevice(id: id, name: name, address: invitation.address,
            certificateSHA256: certificateSHA256, secret: secret).validated()
    }
    func hasSameCredential(as other: SavedNativeDevice) -> Bool {
        id == other.id && certificateSHA256 == other.certificateSHA256 && secret == other.secret
    }
    func validated() throws -> SavedNativeDevice {
        guard try Invitation.base64URL(id).count == 32, Invitation.validViewerLabel(name),
              Invitation.isPrivateIPv4(address), certificateSHA256.count == 64,
              certificateSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), secret.count == 32 else { throw NativeFailure.malformed }
        return self
    }
}

/// No reads occur at construction or in synthetic view fixtures. Access is
/// restricted to this exact application-owned Keychain service/account.
enum NativeDeviceKeychain {
    private static let service = "io.knot.native-preview.trusted-devices.v1"
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service, kSecAttrAccount as String: "devices",
        kSecUseDataProtectionKeychain as String: true] }
    static func load() throws -> [SavedNativeDevice] {
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let bytes = result as? Data, bytes.count <= 32768 else { throw NativeFailure.trust }
        let devices = try JSONDecoder().decode([SavedNativeDevice].self, from: bytes)
        guard devices.count <= 16, Set(devices.map(\.id)).count == devices.count else { throw NativeFailure.malformed }
        return try devices.map { try $0.validated() }
    }
    static func save(_ devices: [SavedNativeDevice]) throws {
        guard devices.count <= 16, Set(devices.map(\.id)).count == devices.count else { throw NativeFailure.oversized }
        _ = try devices.map { try $0.validated() }
        let bytes = try JSONEncoder().encode(devices)
        guard bytes.count <= 32768 else { throw NativeFailure.oversized }
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        if update == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = bytes
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw NativeFailure.trust }
        } else if update != errSecSuccess { throw NativeFailure.trust }
    }
    static func remove(_ id: String) throws { try save(load().filter { $0.id != id }) }
}

protocol NativeTrustedConnecting: AnyObject, Sendable {
    func connect(revoke: Bool) async throws -> Invitation?
    func close()
}
extension NativeTrustedConnecting {
    func connect() async throws -> Invitation? { try await connect(revoke: false) }
}

final class NativeTrustedClient: NativeTrustedConnecting, @unchecked Sendable {
    private let channel: TLSChannel
    private let device: SavedNativeDevice
    private let name: String
    init(device: SavedNativeDevice, viewerName: String) throws {
        self.device = try device.validated()
        guard Invitation.validViewerLabel(viewerName) else { throw NativeFailure.malformed }
        name = viewerName
        channel = TLSChannel(endpoint: .hostPort(host: NWEndpoint.Host(device.address), port: 48635), pin: device.certificateSHA256)
    }
    private static func random() throws -> Data {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw NativeFailure.trust }; return bytes
    }
    static func newDevice(invitation: Invitation, name: String) throws -> SavedNativeDevice {
        try SavedNativeDevice(id: Invitation.encodeBase64URL(random()), name: name,
            address: invitation.address, certificateSHA256: invitation.certificateSHA256, secret: random()).validated()
    }
    private func send(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= 4096 else { throw NativeFailure.oversized }
        try await channel.send(Packet(kind: .hello, payload: data))
    }
    private func receive(keys: Set<String>) async throws -> [String: JSONValue] {
        let header = try await channel.readExactly(5)
        let length = Int(header.readBE(UInt32.self, at: 1))
        guard let kind = header.first, (1...4096).contains(length), kind == 1 || kind == 0x7f,
              kind != 0x7f || length <= 128 else { throw NativeFailure.malformed }
        return try Self.response(kind: kind, payload: await channel.readExactly(length), keys: keys)
    }
    static func response(kind: UInt8, payload: Data, keys: Set<String>) throws -> [String: JSONValue] {
        if kind == 0x7f {
            let response = try StrictJSON.object(payload, keys: ["code"], limit: 128)
            switch try response.string("code") {
            case "rejected": throw NativeFailure.trust
            case "busy": throw NativeFailure.transport
            default: throw NativeFailure.malformed
            }
        }
        guard kind == 1 else { throw NativeFailure.malformed }
        return try StrictJSON.object(payload, keys: keys, limit: 4096)
    }
    func register(invitation: Invitation) async throws {
        try await withTaskCancellationHandler {
            defer { channel.close() }
            try await channel.start()
            try await send(["op": "register", "id": device.id, "name": name, "value": invitation.token,
                            "key": Invitation.encodeBase64URL(device.secret)])
            guard try await receive(keys: ["ok"]).boolean("ok") else { throw NativeFailure.trust }
        } onCancel: { self.close() }
    }
    func connect(revoke: Bool = false) async throws -> Invitation? {
        try await withTaskCancellationHandler {
            defer { channel.close() }
            try await channel.start()
            try await send(["op": revoke ? "revoke" : "connect", "id": device.id, "name": name, "value": "", "key": ""])
            let nonce = try await receive(keys: ["nonce"]).string("nonce")
            guard try Invitation.base64URL(nonce).count == 32 else { throw NativeFailure.malformed }
            let transcript = Data(("KnotNativeTrusted:v1\n" + (revoke ? "revoke" : "connect") + "\n" + device.id + "\n" + nonce + "\n" + name + "\n" + device.certificateSHA256).utf8)
            let proof = Self.proof(key: device.secret, transcript: transcript)
            try await send(["proof": Invitation.encodeBase64URL(proof)])
            if revoke {
                guard try await receive(keys: ["ok"]).boolean("ok") else { throw NativeFailure.trust }; return nil
            }
            let value = try await receive(keys: ["invitation"]).string("invitation")
            let invitation = try Invitation(value)
            guard invitation.address == device.address, invitation.certificateSHA256 == device.certificateSHA256 else { throw NativeFailure.trust }
            return invitation
        } onCancel: { self.close() }
    }
    static func proof(key: Data, transcript: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: transcript, using: SymmetricKey(data: key)))
    }
    func close() { channel.close() }
}
