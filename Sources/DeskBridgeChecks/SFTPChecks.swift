import Foundation
import DeskBridgeCore
import Darwin

private struct SFTPCheckFailure: Error { let message: String }
private func sftpCheck(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SFTPCheckFailure(message: message) }
}

/// Synthetic in-memory SFTP peer. No executable, network, socket, user key or existing file is read.
private final class SFTPFixtureTransport: SFTPTransport, @unchecked Sendable {
    enum ListingMode { case normal, repeatedDots, paddedReplies, longPaths, largeDirectory }
    static let longParent = "/" + String(repeating: "p", count: 8_000)
    private let lock = NSLock()
    private var replies: [Data] = []
    private var files: [String: Data] = ["/files/한글 [draft].txt": Data((0..<140_123).map { UInt8($0 % 251) })]
    private var directories: Set<String> = ["/", "/files"]
    private var symlinks: Set<String> = ["/files/link"]
    private var handles: [Data: String] = [:]
    private var enumerated = Set<Data>()
    private var counter = 0
    private var stopped = false
    private var mismatch = false
    private var nextDirectoryStatus: UInt32?
    private var failNextClose = false
    private var nextReceiveFailure: (any Error)?
    private var readDirectoryRequests = 0
    private var readFileRequests = 0
    private var closed = false
    let version: UInt32
    let listingMode: ListingMode
    init(version: UInt32 = 3, listingMode: ListingMode = .normal) {
        self.version = version; self.listingMode = listingMode
        if listingMode == .longPaths { directories.insert(Self.longParent) }
    }
    func contents(_ path: String) -> Data? { lock.lock(); defer { lock.unlock() }; return files[path] }
    func insertSyntheticFile(_ name: String) { lock.lock(); defer { lock.unlock() }; files["/files/" + name] = Data() }
    func injectMismatchedID() { lock.lock(); mismatch = true; lock.unlock() }
    func injectDirectoryStatus(_ code: UInt32) { lock.lock(); nextDirectoryStatus = code; lock.unlock() }
    func injectCloseFailure() { lock.lock(); failNextClose = true; lock.unlock() }
    func injectReceiveFailure(_ error: any Error) { lock.lock(); nextReceiveFailure = error; lock.unlock() }
    var directoryRequestCount: Int { lock.lock(); defer { lock.unlock() }; return readDirectoryRequests }
    var fileReadRequestCount: Int { lock.lock(); defer { lock.unlock() }; return readFileRequests }
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    func send(_ payload: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { throw SFTPError.cancelled }
        var request = SFTPBinaryReader(payload)
        let type = try request.byte()
        if type == 1 {
            _ = try request.uint32(); var reply = SFTPBinaryWriter(); reply.byte(2); reply.uint32(version)
            replies.append(reply.data); return
        }
        let rawID = try request.uint32(), id = mismatch ? rawID &+ 1 : rawID
        mismatch = false
        func status(_ code: UInt32, _ text: String = "fixture") -> Data {
            var reply = SFTPBinaryWriter(); reply.byte(101); reply.uint32(id); reply.uint32(code); reply.string(text); reply.string("")
            return reply.data
        }
        func attrs(_ path: String, into reply: inout SFTPBinaryWriter) {
            reply.uint32(1 | 4 | 8); reply.uint64(UInt64(files[path]?.count ?? 0))
            reply.uint32(directories.contains(path) ? 0o040755 : symlinks.contains(path) ? 0o120777 : 0o100644)
            reply.uint32(100); reply.uint32(100)
        }
        func attributeReply(_ path: String) -> Data {
            guard files[path] != nil || directories.contains(path) || symlinks.contains(path) else { return status(2) }
            var reply = SFTPBinaryWriter(); reply.byte(105); reply.uint32(id); attrs(path, into: &reply); return reply.data
        }
        switch type {
        case 7:
            replies.append(attributeReply(try request.string()))
        case 8:
            let handle = try request.bytes(); replies.append(handles[handle].map(attributeReply) ?? status(9))
        case 3, 11:
            let path = try request.string()
            if type == 3 {
                let flags = try request.uint32(); _ = try request.uint32()
                if flags & 0x20 != 0 && files[path] != nil { replies.append(status(4)); return }
                if flags & 8 != 0 { files[path] = Data() }
                guard files[path] != nil else { replies.append(status(2)); return }
            } else if !directories.contains(path) { replies.append(status(2)); return }
            counter += 1; let handle = Data("handle-\(counter)".utf8); handles[handle] = path
            var reply = SFTPBinaryWriter(); reply.byte(102); reply.uint32(id); reply.bytes(handle); replies.append(reply.data)
        case 4:
            if failNextClose { failNextClose = false; throw SFTPError.timedOut }
            let handle = try request.bytes(); handles.removeValue(forKey: handle); replies.append(status(0))
        case 12:
            readDirectoryRequests += 1
            if let code = nextDirectoryStatus { nextDirectoryStatus = nil; replies.append(status(code)); return }
            let handle = try request.bytes()
            guard let parent = handles[handle] else { replies.append(status(9)); return }
            if listingMode != .normal {
                let count: Int, rounds: Int
                switch listingMode {
                case .repeatedDots: count = 4096; rounds = 26
                case .paddedReplies: count = 32; rounds = 136
                case .longPaths: count = 512; rounds = 16
                case .largeDirectory: count = 1000; rounds = 10
                case .normal: fatalError("handled above")
                }
                guard readDirectoryRequests <= rounds else { replies.append(status(1)); return }
                var reply = SFTPBinaryWriter(); reply.byte(104); reply.uint32(id); reply.uint32(UInt32(count))
                let padding = listingMode == .paddedReplies ? Data(repeating: 120, count: 16_384) : Data()
                for index in 0..<count {
                    let name = listingMode == .repeatedDots ? (index.isMultiple(of: 2) ? "." : "..") : "entry-\(readDirectoryRequests)-\(index)"
                    reply.string(name); reply.bytes(padding); attrs("fixture-file", into: &reply)
                }
                replies.append(reply.data); return
            }
            guard enumerated.insert(handle).inserted else { replies.append(status(1)); return }
            let prefix = parent == "/" ? "/" : parent + "/"
            let paths = (Set(files.keys).union(directories).union(symlinks)).filter {
                $0.hasPrefix(prefix) && $0.count > prefix.count && !$0.dropFirst(prefix.count).contains("/")
            }.sorted()
            var reply = SFTPBinaryWriter(); reply.byte(104); reply.uint32(id); reply.uint32(UInt32(paths.count + 2))
            for name in [".", ".."] { reply.string(name); reply.string(""); attrs(parent, into: &reply) }
            for path in paths { reply.string(String(path.dropFirst(prefix.count))); reply.string(""); attrs(path, into: &reply) }
            // Empty directories use EOF, which is what an actual server may return.
            replies.append(paths.isEmpty ? status(1) : reply.data)
        case 5:
            readFileRequests += 1
            let handle = try request.bytes(), offset = try request.uint64(), length = try request.uint32()
            guard let path = handles[handle], let data = files[path] else { replies.append(status(9)); return }
            guard offset < data.count else { replies.append(status(1)); return }
            let end = min(data.count, Int(offset) + min(Int(length), 17_000))
            var reply = SFTPBinaryWriter(); reply.byte(103); reply.uint32(id); reply.bytes(data.subdata(in: Int(offset)..<end))
            replies.append(reply.data)
        case 6:
            let handle = try request.bytes(), offset = try request.uint64(), data = try request.bytes()
            guard let path = handles[handle], var contents = files[path], offset == contents.count else { replies.append(status(9)); return }
            contents.append(data); files[path] = contents; replies.append(status(0))
        case 14:
            let path = try request.string(); _ = try request.uint32()
            if directories.contains(path) || files[path] != nil { replies.append(status(4)) }
            else { directories.insert(path); replies.append(status(0)) }
        case 13:
            let path = try request.string(); files.removeValue(forKey: path); replies.append(status(0))
        case 15:
            let path = try request.string(); directories.remove(path); replies.append(status(0))
        case 18:
            let source = try request.string(), target = try request.string()
            guard source.caseInsensitiveCompare(target) != .orderedSame,
                  !files.keys.contains(where: { $0.caseInsensitiveCompare(target) == .orderedSame }),
                  let data = files.removeValue(forKey: source) else { replies.append(status(4)); return }
            files[target] = data; replies.append(status(0))
        default:
            replies.append(status(8))
        }
    }
    func receive() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { throw SFTPError.cancelled }
        if let failure = nextReceiveFailure { nextReceiveFailure = nil; throw failure }
        guard !replies.isEmpty else { throw SFTPError.protocolViolation("fixture reply queue empty") }
        return replies.removeFirst()
    }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    func close() { lock.lock(); stopped = true; closed = true; lock.unlock() }
}

private struct SFTPSyntheticTransportFailure: Error, LocalizedError {
    var errorDescription: String? { "synthetic transport failure" }
}

private final class SFTPProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TransferProgress] = []
    func record(_ value: TransferProgress) { lock.lock(); values.append(value); lock.unlock() }
    func snapshot() -> [TransferProgress] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class SFTPCommitCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private weak var client: SFTPClient?
    func bind(_ value: SFTPClient) { lock.lock(); client = value; lock.unlock() }
    func cancel() { lock.lock(); let value = client; lock.unlock(); value?.cancel() }
}

@discardableResult
public func runSFTPChecks() async throws -> Int {
    var checks = try await runSFTPSSHDiagnosticsChecks()
    let untrusted = "synthetic-server-path /private/fixture <script>unsafe</script>"
    for error in [SFTPError.remoteStatus(2, untrusted), .remoteStatus(3, untrusted), .remoteStatus(99, untrusted),
                  .protocolViolation(untrusted), .connectionLost(untrusted), .invalidPath(untrusted),
                  .invalidConfiguration(untrusted), .localIO(untrusted)] {
        try sftpCheck(!error.localizedDescription.contains(untrusted) && !error.localizedDescription.contains("/private/fixture"),
                      "untrusted SFTP response detail escaped into UI guidance"); checks += 1
    }
    try sftpCheck(SFTPError.remoteStatus(2, untrusted).localizedDescription.contains("찾지 못했습니다") &&
                  SFTPError.remoteStatus(3, untrusted).localizedDescription.contains("접근 권한") &&
                  SFTPError.remoteStatus(99, untrusted).localizedDescription.contains("99"),
                  "fixed SFTP status guidance lost its actionable code meaning"); checks += 1
    try sftpCheck(SFTPError.sshConnectionFailure(.authenticationRejected).localizedDescription.contains("개인 키") &&
                  SFTPError.sshConnectionFailure(.authenticationRejected).localizedDescription.contains("공개 키"),
                  "SSH authentication guidance must cover both Mac selection and Windows registration"); checks += 1
    let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("DeskBridge-SFTP-Checks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: fixtureRoot) }
    var key = SFTPBinaryWriter(); key.string("ssh-ed25519"); key.bytes(Data(repeating: 7, count: 32))
    let publicKey = "ssh-ed25519 " + key.data.base64EncodedString() + " synthetic-fixture"
    let config = try SFTPConnectionConfiguration(host: "synthetic.invalid", username: "deskbridge-transfer", identityFile: fixtureRoot.appendingPathComponent("fake identity"), pinnedHostPublicKey: publicKey)
    try sftpCheck(config.hostKeyFingerprint.hasPrefix("SHA256:"), "pin fingerprint missing"); checks += 1
    let args = config.sshArguments(knownHostsFile: fixtureRoot.appendingPathComponent("folder with spaces/known_hosts"))
    try sftpCheck(args.contains("StrictHostKeyChecking=yes") && args.contains("GlobalKnownHostsFile=/dev/null") && args.contains("IdentitiesOnly=yes") && args.contains("BatchMode=yes"), "strict SSH options missing"); checks += 1
    try sftpCheck(args.suffix(3) == ["--", "synthetic.invalid", "sftp"] && args.contains("ClearAllForwardings=yes") && args.contains("ForwardAgent=no") && args.contains("/dev/null"), "SSH subsystem or isolation arguments changed"); checks += 1
    for host in ["-oProxyCommand=evil", "host;command", "host\nHost *", "::garbage"] {
        do { _ = try SFTPConnectionConfiguration(host: host, username: "user", identityFile: config.identityFile, pinnedHostPublicKey: publicKey); throw SFTPCheckFailure(message: "host injection accepted") }
        catch is SFTPCheckFailure { throw SFTPCheckFailure(message: "host injection accepted") }
        catch { checks += 1 }
    }
    var integers = SFTPBinaryWriter(); integers.uint64(UInt64.max); integers.string("한글 [*] \" $x")
    var reader = SFTPBinaryReader(integers.data)
    let number = try reader.uint64(), text = try reader.string()
    try sftpCheck(number == UInt64.max && text == "한글 [*] \" $x", "binary codec changed filenames"); checks += 1
    do { var bad = SFTPBinaryReader(Data([0xff, 0xff, 0xff, 0xff])); _ = try bad.bytes(); throw SFTPCheckFailure(message: "oversized string accepted") }
    catch is SFTPCheckFailure { throw SFTPCheckFailure(message: "oversized string accepted") }
    catch { checks += 1 }

    let peer = SFTPFixtureTransport(), client = SFTPClient(configuration: config, transportFactory: { peer })
    let unsupportedNames = ["hidden\u{200B}.txt", "invoice\u{202E}cod.exe", "family👩\u{200D}👧.txt"]
    for name in unsupportedNames { peer.insertSyntheticFile(name) }
    try await client.connect()
    let entries = try await client.list(path: "/files")
    try sftpCheck(entries.contains { $0.name == "한글 [draft].txt" && $0.kind == .file && $0.size == 140_123 }, "structured directory listing lost a filename"); checks += 1
    try sftpCheck(!entries.contains { $0.name == "." || $0.name == ".." }, "ordinary dot entries were retained"); checks += 1
    try sftpCheck(entries.count == 2 && !entries.contains { unsupportedNames.contains($0.name) } && !peer.isClosed,
                  "unsupported names blocked safe siblings or escaped listing filtering"); checks += 1
    do { _ = try await client.list(path: "/files/../escape"); throw SFTPCheckFailure(message: "traversal accepted") }
    catch is SFTPCheckFailure { throw SFTPCheckFailure(message: "traversal accepted") }
    catch { checks += 1 }
    let destination = fixtureRoot.appendingPathComponent("received 한글.txt"), progress = SFTPProgressRecorder()
    try await client.download(remotePath: "/files/한글 [draft].txt", destinationURL: destination, progress: { progress.record($0) })
    let received = try Data(contentsOf: destination)
    let quarantineSize = getxattr(destination.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
    try sftpCheck(quarantineSize > 0, "download was published without quarantine metadata"); checks += 1
    try sftpCheck(received == peer.contents("/files/한글 [draft].txt"), "short-read download corrupted data"); checks += 1
    let values = progress.snapshot()
    try sftpCheck(values.count > 3 && values.last?.bytesTransferred == 140_123 && values.last?.fractionCompleted == 1, "download byte progress incorrect"); checks += 1
    let readsBeforeCollision = peer.fileReadRequestCount
    do { try await client.download(remotePath: "/files/한글 [draft].txt", destinationURL: destination); throw SFTPCheckFailure(message: "existing destination replaced") }
    catch SFTPError.destinationExists { checks += 1 }
    let contentsAfterCollision = try Data(contentsOf: destination)
    try sftpCheck(contentsAfterCollision == received, "collision changed existing contents"); checks += 1
    let dangling = fixtureRoot.appendingPathComponent("existing-dangling-link")
    try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: fixtureRoot.appendingPathComponent("never-created-target").path)
    do { try await client.download(remotePath: "/files/한글 [draft].txt", destinationURL: dangling); throw SFTPCheckFailure(message: "dangling destination link accepted") }
    catch SFTPError.destinationExists { checks += 1 }
    try sftpCheck(peer.fileReadRequestCount == readsBeforeCollision, "existing destinations were detected only after remote file reads"); checks += 1
    do { try await client.download(remotePath: "/files/link", destinationURL: fixtureRoot.appendingPathComponent("link")); throw SFTPCheckFailure(message: "symlink followed") }
    catch SFTPError.unsupportedFile { checks += 1 }

    let upload = fixtureRoot.appendingPathComponent("hello [x] $value.txt")
    let uploadData = Data((0..<180_040).map { UInt8($0 % 239) }); try uploadData.write(to: upload)
    let uploadedPath = try await client.upload(localURL: upload)
    try sftpCheck(uploadedPath.hasPrefix("/files/deskbridge-") && uploadedPath.hasSuffix("/hello [x] $value.txt") && peer.contents(uploadedPath) == uploadData, "binary upload or unique destination incorrect"); checks += 1
    let secondUpload = try await client.upload(localURL: upload)
    try sftpCheck(secondUpload != uploadedPath && peer.contents(uploadedPath) == uploadData, "repeated upload overwrote prior file"); checks += 1
    let decomposedName = (String(repeating: "한", count: 81) + ".txt").decomposedStringWithCanonicalMapping
    let decomposedUpload = fixtureRoot.appendingPathComponent(decomposedName)
    try uploadData.write(to: decomposedUpload)
    let canonicalUpload = try await client.upload(localURL: decomposedUpload)
    let canonicalSuffix = "/" + decomposedName.precomposedStringWithCanonicalMapping
    try sftpCheck(Array(canonicalUpload.utf8).suffix(canonicalSuffix.utf8.count).elementsEqual(canonicalSuffix.utf8) && peer.contents(canonicalUpload) == uploadData,
                  "decomposed Korean upload names must use canonical composed Windows filenames"); checks += 1
    for name in ["invoice\u{202E}cod.exe", "hidden\u{200B}.txt"] {
        let obscured = fixtureRoot.appendingPathComponent(name); try Data([1]).write(to: obscured)
        do { _ = try await client.upload(localURL: obscured); throw SFTPCheckFailure(message: "format scalar filename accepted") }
        catch SFTPError.invalidPath { checks += 1 }
    }
    for download in [false, true] {
        let committedPeer = SFTPFixtureTransport(), cancellation = SFTPCommitCancellation()
        let committedClient = SFTPClient(configuration: config, transferCommitted: { cancellation.cancel() },
                                         transportFactory: { committedPeer })
        cancellation.bind(committedClient)
        try await committedClient.connect()
        if download {
            let target = fixtureRoot.appendingPathComponent("late-cancel-committed.txt")
            try await committedClient.download(remotePath: "/files/한글 [draft].txt", destinationURL: target)
            let bytes = try Data(contentsOf: target)
            try sftpCheck(bytes == committedPeer.contents("/files/한글 [draft].txt"), "late cancel lost committed download result")
        } else {
            let remote = try await committedClient.upload(localURL: upload)
            try sftpCheck(committedPeer.contents(remote) == uploadData, "late cancel lost committed upload result")
        }
        checks += 1
        do { _ = try await committedClient.list(); throw SFTPCheckFailure(message: "late cancel retained a broken transport") }
        catch SFTPError.disconnected { checks += 1 }
        await committedClient.disconnect()
    }
    for name in [".upload.part", ".UPLOAD.PART"] {
        let special = fixtureRoot.appendingPathComponent(name), data = Data("original staging-like name \(name)".utf8)
        try data.write(to: special)
        let path = try await client.upload(localURL: special)
        try sftpCheck(path.hasSuffix("/" + name) && peer.contents(path) == data, "staging basename collided with original Windows filename"); checks += 1
    }
    for name in ["CON.txt", "NUL .txt", "nul  .TXT", "COM1 .log", "LPT¹ .txt"] {
        let reserved = fixtureRoot.appendingPathComponent(name); try Data([1]).write(to: reserved)
        do { _ = try await client.upload(localURL: reserved); throw SFTPCheckFailure(message: "Windows reserved filename accepted: " + name) }
        catch SFTPError.invalidPath { checks += 1 }
    }
    let allowedName = fixtureRoot.appendingPathComponent("NUL safe.txt")
    let allowedBytes = Data("synthetic non-reserved name".utf8); try allowedBytes.write(to: allowedName)
    let allowedPath = try await client.upload(localURL: allowedName)
    try sftpCheck(allowedPath.hasSuffix("/NUL safe.txt") && peer.contents(allowedPath) == allowedBytes,
                  "DOS device validation rejected an ordinary filename with spaces"); checks += 1
    let fifo = fixtureRoot.appendingPathComponent("synthetic-source-fifo")
    guard mkfifo(fifo.path, 0o600) == 0 else { throw SFTPCheckFailure(message: "cannot create synthetic upload FIFO") }
    let rescue = armSyntheticFIFORescue(fifo), fifoStart = ProcessInfo.processInfo.systemUptime
    var fifoRefused = false
    do { _ = try await client.upload(localURL: fifo) } catch SFTPError.unsupportedFile { fifoRefused = true }
    let fifoElapsed = ProcessInfo.processInfo.systemUptime - fifoStart
    await withCheckedContinuation { continuation in
        rescue.notify(queue: .global()) { continuation.resume() }
    }
    try sftpCheck(fifoRefused && fifoElapsed < 0.25, "upload FIFO open waited for a writer before fstat"); checks += 1
    peer.injectMismatchedID()
    do { _ = try await client.list(path: "/files"); throw SFTPCheckFailure(message: "response identifier mismatch ignored") }
    catch SFTPError.protocolViolation { checks += 1 }
    await client.disconnect()

    let idlePeer = SFTPFixtureTransport(), idleClient = SFTPClient(configuration: config, transportFactory: { idlePeer })
    try await idleClient.connect()
    idleClient.cancel()
    let idleListing = try await idleClient.list(path: "/files")
    try sftpCheck(idleListing.contains { $0.name == "한글 [draft].txt" }, "idle cancel killed a usable connection"); checks += 1
    idleClient.revoke()
    do { _ = try await idleClient.list(path: "/files"); throw SFTPCheckFailure(message: "terminal revocation retained idle transport") }
    catch SFTPError.cancelled { checks += 1 }
    await idleClient.disconnect()
    let pipe = try SFTPPipeFixture(timeout: 30); defer { pipe.close() }
    // Actual production packet framer, fresh anonymous pipes, inert VERSION response.
    try pipe.incoming.fileHandleForWriting.write(contentsOf: Data([0, 0, 0, 5, 2, 0, 0, 0, 3]))
    let pipeClient = SFTPClient(configuration: config, transportFactory: { pipe.framer })
    try await pipeClient.connect()
    pipeClient.cancel()  // Idle operation cancel deliberately preserves this transport.
    let blockedList = Task.detached { try await pipeClient.list(path: "/files") }
    try pipe.waitForPendingIO()
    let revokedAt = DispatchTime.now().uptimeNanoseconds
    pipeClient.revoke()
    do { _ = try await blockedList.value; throw SFTPCheckFailure(message: "terminal revoke left pipe read blocked") }
    catch SFTPError.cancelled {
        try sftpCheck(DispatchTime.now().uptimeNanoseconds - revokedAt < 1_000_000_000, "terminal revoke waited for packet timeout"); checks += 1
    }
    await pipeClient.disconnect()
    let latePeer = SFTPFixtureTransport(), entered = DispatchSemaphore(value: 0), releaseFactory = DispatchSemaphore(value: 0)
    let lateClient = SFTPClient(configuration: config, transportFactory: {
        entered.signal()
        guard releaseFactory.wait(timeout: .now() + 2) == .success else { throw SFTPError.timedOut }
        return latePeer
    })
    let lateConnect = Task.detached { try await lateClient.connect() }
    func factoryEntered() -> Bool { entered.wait(timeout: .now() + 2) == .success }
    guard factoryEntered() else { throw SFTPCheckFailure(message: "synthetic factory did not start") }
    lateClient.revoke(); releaseFactory.signal()
    do { try await lateConnect.value; throw SFTPCheckFailure(message: "late factory escaped connection revocation") }
    catch SFTPError.cancelled { checks += 1 }
    await lateClient.disconnect()
    let cancelledPeer = SFTPFixtureTransport(), cancelClient = SFTPClient(configuration: config, transportFactory: { cancelledPeer })
    try await cancelClient.connect()
    let cancelledDestination = fixtureRoot.appendingPathComponent("cancelled.txt")
    do {
        try await cancelClient.download(remotePath: "/files/한글 [draft].txt", destinationURL: cancelledDestination) {
            if $0.bytesTransferred > 0 { cancelClient.cancel() }
        }
        throw SFTPCheckFailure(message: "cancelled download completed")
    } catch SFTPError.cancelled { checks += 1 }
    try sftpCheck(!FileManager.default.fileExists(atPath: cancelledDestination.path), "cancelled partial became final"); checks += 1
    let residue = try FileManager.default.contentsOfDirectory(at: fixtureRoot, includingPropertiesForKeys: nil)
    try sftpCheck(!residue.contains { $0.lastPathComponent.hasPrefix(".deskbridge-") && $0.lastPathComponent.hasSuffix(".part") }, "download partial was not cleaned up"); checks += 1
    await cancelClient.disconnect()
    let oldPeer = SFTPFixtureTransport(version: 2), oldClient = SFTPClient(configuration: config, transportFactory: { oldPeer })
    do { try await oldClient.connect(); throw SFTPCheckFailure(message: "wrong protocol version accepted") }
    catch SFTPError.protocolViolation { checks += 1 }
    await oldClient.disconnect()

    // Each hostile peer terminates by itself: reverting a budget must produce a
    // finite failing check rather than hanging the check executable.
    let budgets: [(SFTPFixtureTransport.ListingMode, String, String, Int)] = [
        (.repeatedDots, "/files", "directory entry limit exceeded", 25),
        (.paddedReplies, "/files", "directory reply byte limit exceeded", 128),
        (.longPaths, SFTPFixtureTransport.longParent, "directory path byte limit exceeded", 9),
    ]
    for (mode, path, expectedReason, maximumRequests) in budgets {
        let peer = SFTPFixtureTransport(listingMode: mode)
        let client = SFTPClient(configuration: config, transportFactory: { peer })
        try await client.connect()
        do { _ = try await client.list(path: path); throw SFTPCheckFailure(message: "unbounded listing accepted: \(expectedReason)") }
        catch SFTPError.protocolViolation(let reason) {
            try sftpCheck(reason == expectedReason, "listing stopped for the wrong budget: \(reason)"); checks += 1
        }
        try sftpCheck(peer.directoryRequestCount <= maximumRequests && peer.isClosed, "listing budget did not bound peer work and close the session"); checks += 1
        do { _ = try await client.list(path: "/files"); throw SFTPCheckFailure(message: "listing budget left a reusable session") }
        catch SFTPError.disconnected { checks += 1 }
    }
    let largePeer = SFTPFixtureTransport(listingMode: .largeDirectory)
    let largeClient = SFTPClient(configuration: config, transportFactory: { largePeer })
    try await largeClient.connect()
    let largeDirectory = try await largeClient.list(path: "/files")
    try sftpCheck(largeDirectory.count == 10_000 && !largePeer.isClosed, "ordinary multi-response directory was rejected"); checks += 1
    await largeClient.disconnect()

    // This is the same typed connection policy consumed by FilesModel.
    for error: any Error in [SFTPError.protocolViolation("fixture"), SFTPError.disconnected,
                             SFTPError.cancelled, SFTPError.timedOut, SFTPError.targetChanged, CancellationError(),
                             SFTPError.remoteStatus(6, "fixture"), SFTPError.remoteStatus(7, "fixture")] {
        try sftpCheck(SFTPError.requiresReconnect(after: error), "terminal failure did not require reconnect"); checks += 1
    }
    for error in [SFTPError.invalidPath("fixture"), .unsupportedFile, .destinationExists, .sourceChanged, .localIO("fixture"),
                  .remoteStatus(2, "fixture"), .remoteStatus(3, "fixture"), .remoteStatus(4, "fixture")] {
        try sftpCheck(!SFTPError.requiresReconnect(after: error), "recoverable file error required reconnect"); checks += 1
    }
    for code: UInt32 in [2, 3, 6, 7] {
        let peer = SFTPFixtureTransport(), client = SFTPClient(configuration: config, transportFactory: { peer })
        try await client.connect(); peer.injectDirectoryStatus(code)
        do { _ = try await client.list(path: "/files"); throw SFTPCheckFailure(message: "remote error was ignored") }
        catch SFTPError.remoteStatus(let actual, _) { try sftpCheck(actual == code, "remote status changed"); checks += 1 }
        if code == 2 || code == 3 {
            let recovered = try await client.list(path: "/files")
            try sftpCheck(!recovered.isEmpty && !peer.isClosed, "recoverable READDIR status discarded the connection"); checks += 1
        } else {
            try sftpCheck(peer.isClosed, "terminal remote status did not close the transport"); checks += 1
            do { _ = try await client.list(path: "/files"); throw SFTPCheckFailure(message: "terminal remote status left a reusable session") }
            catch SFTPError.disconnected { checks += 1 }
        }
        await client.disconnect()
    }
    for failure: any Error in [SFTPError.disconnected, SFTPError.timedOut, SFTPError.cancelled,
                              SFTPError.sshConnectionFailure(.hostKeyVerificationFailed),
                              SFTPError.sshConnectionFailure(.authenticationRejected),
                              SFTPError.sshConnectionFailure(.connectionRefused),
                              SFTPError.sshConnectionFailure(.networkUnavailable), SFTPSyntheticTransportFailure()] {
        let peer = SFTPFixtureTransport(), client = SFTPClient(configuration: config, transportFactory: { peer })
        try await client.connect(); peer.injectReceiveFailure(failure)
        do { _ = try await client.list(path: "/files"); throw SFTPCheckFailure(message: "transport failure was ignored") }
        catch is SFTPCheckFailure { throw SFTPCheckFailure(message: "transport failure was ignored") }
        catch {
            try sftpCheck(SFTPError.requiresReconnect(after: error) && peer.isClosed, "transport failure did not surface a terminal connection error"); checks += 1
            if failure is SFTPSyntheticTransportFailure {
                try sftpCheck((error as? SFTPError) == .connectionLost("synthetic transport failure"), "transport failure lost its typed original reason"); checks += 1
            }
            if let expected = failure as? SFTPError {
                try sftpCheck(error as? SFTPError == expected, "typed SSH failure guidance was masked by generic session cleanup"); checks += 1
            }
        }
        do { _ = try await client.list(path: "/files"); throw SFTPCheckFailure(message: "transport failure retained a stale session") }
        catch SFTPError.disconnected { checks += 1 }
    }
    let closePeer = SFTPFixtureTransport(), closeClient = SFTPClient(configuration: config, transportFactory: { closePeer })
    try await closeClient.connect(); closePeer.injectCloseFailure()
    do { _ = try await closeClient.list(path: "/files"); throw SFTPCheckFailure(message: "cleanup transport failure reported a healthy connection") }
    catch SFTPError.timedOut { checks += 1 }
    try sftpCheck(closePeer.isClosed, "failed cleanup did not close the transport"); checks += 1
    let disconnectPeer = SFTPFixtureTransport(), disconnectClient = SFTPClient(configuration: config, transportFactory: { disconnectPeer })
    try await disconnectClient.connect()
    let cancelledCleanup = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        await disconnectClient.disconnect()
    }
    await cancelledCleanup.value
    try sftpCheck(disconnectPeer.isClosed, "a cancelled caller skipped transport cleanup"); checks += 1
    return checks
}

/// New anonymous pipes exercise the exact framer used by the production SSH transport.
private final class SFTPPipeFixture: @unchecked Sendable {
    let outgoing = Pipe()
    let incoming = Pipe()
    let framer: SFTPPipeFramer
    init(timeout: TimeInterval = 1) throws {
        framer = try SFTPPipeFramer(input: outgoing.fileHandleForWriting, output: incoming.fileHandleForReading, packetTimeout: timeout)
    }
    func close() {
        framer.close()
        try? outgoing.fileHandleForReading.close(); try? incoming.fileHandleForWriting.close()
    }
    deinit { close() }
    func waitForPendingIO() throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while !framer.hasPendingIO {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw SFTPCheckFailure(message: "pipe worker did not reach I/O wait") }
            usleep(500)
        }
    }
}

@discardableResult
public func runSFTPPipeChecks() async throws -> Int {
    var checks = 0
    do {
        let fixture = try SFTPPipeFixture(); defer { fixture.close() }
        try fixture.framer.send(Data([11, 22, 33]))
        var ready = pollfd(fd: fixture.outgoing.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&ready, 1, 1000) > 0 else { throw SFTPCheckFailure(message: "framed send produced no bytes") }
        let actual = try fixture.outgoing.fileHandleForReading.read(upToCount: 7)
        try sftpCheck(actual == Data([0, 0, 0, 3, 11, 22, 33]), "production frame length prefix incorrect"); checks += 1
        let descriptors = [fixture.outgoing.fileHandleForWriting.fileDescriptor, fixture.incoming.fileHandleForReading.fileDescriptor]
        try sftpCheck(descriptors.allSatisfy { fcntl($0, F_GETFD) & FD_CLOEXEC != 0 && fcntl($0, F_GETFL) & O_NONBLOCK != 0 }, "framer descriptors can leak across exec or block outside poll"); checks += 1
    }
    do {
        let fixture = try SFTPPipeFixture(); defer { fixture.close() }
        let payload = Data((0..<513).map { UInt8($0 % 251) })
        var frame = SFTPBinaryWriter(); frame.uint32(UInt32(payload.count))
        let bytes = frame.data + payload
        let receiver = Task.detached { try fixture.framer.receive() }
        let writer = Task.detached {
            for byte in bytes.prefix(4) {
                try fixture.incoming.fileHandleForWriting.write(contentsOf: Data([byte])); usleep(1000)
            }
            for start in stride(from: 4, to: bytes.count, by: 17) {
                try fixture.incoming.fileHandleForWriting.write(contentsOf: bytes.subdata(in: start..<min(start + 17, bytes.count)))
                usleep(500)
            }
        }
        let received = try await receiver.value; try await writer.value
        try sftpCheck(received == payload, "fragmented production frame corrupted payload"); checks += 1
    }
    for header in [Data([0, 0x10, 0, 1]), Data([0, 0, 0, 0])] {
        let fixture = try SFTPPipeFixture(); defer { fixture.close() }
        try fixture.incoming.fileHandleForWriting.write(contentsOf: header)
        do { _ = try fixture.framer.receive(); throw SFTPCheckFailure(message: "invalid wire frame length accepted") }
        catch SFTPError.protocolViolation { checks += 1 }
    }
    for truncated in [Data([0, 0]), Data([0, 0, 0, 5, 1, 2]), Data()] {
        let fixture = try SFTPPipeFixture(); defer { fixture.close() }
        try fixture.incoming.fileHandleForWriting.write(contentsOf: truncated)
        try fixture.incoming.fileHandleForWriting.close()
        do { _ = try fixture.framer.receive(); throw SFTPCheckFailure(message: "truncated wire frame or EOF accepted") }
        catch SFTPError.disconnected { checks += 1 }
    }
    do {
        let fixture = try SFTPPipeFixture(timeout: 1.2); defer { fixture.close() }
        try fixture.incoming.fileHandleForWriting.write(contentsOf: Data([0, 0]))
        let receiver = Task.detached { try fixture.framer.receive() }
        let writer = Task.detached {
            usleep(350_000)
            try fixture.incoming.fileHandleForWriting.write(contentsOf: Data([0, 1, 42]))
        }
        let received = try await receiver.value; try await writer.value
        try sftpCheck(received == Data([42]), "poll cancellation slice shortened the real packet deadline"); checks += 1
    }
    do {
        let fixture = try SFTPPipeFixture(timeout: 0.025); defer { fixture.close() }
        try fixture.incoming.fileHandleForWriting.write(contentsOf: Data([0, 0]))
        let started = DispatchTime.now().uptimeNanoseconds
        do { _ = try fixture.framer.receive(); throw SFTPCheckFailure(message: "partial header did not time out") }
        catch SFTPError.timedOut { checks += 1 }
        try sftpCheck(DispatchTime.now().uptimeNanoseconds - started < 2_000_000_000, "pipe timeout was not bounded"); checks += 1
    }
    do {
        let fixture = try SFTPPipeFixture(timeout: 0.025); defer { fixture.close() }
        do { try fixture.framer.send(Data(repeating: 1, count: SFTPPipeFramer.maximumPacketBytes)); throw SFTPCheckFailure(message: "undrained output pipe did not time out") }
        catch SFTPError.timedOut { checks += 1 }
    }
    do {
        let fixture = try SFTPPipeFixture(timeout: 2); defer { fixture.close() }
        let receiver = Task.detached { try fixture.framer.receive() }
        try fixture.waitForPendingIO()
        let started = DispatchTime.now().uptimeNanoseconds
        fixture.framer.cancel()
        do { _ = try await receiver.value; throw SFTPCheckFailure(message: "waiting pipe receive ignored cancellation") }
        catch SFTPError.cancelled {
            try sftpCheck(DispatchTime.now().uptimeNanoseconds - started < 1_000_000_000, "receive cancellation did not wake poll")
            checks += 1
        }
    }
    do {
        let fixture = try SFTPPipeFixture(timeout: 2); defer { fixture.close() }
        let sender = Task.detached { try fixture.framer.send(Data(repeating: 1, count: SFTPPipeFramer.maximumPacketBytes)) }
        // No peer drains the outgoing pipe, so an active send must eventually wait.
        try fixture.waitForPendingIO()
        let started = DispatchTime.now().uptimeNanoseconds
        fixture.framer.cancel()
        do { try await sender.value; throw SFTPCheckFailure(message: "waiting pipe send ignored cancellation") }
        catch SFTPError.cancelled {
            try sftpCheck(DispatchTime.now().uptimeNanoseconds - started < 1_000_000_000, "send cancellation did not wake poll")
            checks += 1
        }
    }
    for payload in [Data(), Data(repeating: 0, count: SFTPPipeFramer.maximumPacketBytes + 1)] {
        let fixture = try SFTPPipeFixture(); defer { fixture.close() }
        do { try fixture.framer.send(payload); throw SFTPCheckFailure(message: "invalid outgoing packet length accepted") }
        catch SFTPError.protocolViolation { checks += 1 }
    }
    return checks
}
