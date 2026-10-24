// SPDX-License-Identifier: GPL-3.0-only
import DeskBridgeCore
import Foundation
import GlimmerEngine

@MainActor func runLinuxContextChecks(temporary: URL) async throws -> Int {
    var count = 0
    func expect(_ condition: Bool, _ message: String) throws { guard condition else { throw ModelCheckFailure(message: message) }; count += 1 }
    let windowsSuite = "org.deskbridge.synthetic." + UUID().uuidString
    let linuxSuite = "org.deskbridge.synthetic." + UUID().uuidString
    defer {
        UserDefaults(suiteName: windowsSuite)?.removePersistentDomain(forName: windowsSuite)
        UserDefaults(suiteName: linuxSuite)?.removePersistentDomain(forName: linuxSuite)
    }
    var release: CheckedContinuation<Void, Never>?
    let controller = DesktopStreamController(stopSession: { _ in await withCheckedContinuation { release = $0 } })
    let pin = SavedHost(address: "192.168.50.20", uniqueID: "synthetic", name: "Synthetic Windows",
                        certificatePEM: "SYNTHETIC NOT A CERTIFICATE", httpPort: 47989, httpsPort: 47984)
    var saved = SavedSettings(); saved.address = pin.address; saved.host = pin
    try SettingsStore(directory: temporary.appendingPathComponent("linux-context-windows")).save(saved)
    let windows = DesktopModel(storageDirectory: temporary.appendingPathComponent("linux-context-windows"), identitySuite: windowsSuite, streamController: controller)
    let linux = DesktopModel(storageDirectory: temporary.appendingPathComponent("linux-context-linux"), identitySuite: linuxSuite, platform: .linux)
    windows.peerDesktop = linux; linux.peerDesktop = windows
    let files = FilesModel(desktop: linux)
    let windowsFiles = FilesModel(desktop: windows)
    var keyBytes = SFTPBinaryWriter(); keyBytes.string("ssh-ed25519"); keyBytes.bytes(Data(repeating: 7, count: 32))
    let key = "ssh-ed25519 " + keyBytes.data.base64EncodedString()
    let reply = try JSONSerialization.data(withJSONObject: ["kind": "deskbridge.windows-connection", "version": 1,
        "requestID": UUID().uuidString, "clientPublicKey": key, "address": "192.168.50.21", "port": 22,
        "username": "deskbridge-transfer", "serverPublicKey": key])
    let setupPreview = try SetupExchange.preview(reply, clientPublicKey: key)
    try expect(windows.canForgetHost, "idle saved pin can be explicitly forgotten")
    try expect(windows.platform == .windows && !linux.supportsFiles && !files.canExchangeSetup, "immutable role capabilities")
    let old = try ConnectionInvitation(name: "Old Windows", addresses: ["192.168.50.20"])
    let invitation = try ConnectionInvitation(name: "Linux", addresses: old.addresses, platform: .linux)
    try windows.reviewInvitation(old)
    for pair in [(windows, invitation), (linux, old)] {
        var refused = false
        do { try pair.0.reviewInvitation(pair.1) } catch { refused = true }
        try expect(refused, "wrong role/legacy Linux invitation rejected")
    }
    try linux.reviewInvitation(invitation)
    try expect(linux.pendingInvitation == invitation && linux.address.isEmpty && !linux.paired, "QR is review only")
    try expect(InvitationRouting.review(invitation.url.absoluteString, windows: windows, linux: linux) == .linuxDesktop, "Linux success stays on Linux page")
    try expect(InvitationRouting.review(old.url.absoluteString, windows: windows, linux: linux) == .desktop, "Windows link selects Windows page")
    var touched = false
    files.perform { touched = true }
    files.connect(); files.generateKey()
    try expect(!touched && !files.busy && !files.connected && files.identityPath.isEmpty, "Linux file APIs refuse before IO or transport")
    var refused = false
    do { try linux.saveFileSettings(username: "synthetic", port: 22, hostKey: "synthetic", identityPath: "/not-read") } catch { refused = true }
    try expect(refused, "Linux settings cannot gain file credentials")
    refused = false
    do { try files.applySelectedIdentity(URL(fileURLWithPath: "/not-read")) } catch { refused = true }
    try expect(refused, "Linux direct key-selection API blocked")
    // Equivalent to windowShouldClose's direct controller disconnect, bypassing model.busy.
    let teardown = Task { await controller.disconnect() }
    for _ in 0..<100 where release == nil { await Task.yield() }
    try expect(release != nil && controller.isEngaged && !windows.streaming && !windows.busy, "teardown remains engaged after disconnected publication")
    try expect(!windowsFiles.canExchangeSetup, "setup import must wait for full same-role controller teardown")
    refused = false
    do { try windowsFiles.applyWindowsConnection(setupPreview) } catch is AppFailure { refused = true }
    try expect(refused && windows.address == pin.address && windows.settings.address == pin.address && windows.settings.sshHostPublicKey.isEmpty,
               "setup import changed the endpoint or file pin while controller teardown was pending")
    refused = false
    do { try windows.saveFileSettings(username: "deskbridge-transfer", port: 22, hostKey: key, identityPath: "/synthetic-not-opened/key", address: "192.168.50.21") }
    catch is AppFailure { refused = true }
    try expect(refused && windows.settings.address == pin.address && windows.address == pin.address,
               "direct file-settings publication bypassed the model endpoint guard during teardown")
    try expect(linux.peerEngaged && !linux.canChoosePC && !linux.canVerifyCurrentPC, "other role waits through full teardown")
    windows.invitationError = nil; linux.invitationError = nil
    try expect(InvitationRouting.review(invitation.url.absoluteString, windows: windows, linux: linux) == .linuxDesktop && linux.invitationError != nil && windows.invitationError == nil, "Linux rejection stays on Linux model and page")
    try expect(!windows.canForgetHost, "certificate cannot be removed during same-role teardown")
    windows.forgetHost()
    windows.start(HostApp(id: 42, name: "Desktop", hdrCapable: false, hidden: false))
    try expect(windows.settings.host?.certificatePEM == pin.certificatePEM && windows.settings.host?.uniqueID == pin.uniqueID, "forget/open during teardown preserve pin")
    linux.perform { touched = true }
    await Task.yield()
    try expect(!touched && !linux.busy, "model operation cannot overlap peer teardown")
    release?.resume(); await teardown.value
    try expect(!controller.isEngaged && !linux.peerEngaged && linux.canVerifyCurrentPC, "peer released only after awaited teardown")
    try expect(windows.canForgetHost, "explicit forget available after complete teardown")
    try expect(windowsFiles.canExchangeSetup, "setup import becomes available after complete teardown")
    linux.perform { touched = true }
    for _ in 0..<100 where linux.busy { await Task.yield() }
    try expect(touched && !linux.busy, "other context usable after complete teardown")
    try expect(windows.settings.host?.certificatePEM == pin.certificatePEM && windows.settings.host?.uniqueID == pin.uniqueID && windows.settings.sshIdentityPath.isEmpty, "Linux actions do not mutate Windows state")
    return count
}
