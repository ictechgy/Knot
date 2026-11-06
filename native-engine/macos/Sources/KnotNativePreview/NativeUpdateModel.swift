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
        do {
            let fresh = try NativeUpdateManifest.verify(Data(contentsOf: stage.appendingPathComponent("manifest.feed")), configuration: configuration, platform: "macos-arm64")
            guard fresh.build == manifest.build else { throw NativeUpdateError.invalid }
            try fresh.verifyFile(stage.appendingPathComponent("payload.zip"))
            let helper = stage.appendingPathComponent("KnotNativeUpdateHandoff")
            try FileManager.default.copyItem(at: executable, to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            guard let configURL = Bundle.main.url(forResource: "NativeUpdateConfig", withExtension: "txt") else { throw NativeUpdateError.unconfigured }
            try FileManager.default.copyItem(at: configURL, to: stage.appendingPathComponent("NativeUpdateConfig.txt"))
            let process = Process(); process.executableURL = helper
            process.arguments = ["--knot-native-update-v1", String(getpid()), Bundle.main.bundleURL.resolvingSymlinksInPath().path, stage.path]
            try process.run()
            pending = nil; available = false; stop(); beforeExit(); NSApp.terminate(nil)
        } catch { status = "안전하게 업데이트를 시작하지 못했습니다. 다시 확인해 주세요." }
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
        guard a.count == 5, let pid = Int32(a[2]), pid > 1 else { throw NativeUpdateError.installation }
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
        let rows = names.split(separator: "\n", omittingEmptySubsequences: true)
        guard !rows.isEmpty, rows.count <= 10_000, rows.allSatisfy({ row in
            let name = String(row), parts = name.split(separator: "/", omittingEmptySubsequences: false)
            return name.hasPrefix("Knot Native Preview.app/") && !name.contains("\\") && !parts.contains("..") &&
                name.utf8.allSatisfy({ $0 >= 32 && $0 != 127 })
        }) else { throw NativeUpdateError.installation }
        let listing = try command("/usr/bin/zipinfo", ["-l", package.path])
        var expandedBytes: Int64 = 0, entryCount = 0
        for row in listing.split(separator: "\n") {
            guard let first = row.first, ["-", "d", "l"].contains(first) else { continue }
            let fields = row.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard first != "l", fields.count >= 5, let size = Int64(fields[3]), size >= 0,
                  size <= 1024 * 1024 * 1024 - expandedBytes else { throw NativeUpdateError.installation }
            expandedBytes += size; entryCount += 1
        }
        guard entryCount == rows.count else { throw NativeUpdateError.installation }
        let extraction = stage.appendingPathComponent("expanded"); try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        _ = try command("/usr/bin/ditto", ["-x", "-k", package.path, extraction.path])
        let candidate = extraction.appendingPathComponent(app.lastPathComponent)
        guard let replacement = Bundle(url: candidate), replacement.bundleIdentifier == installed.bundleIdentifier,
              replacement.object(forInfoDictionaryKey: "KnotNativeVersion") as? String == manifest.version else { throw NativeUpdateError.installation }
        _ = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", candidate.path])
        let deadline = Date().addingTimeInterval(180)
        while kill(pid, 0) == 0 { guard Date() < deadline else { throw NativeUpdateError.installation }; Thread.sleep(forTimeInterval: 0.1) }
        // Stage beside the installed app so the rename publication remains on one filesystem.
        let sibling = app.deletingLastPathComponent().appendingPathComponent(".knot-native-update-" + UUID().uuidString + ".app")
        let backup = app.deletingLastPathComponent().appendingPathComponent(".knot-native-backup-" + UUID().uuidString + ".app")
        try FileManager.default.copyItem(at: candidate, to: sibling)
        try FileManager.default.moveItem(at: app, to: backup)
        do { try FileManager.default.moveItem(at: sibling, to: app) }
        catch { try? FileManager.default.moveItem(at: backup, to: app); try? FileManager.default.removeItem(at: sibling); throw error }
        _ = try command("/usr/bin/open", [app.path, "--args", "--knot-native-update-resume"])
        try? FileManager.default.removeItem(at: backup); try? FileManager.default.removeItem(at: stage)
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
