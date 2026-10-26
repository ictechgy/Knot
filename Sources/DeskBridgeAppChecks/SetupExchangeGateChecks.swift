// SPDX-License-Identifier: GPL-3.0-only
import DeskBridgeCore
import Foundation

/// Simulate modal re-entry using only the actual models' pure gate and snapshot validator.
@MainActor
func runSetupExchangeGateChecks(temporary: URL) throws -> Int {
    var count = 0
    func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ModelCheckFailure(message: message) }; count += 1
    }
    let directory = temporary.appendingPathComponent("setup-exchange-gates")
    let suite = "org.deskbridge.synthetic." + UUID().uuidString
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let desktop = DesktopModel(storageDirectory: directory, identitySuite: suite)
    let files = FilesModel(desktop: desktop)
    let identity = directory.appendingPathComponent("not-opened-private-key").path
    let addresses = "192.168.1.20, 100.80.10.20"
    let cases: [(fileBusy: Bool, connected: Bool, desktopBusy: Bool, streaming: Bool,
                 changedIdentity: Bool, changedAddresses: Bool, available: Bool, validSelection: Bool)] = [
        (false, false, false, false, false, false, true, true),
        (true, false, false, false, false, false, false, false),
        (false, true, false, false, false, false, false, false),
        (false, false, true, false, false, false, false, false),
        (false, false, false, true, false, false, false, false),
        (false, false, false, false, true, false, true, false),
        (false, false, false, false, false, true, true, false),
        (true, true, true, true, true, true, false, false),
    ]
    for state in cases {
        files.busy = state.fileBusy; files.connected = state.connected
        desktop.busy = state.desktopBusy; desktop.streaming = state.streaming
        files.identityPath = state.changedIdentity ? identity + "-replacement" : identity
        files.setupAddresses = state.changedAddresses ? "10.0.0.2" : addresses
        try expect(files.canExchangeSetup == state.available, "setup exchange gate missed a screen or file activity state")
        var accepted = false
        do { try files.requireSetupExchangeSelection(identityPath: identity, setupAddresses: addresses); accepted = true }
        catch is AppFailure {}
        try expect(accepted == state.validSelection, "post-panel exchange accepted stale identity, addresses or activity")
        try expect(desktop.settings.sshIdentityPath.isEmpty && desktop.settings.address.isEmpty,
                   "pure setup exchange validation persisted or published unapproved settings")
    }
    // Drive the actual post-modal commit with fresh synthetic .pub fixtures.
    // No UI, listener, keychain or existing key is opened.
    files.busy = false; files.connected = false; desktop.busy = false; desktop.streaming = false
    files.identityPath = identity; files.setupAddresses = addresses
    let prefix: [UInt8] = [0,0,0,11,115,115,104,45,101,100,50,53,53,49,57,0,0,0,32]
    let clientKey = "ssh-ed25519 " + Data(prefix + Array(repeating: UInt8(1), count: 32)).base64EncodedString()
    let serverKey = "ssh-ed25519 " + Data(prefix + Array(repeating: UInt8(2), count: 32)).base64EncodedString()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try Data(clientKey.utf8).write(to: URL(fileURLWithPath: identity + ".pub"), options: .withoutOverwriting)
    desktop.address = "192.168.1.30"
    let reply: [String: Any] = ["kind": "deskbridge.windows-connection", "version": 1,
        "requestID": UUID().uuidString.lowercased(), "clientPublicKey": clientKey, "address": desktop.address,
        "port": 22, "username": "deskbridge-transfer", "serverPublicKey": serverKey]
    let preview = try SetupExchange.preview(JSONSerialization.data(withJSONObject: reply), clientPublicKey: clientKey)
    func stage() -> UUID {
        let epoch = UUID(); files.enrollmentGeneration = epoch; files.enrollmentConfirmation = epoch
        files.busy = true; files.identityPath = identity; files.setupAddresses = addresses
        return epoch
    }
    for mutation in 0..<5 {
        let epoch = stage()
        try expect(files.enrollmentActive && files.busy && !files.canExchangeSetup && !desktop.canChoosePC,
                   "modal enrollment did not block new activity and update admission")
        switch mutation {
        case 0: files.cancelEnrollment()
        case 1: files.enrollmentGeneration = UUID()
        case 2: files.identityPath = identity + "-changed"
        case 3: files.setupAddresses = "10.0.0.2"
        default: files.enrollmentConfirmation = nil
        }
        var refused = false
        do { try files.applyEnrollmentConfirmation(preview, epoch: epoch, identity: identity, addresses: addresses, publicKey: clientKey) }
        catch { refused = true }
        try expect(refused && files.pinnedHostKey.isEmpty && desktop.settings.sshHostPublicKey.isEmpty,
                   "late canceled/replaced enrollment silently adopted SSH trust")
        files.enrollmentConfirmation = nil; files.busy = false
    }
    // A cancellation during a modal leaves its physical modal gate active until
    // the modal returns; it cannot admit a second enrollment or updater install.
    let canceledModalEpoch = stage(); files.enrollmentModalActive = true
    files.cancelEnrollment()
    try expect(files.enrollmentActive && !files.activityAllowed && !files.canExchangeSetup,
               "canceling a still-visible modal admitted new setup/update activity")
    var canceledModalRefused = false
    do { try files.applyEnrollmentConfirmation(preview, epoch: canceledModalEpoch, identity: identity, addresses: addresses, publicKey: clientKey) }
    catch { canceledModalRefused = true }
    try expect(canceledModalRefused && files.pinnedHostKey.isEmpty, "canceled modal adopted SSH trust")
    files.enrollmentModalActive = false
    let approved = stage()
    desktop.setTerminationAdmissionPaused(true); files.setTerminationAdmissionPaused(true)
    try expect(!files.canExchangeSetup && !desktop.canChoosePC, "Quit drain admitted a new setup exchange")
    try files.applyEnrollmentConfirmation(preview, epoch: approved, identity: identity, addresses: addresses, publicKey: clientKey)
    try expect(files.pinnedHostKey == serverKey && desktop.settings.sshHostPublicKey == serverKey,
               "approved exact enrollment did not persist the public SSH pin")
    try expect(files.enrollmentActive, "owned synchronous commit cleared update gate before completion cleanup")
    files.enrollmentConfirmation = nil; files.busy = false
    desktop.setTerminationAdmissionPaused(false); files.setTerminationAdmissionPaused(false)
    return count
}
