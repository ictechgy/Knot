import Foundation
import Security
import Testing
@testable import KnotNativeCore
@testable import KnotNativePreview

// This entire suite uses inert injected functions, never a live Keychain.
private final class SyntheticKeychainAccess: NativeDeviceKeychainAccess {
    var readStatus = errSecItemNotFound
    var value: CFTypeRef?
    var updateStatus = errSecItemNotFound
    var addStatus = errSecSuccess
    var interactionStatus = errSecSuccess
    var previousInteraction = true
    var policyStatuses: [OSStatus] = []
    var policies: [Bool] = []
    var copies: [[String: Any]] = []
    var updates: [([String: Any], [String: Any])] = []
    var additions: [[String: Any]] = []
    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        copies.append(query); return (readStatus, value)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        updates.append((query, attributes)); return updateStatus
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        additions.append(attributes); return addStatus
    }
    func interactionAllowed() -> (OSStatus, Bool) { (interactionStatus, previousInteraction) }
    func setInteractionAllowed(_ allowed: Bool) -> OSStatus {
        policies.append(allowed)
        return policyStatuses.isEmpty ? errSecSuccess : policyStatuses.removeFirst()
    }
}

struct NativeDeviceKeychainTests {
    private func device() throws -> SavedNativeDevice {
        let fields: [String: String] = ["id": Invitation.encodeBase64URL(Data(repeating: 1, count: 32)),
            "name": "Synthetic PC", "address": "192.168.50.20", "certificateSHA256": String(repeating: "a", count: 64),
            "secret": Data(repeating: 2, count: 32).base64EncodedString()]
        return try JSONDecoder().decode(SavedNativeDevice.self, from: JSONSerialization.data(withJSONObject: fields)).validated()
    }
    @Test func constructionIsInertAndOnlyNotFoundMeansEmpty() throws {
        let access = SyntheticKeychainAccess()
        let store = NativeDeviceKeychainStore(access: access)
        #expect(access.copies.isEmpty && access.policies.isEmpty)
        #expect(try store.load().isEmpty)
        #expect(access.policies == [false, true])
        access.readStatus = errSecInteractionNotAllowed
        #expect(throws: NativeDeviceKeychainFailure(operation: .read, status: errSecInteractionNotAllowed)) {
            try store.load()
        }
        #expect(access.policies == [false, true, false, true])
        #expect(access.updates.isEmpty && access.additions.isEmpty)
    }
    @Test func fileBasedQueryPreservesDefaultACLAndNamespace() throws {
        let access = SyntheticKeychainAccess()
        let store = NativeDeviceKeychainStore(access: access)
        try store.save([device()])
        #expect(access.policies == [false, true])
        #expect(access.updates.isEmpty && access.additions.count == 1)
        let query = try #require(access.copies.first)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == false)
        #expect(query[kSecAttrService as String] as? String == "io.knot.native-preview.trusted-devices.file.v2")
        #expect(query[kSecAttrAccount as String] as? String == "devices")
        let add = try #require(access.additions.first)
        let expectedKeys = Set([kSecClass, kSecAttrService, kSecAttrAccount, kSecUseDataProtectionKeychain, kSecValueData].map { $0 as String })
        #expect(Set(add.keys) == expectedKeys)
        #expect(try JSONDecoder().decode([SavedNativeDevice].self, from: #require(add[kSecValueData as String] as? Data)) == [device()])
    }
    @Test func updateFailureNeverCreatesReplacementOrErasesData() throws {
        let access = SyntheticKeychainAccess()
        let store = NativeDeviceKeychainStore(access: access)
        access.readStatus = errSecSuccess
        access.value = try JSONEncoder().encode([device()]) as CFData
        access.updateStatus = errSecAuthFailed
        #expect(throws: NativeDeviceKeychainFailure(operation: .update, status: errSecAuthFailed)) {
            try store.save([device()])
        }
        #expect(access.additions.isEmpty && access.policies == [false, true])
        access.readStatus = errSecItemNotFound; access.addStatus = errSecMissingEntitlement
        #expect(throws: NativeDeviceKeychainFailure(operation: .add, status: errSecMissingEntitlement)) {
            try store.save([device()])
        }
        #expect(access.policies == [false, true, false, true])
    }
    @Test func unreadableOrCorruptExistingItemCanNeverBeOverwritten() throws {
        let access = SyntheticKeychainAccess()
        let store = NativeDeviceKeychainStore(access: access)
        access.readStatus = errSecAuthFailed
        // Even if a real legacy update would succeed, we never attempt it.
        access.updateStatus = errSecSuccess
        #expect(throws: NativeDeviceKeychainFailure(operation: .read, status: errSecAuthFailed)) {
            try store.save([device()])
        }
        #expect(access.updates.isEmpty && access.additions.isEmpty)
        access.readStatus = errSecSuccess; access.value = Data("corrupt".utf8) as CFData
        #expect(throws: (any Error).self) { try store.save([device()]) }
        #expect(access.updates.isEmpty && access.additions.isEmpty)
    }
    @Test func readAuthorizedExistingItemUpdatesWithoutReplacement() throws {
        let access = SyntheticKeychainAccess()
        let store = NativeDeviceKeychainStore(access: access)
        access.readStatus = errSecSuccess; access.value = try JSONEncoder().encode([device()]) as CFData
        access.updateStatus = errSecSuccess
        try store.save([device()])
        #expect(access.copies.count == 1 && access.updates.count == 1 && access.additions.isEmpty)
        access.updateStatus = errSecItemNotFound
        #expect(throws: NativeDeviceKeychainFailure(operation: .update, status: errSecItemNotFound)) {
            try store.save([device()])
        }
        #expect(access.additions.isEmpty)
    }
    @Test func existingDataIsValidatedAndReadWithoutAnyWrite() throws {
        let access = SyntheticKeychainAccess()
        let store = NativeDeviceKeychainStore(access: access)
        access.readStatus = errSecSuccess
        access.value = try JSONEncoder().encode([device()]) as CFData
        #expect(try store.load() == [device()])
        #expect(access.copies[0][kSecReturnData as String] as? Bool == true)
        #expect(access.copies[0][kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
        access.value = Data(repeating: 0, count: 32769) as CFData
        #expect(throws: (any Error).self) { try store.load() }
        access.value = Data("[]invalid".utf8) as CFData
        #expect(throws: (any Error).self) { try store.load() }
        #expect(access.updates.isEmpty && access.additions.isEmpty)
    }
    @Test func authorizationIsExplicitAndRestoresOriginalDisabledPolicy() throws {
        let access = SyntheticKeychainAccess(); access.previousInteraction = false
        let store = NativeDeviceKeychainStore(access: access)
        #expect(try store.load(allowUserInteraction: true).isEmpty)
        #expect(access.policies == [true, false])
        try store.save([], allowUserInteraction: true)
        #expect(access.policies == [true, false, true, false])
    }
    @Test func policyFailuresFailClosedWithoutStoreAccess() throws {
        let access = SyntheticKeychainAccess()
        let store = NativeDeviceKeychainStore(access: access)
        access.interactionStatus = errSecNotAvailable
        #expect(throws: NativeDeviceKeychainFailure(operation: .interactionState, status: errSecNotAvailable)) {
            try store.load()
        }
        #expect(access.copies.isEmpty && access.policies.isEmpty)
        access.interactionStatus = errSecSuccess; access.policyStatuses = [errSecParam]
        #expect(throws: NativeDeviceKeychainFailure(operation: .interactionPolicy, status: errSecParam)) {
            try store.load()
        }
        #expect(access.copies.isEmpty && access.policies == [false, true])
        access.policyStatuses = [errSecSuccess, errSecNotAvailable]
        #expect(throws: NativeDeviceKeychainFailure(operation: .restoreInteractionPolicy, status: errSecNotAvailable)) {
            try store.load()
        }
        #expect(access.copies.count == 1)
    }
    @Test func invalidDeviceListCannotReachTheOS() throws {
        let access = SyntheticKeychainAccess()
        let store = NativeDeviceKeychainStore(access: access)
        let one = try device()
        #expect(throws: (any Error).self) { try store.save([one, one]) }
        #expect(access.policies.isEmpty && access.updates.isEmpty && access.additions.isEmpty)
    }
}
