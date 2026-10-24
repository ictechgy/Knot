// SPDX-License-Identifier: GPL-3.0-only
import DeskBridgeCore
import Foundation

/// Actual post-panel model entry point, without creating or opening a panel/key file.
@MainActor
func runFileIdentitySelectionChecks(temporary: URL) throws -> Int {
    var count = 0
    func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ModelCheckFailure(message: message) }; count += 1
    }
    for failStorage in [false, true] {
        let directory = temporary.appendingPathComponent(failStorage ? "identity-storage-failure" : "identity-selection")
        let store = SettingsStore(directory: directory)
        var original = SavedSettings(); original.address = "192.168.1.20"
        original.sshIdentityPath = directory.appendingPathComponent("original-not-opened-key").path
        original.sshHostPublicKey = "SYNTHETIC SSH PIN"
        original.host = SavedHost(address: original.address, uniqueID: "synthetic-PC", name: "Synthetic PC",
            certificatePEM: "SYNTHETIC SCREEN PIN", httpPort: 47989, httpsPort: 47984)
        try store.save(original)
        let suite = "org.deskbridge.synthetic." + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let desktop = DesktopModel(storageDirectory: directory, identitySuite: suite)
        let files = FilesModel(desktop: desktop)
        files.generatedPublicKey = "SYNTHETIC PREVIOUS PUBLIC KEY"
        let candidate = directory.appendingPathComponent("new-not-opened-private-key")
        if failStorage {
            try FileManager.default.removeItem(at: directory)
            let blocker = Data("synthetic settings blocker".utf8); try blocker.write(to: directory)
            var failed = false
            do { try files.applySelectedIdentity(candidate) } catch { failed = true }
            try expect(failed, "identity persistence failure must be surfaced")
            try expect(files.identityPath == original.sshIdentityPath &&
                       files.generatedPublicKey == "SYNTHETIC PREVIOUS PUBLIC KEY" &&
                       desktop.settings.sshIdentityPath == original.sshIdentityPath,
                       "failed identity save must not publish the new key or clear its public key")
            try expect(try Data(contentsOf: directory) == blocker, "failed identity save changed its filesystem blocker")
        } else {
            files.identityPath = ""
            let clearedDraft = files.keyReplacementSnapshot
            try expect(files.requiresKeyReplacementConfirmation && clearedDraft.savedPath == original.sshIdentityPath && clearedDraft.draftPath.isEmpty,
                       "clearing the draft must not bypass replacement confirmation for a saved identity")
            files.generateKey()
            try expect(!files.busy && files.errorMessage != nil && files.identityPath.isEmpty &&
                       desktop.settings.sshIdentityPath == original.sshIdentityPath,
                       "unconfirmed generation with a cleared draft must preserve the saved identity before key IO")
            files.identityPath = candidate.path
            files.errorMessage = nil
            files.generateKey(replacingIdentity: clearedDraft)
            try expect(!files.busy && files.errorMessage != nil && desktop.settings.sshIdentityPath == original.sshIdentityPath,
                       "confirmation for a previous draft must not authorize generation in a changed context")
            var staleDraftRefused = false
            do { try files.requireKeyReplacementSelection(clearedDraft) } catch is AppFailure { staleDraftRefused = true }
            try expect(staleDraftRefused, "post-generation selection guard must reject a changed draft")
            let savedSelection = files.keyReplacementSnapshot
            try desktop.rememberFileIdentity(path: directory.appendingPathComponent("changed-saved-not-opened-key").path)
            var staleSavedRefused = false
            do { try files.requireKeyReplacementSelection(savedSelection) } catch is AppFailure { staleSavedRefused = true }
            files.errorMessage = nil
            files.generateKey(replacingIdentity: savedSelection)
            try expect(staleSavedRefused && !files.busy && files.errorMessage != nil,
                       "saved identity changes must invalidate both confirmation and the persistence guard")
            try desktop.rememberFileIdentity(path: original.sshIdentityPath)
            files.identityPath = original.sshIdentityPath
            let settingsBefore = try Data(contentsOf: directory.appendingPathComponent("settings.json"))
            for state in 0..<2 {
                files.busy = state == 0; files.connected = state == 1
                var refused = false
                do { try files.applySelectedIdentity(candidate) }
                catch let error as AppFailure { refused = error.message.contains("파일 작업과 연결") }
                try expect(refused, "post-panel key selection must recheck busy and connected state")
                try expect(files.identityPath == original.sshIdentityPath &&
                           files.generatedPublicKey == "SYNTHETIC PREVIOUS PUBLIC KEY",
                           "blocked key selection changed the visible identity")
                try expect(try Data(contentsOf: directory.appendingPathComponent("settings.json")) == settingsBefore,
                           "blocked key selection changed persisted identity")
            }
            files.busy = false; files.connected = false
            for rejected in [directory.appendingPathComponent("fixture.pub"), directory.appendingPathComponent("fixture.PUB"),
                             URL(string: "https://synthetic.invalid/key")!] {
                var refused = false
                do { try files.applySelectedIdentity(rejected) } catch is AppFailure { refused = true }
                try expect(refused, "public keys and non-file URLs must not become the private identity")
                try expect(files.identityPath == original.sshIdentityPath &&
                           files.generatedPublicKey == "SYNTHETIC PREVIOUS PUBLIC KEY" &&
                           desktop.settings.sshIdentityPath == original.sshIdentityPath,
                           "rejected identity changed in-memory state")
                try expect(try Data(contentsOf: directory.appendingPathComponent("settings.json")) == settingsBefore,
                           "rejected identity changed persisted state")
            }
            files.errorMessage = "synthetic previous error"
            try files.applySelectedIdentity(candidate)
            try expect(files.identityPath == candidate.path && files.generatedPublicKey.isEmpty && files.errorMessage == nil,
                       "successful identity selection must publish the saved path and clear stale public-key UI")
            try expect(desktop.settings.sshIdentityPath == candidate.path && (try store.load()).sshIdentityPath == candidate.path,
                       "successful identity selection must persist before publishing")
            try expect(desktop.settings.host?.certificatePEM == original.host?.certificatePEM &&
                       desktop.settings.sshHostPublicKey == original.sshHostPublicKey,
                       "identity selection must retain independent screen and SSH trust")
            try expect(!FileManager.default.fileExists(atPath: candidate.path), "identity selection unexpectedly created or opened a key fixture")
        }
    }
    return count
}
