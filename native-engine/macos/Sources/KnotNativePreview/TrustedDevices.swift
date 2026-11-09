import Foundation
import Security
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

/// Contains only non-secret error metadata suitable for diagnostics.
struct NativeDeviceKeychainFailure: Error, Equatable, Sendable {
    enum Operation: String, Sendable {
        case read, update, add, prepareReadback, interactionState, interactionPolicy, restoreInteractionPolicy
    }
    let operation: Operation
    let status: OSStatus
}

/// The seam never touches the OS until a store operation is explicitly called.
protocol NativeDeviceKeychainAccess {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?)
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ attributes: [String: Any]) -> OSStatus
    func interactionAllowed() -> (OSStatus, Bool)
    func setInteractionAllowed(_ allowed: Bool) -> OSStatus
}

private struct SystemNativeDeviceKeychainAccess: NativeDeviceKeychainAccess {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        var result: CFTypeRef?
        return (SecItemCopyMatching(query as CFDictionary, &result), result)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    // LAContext.interactionNotAllowed does not suppress file-based Keychain ACL
    // prompts. Use the legacy process-local policy for a serialized sync scope.
    func interactionAllowed() -> (OSStatus, Bool) {
        var allowed: DarwinBoolean = false
        let status = SecKeychainGetUserInteractionAllowed(&allowed)
        return (status, allowed.boolValue)
    }
    func setInteractionAllowed(_ allowed: Bool) -> OSStatus {
        SecKeychainSetUserInteractionAllowed(allowed)
    }
}

struct NativeDeviceKeychainStore {
    // Ad-hoc previews cannot use entitlement-gated Data Protection storage.
    // Separate the namespace; never inspect/migrate old credentials implicitly.
    static let service = "io.knot.native-preview.trusted-devices.file.v2"
    private static let accessLock = NSLock()
    private let access: any NativeDeviceKeychainAccess
    init(access: any NativeDeviceKeychainAccess) { self.access = access }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service, kSecAttrAccount as String: "devices",
         kSecUseDataProtectionKeychain as String: false]
    }
    private func scopedAccess<T>(allowUserInteraction: Bool, _ action: () throws -> T) throws -> T {
        if allowUserInteraction {
            Self.accessLock.lock()
        } else if !Self.accessLock.try() {
            // A foreground authorization dialog may own the process policy.
            // Background/main-actor callers must fail promptly rather than wait.
            throw NativeDeviceKeychainFailure(operation: .interactionPolicy, status: errSecInteractionNotAllowed)
        }
        defer { Self.accessLock.unlock() }
        let (status, previous) = access.interactionAllowed()
        guard status == errSecSuccess else {
            throw NativeDeviceKeychainFailure(operation: .interactionState, status: status)
        }
        let changed = access.setInteractionAllowed(allowUserInteraction)
        guard changed == errSecSuccess else {
            let restored = access.setInteractionAllowed(previous)
            guard restored == errSecSuccess else {
                throw NativeDeviceKeychainFailure(operation: .restoreInteractionPolicy, status: restored)
            }
            throw NativeDeviceKeychainFailure(operation: .interactionPolicy, status: changed)
        }
        let result = Result(catching: action)
        let restored = access.setInteractionAllowed(previous)
        guard restored == errSecSuccess else {
            throw NativeDeviceKeychainFailure(operation: .restoreInteractionPolicy, status: restored)
        }
        return try result.get()
    }
    private func readStoredDevices() throws -> [SavedNativeDevice]? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = access.copyMatching(request)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw NativeDeviceKeychainFailure(operation: .read, status: status)
        }
        guard let bytes = result as? Data, bytes.count <= 32768 else { throw NativeFailure.malformed }
        let devices = try JSONDecoder().decode([SavedNativeDevice].self, from: bytes)
        guard devices.count <= 16, Set(devices.map(\.id)).count == devices.count else { throw NativeFailure.malformed }
        return try devices.map { try $0.validated() }
    }
    func load(allowUserInteraction: Bool = false) throws -> [SavedNativeDevice] {
        try scopedAccess(allowUserInteraction: allowUserInteraction) { try readStoredDevices() ?? [] }
    }
    /// Verify existing data without rewriting it. Only a missing store creates
    /// a new empty item; preparation cannot prove a future update will succeed.
    func prepare() throws {
        try scopedAccess(allowUserInteraction: false) {
            guard try readStoredDevices() == nil else { return }
            var add = query
            add[kSecValueData as String] = try JSONEncoder().encode([SavedNativeDevice]())
            let added = access.add(add)
            guard added == errSecSuccess else {
                throw NativeDeviceKeychainFailure(operation: .add, status: added)
            }
            guard try readStoredDevices() == [] else {
                throw NativeDeviceKeychainFailure(operation: .prepareReadback, status: errSecDecode)
            }
        }
    }
    func save(_ devices: [SavedNativeDevice], allowUserInteraction: Bool = false) throws {
        guard devices.count <= 16, Set(devices.map(\.id)).count == devices.count else { throw NativeFailure.oversized }
        _ = try devices.map { try $0.validated() }
        let bytes = try JSONEncoder().encode(devices)
        guard bytes.count <= 32768 else { throw NativeFailure.oversized }
        try scopedAccess(allowUserInteraction: allowUserInteraction) {
            // The file-based API can update an item even when its read ACL would
            // reject this binary. Require authorized, valid existing data first;
            // a changed ad-hoc signature must never overwrite an unreadable item.
            if try readStoredDevices() == nil {
                var add = query; add[kSecValueData as String] = bytes
                // Omit custom ACL, access group, sync and DPK-only accessibility.
                // The OS assigns the creating application's default ACL.
                let added = access.add(add)
                guard added == errSecSuccess else {
                    throw NativeDeviceKeychainFailure(operation: .add, status: added)
                }
            } else {
                let updated = access.update(query, attributes: [kSecValueData as String: bytes])
                guard updated == errSecSuccess else {
                    throw NativeDeviceKeychainFailure(operation: .update, status: updated)
                }
            }
        }
    }
}

/// No reads occur at construction or in synthetic view fixtures. Foreground
/// reauthorization is opt-in; automatic reconnect never opens a Keychain dialog.
/// An updated ad-hoc binary may require the user to authorize the new signature.
enum NativeDeviceKeychain {
    private static let authorizationQueue = DispatchQueue(label: "org.knot.native-preview.keychain-authorization")
    private static var store: NativeDeviceKeychainStore { NativeDeviceKeychainStore(access: SystemNativeDeviceKeychainAccess()) }
    static func load(allowUserInteraction: Bool = false) throws -> [SavedNativeDevice] {
        try store.load(allowUserInteraction: allowUserInteraction)
    }
    static func prepare() throws { try store.prepare() }
    /// Invoke only for an explicit foreground user action. The entire blocking
    /// policy/read/restore scope runs off the main actor so the app stays usable
    /// while macOS asks the user to authorize an updated app signature.
    static func authorizeLoad() async throws -> [SavedNativeDevice] {
        try await authorizeLoad(using: { try load(allowUserInteraction: true) })
    }
    static func authorizeLoad(using operation: @escaping @Sendable () throws -> [SavedNativeDevice]) async throws -> [SavedNativeDevice] {
        try await withCheckedThrowingContinuation { continuation in
            authorizationQueue.async {
                continuation.resume(with: Result(catching: operation))
            }
        }
    }
    static func save(_ devices: [SavedNativeDevice], allowUserInteraction: Bool = false) throws {
        try store.save(devices, allowUserInteraction: allowUserInteraction)
    }
    static func remove(_ id: String, allowUserInteraction: Bool = false) throws {
        try save(load(allowUserInteraction: allowUserInteraction).filter { $0.id != id },
                 allowUserInteraction: allowUserInteraction)
    }
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
