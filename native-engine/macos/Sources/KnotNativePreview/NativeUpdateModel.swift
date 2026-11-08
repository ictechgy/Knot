// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AppKit
import Darwin
import Combine

private final class NativeUpdateDownloadLimit: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let maximum: Int64
    init(_ maximum: Int64) { self.maximum = maximum }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximum || totalBytesExpectedToWrite > maximum { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

/// The object owns only a newly launched helper and its inherited pipes.
/// Failed handoff revokes its nonce before closing the process-lifetime pipe.
final class NativePreparedUpdate: @unchecked Sendable {
    let process: Process, output: Pipe, input: Pipe, stage: URL, nonce: String
    init(process: Process, output: Pipe, input: Pipe, stage: URL, nonce: String) {
        self.process = process; self.output = output; self.input = input; self.stage = stage; self.nonce = nonce
    }
    func commit() throws { try input.fileHandleForWriting.write(contentsOf: NativeUpdateAcknowledgement.commit(nonce)) }
    private static let cancellationQueue = DispatchQueue(label: "org.knot.native-update.cancel", qos: .utility, attributes: .concurrent)
    func cancel() async -> Bool {
        // A dedicated blocking queue preserves shutdown even when the caller is
        // cancelled, without parking a Swift cooperative-pool thread for grace.
        await withCheckedContinuation { continuation in
            Self.cancellationQueue.async { continuation.resume(returning: self.cancelSynchronously()) }
        }
    }
    private func cancelSynchronously() -> Bool {
        try? Data(nonce.utf8).write(to: stage.appendingPathComponent("cancel-" + nonce), options: .withoutOverwriting)
        try? input.fileHandleForWriting.close()
        let stopped = NativeUpdateChildShutdown.stop(
            isRunning: { self.process.isRunning }, terminate: { self.process.terminate() },
            kill: { _ = Darwin.kill(self.process.processIdentifier, SIGKILL) }, polls: 1800)
        if stopped { closePipes() }
        // A dead helper is not by itself proof that its tool children drained.
        // The helper writes cleanup only after command supervision and removal
        // of any incomplete sibling copy. Forced termination retains the stage.
        let started = stage.appendingPathComponent("started-" + nonce)
        let cleanup = stage.appendingPathComponent("cleanup-" + nonce)
        return stopped && (!FileManager.default.fileExists(atPath: started.path) || (try? Data(contentsOf: cleanup)) == Data(nonce.utf8))
    }
    func closePipes() {
        try? input.fileHandleForReading.close(); try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
    }
}

/// Synchronous owned-child shutdown runs only on a detached worker. Injected
/// clocks/children let tests prove cancelled callers still observe the grace.
enum NativeUpdateChildShutdown {
    static func stop(isRunning: () -> Bool, terminate: () -> Void, kill: () -> Void,
                     pause: () -> Void = { Thread.sleep(forTimeInterval: 0.025) }, polls: Int = 80, killPolls: Int = 80) -> Bool {
        if !isRunning() { return true }
        terminate()
        for _ in 0..<polls { if !isRunning() { return true }; pause() }
        if isRunning() { kill() }
        for _ in 0..<killPolls { if !isRunning() { return true }; pause() }
        return !isRunning()
    }
}

struct NativeUpdateUnconfirmedCancellation: Error {
    let prepared: NativePreparedUpdate
}

struct NativeUpdateInstallation: Sendable {
    let app: URL, executable: URL, configuration: URL
    @MainActor static func current() -> NativeUpdateInstallation? {
        guard let executable = Bundle.main.executableURL,
              let configuration = Bundle.main.url(forResource: "NativeUpdateConfig", withExtension: "txt") else { return nil }
        return Self(app: Bundle.main.bundleURL, executable: executable, configuration: configuration)
    }
}

@MainActor final class NativeUpdateModel: ObservableObject {
    @Published private(set) var status = "자동 업데이트 배포가 아직 구성되지 않았습니다."
    @Published private(set) var available = false
    @Published private(set) var checking = false
    let configured: Bool
    private let configuration: NativeUpdateConfiguration?
    private var pending: (NativeUpdateManifest, URL)?
    private var checks: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var generation: UInt64 = 0
    private let download: @Sendable (NativeUpdateConfiguration) async throws -> (NativeUpdateManifest, URL)
    private let now: @Sendable () -> Int64
    private let installation: @MainActor () -> NativeUpdateInstallation?
    private let prepareInstallation: @Sendable (NativeUpdateManifest, URL, NativeUpdateConfiguration, URL, URL, URL) async throws -> NativePreparedUpdate
    private let terminateApplication: @MainActor () -> Void
    // Keep the parent's lifetime writer open through the actual process exit.
    private var committedHandoff: NativePreparedUpdate?
    private var unconfirmedHandoff: NativePreparedUpdate?
    init(configuration: NativeUpdateConfiguration? = NativeUpdateConfiguration.load(),
         download: (@Sendable (NativeUpdateConfiguration) async throws -> (NativeUpdateManifest, URL))? = nil,
         now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) },
         installation: (@MainActor () -> NativeUpdateInstallation?)? = nil,
         prepare: (@Sendable (NativeUpdateManifest, URL, NativeUpdateConfiguration, URL, URL, URL) async throws -> NativePreparedUpdate)? = nil,
         terminate: (@MainActor () -> Void)? = nil) {
        self.configuration = configuration; configured = configuration?.configured == true
        self.download = download ?? Self.prepareDownload; self.now = now
        self.installation = installation ?? NativeUpdateInstallation.current
        self.prepareInstallation = prepare ?? Self.prepareInstall
        self.terminateApplication = terminate ?? { NSApp.terminate(nil) }
        if configured { status = "새 버전을 자동으로 확인합니다." }
    }
    func startAutomaticChecks() {
        guard configured, checks == nil else { return }
        checks = Task { [weak self] in
            while !Task.isCancelled {
                self?.check()
                do { try await Task.sleep(for: .seconds(86_400)) } catch { break }
            }
        }
    }
    func stop() {
        checks?.cancel(); checks = nil
        // Once COMMIT transfers ownership, normal application shutdown must not
        // delete files still used by the helper or close its lifetime pipe.
        guard committedHandoff == nil else { return }
        generation &+= 1; operation?.cancel(); operation = nil; checking = false
        discardPending(synchronously: true)
    }
    private func discardPending(synchronously: Bool = false) {
        let owned = pending?.1; pending = nil; available = false
        if let owned {
            // Shutdown must finish unlinking the inactive payload before the
            // process exits. This is metadata cleanup, never a hash or copy.
            if synchronously { try? FileManager.default.removeItem(at: owned) }
            else { Task.detached { try? FileManager.default.removeItem(at: owned) } }
        }
    }
    func check() {
        guard configured, let configuration, !checking, committedHandoff == nil, unconfirmedHandoff == nil else { return }
        if let (manifest, _) = pending, manifest.expires <= now() { discardPending() }
        guard pending == nil else { return }
        checking = true; status = "업데이트를 확인하고 있습니다."
        generation &+= 1; let run = generation
        let download = self.download
        operation = Task { [weak self] in
            let worker = Task.detached { try await download(configuration) }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, self.generation == run, !Task.isCancelled else {
                    Task.detached { try? FileManager.default.removeItem(at: result.1) }; return
                }
                self.pending = result; self.available = true; self.checking = false; self.operation = nil
                self.status = "\(result.0.version) 준비 완료 · 설치 후 자동으로 다시 엽니다."
            } catch {
                guard let self, self.generation == run else { return }
                self.checking = false; self.operation = nil
                if case NativeUpdateError.downgrade = error { self.status = "현재 최신 버전을 사용하고 있습니다." }
                else if !(error is CancellationError) { self.status = "업데이트를 확인하지 못했습니다. 현재 버전은 계속 사용할 수 있습니다." }
            }
        }
    }
    func install(beforeExit: @escaping @MainActor () -> Void) {
        guard let (manifest, stage) = pending, !checking, committedHandoff == nil, unconfirmedHandoff == nil, let configuration,
              let installation = installation(), installation.app.pathExtension == "app", !installation.app.path.hasPrefix("/Volumes/"),
              FileManager.default.isWritableFile(atPath: installation.app.deletingLastPathComponent().path) else {
            if !checking, committedHandoff == nil { discardPending() }
            status = "설치된 앱을 업데이트하려면 쓰기 가능한 Applications 폴더로 옮겨 주세요."; return
        }
        // The operation now owns this stage. stop() cannot remove it while a
        // hash, copy, or helper is still using it. Failure permits a fresh check.
        pending = nil; available = false
        checking = true; status = "업데이트를 설치할 준비를 하고 있습니다."
        generation &+= 1; let run = generation
        let app = installation.app.resolvingSymlinksInPath(), prepare = prepareInstallation
        operation = Task { [weak self] in
            let worker = Task.detached { try await prepare(manifest, stage, configuration, installation.executable, installation.configuration, app) }
            do {
                let prepared = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, self.generation == run, !Task.isCancelled else {
                    if await prepared.cancel() { Task.detached { try? FileManager.default.removeItem(at: stage) } }; return
                }
                do { try prepared.commit() }
                catch {
                    if await prepared.cancel() { Task.detached { try? FileManager.default.removeItem(at: stage) } }
                    else { throw NativeUpdateUnconfirmedCancellation(prepared: prepared) }
                    throw error
                }
                self.committedHandoff = prepared; self.checking = false; self.operation = nil
                self.checks?.cancel(); self.checks = nil
                beforeExit(); self.terminateApplication()
            } catch {
                guard let self, self.generation == run else { return }
                self.checking = false; self.operation = nil
                if let uncertain = error as? NativeUpdateUnconfirmedCancellation {
                    self.unconfirmedHandoff = uncertain.prepared
                    self.status = "업데이트 작업의 취소를 확인하지 못해 추가 업데이트를 중단했습니다. 현재 앱은 계속 사용할 수 있습니다."
                } else {
                    self.status = "업데이트 준비를 취소했습니다. 현재 앱은 계속 사용할 수 있으며 새 버전을 다시 확인할 수 있습니다."
                }
            }
        }
    }
    private nonisolated static func prepareDownload(_ configuration: NativeUpdateConfiguration) async throws -> (NativeUpdateManifest, URL) {
        let directory = try privateStage(); var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: directory) } }
        let envelopeURL = try await download(try NativeUpdateManifest.https(configuration.macFeed), maximum: 16_384, to: directory.appendingPathComponent("manifest.feed"))
        let manifest = try NativeUpdateManifest.verify(Data(contentsOf: envelopeURL), configuration: configuration, platform: "macos-arm64")
        let package = try await download(manifest.url, maximum: manifest.bytes, to: directory.appendingPathComponent("payload.zip"))
        try manifest.verifyFile(package); try Task.checkCancellation(); retained = true
        return (manifest, directory)
    }
    private nonisolated static func prepareInstall(manifest: NativeUpdateManifest, stage: URL, configuration: NativeUpdateConfiguration,
                                                   executable: URL, configURL: URL, app: URL) async throws -> NativePreparedUpdate {
        let process = Process(), output = Pipe(), input = Pipe(), nonce = UUID().uuidString + UUID().uuidString
        let prepared = NativePreparedUpdate(process: process, output: output, input: input, stage: stage, nonce: nonce)
        do {
            try Task.checkCancellation()
            let fresh = try NativeUpdateManifest.verify(Data(contentsOf: stage.appendingPathComponent("manifest.feed")), configuration: configuration, platform: "macos-arm64")
            guard fresh.build == manifest.build else { throw NativeUpdateError.invalid }
            try fresh.verifyFile(stage.appendingPathComponent("payload.zip")); try Task.checkCancellation()
            let helper = stage.appendingPathComponent("KnotNativeUpdateHandoff")
            try FileManager.default.copyItem(at: executable, to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            try FileManager.default.copyItem(at: configURL, to: stage.appendingPathComponent("NativeUpdateConfig.txt"))
            process.executableURL = helper
            process.arguments = ["--knot-native-update-v2", String(getpid()), app.path, stage.path, nonce]
            process.standardOutput = output; process.standardInput = input; process.standardError = FileHandle.nullDevice
            try process.run(); try output.fileHandleForWriting.close(); try input.fileHandleForReading.close()
            try await NativeUpdateAcknowledgement.wait(readDescriptor: output.fileHandleForReading.fileDescriptor,
                                                       expected: NativeUpdateAcknowledgement.receipt(nonce))
            try Task.checkCancellation(); guard process.isRunning else { throw NativeUpdateError.installation }
            return prepared
        } catch {
            if await prepared.cancel() { try? FileManager.default.removeItem(at: stage) }
            else { throw NativeUpdateUnconfirmedCancellation(prepared: prepared) }
            throw error
        }
    }
    private nonisolated static func privateStage() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("knot-native-update-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    private nonisolated static func download(_ url: URL, maximum: Int64, to target: URL) async throws -> URL {
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 1800
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: NativeUpdateDownloadLimit(maximum), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url == url, response.expectedContentLength <= maximum,
              (try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= maximum else { throw NativeUpdateError.download }
        try Task.checkCancellation(); try FileManager.default.moveItem(at: temporary, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return target
    }
}

enum NativeUpdateRecoveryGate {
    /// Used by the helper catch itself; TERM/CANCEL is checked again after a
    /// potentially slow canonical verification, immediately before reopening.
    static func reopen(isRevoked: () -> Bool, validateCanonical: () -> Bool, relaunch: () -> Void) -> Bool {
        guard !isRevoked(), validateCanonical(), !isRevoked() else { return false }
        relaunch(); return true
    }
}

/// Helper-only cooperative TERM handling and exact command-child supervision.
/// No PID scans or process-name kills. Lack of a drain proof suppresses cleanup.
final class NativeUpdateHelperContext: @unchecked Sendable {
    let stage: URL, nonce: String
    private let lock = NSLock()
    private var terminated = false
    private var source: DispatchSourceSignal?
    private(set) var writersConfirmed = true
    init(stage: URL, nonce: String, installSignalHandlers: Bool = true) throws {
        self.stage = stage; self.nonce = nonce
        if installSignalHandlers {
            signal(SIGTERM, SIG_IGN); signal(SIGPIPE, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in
                self?.requestTermination()
            }
            source.resume(); self.source = source
        }
        try Data(nonce.utf8).write(to: stage.appendingPathComponent("started-" + nonce), options: .withoutOverwriting)
    }
    deinit { source?.cancel() }
    func requestTermination() { lock.lock(); terminated = true; lock.unlock() }
    var isRevoked: Bool {
        lock.lock(); let stopping = terminated; lock.unlock()
        return stopping || FileManager.default.fileExists(atPath: stage.appendingPathComponent("cancel-" + nonce).path)
    }
    func check() throws { guard !isRevoked else { throw NativeUpdateError.installation } }

    func command(_ path: String, _ args: [String]) throws -> String {
        try check()
        let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath: path); process.arguments = args
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        try process.run(); try pipe.fileHandleForWriting.close()
        defer { try? pipe.fileHandleForReading.close() }
        let fd = pipe.fileHandleForReading.fileDescriptor, flags = fcntl(pipe.fileHandleForReading.fileDescriptor, F_GETFL)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536), eof = false
        do {
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw NativeUpdateError.installation }
            let deadline = Date().addingTimeInterval(1800)
            while !eof || process.isRunning {
                try check(); guard Date() < deadline else { throw NativeUpdateError.installation }
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    guard data.count <= 8 * 1024 * 1024 - count else { throw NativeUpdateError.installation }
                    data.append(contentsOf: buffer.prefix(count))
                } else if count == 0 { eof = true }
                else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw NativeUpdateError.installation }
                if !eof || process.isRunning { Thread.sleep(forTimeInterval: 0.025) }
            }
            process.waitUntilExit(); guard process.terminationStatus == 0 else { throw NativeUpdateError.installation }
            return String(decoding: data, as: UTF8.self)
        } catch {
            let stopped = NativeUpdateChildShutdown.stop(isRunning: { process.isRunning }, terminate: { process.terminate() },
                kill: { _ = Darwin.kill(process.processIdentifier, SIGKILL) })
            // EOF also proves no inherited output writer remains. A command
            // whose completion cannot be proved must never license stage sweep.
            var drained = eof
            if stopped, !drained {
                for _ in 0..<80 {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                    if count == 0 { drained = true; break }
                    if count < 0, errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { break }
                    Thread.sleep(forTimeInterval: 0.025)
                }
            }
            if !stopped || !drained { writersConfirmed = false }
            throw error
        }
    }
}

/// Dispatch before creating any windows. This helper never initializes session/capture/file adapters.
enum NativeUpdateHandoff {
    static func runIfRequested() {
        let a = CommandLine.arguments
        guard a.count > 1, a[1] == "--knot-native-update-v2" else { return }
        do { try run(a); exit(0) } catch { exit(1) }
    }
    private static func run(_ a: [String]) throws {
        guard a.count == 6, let pid = Int32(a[2]), pid > 1, NativeUpdateAcknowledgement.validNonce(a[5]) else { throw NativeUpdateError.installation }
        let app = URL(fileURLWithPath: a[3]).standardizedFileURL, stage = URL(fileURLWithPath: a[4]).standardizedFileURL
        guard app.path == app.resolvingSymlinksInPath().path, app.lastPathComponent == "Knot Native Preview.app",
              stage.path == stage.resolvingSymlinksInPath().path, stage.lastPathComponent.hasPrefix("knot-native-update-"),
              stage.deletingLastPathComponent().path == FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path,
              let config = NativeUpdateConfiguration.load(stage.appendingPathComponent("NativeUpdateConfig.txt")), config.configured else { throw NativeUpdateError.installation }
        var info = stat()
        guard lstat(stage.path, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw NativeUpdateError.installation }
        let context = try NativeUpdateHelperContext(stage: stage, nonce: a[5])
        var ownedReplacement: URL?, published = false
        defer {
            if !published {
                if let ownedReplacement { try? FileManager.default.removeItem(at: ownedReplacement) }
                if context.writersConfirmed, ownedReplacement == nil || !FileManager.default.fileExists(atPath: ownedReplacement!.path) {
                    try? Data(a[5].utf8).write(to: stage.appendingPathComponent("cleanup-" + a[5]), options: .withoutOverwriting)
                }
            }
        }
        try context.check()
        let manifest = try NativeUpdateManifest.verify(Data(contentsOf: stage.appendingPathComponent("manifest.feed")), configuration: config, platform: "macos-arm64")
        let package = stage.appendingPathComponent("payload.zip"); try manifest.verifyFile(package)
        guard let installed = Bundle(url: app), installed.bundleIdentifier == "org.knot.native-preview",
              let installedVersion = installed.object(forInfoDictionaryKey: "KnotNativeVersion") as? String,
              try NativeUpdateManifest.versionBuild(installedVersion) < manifest.build else { throw NativeUpdateError.downgrade }
        let names = try context.command("/usr/bin/zipinfo", ["-1", package.path])
        let listing = try context.command("/usr/bin/zipinfo", ["-l", package.path])
        try NativeUpdateArchiveInventory.validate(names: names, listing: listing)
        let extraction = stage.appendingPathComponent("expanded"); try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        _ = try context.command("/usr/bin/ditto", ["-x", "-k", package.path, extraction.path])
        let candidate = extraction.appendingPathComponent(app.lastPathComponent)
        guard let replacement = Bundle(url: candidate), replacement.bundleIdentifier == installed.bundleIdentifier,
              replacement.object(forInfoDictionaryKey: "KnotNativeVersion") as? String == manifest.version else { throw NativeUpdateError.installation }
        _ = try context.command("/usr/bin/codesign", ["--verify", "--deep", "--strict", candidate.path])
        let transaction = try NativeUpdateTransaction.prepare(candidate: candidate, destination: app, onReplacement: { ownedReplacement = $0 }) { copied in
            guard let bundle = Bundle(url: copied), bundle.bundleIdentifier == installed.bundleIdentifier,
                  bundle.object(forInfoDictionaryKey: "KnotNativeVersion") as? String == manifest.version else { throw NativeUpdateError.installation }
            _ = try context.command("/usr/bin/codesign", ["--verify", "--deep", "--strict", copied.path])
        }
        // Every validation and same-volume atomic-exchange capability check above
        // must finish before the parent is allowed to leave its working window.
        try FileHandle.standardOutput.write(contentsOf: NativeUpdateAcknowledgement.receipt(a[5]))
        // COMMIT is explicit. EOF alone never authorizes publication. After
        // COMMIT, EOF binds the wait to the actual parent-owned pipe, not just a
        // recyclable numeric PID. A cancellation marker wins before publish.
        try NativeUpdateAcknowledgement.waitForCommitAndParentExit(readDescriptor: STDIN_FILENO, nonce: a[5])
        // The complete COMMIT plus EOF is the process-lifetime proof. A
        // recycled numeric PID must not strand an otherwise validated update.
        do {
            try context.check()
            try transaction.publish(); published = true
            _ = try context.command("/usr/bin/open", [app.path, "--args", "--knot-native-update-resume"])
            transaction.discardPreparedCopy()
            try? FileManager.default.removeItem(at: stage)
        } catch {
            // Parent is known gone and atomic publication preserves a complete
            // canonical app. Revalidate that code before best-effort reopening.
            _ = NativeUpdateRecoveryGate.reopen(isRevoked: { context.isRevoked }, validateCanonical: {
                guard let canonical = Bundle(url: app), canonical.bundleIdentifier == installed.bundleIdentifier,
                      let version = canonical.object(forInfoDictionaryKey: "KnotNativeVersion") as? String,
                      version == installedVersion || version == manifest.version else { return false }
                return (try? command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])) != nil
            }, relaunch: {
                _ = try? command("/usr/bin/open", [app.path, "--args", "--knot-native-update-resume"])
            })
            throw error
        }
    }
    private static func command(_ path: String, _ args: [String]) throws -> String {
        let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath: path); process.arguments = args
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); var data = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
            guard data.count <= 8 * 1024 * 1024 - chunk.count else { process.terminate(); throw NativeUpdateError.installation }
            data.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NativeUpdateError.installation }
        return String(decoding: data, as: UTF8.self)
    }
}

/// One nonce-bound message on an inherited, owned pipe. Reads are nonblocking
/// and yield between attempts, so helper validation never blocks the app UI.
enum NativeUpdateAcknowledgement {
    static func validNonce(_ value: String) -> Bool {
        value.utf8.count == 72 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 45 }
    }
    static func receipt(_ nonce: String) -> Data { Data(("KNOT-NATIVE-UPDATE-READY-1\n" + nonce + "\n").utf8) }
    static func commit(_ nonce: String) -> Data { Data(("KNOT-NATIVE-UPDATE-COMMIT-1\n" + nonce + "\n").utf8) }
    /// Helper-only blocking wait. Parent failure closes this pipe without a
    /// complete COMMIT; normal EOF after COMMIT means that lifetime ended.
    static func waitForCommitAndParentExit(readDescriptor: Int32, nonce: String, timeout: TimeInterval = 180) throws {
        let flags = fcntl(readDescriptor, F_GETFL), expected = commit(nonce)
        guard validNonce(nonce), timeout > 0, flags >= 0,
              fcntl(readDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw NativeUpdateError.installation }
        let deadline = Date().addingTimeInterval(timeout)
        var received = Data(), buffer = [UInt8](repeating: 0, count: 257)
        while Date() < deadline {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(readDescriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                received.append(contentsOf: buffer.prefix(count))
                guard received.count <= expected.count, expected.starts(with: received) else { throw NativeUpdateError.installation }
            } else if count == 0 {
                guard received == expected else { throw NativeUpdateError.installation }; return
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw NativeUpdateError.installation }
            Thread.sleep(forTimeInterval: 0.025)
        }
        throw NativeUpdateError.installation
    }
    static func wait(readDescriptor: Int32, expected: Data, timeout: Duration = .seconds(45)) async throws {
        let flags = fcntl(readDescriptor, F_GETFL)
        guard flags >= 0, fcntl(readDescriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              !expected.isEmpty, expected.count <= 256 else { throw NativeUpdateError.installation }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var received = Data(), buffer = [UInt8](repeating: 0, count: 257)
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw NativeUpdateError.installation }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(readDescriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                received.append(contentsOf: buffer.prefix(count))
                guard received.count <= expected.count, expected.starts(with: received) else { throw NativeUpdateError.installation }
                if received.count == expected.count { return }
            } else if count == 0 { throw NativeUpdateError.installation }
            else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw NativeUpdateError.installation }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}

enum NativeUpdateArchiveInventory {
    static func validate(names: String, listing: String) throws {
        let rows = names.split(separator: "\n", omittingEmptySubsequences: true)
        var unique = Set<String>()
        guard !rows.isEmpty, rows.count <= 10_000 else { throw NativeUpdateError.installation }
        for row in rows {
            let name = String(row), parts = name.split(separator: "/", omittingEmptySubsequences: false)
            guard name.hasPrefix("Knot Native Preview.app/"), !name.contains("\\"), !parts.contains(".."), !parts.contains("."),
                  parts.dropLast().allSatisfy({ !$0.isEmpty }),
                  name.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }),
                  unique.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw NativeUpdateError.installation }
        }
        var expandedBytes: Int64 = 0, entryCount = 0
        for row in listing.split(separator: "\n") {
            guard let first = row.first, ["-", "d", "l", "b", "c", "p", "s"].contains(first) else { continue }
            let fields = row.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard ["-", "d"].contains(first), fields.count >= 5, let size = Int64(fields[3]), size >= 0,
                  size <= 1024 * 1024 * 1024 - expandedBytes else { throw NativeUpdateError.installation }
            expandedBytes += size; entryCount += 1
        }
        guard entryCount == rows.count else { throw NativeUpdateError.installation }
    }
}

/// Prepared update and installed app always remain two complete directories.
/// Publish performs one kernel namespace exchange; there is no old->backup gap.
struct NativeUpdateTransaction {
    let destination: URL, replacement: URL
    private let installedIdentity: Identity, preparedIdentity: Identity, parentIdentity: Identity
    struct Identity: Equatable {
        let device: dev_t, inode: ino_t
        static func directory(_ path: URL, owned: Bool = true) throws -> Identity {
            var value = stat()
            guard path.standardizedFileURL.path == path.resolvingSymlinksInPath().path,
                  lstat(path.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR,
                  !owned || value.st_uid == geteuid() else { throw NativeUpdateError.installation }
            return Identity(device: value.st_dev, inode: value.st_ino)
        }
    }
    static func exchange(_ a: URL, _ b: URL) throws {
        guard renameatx_np(AT_FDCWD, a.path, AT_FDCWD, b.path, UInt32(RENAME_SWAP)) == 0 else { throw NativeUpdateError.installation }
    }
    static func probeAtomicExchange(in parent: URL) throws {
        let a = parent.appendingPathComponent(".knot-native-swap-probe-" + UUID().uuidString)
        let b = parent.appendingPathComponent(".knot-native-swap-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let ai = try Identity.directory(a), bi = try Identity.directory(b)
        try exchange(a, b)
        guard try Identity.directory(a) == bi, try Identity.directory(b) == ai else { throw NativeUpdateError.installation }
    }
    static func prepare(candidate: URL, destination: URL,
                        probe: (URL) throws -> Void = NativeUpdateTransaction.probeAtomicExchange,
                        onReplacement: (URL) -> Void = { _ in }, validate: (URL) throws -> Void) throws -> NativeUpdateTransaction {
        let parent = destination.deletingLastPathComponent()
        let installed = try Identity.directory(destination), parentIdentity = try Identity.directory(parent, owned: false)
        _ = try Identity.directory(candidate)
        try probe(parent)
        let replacement = parent.appendingPathComponent(".knot-native-update-" + UUID().uuidString + ".app")
        onReplacement(replacement)
        do {
            try FileManager.default.copyItem(at: candidate, to: replacement)
            try validate(replacement)
            let prepared = try Identity.directory(replacement)
            guard prepared.device == installed.device else { throw NativeUpdateError.installation }
            return Self(destination: destination, replacement: replacement, installedIdentity: installed,
                        preparedIdentity: prepared, parentIdentity: parentIdentity)
        } catch { try? FileManager.default.removeItem(at: replacement); throw error }
    }
    func publish(exchange: (URL, URL) throws -> Void = NativeUpdateTransaction.exchange) throws {
        guard try Identity.directory(destination) == installedIdentity,
              try Identity.directory(replacement) == preparedIdentity,
              try Identity.directory(destination.deletingLastPathComponent(), owned: false) == parentIdentity else { throw NativeUpdateError.installation }
        try exchange(destination, replacement)
    }
    func discardPreparedCopy() { try? FileManager.default.removeItem(at: replacement) }
}
