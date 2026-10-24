// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CryptoKit
import Darwin
import DeskBridgeCore
import Foundation

@MainActor private final class SyntheticMacHostChild: MacHostOwnedProcess {
    var running = true
    var onExit: (@MainActor () -> Void)?
    var stops = 0; var forces = 0
    func stop() { stops += 1 }
    func forceStop() { forces += 1; finish() }
    func finish() { running = false; onExit?() }
}

@MainActor private final class SyntheticMacHostDownloadOwner {
    weak var model: MacHostModel?
}

@MainActor func runMacHostChecks(temporary: URL) async throws -> Int {
    var count = 0
    func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw ModelCheckFailure(message: message) }; count += 1
    }
    func settle(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 { if predicate() { return }; try await Task.sleep(for: .milliseconds(2)) }
        throw ModelCheckFailure(message: "synthetic Mac host operation did not settle")
    }
    let fixture = temporary.appendingPathComponent("mac-host", isDirectory: true)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    let directory = fixture.appendingPathComponent("private")
    let arguments = try MacHostPolicy.arguments(directory: directory, name: "Synthetic Mac")
    let options = Dictionary(uniqueKeysWithValues: arguments.dropFirst().map {
        let split = $0.split(separator: "=", maxSplits: 1); return (String(split[0]), String(split[1]))
    })
    try expect(options["lan_encryption_mode"] == "2" && options["wan_encryption_mode"] == "2", "host encryption not mandatory")
    try expect(options["upnp"] == "disabled" && options["origin_web_ui_allowed"] == "pc", "host discovery/web boundary changed")
    try expect(options["system_tray"] == "disabled" && options["controller"] == "disabled" && options["log_path"] == "/dev/null", "unrequested host capabilities enabled")
    try expect(["file_apps", "file_state", "credentials_file", "pkey", "cert"].allSatisfy { options[$0]?.hasPrefix(directory.path + "/") == true }, "host adopted default user state")
    for name in ["bad#comment", "[list]", "bad\nname"] {
        try expect((try? MacHostPolicy.arguments(directory: directory, name: name)) == nil, "upstream option parser injection accepted")
    }
    try expect((try? MacHostPolicy.arguments(directory: fixture.appendingPathComponent("bad=path"), name: "Synthetic")) == nil, "config path treated as an option")
    let addresses = try [MacHostAddress(interface: "en0", address: "192.168.1.20"), MacHostAddress(interface: "utun8", address: "100.80.10.20")]
    try expect(MacHostAddress.selected(addresses + addresses).count == 2, "address hints not deduplicated")
    try expect((try? MacHostAddress(interface: "en0", address: "8.8.8.8")) == nil, "public host invitation address accepted")
    try expect((try? MacHostAddress(interface: "en0", address: "169.254.1.2")) == nil, "linklocal host suggestion accepted")
    try MacHostStorage.prepare(directory: directory)
    let web = directory.appendingPathComponent("web-credentials.json")
    try expect((try? MacHostStorage.prepareWebCredentials(directory: directory, username: "deskbridge", password: "short")) == nil && !FileManager.default.fileExists(atPath: web.path), "blank/weak first-start credentials allowed")
    let vector = try SunshineWebCredentials.encode(username: "deskbridge", password: "Synthetic-password-42!", salt: "0123456789ABCDEF")
    let decoded = try JSONSerialization.jsonObject(with: vector) as! [String: String]
    try expect(decoded["password"] == "F55578F96AAE2127B01A4BB740A88BE284A34515B359E6960C1003F05B189FA9", "pinned Sunshine password hash byte order differs")
    try MacHostStorage.prepareWebCredentials(directory: directory, username: "deskbridge", password: "Synthetic-password-42!")
    let originalWeb = try Data(contentsOf: web)
    try SunshineWebCredentials.validate(originalWeb)
    try expect(!String(decoding: originalWeb, as: UTF8.self).contains("Synthetic-password-42!"), "persisted plain administrator password")
    try MacHostStorage.prepareWebCredentials(directory: directory, username: "other", password: "Changed-password-42!")
    try expect(try Data(contentsOf: web) == originalWeb, "start overwrote existing administrator")
    try Data("{}".utf8).write(to: web)
    try expect((try? MacHostStorage.prepareWebCredentials(directory: directory, username: "deskbridge", password: "Synthetic-password-42!")) == nil, "malformed credentials reopened bootstrap")
    try originalWeb.write(to: web)
    let apps = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("apps.json"))) as! [String: Any]
    let entries = apps["apps"] as! [[String: Any]]
    try expect(entries.count == 1 && entries[0]["name"] as? String == "Desktop" && entries[0]["cmd"] as? String == "", "Desktop entry executes commands")
    let syntheticState = Data("SYNTHETIC STATE NOT A KEY".utf8)
    let state = directory.appendingPathComponent("state.json")
    try syntheticState.write(to: state); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: state.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: state.path)
    try MacHostStorage.prepare(directory: directory)
    let stateMode = try FileManager.default.attributesOfItem(atPath: state.path)[.posixPermissions] as? Int
    try expect(stateMode == 0o600, "upstream-created state permissions were not tightened")
    try expect(try Data(contentsOf: state) == syntheticState, "host preparation replaced stored pairing state")
    let customConfig = Data("# Synthetic user preference\nencoder=software\n".utf8)
    let customApps = Data("{\"apps\":[{\"name\":\"Desktop\",\"cmd\":\"\"},{\"name\":\"Synthetic\",\"cmd\":\"\"}]}".utf8)
    let configURL = directory.appendingPathComponent("sunshine.conf")
    let appsURL = directory.appendingPathComponent("apps.json")
    try customConfig.write(to: configURL); try customApps.write(to: appsURL)
    try MacHostStorage.prepare(directory: directory)
    try expect(try Data(contentsOf: configURL) == customConfig, "host restart overwrote app-owned user preferences")
    try expect(try Data(contentsOf: appsURL) == customApps, "host restart overwrote app-owned applications")
    let outside = fixture.appendingPathComponent("untouched")
    try Data("SYNTHETIC UNTOUCHED".utf8).write(to: outside)
    try FileManager.default.removeItem(at: directory.appendingPathComponent("apps.json"))
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("apps.json"), withDestinationURL: outside)
    try expect((try? MacHostStorage.prepare(directory: directory)) == nil, "host config symlink accepted")
    try expect(try Data(contentsOf: outside) == Data("SYNTHETIC UNTOUCHED".utf8), "host followed config symlink")
    let permissive = fixture.appendingPathComponent("permissive")
    try FileManager.default.createDirectory(at: permissive, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    try expect((try? MacHostStorage.prepare(directory: permissive)) == nil, "host accepted other-user-readable storage")

    let child = SyntheticMacHostChild(); var starts = 0; var downloads = 0
    let model = MacHostModel(operations: .init(installed: { true }, addresses: { addresses }, start: { _, _, _ in starts += 1; return child }, download: { _ in downloads += 1 }))
    try expect(starts == 0 && model.phase == .stopped && model.addresses.isEmpty, "host auto-started or read live addresses on construction")
    model.refresh(); model.start(); try expect(starts == 0, "host started without user acknowledgement")
    model.acknowledged = true; model.start(); model.start()
    try await settle { model.phase == .running }
    try expect(starts == 1 && model.invitation != nil, "duplicate host start or missing running invitation")
    let runningStatus = model.status
    model.download(to: fixture.appendingPathComponent("running-not-created.dmg"))
    try expect(!model.canDownload && !model.downloading && downloads == 0 && model.status == runningStatus,
               "running host allowed a download to replace sharing guidance")
    let invitation = model.invitation!
    try expect(invitation.platform == .macos, "Mac host invitation lost its explicit OS role")
    try expect(try ConnectionInvitation(text: invitation.url.absoluteString) == invitation,
               "Mac host invitation lost its roundtrip")
    guard let png = MacHostQR.png(invitation) else { throw ModelCheckFailure(message: "synthetic host QR not generated") }
    try expect(try ConnectionQRReader.decode(data: png) == invitation, "host QR not decoded by actual QR reader")
    model.stop(); try expect(child.stops == 1 && model.phase == .stopping && model.invitation == nil, "stop did not revoke published invitation")
    model.download(to: fixture.appendingPathComponent("stopping-not-created.dmg"))
    try expect(!model.canDownload && !model.downloading && downloads == 0, "stopping host accepted a download")
    child.finish(); try expect(model.phase == .stopped && model.errorMessage == nil, "requested host stop reported failure")
    model.download(to: fixture.appendingPathComponent("synthetic.dmg")); try await settle { !model.downloading }
    try expect(downloads == 1 && model.downloadedURL != nil && starts == 1, "download launched a host")

    // A normal provider return means the exclusive final copy committed. A
    // cancellation request at that boundary must preserve its published URL.
    let committedOwner = SyntheticMacHostDownloadOwner()
    let committedDestination = fixture.appendingPathComponent("synthetic-committed.dmg")
    let committedHost = MacHostModel(operations: .init(installed: { true }, addresses: { addresses },
        start: { _, _, _ in SyntheticMacHostChild() }, download: { _ in committedOwner.model?.cancelDownload() }))
    committedOwner.model = committedHost
    committedHost.download(to: committedDestination)
    try await settle { !committedHost.downloading }
    try expect(committedHost.downloadedURL == committedDestination && committedHost.errorMessage == nil &&
               committedHost.status == "취소를 요청했지만 DMG 저장을 마쳤습니다.",
               "cancellation racing a committed provider return hid the saved DMG or claimed cancellation")
    let uncommittedHost = MacHostModel(operations: .init(installed: { true }, addresses: { addresses },
        start: { _, _, _ in SyntheticMacHostChild() }, download: { _ in throw CancellationError() }))
    uncommittedHost.download(to: fixture.appendingPathComponent("synthetic-uncommitted.dmg"))
    try await settle { !uncommittedHost.downloading }
    try expect(uncommittedHost.downloadedURL == nil && uncommittedHost.errorMessage == nil && uncommittedHost.status == "다운로드 취소됨",
               "pre-commit provider cancellation was reported as a committed download")

    // Application activation reads installation presence only; no UI, preferences, or network.
    let activationCenter = NotificationCenter()
    let activationChild = SyntheticMacHostChild()
    var installationPresent = false, installationReads = 0, addressReads = 0
    let activationModel = MacHostModel(operations: .init(installed: {
        installationReads += 1; return installationPresent
    }, addresses: { addressReads += 1; return addresses }, start: { _, _, _ in activationChild }, download: { _ in }),
        activationCenter: activationCenter)
    activationModel.refresh()
    try expect(!activationModel.installed && installationReads == 1 && addressReads == 1,
               "synthetic installation baseline did not refresh")
    installationPresent = true
    activationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    try await settle { activationModel.installed }
    try expect(installationReads == 2 && addressReads == 1, "activation did not refresh installation independently")
    activationModel.acknowledged = true; activationModel.start()
    try await settle { activationModel.phase == .running }
    let activationStatus = activationModel.status, activationAddress = activationModel.selectedAddress
    let activeAddressReads = addressReads
    installationPresent = false
    activationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    try await settle { !activationModel.installed }
    try expect(activationModel.phase == .running && activationModel.status == activationStatus &&
               activationModel.selectedAddress == activationAddress && addressReads == activeAddressReads,
               "activation replaced running share state or refreshed its selected address")
    let readsBeforeShutdown = installationReads
    activationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil) // Already queued at shutdown.
    activationModel.beginShutdown(); activationChild.finish()
    installationPresent = true
    activationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    activationModel.refresh()
    try await Task.sleep(for: .milliseconds(20))
    try expect(installationReads == readsBeforeShutdown && !activationModel.installed && !activationModel.canDownload,
               "activation or refresh restarted installation work after shutdown")

    var releaseDownload: CheckedContinuation<Void, Never>?
    var downloadStarts = 0, blockedHostStarts = 0
    let downloadingHost = MacHostModel(operations: .init(installed: { true }, addresses: { addresses },
        start: { _, _, _ in blockedHostStarts += 1; return SyntheticMacHostChild() }, download: { _ in
            downloadStarts += 1; await withCheckedContinuation { releaseDownload = $0 }
        }))
    downloadingHost.refresh(); downloadingHost.acknowledged = true
    downloadingHost.download(to: fixture.appendingPathComponent("cancelled-not-created.dmg"))
    try await settle { releaseDownload != nil }
    downloadingHost.start(); downloadingHost.download(to: fixture.appendingPathComponent("duplicate-not-created.dmg"))
    try expect(blockedHostStarts == 0 && downloadStarts == 1 && downloadingHost.phase == .stopped && !downloadingHost.canDownload,
               "download allowed a concurrent host start or duplicate download")
    downloadingHost.beginShutdown(); releaseDownload!.resume()
    try await settle { !downloadingHost.downloading }
    try expect(downloadingHost.downloadedURL == nil && blockedHostStarts == 0,
               "cancelled download published a verified DMG after shutdown")
    let exited = SyntheticMacHostChild()
    let failed = MacHostModel(operations: .init(installed: { true }, addresses: { addresses }, start: { _, _, _ in exited }, download: { _ in }))
    failed.refresh(); failed.acknowledged = true; failed.start(); try await settle { failed.phase == .running }
    exited.finish(); try expect(failed.phase == .stopped && failed.errorMessage != nil && failed.invitation == nil, "unexpected exit retained success status")
    let unavailable = MacHostModel(operations: .init(installed: { true }, addresses: { addresses },
        start: { _, _, _ in throw MacHostPolicy.Failure.helperUnavailable }, download: { _ in }))
    unavailable.refresh(); unavailable.acknowledged = true; unavailable.start()
    try await settle { unavailable.phase == .stopped && unavailable.errorMessage != nil }
    try expect(unavailable.errorMessage == MacHostPolicy.Failure.helperUnavailable.localizedDescription && unavailable.invitation == nil,
               "helper startup failure was misreported as a running Sunshine exit")
    var continuation: CheckedContinuation<any MacHostOwnedProcess, Never>?
    let suspendedChild = SyntheticMacHostChild()
    let cancelled = MacHostModel(operations: .init(installed: { true }, addresses: { addresses }, start: { _, _, _ in await withCheckedContinuation { continuation = $0 } }, download: { _ in }))
    cancelled.refresh(); cancelled.acknowledged = true; cancelled.start(); try await settle { continuation != nil }
    cancelled.stop(); continuation!.resume(returning: suspendedChild)
    try await settle { suspendedChild.stops == 1 }
    try expect(cancelled.phase == .stopping && cancelled.invitation == nil, "cancelled start published a host")
    suspendedChild.finish(); try expect(cancelled.phase == .stopped, "cancelled owned child not stopped")
    continuation = nil
    let alreadyExited = SyntheticMacHostChild()
    let earlyExit = MacHostModel(operations: .init(installed: { true }, addresses: { addresses }, start: { _, _, _ in await withCheckedContinuation { continuation = $0 } }, download: { _ in }))
    earlyExit.refresh(); earlyExit.acknowledged = true; earlyExit.start(); try await settle { continuation != nil }
    earlyExit.stop(); alreadyExited.finish(); continuation!.resume(returning: alreadyExited)
    try await settle { earlyExit.phase == .stopped }
    try expect(earlyExit.errorMessage == nil && earlyExit.invitation == nil, "cancelled already-exited child left model stuck stopping")
    // Quit stays pending on another owner after this host has already stopped.
    let terminalChild = SyntheticMacHostChild()
    var terminalStarts = 0, terminalDownloads = 0
    let terminalHost = MacHostModel(operations: .init(installed: { true }, addresses: { addresses }, start: { _, _, _ in terminalStarts += 1; return terminalChild }, download: { _ in terminalDownloads += 1 }))
    terminalHost.refresh(); terminalHost.acknowledged = true; terminalHost.start()
    try await settle { terminalHost.phase == .running }
    let windowsSuite = "org.deskbridge.synthetic." + UUID().uuidString
    let linuxSuite = "org.deskbridge.synthetic." + UUID().uuidString
    defer { UserDefaults(suiteName: windowsSuite)?.removePersistentDomain(forName: windowsSuite); UserDefaults(suiteName: linuxSuite)?.removePersistentDomain(forName: linuxSuite) }
    let savedPin = SavedHost(address: "192.168.50.20", uniqueID: "synthetic", name: "Synthetic", certificatePEM: "SYNTHETIC NOT A CERTIFICATE", httpPort: 47989, httpsPort: 47984)
    var saved = SavedSettings(); saved.address = savedPin.address; saved.host = savedPin
    let windowsRoot = fixture.appendingPathComponent("quit-windows"), linuxRoot = fixture.appendingPathComponent("quit-linux")
    try SettingsStore(directory: windowsRoot).save(saved); try SettingsStore(directory: linuxRoot).save(saved)
    let windows = DesktopModel(storageDirectory: windowsRoot, identitySuite: windowsSuite)
    let linux = DesktopModel(storageDirectory: linuxRoot, identitySuite: linuxSuite, platform: .linux)
    let transfers = FilesModel(desktop: windows)
    transfers.identityPath = windowsRoot.appendingPathComponent("not-opened-configured-key").path
    let configuredIdentity = transfers.identityPath
    try expect(transfers.requiresKeyReplacementConfirmation, "configured SSH identity did not require replacement confirmation")
    transfers.generateKey()
    try expect(!transfers.busy && transfers.identityPath == configuredIdentity && transfers.errorMessage != nil,
               "key generation replaced configured identity without explicit confirmation")
    transfers.errorMessage = nil
    transfers.generateKey(replacingIdentity: .init(savedPath: transfers.keyReplacementSnapshot.savedPath, draftPath: configuredIdentity + "-stale"))
    try expect(!transfers.busy && transfers.identityPath == configuredIdentity && transfers.errorMessage != nil,
               "key generation accepted confirmation for a different identity")
    var releaseQuit: CheckedContinuation<Void, Never>?
    var hostCleaned = false, quitReplied = false, touchedOperation = false
    let termination = DesktopTermination()
    termination.begin(revoke: {
        windows.beginShutdown(); linux.beginShutdown(); transfers.beginShutdown(); terminalHost.beginShutdown()
    }, cleanup: {
        await DesktopTermination.cleanupOwners([
            { await withCheckedContinuation { releaseQuit = $0 } },
            { await terminalHost.shutdown(); hostCleaned = true },
            { await transfers.shutdown() }
        ])
    }, reply: { quitReplied = true })
    terminalChild.finish()
    try await settle { hostCleaned && releaseQuit != nil }
    try expect(!quitReplied && terminalHost.phase == .stopped, "quit fixture did not hold another owner after host cleanup")
    terminalHost.start(); terminalHost.download(to: fixture.appendingPathComponent("never-created.dmg"))
    for desktop in [windows, linux] {
        desktop.perform { touchedOperation = true }; desktop.forgetHost(); desktop.startNearbySearch()
        let selected = try? desktop.selectCandidateAddress("192.168.50.21")
        try expect(selected == nil && !desktop.canChoosePC && !desktop.canVerifyCurrentPC && !desktop.canForgetHost, "desktop accepted new work during quit")
        try expect(desktop.settings.host?.certificatePEM == savedPin.certificatePEM && desktop.address == savedPin.address, "quit re-entry changed saved trust")
    }
    transfers.perform { touchedOperation = true }; transfers.connect(); transfers.generateKey()
    await Task.yield()
    try expect(terminalStarts == 1 && terminalDownloads == 0 && !terminalChild.running && !touchedOperation && !transfers.canExchangeSetup, "new sharing/network/file work escaped completed quit cleanup")
    releaseQuit?.resume(); try await settle { quitReplied }
    count += try await runMacHostDownloadChecks(temporary: fixture)
    count += try await runMacHostFileWorkChecks(temporary: fixture)
    count += try runMacHostSigningChecks(temporary: fixture)
    count += try await runOwnedMacHostProcessChecks(temporary: fixture)
    return count
}

@MainActor private func runMacHostFileWorkChecks(temporary: URL) async throws -> Int {
    var count = 0
    func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw ModelCheckFailure(message: message) }; count += 1
    }
    let fixture = temporary.appendingPathComponent("file-work-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
    let onMainThread = try await MacHostFileWork.perform { Thread.isMainThread }
    try expect(!onMainThread, "blocking Mac host verification ran on the main thread")

    let entered = "file-work-entered-" + UUID().uuidString
    let cancellation = Task<Void, any Error> {
        try await MacHostFileWork.perform { () throws -> Void in
            SyntheticMacHostDownloadProtocol.events.start(entered)
            let deadline = ContinuousClock.now + .seconds(2)
            while !Task.isCancelled && ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.001) }
            try Task.checkCancellation()
            throw ModelCheckFailure(message: "worker did not receive cancellation")
        }
    }
    var didEnter = false
    for _ in 0..<1000 {
        if SyntheticMacHostDownloadProtocol.events.hasStarted(entered) { didEnter = true; break }
        try await Task.sleep(for: .milliseconds(2))
    }
    cancellation.cancel()
    var cancelled = false
    do { _ = try await cancellation.value } catch is CancellationError { cancelled = true }
    try expect(didEnter && cancelled, "cancellation did not reach offloaded verification")

    let invalidApp = fixture.appendingPathComponent("SyntheticUnsigned.app", isDirectory: true)
    try FileManager.default.createDirectory(at: invalidApp, withIntermediateDirectories: false)
    var refused = false
    do { try await MacHostFileWork.perform { try MacHostFileWork.validateApplication(invalidApp) } }
    catch MacHostPolicy.Failure.untrustedApplication { refused = true }
    try expect(refused, "offloaded signature verification accepted an unsigned inert fixture")

    let bytes = Data((0..<600_001).map { UInt8($0 % 251) })
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let source = fixture.appendingPathComponent("synthetic.dmg")
    let saved = fixture.appendingPathComponent("saved.dmg")
    try bytes.write(to: source)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
    try await MacHostFileWork.perform {
        try MacHostFileWork.verifyAndCopy(source, to: saved, expectedBytes: Int64(bytes.count), sha256: digest)
    }
    try expect(try Data(contentsOf: saved) == bytes, "streamed hash/exclusive copy changed synthetic DMG bytes")
    try expect(getxattr(saved.path, "com.apple.quarantine", nil, 0, 0, 0) > 0,
               "verified saved DMG lost its quarantine attribute")
    for (name, size, hash) in [("wrong-size", Int64(bytes.count - 1), digest), ("wrong-hash", Int64(bytes.count), String(repeating: "0", count: 64))] {
        let destination = fixture.appendingPathComponent(name)
        refused = false
        do {
            try await MacHostFileWork.perform {
                try MacHostFileWork.verifyAndCopy(source, to: destination, expectedBytes: size, sha256: hash)
            }
        } catch MacHostPolicy.Failure.download { refused = true }
        try expect(refused && !FileManager.default.fileExists(atPath: destination.path), "invalid DMG verification committed output: " + name)
    }

    for kind in ["file", "directory", "dangling-symlink"] {
        let destination = fixture.appendingPathComponent("existing-" + kind)
        if kind == "directory" { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false) }
        else if kind == "dangling-symlink" { try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: fixture.appendingPathComponent("absent")) }
        else { try Data("SYNTHETIC EXISTING".utf8).write(to: destination) }
        let marker = "collision-fetch-" + UUID().uuidString
        refused = false
        do {
            try await MacHostFileWork.download(to: destination, expectedBytes: Int64(bytes.count), sha256: digest) {
                SyntheticMacHostDownloadProtocol.events.start(marker)
                throw ModelCheckFailure(message: "existing destination reached download transport")
            }
        } catch MacHostPolicy.Failure.collision { refused = true }
        try expect(refused && !SyntheticMacHostDownloadProtocol.events.hasStarted(marker),
                   "existing destination was not refused before transport: " + kind)
    }
    let competing = fixture.appendingPathComponent("competing.dmg")
    let fetched = fixture.appendingPathComponent("fetched.dmg")
    try bytes.write(to: fetched)
    refused = false
    do {
        try await MacHostFileWork.download(to: competing, expectedBytes: Int64(bytes.count), sha256: digest) {
            try Data("SYNTHETIC COMPETING".utf8).write(to: competing, options: .withoutOverwriting)
            return fetched
        }
    } catch MacHostPolicy.Failure.collision { refused = true }
    try expect(refused && (try Data(contentsOf: competing)) == Data("SYNTHETIC COMPETING".utf8) &&
               !FileManager.default.fileExists(atPath: fetched.path), "post-fetch collision overwrote another file or retained its temporary DMG")

    let cancelledSource = fixture.appendingPathComponent("cancelled-source.dmg")
    let cancelledDestination = fixture.appendingPathComponent("cancelled-output.dmg")
    try bytes.write(to: cancelledSource)
    let cancelledCopy = Task {
        try await MacHostFileWork.download(to: cancelledDestination, expectedBytes: Int64(bytes.count), sha256: digest) {
            withUnsafeCurrentTask { $0?.cancel() }
            return cancelledSource
        }
    }
    cancelled = false
    do { try await cancelledCopy.value } catch is CancellationError { cancelled = true }
    try expect(cancelled && !FileManager.default.fileExists(atPath: cancelledDestination.path) &&
               !FileManager.default.fileExists(atPath: cancelledSource.path), "cancelled verification saved output or retained the temporary DMG")
    return count
}

private final class SyntheticMacHostDownloadEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var started: Set<String> = []
    private var stopped: Set<String> = []
    func start(_ path: String) { lock.lock(); started.insert(path); lock.unlock() }
    func stop(_ path: String) { lock.lock(); stopped.insert(path); lock.unlock() }
    func hasStarted(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return started.contains(path) }
    func hasStopped(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return stopped.contains(path) }
}

/// Every request is handled in memory; even a mistaken host can never reach DNS.
private final class SyntheticMacHostDownloadProtocol: URLProtocol, @unchecked Sendable {
    static let events = SyntheticMacHostDownloadEvents()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.events.start(url.path)
        let scenario = url.lastPathComponent
        let fields: [String: String] = scenario == "declared-overflow" ? ["Content-Length": "7"] : [:]
        let finalURL = scenario == "foreign-response" ? URL(string: "https://untrusted.invalid/body")! : url
        let response = HTTPURLResponse(url: finalURL, statusCode: scenario == "status" ? 503 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: fields)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if scenario == "stall" || scenario == "cancel" { return }
        if scenario != "declared-overflow" {
            client?.urlProtocol(self, didLoad: Data("abc".utf8))
            if scenario != "short" { client?.urlProtocol(self, didLoad: Data(scenario == "body-overflow" ? "defg".utf8 : "def".utf8)) }
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.events.stop(request.url!.path) }
}

private final class SyntheticMacHostRedirectResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URLRequest?
    private var calls = 0
    func set(_ request: URLRequest?) { lock.lock(); value = request; calls += 1; lock.unlock() }
    var request: URLRequest? { lock.lock(); defer { lock.unlock() }; return value }
    var wasCalledOnce: Bool { lock.lock(); defer { lock.unlock() }; return calls == 1 }
}

@MainActor private func runMacHostDownloadChecks(temporary: URL) async throws -> Int {
    var count = 0
    func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw ModelCheckFailure(message: message) }; count += 1
    }
    let fixture = temporary.appendingPathComponent("download-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
    let prefix = "https://github.com/LizardByte/Sunshine/releases/download/synthetic-" + UUID().uuidString + "/"
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SyntheticMacHostDownloadProtocol.self]
    func url(_ scenario: String) -> URL { URL(string: prefix + scenario)! }
    func empty() throws -> Bool { try FileManager.default.contentsOfDirectory(atPath: fixture.path).isEmpty }
    func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 { if predicate() { return }; try await Task.sleep(for: .milliseconds(2)) }
        throw ModelCheckFailure(message: "synthetic download did not settle")
    }
    let exact = try await MacHostDownload.fetch(from: url("exact"), expectedBytes: 6,
                                               configuration: configuration, temporaryDirectory: fixture)
    try expect(try Data(contentsOf: exact) == Data("abcdef".utf8), "bounded download changed exact synthetic bytes")
    let mode = try FileManager.default.attributesOfItem(atPath: exact.path)[.posixPermissions] as? Int
    try expect(mode == 0o600, "temporary download was readable by other users")
    try FileManager.default.removeItem(at: exact)
    for scenario in ["declared-overflow", "body-overflow", "short", "status", "foreign-response"] {
        var refused = false
        do {
            let file = try await MacHostDownload.fetch(from: url(scenario), expectedBytes: 6,
                                                       configuration: configuration, temporaryDirectory: fixture)
            try? FileManager.default.removeItem(at: file)
        } catch { refused = true }
        try expect(refused && (try empty()), "unbounded/invalid download accepted or partial file retained: " + scenario)
    }
    let cancellationURL = url("cancel")
    let cancellation = Task {
        try await MacHostDownload.fetch(from: cancellationURL, expectedBytes: 6,
                                        configuration: configuration, temporaryDirectory: fixture)
    }
    try await waitFor { SyntheticMacHostDownloadProtocol.events.hasStarted(cancellationURL.path) }
    cancellation.cancel()
    var cancelled = false
    do { let file = try await cancellation.value; try? FileManager.default.removeItem(at: file) }
    catch is CancellationError { cancelled = true }
    try await waitFor { SyntheticMacHostDownloadProtocol.events.hasStopped(cancellationURL.path) }
    try expect(cancelled && (try empty()), "active download cancellation did not stop transport and remove partial file")
    let beforeStartURL = url("cancel-before-start")
    let beforeStart = Task {
        try await MacHostDownload.fetch(from: beforeStartURL, expectedBytes: 6,
                                        configuration: configuration, temporaryDirectory: fixture)
    }
    beforeStart.cancel(); cancelled = false
    do { let file = try await beforeStart.value; try? FileManager.default.removeItem(at: file) }
    catch is CancellationError { cancelled = true }
    try expect(cancelled && !SyntheticMacHostDownloadProtocol.events.hasStarted(beforeStartURL.path) && (try empty()),
               "cancelled download created a request or temporary file")
    let started = ContinuousClock.now
    var timedOut = false
    do {
        _ = try await MacHostDownload.fetch(from: url("stall"), expectedBytes: 6,
                                            configuration: configuration, timeout: 0.05, temporaryDirectory: fixture)
    } catch let error as URLError { timedOut = error.code == .timedOut }
    try await waitFor { SyntheticMacHostDownloadProtocol.events.hasStopped(url("stall").path) }
    try expect(timedOut && started.duration(to: .now) < .seconds(2) && (try empty()),
               "download wall-clock timeout did not stop transport and remove partial file")

    // Invoke the actual redirect callback without resuming any URLSession task.
    // This verifies the pre-follow decision, including cases URLProtocol itself
    // normalizes before delivery to a URLSession delegate.
    let policy = MacHostDownload.Policy(source: url("redirect"), bytes: 6, maximumRedirects: 2)
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: policy.source)
    let response = HTTPURLResponse(url: policy.source, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: [:])!
    let forbidden = ["http://release-assets.githubusercontent.com/body", "https://untrusted.invalid/body",
                     "https://github.com.untrusted.invalid/body", "https://release-assets.githubusercontent.com:444/body",
                     "https://user:password@release-assets.githubusercontent.com/body", "https://github.com/other/project/releases/body",
                     policy.source.absoluteString + "?alternate=1", "https://objects.githubusercontent.com/body#fragment"]
    for target in forbidden {
        let transfer = try MacHostDownloadTransfer(policy: policy, timeout: 1, temporaryDirectory: fixture)
        let result = SyntheticMacHostRedirectResult()
        transfer.urlSession(session, task: task, willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: URL(string: target)!), completionHandler: { result.set($0) })
        try expect(result.wasCalledOnce && result.request == nil && (try empty()), "redirect was followed before allowlist rejection: " + target)
    }
    let transfer = try MacHostDownloadTransfer(policy: policy, timeout: 1, temporaryDirectory: fixture)
    defer { transfer.cancel() }
    for (index, target) in ["https://release-assets.githubusercontent.com/body?signature=synthetic",
                            "https://objects.githubusercontent.com:443/body", policy.source.absoluteString].enumerated() {
        var request = URLRequest(url: URL(string: target)!)
        request.setValue("synthetic-secret", forHTTPHeaderField: "Authorization")
        request.setValue("synthetic-proxy-secret", forHTTPHeaderField: "Proxy-Authorization")
        request.setValue("synthetic-cookie", forHTTPHeaderField: "Cookie")
        let result = SyntheticMacHostRedirectResult()
        transfer.urlSession(session, task: task, willPerformHTTPRedirection: response,
                            newRequest: request, completionHandler: { result.set($0) })
        if index < 2 {
            try expect(result.wasCalledOnce && result.request?.url == request.url && result.request?.value(forHTTPHeaderField: "Authorization") == nil &&
                       result.request?.value(forHTTPHeaderField: "Proxy-Authorization") == nil &&
                       result.request?.value(forHTTPHeaderField: "Cookie") == nil,
                       "official asset redirect was refused or forwarded ambient credentials")
        } else {
            try expect(result.wasCalledOnce && result.request == nil && (try empty()), "download redirect count was unbounded")
        }
    }

    let bounded = try MacHostDownloadTransfer(policy: policy, timeout: 1, temporaryDirectory: fixture)
    let bodyResponse = HTTPURLResponse(url: policy.source, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
    bounded.urlSession(session, dataTask: task, didReceive: bodyResponse, completionHandler: { _ in })
    bounded.urlSession(session, dataTask: task, didReceive: Data("abc".utf8))
    let partials = try FileManager.default.contentsOfDirectory(at: fixture, includingPropertiesForKeys: nil)
    try expect(partials.count == 1 && (try Data(contentsOf: partials[0])) == Data("abc".utf8),
               "bounded sink did not receive the initial synthetic chunk")
    // Keep a read descriptor across unlink to inspect exactly what was written.
    let retained = try FileHandle(forReadingFrom: partials[0]); defer { try? retained.close() }
    bounded.urlSession(session, dataTask: task, didReceive: Data("defg".utf8))
    try expect(try retained.readToEnd() == Data("abc".utf8) && empty(),
               "overflow chunk was written before the byte cap or partial-file cleanup")
    return count
}

/// Compiles and runs only this new inert fixture, never Sunshine or app main.
/// The owned host cannot fork; an unrelated companion remains unaffected.
@MainActor private func runOwnedMacHostProcessChecks(temporary: URL) async throws -> Int {
    let source = temporary.appendingPathComponent("owned-process.c")
    let executable = temporary.appendingPathComponent("owned-process")
    let forkMarker = temporary.appendingPathComponent("fork-escaped")
    let forkStarted = temporary.appendingPathComponent("fork-escaped.started")
    let forkDenied = temporary.appendingPathComponent("fork-escaped.denied")
    let companionMarker = temporary.appendingPathComponent("companion-completed")
    let lingerReady = temporary.appendingPathComponent("linger-ready")
    let code = """
    #include <unistd.h>
    #include <stdio.h>
    #include <string.h>
    #include <signal.h>
    #include <errno.h>
    int main(int argc, char **argv) {
      if (argc != 3) return 2;
      if (strcmp(argv[1], "fork") == 0) {
        pid_t p = fork();
        if (p < 0) {
          if (errno != EPERM) return 4;
          char proof[4096]; snprintf(proof, sizeof(proof), "%s.denied", argv[2]);
          FILE *f = fopen(proof, "wx"); if (!f) return 5; fputs("SYNTHETIC EPERM", f); fclose(f);
          return 0;
        }
        if (p > 0) {
          char proof[4096]; snprintf(proof, sizeof(proof), "%s.started", argv[2]);
          FILE *f = fopen(proof, "wx"); if (!f) return 5; fputs("SYNTHETIC", f); fclose(f);
          usleep(30000); return 0;
        }
      } else if (strcmp(argv[1], "linger") == 0) {
        if (signal(SIGTERM, SIG_IGN) == SIG_ERR) return 6;
        FILE *ready = fopen(argv[2], "wx"); if (!ready) return 7;
        int written = fputs("SYNTHETIC SIGTERM READY", ready);
        int closed = fclose(ready);
        if (written == EOF || closed != 0) return 8;
        for (;;) pause();
      }
      usleep(400000);
      FILE *f = fopen(argv[2], "wx");
      if (!f) return 3;
      fputs("SYNTHETIC FIXTURE ONLY", f); fclose(f); return 0;
    }
    """
    try Data(code.utf8).write(to: source)
    let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
    compiler.arguments = [source.path, "-O2", "-o", executable.path]
    compiler.standardInput = FileHandle.nullDevice; compiler.standardOutput = FileHandle.nullDevice; compiler.standardError = FileHandle.nullDevice
    try compiler.run(); compiler.waitUntilExit()
    guard compiler.terminationStatus == 0 else { throw ModelCheckFailure(message: "owned process fixture did not compile") }
    let companion = Process(); companion.executableURL = executable
    companion.arguments = ["companion", companionMarker.path]
    companion.standardInput = FileHandle.nullDevice; companion.standardOutput = FileHandle.nullDevice; companion.standardError = FileHandle.nullDevice
    try companion.run()
    let owned = try MacHostChild(executable: executable, arguments: ["fork", forkMarker.path])
    for _ in 0..<1000 { if !owned.running { break }; try await Task.sleep(for: .milliseconds(2)) }
    guard !owned.running else { owned.forceStop(); throw ModelCheckFailure(message: "owned parent exit did not settle") }
    try await Task.sleep(for: .milliseconds(600))
    companion.waitUntilExit()
    guard (try? Data(contentsOf: forkDenied)) == Data("SYNTHETIC EPERM".utf8),
          !FileManager.default.fileExists(atPath: forkStarted.path),
          !FileManager.default.fileExists(atPath: forkMarker.path), companion.terminationStatus == 0,
          FileManager.default.fileExists(atPath: companionMarker.path) else {
        throw ModelCheckFailure(message: "owned host fork was not denied or cleanup affected unrelated companion")
    }
    let linger = try MacHostChild(executable: executable, arguments: ["linger", lingerReady.path])
    defer { linger.forceStop() }
    // Spawning the supervisor does not mean its sandboxed child has exec'd.
    // Stop only after the inert child confirms its SIGTERM handler is installed.
    let ready = Data("SYNTHETIC SIGTERM READY".utf8)
    let readinessDeadline = ContinuousClock.now + .seconds(5)
    while linger.running && (try? Data(contentsOf: lingerReady)) != ready && ContinuousClock.now < readinessDeadline {
        try await Task.sleep(for: .milliseconds(2))
    }
    guard linger.running, (try? Data(contentsOf: lingerReady)) == ready else {
        throw ModelCheckFailure(message: "owned process fixture did not become ready for forced group stop")
    }
    linger.stop(); try await Task.sleep(for: .milliseconds(20))
    guard linger.running else { throw ModelCheckFailure(message: "fixture did not exercise forced group stop") }
    linger.forceStop()
    for _ in 0..<1000 { if !linger.running { break }; try await Task.sleep(for: .milliseconds(2)) }
    guard !linger.running else { throw ModelCheckFailure(message: "owned group forced stop did not settle") }
    return 4
}
