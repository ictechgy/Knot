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

@MainActor final class NativeUpdateModel: ObservableObject {
    @Published private(set) var status = "자동 업데이트 배포가 아직 구성되지 않았습니다."
    @Published private(set) var available = false
    @Published private(set) var checking = false
    let configured: Bool
    private let configuration: NativeUpdateConfiguration?
    private var pending: (NativeUpdateManifest, URL)?
    private var checks: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    init() {
        configuration = NativeUpdateConfiguration.load(); configured = configuration?.configured == true
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
    func stop() { checks?.cancel(); checks = nil; operation?.cancel(); operation = nil }
    func check() {
        guard configured, let configuration, !checking, !available else { return }
        checking = true; status = "업데이트를 확인하고 있습니다."
        operation = Task { [weak self] in
            var stage: URL?
            do {
                let directory = try Self.privateStage(); stage = directory
                let envelopeURL = try await Self.download(try NativeUpdateManifest.https(configuration.macFeed), maximum: 16_384, to: directory.appendingPathComponent("manifest.feed"))
                let envelope = try Data(contentsOf: envelopeURL)
                let manifest = try NativeUpdateManifest.verify(envelope, configuration: configuration, platform: "macos-arm64")
                let package = try await Self.download(manifest.url, maximum: manifest.bytes, to: directory.appendingPathComponent("payload.zip"))
                try manifest.verifyFile(package); try Task.checkCancellation()
                guard let self else { return }
                self.pending = (manifest, directory); self.available = true; self.checking = false
                self.status = "\(manifest.version) 준비 완료 · 설치 후 자동으로 다시 엽니다."
                stage = nil
            } catch NativeUpdateError.downgrade { self?.checking = false; self?.status = "현재 최신 버전을 사용하고 있습니다." }
            catch is CancellationError { self?.checking = false }
            catch { self?.checking = false; self?.status = "업데이트를 확인하지 못했습니다. 현재 버전은 계속 사용할 수 있습니다." }
            if let stage { try? FileManager.default.removeItem(at: stage) }
        }
    }
    func install(beforeExit: @escaping @MainActor () -> Void) {
        guard let (manifest, stage) = pending, !checking, let configuration,
              let executable = Bundle.main.executableURL, Bundle.main.bundleURL.pathExtension == "app",
              !Bundle.main.bundleURL.path.hasPrefix("/Volumes/"),
              FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path) else {
            status = "설치된 앱을 업데이트하려면 쓰기 가능한 Applications 폴더로 옮겨 주세요."; return
        }
        checking = true; status = "업데이트를 설치할 준비를 하고 있습니다."
        operation = Task { [weak self] in
            let pipe = Pipe(), process = Process()
            defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
            do {
                let fresh = try NativeUpdateManifest.verify(Data(contentsOf: stage.appendingPathComponent("manifest.feed")), configuration: configuration, platform: "macos-arm64")
                guard fresh.build == manifest.build else { throw NativeUpdateError.invalid }
                try fresh.verifyFile(stage.appendingPathComponent("payload.zip"))
                let helper = stage.appendingPathComponent("KnotNativeUpdateHandoff")
                try FileManager.default.copyItem(at: executable, to: helper)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
                guard let configURL = Bundle.main.url(forResource: "NativeUpdateConfig", withExtension: "txt") else { throw NativeUpdateError.unconfigured }
                try FileManager.default.copyItem(at: configURL, to: stage.appendingPathComponent("NativeUpdateConfig.txt"))
                let nonce = UUID().uuidString + UUID().uuidString
                process.executableURL = helper
                process.arguments = ["--knot-native-update-v1", String(getpid()), Bundle.main.bundleURL.resolvingSymlinksInPath().path, stage.path, nonce]
                process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
                try process.run()
                // Only the child owns the write end after launch. EOF then reports a
                // validation failure immediately instead of waiting for a timeout.
                try pipe.fileHandleForWriting.close()
                try await NativeUpdateAcknowledgement.wait(readDescriptor: pipe.fileHandleForReading.fileDescriptor,
                                                           expected: NativeUpdateAcknowledgement.receipt(nonce))
                try Task.checkCancellation()
                guard let self, process.isRunning else { throw NativeUpdateError.installation }
                self.pending = nil; self.available = false; self.checking = false
                self.checks?.cancel(); self.checks = nil
                beforeExit(); NSApp.terminate(nil)
            } catch {
                if process.isRunning { process.terminate() }
                // The existing app and window stay usable if preparation/READY fails.
                self?.checking = false
                self?.status = "업데이트 준비를 완료하지 못했습니다. 현재 앱은 계속 사용할 수 있습니다."
                for name in ["KnotNativeUpdateHandoff", "NativeUpdateConfig.txt"] {
                    try? FileManager.default.removeItem(at: stage.appendingPathComponent(name))
                }
            }
        }
    }
    private static func privateStage() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("knot-native-update-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    private static func download(_ url: URL, maximum: Int64, to target: URL) async throws -> URL {
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

/// Dispatch before creating any windows. This helper never initializes session/capture/file adapters.
enum NativeUpdateHandoff {
    static func runIfRequested() {
        let a = CommandLine.arguments
        guard a.count > 1, a[1] == "--knot-native-update-v1" else { return }
        do { try run(a); exit(0) } catch { exit(1) }
    }
    private static func run(_ a: [String]) throws {
        guard a.count == 6, let pid = Int32(a[2]), pid > 1, NativeUpdateAcknowledgement.validNonce(a[5]) else { throw NativeUpdateError.installation }
        let app = URL(fileURLWithPath: a[3]).standardizedFileURL, stage = URL(fileURLWithPath: a[4]).standardizedFileURL
        guard app.path == app.resolvingSymlinksInPath().path, app.lastPathComponent == "Knot Native Preview.app",
              stage.path == stage.resolvingSymlinksInPath().path, stage.lastPathComponent.hasPrefix("knot-native-update-"),
              stage.deletingLastPathComponent() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath(),
              let config = NativeUpdateConfiguration.load(stage.appendingPathComponent("NativeUpdateConfig.txt")), config.configured else { throw NativeUpdateError.installation }
        var info = stat()
        guard lstat(stage.path, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw NativeUpdateError.installation }
        let manifest = try NativeUpdateManifest.verify(Data(contentsOf: stage.appendingPathComponent("manifest.feed")), configuration: config, platform: "macos-arm64")
        let package = stage.appendingPathComponent("payload.zip"); try manifest.verifyFile(package)
        guard let installed = Bundle(url: app), installed.bundleIdentifier == "org.knot.native-preview",
              let installedVersion = installed.object(forInfoDictionaryKey: "KnotNativeVersion") as? String,
              try NativeUpdateManifest.versionBuild(installedVersion) < manifest.build else { throw NativeUpdateError.downgrade }
        let names = try command("/usr/bin/zipinfo", ["-1", package.path])
        let listing = try command("/usr/bin/zipinfo", ["-l", package.path])
        try NativeUpdateArchiveInventory.validate(names: names, listing: listing)
        let extraction = stage.appendingPathComponent("expanded"); try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        _ = try command("/usr/bin/ditto", ["-x", "-k", package.path, extraction.path])
        let candidate = extraction.appendingPathComponent(app.lastPathComponent)
        guard let replacement = Bundle(url: candidate), replacement.bundleIdentifier == installed.bundleIdentifier,
              replacement.object(forInfoDictionaryKey: "KnotNativeVersion") as? String == manifest.version else { throw NativeUpdateError.installation }
        _ = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", candidate.path])
        let transaction = try NativeUpdateTransaction.prepare(candidate: candidate, destination: app) { copied in
            guard let bundle = Bundle(url: copied), bundle.bundleIdentifier == installed.bundleIdentifier,
                  bundle.object(forInfoDictionaryKey: "KnotNativeVersion") as? String == manifest.version else { throw NativeUpdateError.installation }
            _ = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", copied.path])
        }
        var published = false
        defer { if !published { transaction.discardPreparedCopy() } }
        // Every validation and same-volume atomic-exchange capability check above
        // must finish before the parent is allowed to leave its working window.
        try FileHandle.standardOutput.write(contentsOf: NativeUpdateAcknowledgement.receipt(a[5]))
        let deadline = Date().addingTimeInterval(180)
        while kill(pid, 0) == 0 { guard Date() < deadline else { throw NativeUpdateError.installation }; Thread.sleep(forTimeInterval: 0.1) }
        try transaction.publish()
        published = true
        _ = try command("/usr/bin/open", [app.path, "--args", "--knot-native-update-resume"])
        // After exchange, replacement contains the old app. Retain it if launching
        // the new app fails; the canonical path always contains a complete app.
        transaction.discardPreparedCopy()
        try? FileManager.default.removeItem(at: stage)
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
                        validate: (URL) throws -> Void) throws -> NativeUpdateTransaction {
        let parent = destination.deletingLastPathComponent()
        let installed = try Identity.directory(destination), parentIdentity = try Identity.directory(parent, owned: false)
        _ = try Identity.directory(candidate)
        try probe(parent)
        let replacement = parent.appendingPathComponent(".knot-native-update-" + UUID().uuidString + ".app")
        try FileManager.default.copyItem(at: candidate, to: replacement)
        do {
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
