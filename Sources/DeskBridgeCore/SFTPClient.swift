import Foundation
import Darwin

/// Serial SFTP v3 client. The worker queue owns protocol state; cancellation can interrupt it.
public final class SFTPClient: @unchecked Sendable {
    public typealias ProgressHandler = @Sendable (TransferProgress) -> Void
    private let configuration: SFTPConnectionConfiguration
    private let transportFactory: (@Sendable () throws -> any SFTPTransport)?
    private let transferCommitted: @Sendable () -> Void
    private let queue = DispatchQueue(label: "DeskBridge.SFTP", qos: .userInitiated)
    private let stateLock = NSLock()
    private var activeTransport: (any SFTPTransport)?
    private var operationCancellation: SFTPOperationCancellation?
    private var cancellationEpoch: UInt64 = 0
    private var session: SFTPSession?

    public init(configuration: SFTPConnectionConfiguration) {
        self.configuration = configuration; self.transportFactory = nil; self.transferCommitted = {}
    }
    /// Allows offline checks with a synthetic transport; production uses system OpenSSH.
    public init(configuration: SFTPConnectionConfiguration, transferCommitted: @escaping @Sendable () -> Void = {},
                transportFactory: @escaping @Sendable () throws -> any SFTPTransport) {
        self.configuration = configuration; self.transportFactory = transportFactory; self.transferCommitted = transferCommitted
    }
    public func connect() async throws {
        try await perform {
            self.closeSession()
            let transport = try self.transportFactory?() ?? SFTPSSHTransport(configuration: self.configuration)
            self.stateLock.lock(); self.activeTransport = transport
            let cancellation = self.operationCancellation; self.stateLock.unlock()
            cancellation?.attach(transport)
            do {
                let session = SFTPSession(transport: transport)
                try session.initialize(); self.session = session
            } catch {
                transport.close()
                self.stateLock.lock(); self.activeTransport = nil; self.stateLock.unlock()
                throw error
            }
        }
    }
    public func list(path: String = "/") async throws -> [SFTPEntry] {
        try await perform { try self.connected().list(path: path) }
    }
    public func upload(localURL: URL, remoteDirectory: String = "/files", progress: @escaping ProgressHandler = { _ in }) async throws -> String {
        try await perform(preservingCommittedResult: true) { try self.connected().upload(localURL: localURL, remoteDirectory: remoteDirectory, progress: progress) }
    }
    public func download(remotePath: String, destinationURL: URL, progress: @escaping ProgressHandler = { _ in }) async throws {
        try await perform(preservingCommittedResult: true) { try self.connected().download(remotePath: remotePath, destinationURL: destinationURL, progress: progress) }
    }
    /// Interrupts active/queued work. An idle cancel does not kill a usable connection.
    public func cancel() {
        stateLock.lock(); cancellationEpoch &+= 1
        let cancellation = operationCancellation
        let transport = cancellation == nil ? nil : activeTransport; stateLock.unlock()
        cancellation?.cancel()
        transport?.cancel()
    }
    public func disconnect() async {
        revoke()
        // Cleanup must run even when the calling Task has already been cancelled.
        await withCheckedContinuation { continuation in
            queue.async {
                self.closeSession()
                continuation.resume()
            }
        }
    }
    private func closeSession() {
        let sessionTransport = session?.transport; session = nil
        stateLock.lock(); let transport = activeTransport; activeTransport = nil; stateLock.unlock()
        (transport ?? sessionTransport)?.close()
    }
    /// Terminal revocation includes idle transports; ordinary cancel preserves them.
    public func revoke() {
        stateLock.lock(); cancellationEpoch &+= 1
        let cancellation = operationCancellation, transport = activeTransport
        stateLock.unlock()
        cancellation?.cancel(); transport?.cancel()
    }
    private func connected() throws -> SFTPSession {
        guard let session else { throw SFTPError.disconnected }; return session
    }
    private func perform<T: Sendable>(preservingCommittedResult: Bool = false, _ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let cancellation = SFTPOperationCancellation()
        let epoch = stateLock.withLock { cancellationEpoch }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    // A task cancelled while waiting for this serial queue never owns the live transport.
                    do { try cancellation.check() }
                    catch { continuation.resume(throwing: error); return }
                    self.stateLock.lock()
                    guard self.cancellationEpoch == epoch else {
                        self.stateLock.unlock()
                        continuation.resume(throwing: SFTPError.cancelled); return
                    }
                    self.operationCancellation = cancellation
                    let transport = self.activeTransport; self.stateLock.unlock()
                    if let transport { cancellation.attach(transport) }
                    let outcome: Result<T, any Error>
                    do {
                        try cancellation.check()
                        let result = try operation()
                        if preservingCommittedResult {
                            // Successful transfer return proves rename committed. A later
                            // cancellation closes the transport, but cannot undo that result.
                            self.transferCommitted()
                            do { try cancellation.check() } catch { self.closeSession() }
                            if self.session?.invalid == true { self.closeSession() }
                        } else {
                            try cancellation.check()
                            if let session = self.session, session.invalid { throw session.failure ?? SFTPError.disconnected }
                        }
                        outcome = .success(result)
                    } catch {
                        let terminal = SFTPError.requiresReconnect(after: error)
                        let invalidSession = self.session?.invalid == true
                        if terminal || invalidSession { self.closeSession() }
                        // An ignored best-effort CLOSE can also invalidate a session.
                        // Preserve the original failure while making its connection state explicit.
                        let reported: any Error = invalidSession && !terminal ? SFTPError.connectionLost(error.localizedDescription) : error
                        outcome = .failure(reported)
                    }
                    cancellation.detach()
                    self.stateLock.lock(); self.operationCancellation = nil; self.stateLock.unlock()
                    // A caller that has resumed must observe an idle cancellation slot.
                    continuation.resume(with: outcome)
                }
            }
        } onCancel: { cancellation.cancel() }
    }
    deinit { activeTransport?.cancel() }
}

private final class SFTPOperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var transport: (any SFTPTransport)?
    func attach(_ transport: any SFTPTransport) {
        lock.lock(); self.transport = transport; let cancelled = self.cancelled; lock.unlock()
        if cancelled { transport.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let transport = self.transport; lock.unlock()
        transport?.cancel()
    }
    func detach() { lock.withLock { transport = nil } }
    func check() throws {
        lock.lock(); let cancelled = self.cancelled; lock.unlock()
        if cancelled { throw SFTPError.cancelled }
    }
}

private final class SFTPSession {
    let transport: any SFTPTransport
    private var nextID: UInt32 = 1
    private(set) var invalid = false
    private(set) var failure: (any Error)?
    private var requestDeadline: UInt64?
    private let chunkBytes = 64 * 1024
    private let maximumFileSize: UInt64 = 128 * 1024 * 1024 * 1024
    init(transport: any SFTPTransport) { self.transport = transport }

    func initialize() throws {
        var initPacket = SFTPBinaryWriter(); initPacket.byte(1); initPacket.uint32(3)
        try transport.send(initPacket.data)
        var reply = SFTPBinaryReader(try transport.receive())
        guard try reply.byte() == 2, try reply.uint32() == 3 else {
            throw SFTPError.protocolViolation("SFTP version 3 is required")
        }
        var extensionCount = 0
        while reply.remaining > 0 {
            extensionCount += 1
            guard extensionCount <= 128 else { throw SFTPError.protocolViolation("too many extensions") }
            _ = try reply.bytes(maximum: 8192); _ = try reply.bytes(maximum: 8192)
        }
    }

    private func request(_ type: UInt8, _ body: (inout SFTPBinaryWriter) -> Void) throws -> (UInt8, SFTPBinaryReader) {
        guard !invalid else { throw SFTPError.disconnected }
        let id = nextID; nextID = nextID == UInt32.max ? 1 : nextID + 1
        var packet = SFTPBinaryWriter(); packet.byte(type); packet.uint32(id); body(&packet)
        do {
            try checkDeadline()
            try transport.send(packet.data)
            try checkDeadline()
            var response = SFTPBinaryReader(try transport.receive())
            try checkDeadline()
            let responseType = try response.byte()
            guard try response.uint32() == id else { throw SFTPError.protocolViolation("response identifier mismatch") }
            return (responseType, response)
        } catch {
            invalid = true; failure = error; transport.cancel(); throw error
        }
    }
    private func checkDeadline() throws {
        if let requestDeadline, DispatchTime.now().uptimeNanoseconds >= requestDeadline { throw SFTPError.timedOut }
    }
    private func status(_ reply: (UInt8, SFTPBinaryReader), allowingEOF: Bool = false) throws -> Bool {
        guard reply.0 == 101 else { throw SFTPError.protocolViolation("expected status") }
        var body = reply.1
        let code = try body.uint32()
        let raw = try body.string(maximum: 8192); _ = try body.string(maximum: 128); try body.requireEnd()
        if code == 0 { return false }
        if code == 1 && allowingEOF { return true }
        let message = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(240))
        throw SFTPError.remoteStatus(code, message)
    }
    private func expect(_ expected: UInt8, reply: (UInt8, SFTPBinaryReader)) throws -> SFTPBinaryReader {
        if reply.0 == 101 { _ = try status(reply); throw SFTPError.protocolViolation("unexpected success status") }
        guard reply.0 == expected else { throw SFTPError.protocolViolation("unexpected response type") }
        return reply.1
    }
    private func attributes(path: String) throws -> SFTPAttributes {
        var body = try expect(105, reply: request(7) { $0.string(path) })
        let result = try SFTPAttributes.decode(&body); try body.requireEnd(); return result
    }
    private func attributes(handle: Data) throws -> SFTPAttributes {
        var body = try expect(105, reply: request(8) { $0.bytes(handle) })
        let result = try SFTPAttributes.decode(&body); try body.requireEnd(); return result
    }
    /// Defense in depth. Windows chroot + NTFS ACLs remain the actual authorization boundary.
    private func checkedPath(_ input: String, directory: Bool) throws -> String {
        let path = try SFTPPaths.remote(input)
        let parts = path.split(separator: "/").map(String.init)
        var prefix = ""
        let root = try attributes(path: "/")
        guard root.kind == .directory else { throw SFTPError.unsupportedFile }
        for (index, component) in parts.enumerated() {
            prefix += "/" + component
            let entry = try attributes(path: prefix)
            if entry.kind == .symlink { throw SFTPError.unsupportedFile }
            let needsDirectory = index < parts.count - 1 || directory
            guard needsDirectory ? entry.kind == .directory : entry.kind == .file else {
                throw SFTPError.unsupportedFile
            }
        }
        if parts.isEmpty && !directory { throw SFTPError.unsupportedFile }
        return path
    }
    private func open(path: String, flags: UInt32) throws -> Data {
        var body = try expect(102, reply: request(3) { $0.string(path); $0.uint32(flags); $0.uint32(0) })
        let handle = try body.bytes(maximum: 1024); try body.requireEnd()
        guard !handle.isEmpty else { throw SFTPError.protocolViolation("empty file handle") }
        return handle
    }
    private func close(handle: Data) throws { _ = try status(request(4) { $0.bytes(handle) }) }

    func list(path: String) throws -> [SFTPEntry] {
        // One operation deadline complements the per-packet transport timeout.
        // A currently pending packet can take at most its remaining packet timeout.
        requestDeadline = DispatchTime.now().uptimeNanoseconds + 60_000_000_000
        defer { requestDeadline = nil }
        let path = try checkedPath(path, directory: true)
        var openBody = try expect(102, reply: request(11) { $0.string(path) })
        let handle = try openBody.bytes(maximum: 1024); try openBody.requireEnd()
        guard !handle.isEmpty else { throw SFTPError.protocolViolation("empty directory handle") }
        defer {
            // Cleanup retains its per-packet timeout rather than inheriting an
            // expired listing budget after the result has already been read.
            requestDeadline = nil
            if !invalid { try? close(handle: handle) }
        }
        var entries: [SFTPEntry] = [], names = Set<String>()
        var rawEntries = 0, responses = 0, replyBytes = 0, retainedStringBytes = 0
        do {
            while true {
                try checkDeadline()
                guard responses < 100_001 else { throw SFTPError.protocolViolation("directory response limit exceeded") }
                let reply = try request(12) { $0.bytes(handle) }
                responses += 1
                let payloadBytes = reply.1.remaining + 5 // type + request ID were consumed by request().
                guard payloadBytes <= 1_048_576, payloadBytes + 4 <= 64 * 1024 * 1024 - replyBytes else {
                    throw SFTPError.protocolViolation("directory reply byte limit exceeded")
                }
                replyBytes += payloadBytes + 4
                try checkDeadline()
                if reply.0 == 101 {
                    guard try status(reply, allowingEOF: true) else { throw SFTPError.protocolViolation("missing directory entries") }
                    break
                }
                var body = try expect(104, reply: reply)
                let count = Int(try body.uint32())
                guard count > 0, count <= 4096, count <= 100_000 - rawEntries else {
                    throw SFTPError.protocolViolation("directory entry limit exceeded")
                }
                rawEntries += count // Charge every name before filtering unsupported entries.
                for _ in 0..<count {
                    let name = try body.string(); _ = try body.bytes(maximum: 16384)
                    let attrs = try SFTPAttributes.decode(&body)
                    if name == "." || name == ".." { continue }
                    let fullPath: String
                    do { fullPath = try SFTPPaths.append(name, to: path) }
                    catch SFTPError.invalidPath(_) { continue }
                    let stringBytes = name.utf8.count + fullPath.utf8.count
                    guard stringBytes <= 32 * 1024 * 1024 - retainedStringBytes else {
                        throw SFTPError.protocolViolation("directory path byte limit exceeded")
                    }
                    retainedStringBytes += stringBytes
                    guard names.insert(name).inserted else { throw SFTPError.protocolViolation("duplicate directory entry") }
                    entries.append(SFTPEntry(name: name, path: fullPath, kind: attrs.kind, size: attrs.size))
                }
                try body.requireEnd()
            }
        } catch {
            // Do not wait on CLOSE after a protocol budget failure. Remote file
            // errors remain recoverable and still close their directory handle.
            if SFTPError.requiresReconnect(after: error) { invalid = true; transport.cancel() }
            throw error
        }
        return entries.sorted {
            if ($0.kind == .directory) != ($1.kind == .directory) { return $0.kind == .directory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func upload(localURL: URL, remoteDirectory: String, progress: SFTPClient.ProgressHandler) throws -> String {
        guard localURL.isFileURL else { throw SFTPError.invalidPath("choose a local file") }
        let filename = localURL.lastPathComponent.precomposedStringWithCanonicalMapping
        try SFTPPaths.windowsFilename(filename)
        let local = Darwin.open(localURL.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard local >= 0 else { throw SFTPError.localIO("cannot open source file") }
        let file = FileHandle(fileDescriptor: local, closeOnDealloc: true)
        defer { try? file.close() }
        var initial = stat()
        guard fstat(local, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG, initial.st_size >= 0 else {
            throw SFTPError.unsupportedFile
        }
        let size = UInt64(initial.st_size)
        guard size <= maximumFileSize else { throw SFTPError.unsupportedFile }
        let parent = try checkedPath(remoteDirectory, directory: true)
        let job = try SFTPPaths.append("deskbridge-\(UUID().uuidString.lowercased())", to: parent)
        _ = try status(request(14) { $0.string(job); $0.uint32(0) })
        let stagingName = filename.caseInsensitiveCompare(".upload.part") == .orderedSame ? ".upload-stage.part" : ".upload.part"
        let partial = try SFTPPaths.append(stagingName, to: job)
        let destination = try SFTPPaths.append(filename, to: job)
        var handle: Data?
        var committed = false
        defer {
            if let handle { try? close(handle: handle) }
            if !committed {
                _ = try? status(request(13) { $0.string(partial) })
                _ = try? status(request(15) { $0.string(job) })
            }
        }
        // WRITE | CREATE | EXCLUSIVE: never truncate an existing remote file.
        handle = try open(path: partial, flags: 0x2 | 0x8 | 0x20)
        let remoteHandle = handle!
        var offset: UInt64 = 0
        progress(TransferProgress(bytesTransferred: 0, totalBytes: size))
        while offset < size {
            guard let data = try file.read(upToCount: min(chunkBytes, Int(size - offset))), !data.isEmpty else {
                throw SFTPError.sourceChanged
            }
            _ = try status(request(6) { $0.bytes(remoteHandle); $0.uint64(offset); $0.bytes(data) })
            offset += UInt64(data.count)
            progress(TransferProgress(bytesTransferred: offset, totalBytes: size))
        }
        var final = stat()
        guard fstat(local, &final) == 0, final.st_size == initial.st_size,
              final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec else { throw SFTPError.sourceChanged }
        let uploaded = try attributes(handle: remoteHandle)
        guard uploaded.size == size, uploaded.kind == .file else { throw SFTPError.sourceChanged }
        try close(handle: remoteHandle); handle = nil
        // Base v3 rename, intentionally not posix-rename (which permits replacement).
        _ = try status(request(18) { $0.string(partial); $0.string(destination) })
        committed = true
        return destination
    }

    func download(remotePath: String, destinationURL: URL, progress: SFTPClient.ProgressHandler) throws {
        guard destinationURL.isFileURL else { throw SFTPError.invalidPath("choose a local destination") }
        let filename = destinationURL.lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format }) else {
            throw SFTPError.invalidPath("invalid local destination")
        }
        let directory = destinationURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let dirFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dirFD >= 0 else { throw SFTPError.localIO("cannot open destination folder") }
        defer { Darwin.close(dirFD) }
        var existing = stat()
        if fstatat(dirFD, filename, &existing, AT_SYMLINK_NOFOLLOW) == 0 { throw SFTPError.destinationExists }
        guard errno == ENOENT else { throw SFTPError.localIO("cannot inspect destination name") }
        let temporaryName = ".deskbridge-\(UUID().uuidString).part"
        let local = openat(dirFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard local >= 0 else { throw SFTPError.localIO("cannot create exclusive partial file") }
        let file = FileHandle(fileDescriptor: local, closeOnDealloc: true)
        var moved = false
        defer { try? file.close(); if !moved { unlinkat(dirFD, temporaryName, 0) } }
        // Check destination-volume support before requesting file bytes. The
        // marker stays on this same exclusive inode through final publication.
        let quarantine = Data("0081;\(String(Int(Date().timeIntervalSince1970), radix: 16));Knot;".utf8)
        let marked = quarantine.withUnsafeBytes {
            fsetxattr(local, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0)
        }
        guard marked == 0 else { throw SFTPError.localIO("cannot mark downloaded file for macOS quarantine") }
        let remote = try checkedPath(remotePath, directory: false)
        let handle = try open(path: remote, flags: 1)
        var remoteClosed = false
        defer { if !remoteClosed { try? close(handle: handle) } }
        let initial = try attributes(handle: handle)
        guard initial.kind == .file, let size = initial.size, size <= maximumFileSize else { throw SFTPError.unsupportedFile }
        var offset: UInt64 = 0
        progress(TransferProgress(bytesTransferred: 0, totalBytes: size))
        while offset < size {
            let requested = UInt32(min(UInt64(chunkBytes), size - offset))
            let reply = try request(5) { $0.bytes(handle); $0.uint64(offset); $0.uint32(requested) }
            if reply.0 == 101 { _ = try status(reply, allowingEOF: true); throw SFTPError.sourceChanged }
            var body = try expect(103, reply: reply)
            let data = try body.bytes(maximum: Int(requested)); try body.requireEnd()
            guard !data.isEmpty else { throw SFTPError.protocolViolation("empty data before EOF") }
            try file.write(contentsOf: data); offset += UInt64(data.count)
            progress(TransferProgress(bytesTransferred: offset, totalBytes: size))
        }
        let final = try attributes(handle: handle)
        guard final.size == initial.size, final.modificationTime == initial.modificationTime else { throw SFTPError.sourceChanged }
        try close(handle: handle); remoteClosed = true
        try file.synchronize(); try file.close()
        guard renameatx_np(dirFD, temporaryName, dirFD, filename, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw SFTPError.destinationExists }
            throw SFTPError.localIO("cannot finalize download")
        }
        moved = true
    }
}
