// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import DeskBridgeCore
import Foundation
import GlimmerEngine

/// Actual Quit and model admissions; all transports, host processes and storage are inert.
@MainActor
func runTerminationAdmissionChecks(temporary: URL) async throws -> Int {
    var count = 0, networkCalls = 0, admittedBodies = 0, hostStarts = 0, hostDownloads = 0, hostReads = 0
    func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ModelCheckFailure(message: message) }; count += 1
    }
    func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw ModelCheckFailure(message: "synthetic Quit admission did not settle")
    }
    let app = HostApp(id: 42, name: "Desktop", hdrCapable: false, hidden: false)
    var models: [DesktopModel] = [], suites: [String] = []
    defer {
        AppLifecycle.desktop = nil; AppLifecycle.linuxDesktop = nil; AppLifecycle.files = nil; AppLifecycle.macHost = nil
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    }
    for platform: HostPlatform in [.windows, .linux] {
        let directory = temporary.appendingPathComponent("quit-admission-" + platform.rawValue)
        let suite = "org.deskbridge.synthetic." + UUID().uuidString; suites.append(suite)
        var info = ServerInfo(address: "192.168.1.30", uniqueId: "synthetic-host", serverName: "Synthetic")
        info.serverCertPEM = "SYNTHETIC NOT A CERTIFICATE"; info.pairStatus = .paired
        var settings = SavedSettings(); settings.address = info.address
        settings.host = SavedHost(address: info.address, uniqueID: info.uniqueId, name: info.serverName,
            certificatePEM: info.serverCertPEM!, httpPort: 47989, httpsPort: 47984)
        try SettingsStore(directory: directory).save(settings)
        let result = info
        let operations = DesktopOperations(fetchServerInfo: { _, _ in networkCalls += 1; return result },
            appList: { _ in networkCalls += 1; return [app] }, openStream: { _, _, _, _, _ in networkCalls += 1 })
        let model = DesktopModel(storageDirectory: directory, identitySuite: suite, platform: platform, operations: operations)
        model.connect(); try await waitFor { !model.busy }
        try expect(model.paired && model.apps.count == 1, "synthetic model setup did not reach verified state")
        models.append(model)
    }
    let windows = models[0], linux = models[1]
    windows.peerDesktop = linux; linux.peerDesktop = windows
    let files = FilesModel(desktop: windows)
    let address = try MacHostAddress(interface: "synthetic", address: "192.168.1.20")
    var releaseDownload: CheckedContinuation<Void, Never>?
    var downloadCancellationObserved = false
    let host = MacHostModel(operations: .init(installed: { hostReads += 1; return true },
        addresses: { [address] }, start: { _, _, _ in hostStarts += 1; return QuitAdmissionChild() },
        download: { _ in
            hostDownloads += 1; await withCheckedContinuation { releaseDownload = $0 }
            downloadCancellationObserved = Task.isCancelled
        }),
        activationCenter: NotificationCenter())
    host.refresh(); host.acknowledged = true
    AppLifecycle.desktop = windows; AppLifecycle.linuxDesktop = linux; AppLifecycle.files = files; AppLifecycle.macHost = host
    let lifecycle = AppLifecycle()
    let destination = temporary.appendingPathComponent("inert-not-created.dmg")
    host.download(to: destination)
    try await waitFor { releaseDownload != nil }
    let originalSettings = try Data(contentsOf: windows.store.directory.appendingPathComponent("settings.json"))
    var replies: [Bool] = []
    let reply = lifecycle.requestTermination(timeout: .milliseconds(200), poll: .milliseconds(1)) { replies.append($0) }
    try expect(reply == .terminateLater && lifecycle.preparingToTerminate, "actual Quit did not enter its protected drain")
    try expect(models.allSatisfy { $0.terminationAdmissionPaused } && files.terminationAdmissionPaused && host.terminationAdmissionPaused,
               "Quit did not synchronously pause every owner's admission")
    let before = networkCalls
    for model in models {
        model.connect(); model.pair(); model.start(app); model.perform { admittedBodies += 1 }
        model.forgetHost()
        var refusedTarget = false
        do { try model.selectCandidateAddress("192.168.1.31") } catch { refusedTarget = true }
        try expect(refusedTarget && !model.busy && !model.canChoosePC && !model.canVerifyCurrentPC && !model.canForgetHost,
                   "draining Quit admitted a desktop/target/trust entry")
        model.disconnect(); try await waitFor { !model.busy }
        try expect(model.status.contains("연결을 끊었습니다"), "Quit admission blocked owned desktop disconnect")
        model.cancelOperation()
    }
    files.connect(); files.refresh(); files.parent(); files.perform { admittedBodies += 1 }
    files.generateKey()
    var refusedSetup = false
    do { try files.requireSetupExchangeSelection(identityPath: files.identityPath) } catch { refusedSetup = true }
    var refusedIdentity = false
    do { try files.applySelectedIdentity(temporary.appendingPathComponent("not-opened-key")) } catch { refusedIdentity = true }
    try expect(refusedIdentity && refusedSetup && !files.busy && files.errorMessage == nil && files.enrollmentOperation == nil && files.enrollmentServer == nil,
               "draining Quit admitted file/setup/key work")
    files.connected = true
    files.disconnect(); try await waitFor { !files.busy }
    try expect(!files.connected && files.status.contains("연결을 끊었습니다"), "Quit admission blocked owned file disconnect")
    try expect(networkCalls == before && admittedBodies == 0 && hostStarts == 0 && hostDownloads == 1,
               "refused Quit-time work reached an injected transport or operation")
    try expect(host.downloading && host.downloadedURL == nil, "admission pause canceled the existing protected download")
    host.cancelDownload()
    try await waitFor { !lifecycle.preparingToTerminate }
    try expect(replies == [false] && models.allSatisfy { !$0.terminationAdmissionPaused } && !files.terminationAdmissionPaused && !host.terminationAdmissionPaused,
               "refused Quit did not restore all admission gates exactly once")
    await Task.yield()
    try expect(networkCalls == before && !windows.busy && !linux.busy && windows.pairingPIN == nil && linux.pairingPIN == nil,
               "restoring admission implicitly reconnected or paired")
    try expect(try Data(contentsOf: windows.store.directory.appendingPathComponent("settings.json")) == originalSettings,
               "refused Quit changed saved screen or file trust")
    windows.connect(); try await waitFor { !windows.busy }
    files.perform { admittedBodies += 1 }; try await waitFor { !files.busy }
    try expect(networkCalls == before + 2 && admittedBodies == 1, "refused Quit left model admission permanently closed")
    releaseDownload?.resume(); releaseDownload = nil
    try await waitFor { !host.downloading }
    try expect(downloadCancellationObserved && host.downloadedURL == destination,
               "Quit blocked cancellation or discarded an already-committed download provider return")

    // Let an already-admitted transaction persist during a second, successful Quit.
    var releasePersistence: CheckedContinuation<Void, Never>?
    let persistedIdentity = temporary.appendingPathComponent("synthetic-saved-key-path").path
    files.perform {
        await withCheckedContinuation { releasePersistence = $0 }
        try windows.rememberFileIdentity(path: persistedIdentity)
    }
    try await waitFor { releasePersistence != nil }
    _ = lifecycle.requestTermination(timeout: .seconds(1), poll: .milliseconds(1)) { replies.append($0) }
    let reads = hostReads
    host.refresh(); host.start(); host.download(to: temporary.appendingPathComponent("refused-not-created.dmg"))
    try expect(hostStarts == 0 && hostDownloads == 1 && hostReads == reads && host.phase == .stopped,
               "Quit drain admitted a fresh sharing start, download or refresh")
    try expect(files.busy && files.terminationAdmissionPaused, "Quit canceled an already-admitted settings transaction")
    releasePersistence?.resume(); releasePersistence = nil
    try await waitFor { replies.count == 2 }
    try expect(replies == [false, true] && (try windows.store.load()).sshIdentityPath == persistedIdentity,
               "successful Quit replied before protected persistence completed")
    try expect(host.shuttingDown && models.allSatisfy { !$0.activityAllowed } && !files.activityAllowed,
               "successful Quit reopened admission before final shutdown")
    return count
}

@MainActor private final class QuitAdmissionChild: MacHostOwnedProcess {
    var running = true
    var onExit: (@MainActor () -> Void)?
    func stop() { running = false; onExit?() }
    func forceStop() { stop() }
}
