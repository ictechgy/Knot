import Foundation
import Darwin
import CryptoKit
import Testing
import KnotNativeCore
@testable import KnotNativePreview

private final class ScriptedFileChannel: NativeFileChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data
    private var closed = false
    private var writes: [FilePacket] = []
    private var reads = 0
    private var budgets: [Duration] = []
    private let headerDelay: Duration
    private let failComplete: Bool
    private let afterRead: (@Sendable (Int) -> Void)?
    private let afterSend: (@Sendable (FilePacket) -> Void)?
    init(_ packets: [FilePacket], afterRead: (@Sendable (Int) -> Void)? = nil,
         afterSend: (@Sendable (FilePacket) -> Void)? = nil, headerDelay: Duration = .zero, failComplete: Bool = false) {
        bytes = packets.reduce(into: Data()) { $0.append($1.encoded) }; self.afterRead = afterRead; self.afterSend = afterSend; self.headerDelay = headerDelay; self.failComplete = failComplete
    }
    func start() async throws { try check() }
    private func check() throws { lock.lock(); defer { lock.unlock() }; if closed { throw NativeFileError.closed } }
    private func take(_ count: Int, timeout: Duration) throws -> (Data, Int) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, count <= bytes.count else { throw NativeFileError.io }
        let result = Data(bytes.prefix(count)); bytes.removeFirst(count); reads += 1; budgets.append(timeout); return (result, reads)
    }
    func readExactly(_ count: Int, timeout: Duration) async throws -> Data {
        if count == 5, headerDelay > .zero { try await Task.sleep(for: headerDelay) }
        let (result, index) = try take(count, timeout: timeout); afterRead?(index); return result
    }
    private func record(_ packet: FilePacket) throws {
        lock.lock(); defer { lock.unlock() }; guard !closed else { throw NativeFileError.closed }; writes.append(packet)
    }
    func send(_ packet: FilePacket) async throws {
        try record(packet)
        if failComplete && packet.kind == .complete { throw NativeFailure.transport }
        afterSend?(packet)
    }
    func close() { lock.lock(); closed = true; lock.unlock() }
    func snapshot() -> [FilePacket] { lock.lock(); defer { lock.unlock() }; return writes }
    func isClosed() -> Bool { lock.lock(); defer { lock.unlock() }; return closed }
    func timeoutSnapshot() -> [Duration] { lock.lock(); defer { lock.unlock() }; return budgets }
}

private func ownedClientDirectory() throws -> URL {
    let url = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path.hasPrefix("/var/") ? "/private" + FileManager.default.temporaryDirectory.path : FileManager.default.temporaryDirectory.path).appendingPathComponent("knot-client-file-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); return url
}
private func fileEndpoint() throws -> NativeFileEndpoint {
    let json = try JSONSerialization.data(withJSONObject: ["v": 1, "address": "192.168.50.12", "port": 48631,
        "certificateSHA256": String(repeating: "a", count: 64), "token": Invitation.encodeBase64URL(Data(repeating: 1, count: 32))])
    let invitation = try Invitation("knot-native:v1:" + Invitation.encodeBase64URL(json))
    let offer = try NativeFileOffer(port: 48634, token: Invitation.encodeBase64URL(Data(repeating: 2, count: 32)), rootName: "Knot Files")
    return try NativeFileEndpoint(invitation: invitation, offer: offer)
}
private func authorizedFilePacket() throws -> FilePacket { try FilePacket(kind: .authorized, payload: FileWire.json(["v": 2])) }
private func fileDownloadPackets(_ entry: NativeFileEntry, bytes: Data, badOffset: Bool = false, badHash: Bool = false) throws -> [FilePacket] {
    var packets = [try authorizedFilePacket(), try FilePacket(kind: .accepted, payload: FileWire.json(["name": entry.name, "size": entry.size, "kind": entry.kind.rawValue, "count": 0]))]
    var cursor = 0
    while cursor < bytes.count {
        let part = bytes.subdata(in: cursor..<min(bytes.count, cursor + FileWire.chunkBytes))
        var payload = Data(); payload.appendBE(UInt64(cursor + (badOffset ? 1 : 0))); payload.append(part)
        packets.append(try FilePacket(kind: .chunk, payload: payload)); cursor += part.count
    }
    packets.append(try FileWire.finish(size: Int64(bytes.count), digest: badHash ? Data(repeating: 0, count: 32) : Data(SHA256.hash(data: bytes))))
    return packets
}

@Test func fileClientDownloadsEmptyAndChunkBoundaryBytesWithExactQuarantinedName() async throws {
    let root = try ownedClientDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    for count in [0, 65_541] {
        let bytes = Data((0..<count).map { UInt8($0 % 251) }), name = "검증-\(count).bin"
        let entry = try NativeFileEntry(id: String(repeating: "a", count: 32), name: name, size: Int64(count))
        let channel = ScriptedFileChannel(try fileDownloadPackets(entry, bytes: bytes)), gate = FileRunGate()
        let client = NativeFileClient(endpoint: try fileEndpoint(), gate: gate, makeChannel: { _ in channel })
        let id = try gate.begin(); defer { gate.end(id) }
        let target = root.appendingPathComponent(name)
        #expect(try await client.download(entry: entry, destination: target, operation: id, progress: { _, _ in }) == target)
        #expect(try Data(contentsOf: target) == bytes)
        #expect(channel.isClosed() && channel.snapshot().map(\.kind) == [.hello, .get, .complete])
        let receipt = try FileWire.completion(try #require(channel.snapshot().last).payload)
        #expect(receipt.name == name && receipt.hash == NativeFileClient.hex(Data(SHA256.hash(data: bytes))))
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
}

@Test func fileClientRejectsWrongOffsetsAndHashesAndCleansAllOwnedPartials() async throws {
    let root = try ownedClientDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data([1, 2, 3]), entry = try NativeFileEntry(id: String(repeating: "b", count: 32), name: "source.txt", size: 3)
    for (offset, hash) in [(true, false), (false, true)] {
        let channel = ScriptedFileChannel(try fileDownloadPackets(entry, bytes: bytes, badOffset: offset, badHash: hash)), gate = FileRunGate()
        let client = NativeFileClient(endpoint: try fileEndpoint(), gate: gate, makeChannel: { _ in channel }), id = try gate.begin()
        do { _ = try await client.download(entry: entry, destination: root.appendingPathComponent("target.txt"), operation: id, progress: { _, _ in }); Issue.record("Malformed file was published") } catch {}
        gate.end(id)
        #expect(channel.isClosed() && !channel.snapshot().contains { $0.kind == .complete })
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}

@Test func fileClientLateFinishAfterSessionRevocationCannotPublish() async throws {
    let root = try ownedClientDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data([7]), entry = try NativeFileEntry(id: String(repeating: "c", count: 32), name: "source.txt", size: 1)
    let gate = FileRunGate()
    let channel = ScriptedFileChannel(try fileDownloadPackets(entry, bytes: bytes), afterRead: { index in if index == 8 { gate.close() } })
    let client = NativeFileClient(endpoint: try fileEndpoint(), gate: gate, makeChannel: { _ in channel }), id = try gate.begin()
    do { _ = try await client.download(entry: entry, destination: root.appendingPathComponent("target.txt"), operation: id, progress: { _, _ in }); Issue.record("Late file finish crossed revocation") }
    catch { #expect(error as? NativeFileError == .closed) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test func fileReceiveRetainsVerifiedLocalSuccessWhenFinalTransportAcknowledgementFails() async throws {
    let root = try ownedClientDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data("verified local receipt".utf8)
    let entry = try NativeFileEntry(id: String(repeating: "d", count: 32), name: "safe.txt", size: Int64(bytes.count))
    let channel = ScriptedFileChannel(try fileDownloadPackets(entry, bytes: bytes), failComplete: true), gate = FileRunGate()
    let client = NativeFileClient(endpoint: try fileEndpoint(), gate: gate, makeChannel: { _ in channel }), operation = try gate.begin()
    defer { gate.end(operation) }
    let destination = root.appendingPathComponent("safe.txt")
    #expect(try await client.download(entry: entry, destination: destination, operation: operation, progress: { _, _ in }) == destination)
    #expect(try Data(contentsOf: destination) == bytes && channel.isClosed())
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["safe.txt"])
}

@Test func fileClientUploadsActualBytesAndVerifiesCollisionResolvedCompletion() async throws {
    let root = try ownedClientDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data("fresh synthetic 한글 bytes".utf8), source = root.appendingPathComponent("source.txt")
    try bytes.write(to: source)
    let target = "source (2).txt", digest = NativeFileClient.hex(Data(SHA256.hash(data: bytes)))
    let channel = ScriptedFileChannel([try authorizedFilePacket(), try FilePacket(kind: .accepted, payload: FileWire.json(["name": source.lastPathComponent, "size": bytes.count, "kind": "file", "count": 0])),
        try FilePacket(kind: .complete, payload: FileWire.json(["name": target, "size": bytes.count, "sha256": digest]))])
    let gate = FileRunGate(), id = try gate.begin(), client = NativeFileClient(endpoint: try fileEndpoint(), gate: gate, makeChannel: { _ in channel })
    defer { gate.end(id) }
    let receipt = try await client.upload(url: source, operation: id, progress: { _, _ in })
    #expect(receipt.name == target && receipt.size == Int64(bytes.count) && receipt.hash == digest)
    let writes = channel.snapshot(); #expect(writes.map(\.kind) == [.hello, .put, .chunk, .finish])
    #expect(writes[2].payload.dropFirst(8) == bytes)
    #expect(try Data(contentsOf: source) == bytes)
}

@Test func fileClientSourceMutationStopsBeforeFinishAndDoesNotReplay() async throws {
    let root = try ownedClientDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.txt"); try Data([1, 2, 3]).write(to: source)
    let channel = ScriptedFileChannel([try authorizedFilePacket(), try FilePacket(kind: .accepted, payload: FileWire.json(["name": "source.txt", "size": 3, "kind": "file", "count": 0]))], afterSend: { packet in
        if packet.kind == .chunk { try? Data([1, 2, 3, 4]).write(to: source) }
    })
    let gate = FileRunGate(), id = try gate.begin(), client = NativeFileClient(endpoint: try fileEndpoint(), gate: gate, makeChannel: { _ in channel })
    do { _ = try await client.upload(url: source, operation: id, progress: { _, _ in }); Issue.record("Changed source was acknowledged") }
    catch { #expect(error as? NativeFileError == .changed) }
    gate.end(id)
    #expect(channel.isClosed() && !channel.snapshot().contains { $0.kind == .finish })
}

@Test func uploadMissingOrInvalidCompletionIsUnconfirmedAndNeverReplayed() async throws {
    let root = try ownedClientDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.txt"); try Data([1]).write(to: source)
    let authorized = try authorizedFilePacket(), accepted = try FilePacket(kind: .accepted, payload: FileWire.json(["name": "source.txt", "size": 1, "kind": "file", "count": 0]))
    let invalid = try FilePacket(kind: .complete, payload: FileWire.json(["name": "source.txt", "size": 1, "sha256": String(repeating: "0", count: 64)]))
    for responses in [[authorized, accepted], [authorized, accepted, invalid]] {
        let channel = ScriptedFileChannel(responses), gate = FileRunGate(), operation = try gate.begin()
        let client = NativeFileClient(endpoint: try fileEndpoint(), gate: gate, makeChannel: { _ in channel })
        do { _ = try await client.upload(url: source, operation: operation, progress: { _, _ in }); Issue.record("Unconfirmed upload was called successful") }
        catch { #expect(error as? NativeFileError == .unconfirmed) }
        gate.end(operation)
        #expect(channel.snapshot().filter { $0.kind == .finish }.count == 1 && channel.isClosed())
        #expect(try Data(contentsOf: source) == Data([1]))
    }
}

@Test func fileListRejectsDuplicateIdsAndTerminalCountMismatch() async throws {
    let entry = try FilePacket(kind: .entry, payload: FileWire.json(["entry": String(repeating: "a", count: 32), "name": "safe.txt", "size": 0, "kind": "file"]))
    let end = try FilePacket(kind: .listEnd, payload: FileWire.json(["count": 2, "truncated": false]))
    for replies in [[entry, entry, end], [entry, end]] {
        let channel = ScriptedFileChannel([try authorizedFilePacket()] + replies), gate = FileRunGate()
        let id = try gate.begin(), client = NativeFileClient(endpoint: try fileEndpoint(), gate: gate, makeChannel: { _ in channel })
        do { _ = try await client.list(operation: id); Issue.record("Invalid bounded listing was accepted") } catch {}
        gate.end(id); #expect(channel.isClosed())
    }
}

@Test func fileAuthAndMetadataPayloadsConsumeTheSameAbsoluteHeaderBudget() async throws {
    let entry = try FilePacket(kind: .entry, payload: FileWire.json(["entry": String(repeating: "a", count: 32), "name": "safe.txt", "size": 0, "kind": "file"]))
    let end = try FilePacket(kind: .listEnd, payload: FileWire.json(["count": 1, "truncated": false]))
    let channel = ScriptedFileChannel([try authorizedFilePacket(), entry, end], headerDelay: .milliseconds(25))
    let gate = FileRunGate(), id = try gate.begin(), client = NativeFileClient(endpoint: try fileEndpoint(), gate: gate, makeChannel: { _ in channel })
    defer { gate.end(id) }
    #expect(try await client.list(operation: id).entries.count == 1)
    let budgets = channel.timeoutSnapshot(); try #require(budgets.count == 6)
    #expect(budgets[0] <= .seconds(10) && budgets[1] < budgets[0] - .milliseconds(15))
    #expect(budgets[3] < budgets[2] - .milliseconds(15))
    #expect(budgets[4] < budgets[2])
}

private actor LateFileWorker: NativeFileWorking {
    private var waiting: CheckedContinuation<URL, any Error>?
    private var calls = 0
    func list(operation: UUID) async throws -> NativeFileListing { throw NativeFileError.closed }
    func upload(url: URL, operation: UUID, progress: @escaping NativeFileProgress) async throws -> NativeFileReceipt { throw NativeFileError.closed }
    func download(entry: NativeFileEntry, destination: URL, operation: UUID, progress: @escaping NativeFileProgress) async throws -> URL {
        calls += 1
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func hasWaiting() -> Bool { waiting != nil }
    func finish(_ url: URL) { let value = waiting; waiting = nil; value?.resume(returning: url) }
    func callCount() -> Int { calls }
}

@Test @MainActor func fileModelCloseRejectsLateWorkerAndFuturePickerBeforeAnyWrite() async throws {
    let worker = LateFileWorker(), gate = FileRunGate()
    let entry = try NativeFileEntry(id: String(repeating: "e", count: 32), name: "safe.txt", size: 0)
    let model = FileTransferModel(rootName: "Synthetic", client: worker, gate: gate, entries: [entry])
    let destination = URL(fileURLWithPath: "/synthetic-not-accessed/late.txt")
    let pending = Task { try await model.receive(entry, destination: destination) }
    for _ in 0..<100 { if await worker.hasWaiting() { break }; try await Task.sleep(for: .milliseconds(1)) }
    try #require(await worker.hasWaiting()); model.close(); await worker.finish(destination)
    if case .success = await pending.result { Issue.record("Late picker callback reported success after close") }
    #expect(!model.isBusy && model.entries.isEmpty && model.status == NativeFileError.closed.message)
    do { _ = try await model.receive(entry, destination: destination); Issue.record("Closed model admitted future file promise") } catch {}
    #expect(await worker.callCount() == 1)
}

private func treeDownloadPackets(name: String, nodes: [(NativeFileNode, Data)], badTreeHash: Bool = false) throws -> [FilePacket] {
    let size = nodes.reduce(Int64(0)) { $0 + $1.0.size }
    var packets = [try authorizedFilePacket(), try FilePacket(kind: .accepted, payload: FileWire.json(["name": name, "size": size, "kind": "folder", "count": nodes.count]))]
    var hash = SHA256()
    for (node, bytes) in nodes {
        let raw = try node.json
        var length = Data(); length.appendBE(UInt32(raw.count)); hash.update(data: length); hash.update(data: raw)
        packets.append(try FilePacket(kind: .node, payload: raw))
        if node.kind == .folder { continue }
        var offset = 0
        while offset < bytes.count {
            let part = bytes.subdata(in: offset..<min(bytes.count, offset + FileWire.chunkBytes))
            var payload = Data(); payload.appendBE(UInt64(offset)); payload.append(part)
            packets.append(try FilePacket(kind: .chunk, payload: payload)); offset += part.count
        }
        hash.update(data: bytes)
        packets.append(try FileWire.finish(size: node.size, digest: Data(SHA256.hash(data: bytes))))
    }
    packets.append(try FilePacket(kind: .treeEnd, payload: FileWire.json(["count": nodes.count, "size": size,
        "sha256": badTreeHash ? String(repeating: "0", count: 64) : NativeFileClient.hex(Data(hash.finalize()))])))
    return packets
}

@Test func fileClientReceivesEmptyAndNestedUnicodeTreesAtomicallyAndRejectsTreeHashFailure() async throws {
    let root = try ownedClientDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let folder = try NativeFileNode(id: 1, parent: 0, name: "빈 폴더", kind: .folder, size: 0)
    let empty = try NativeFileNode(id: 2, parent: 1, name: "empty", kind: .file, size: 0)
    let bytes = Data((0..<65_541).map { UInt8($0 % 251) })
    let leaf = try NativeFileNode(id: 3, parent: 0, name: "검증.bin", kind: .file, size: Int64(bytes.count))
    for (index, nodes, badHash) in [(0, [(NativeFileNode, Data)](), false), (1, [(folder, Data()), (empty, Data()), (leaf, bytes)], false), (2, [(folder, Data()), (empty, Data()), (leaf, bytes)], true)] {
        let entry = try NativeFileEntry(id: String(repeating: "f", count: 32), name: "tree", size: 0, kind: .folder)
        let channel = ScriptedFileChannel(try treeDownloadPackets(name: entry.name, nodes: nodes, badTreeHash: badHash)), gate = FileRunGate()
        let client = NativeFileClient(endpoint: try fileEndpoint(), gate: gate, makeChannel: { _ in channel }), operation = try gate.begin()
        let destination = root.appendingPathComponent("tree-\(index)")
        do {
            #expect(try await client.download(entry: entry, destination: destination, operation: operation, progress: { _, _ in }) == destination)
            #expect(!badHash)
            if index == 1 { #expect(try Data(contentsOf: destination.appendingPathComponent(leaf.name)) == bytes) }
        } catch { #expect(badHash && error as? NativeFileError == .changed) }
        gate.end(operation)
        #expect(channel.snapshot().contains { $0.kind == .complete } == !badHash)
        if badHash { #expect(!FileManager.default.fileExists(atPath: destination.path)) }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["tree-0", "tree-1"])
}

@Test func fileClientUploadsFolderSnapshotAndRawNodeHashWithoutDeletingSource() async throws {
    let root = try ownedClientDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("tree"), empty = source.appendingPathComponent("빈 폴더")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
    try Data([1, 2, 3]).write(to: source.appendingPathComponent("검증.bin"))
    let snapshot = try NativeFileTreeSource(url: source)
    var hash = SHA256()
    for item in snapshot.items {
        var length = Data(); length.appendBE(UInt32(item.raw.count)); hash.update(data: length); hash.update(data: item.raw)
        if item.node.kind == .file { hash.update(data: Data([1, 2, 3])) }
    }
    let digest = NativeFileClient.hex(Data(hash.finalize()))
    let channel = ScriptedFileChannel([try authorizedFilePacket(), try FilePacket(kind: .accepted, payload: FileWire.json(["name": "tree", "size": 3, "kind": "folder", "count": 2])),
        try FilePacket(kind: .complete, payload: FileWire.json(["name": "tree (2)", "size": 3, "sha256": digest]))])
    let gate = FileRunGate(), operation = try gate.begin(), client = NativeFileClient(endpoint: try fileEndpoint(), gate: gate, makeChannel: { _ in channel })
    defer { gate.end(operation) }
    let receipt = try await client.upload(url: source, operation: operation, progress: { _, _ in })
    #expect(receipt.name == "tree (2)" && receipt.hash == digest)
    #expect(channel.snapshot().first(where: { $0.kind == .treePut }) != nil && channel.snapshot().last?.kind == .treeEnd)
    #expect(try Data(contentsOf: source.appendingPathComponent("검증.bin")) == Data([1, 2, 3]))
}

@Test func fileClientCaptureUsesOnlyNonceAndStrictSeparateListing() async throws {
    let nonce = String(repeating: "a", count: 32), entry = try FilePacket(kind: .entry, payload: FileWire.json(["entry": String(repeating: "b", count: 32), "name": "folder", "size": 0, "kind": "folder"]))
    let end = try FilePacket(kind: .listEnd, payload: FileWire.json(["count": 1, "truncated": false]))
    let channel = ScriptedFileChannel([try authorizedFilePacket(), entry, end]), gate = FileRunGate(), operation = try gate.begin()
    let client = NativeFileClient(endpoint: try fileEndpoint(), gate: gate, makeChannel: { _ in channel })
    let listing = try await client.captureExplorer(nonce: nonce, operation: operation); gate.end(operation)
    #expect(listing.entries.count == 1 && listing.entries[0].isFolder)
    #expect(channel.snapshot().map(\.kind) == [.hello, .explorerCapture])
    #expect(try FileWire.explorerNonce(channel.snapshot()[1].payload) == nonce)
}

private actor CapturedFileWorker: NativeFileWorking {
    let captured: [NativeFileEntry]
    private var captureWaiting: CheckedContinuation<NativeFileListing, any Error>?
    private var downloads: [CheckedContinuation<URL, any Error>] = []
    private var destinations: [URL] = []
    private var active = 0, peak = 0, calls = 0
    init(_ captured: [NativeFileEntry]) { self.captured = captured }
    func list(operation: UUID) async throws -> NativeFileListing { NativeFileListing(entries: [], truncated: false) }
    func captureExplorer(nonce: String, operation: UUID) async throws -> NativeFileListing {
        try await withCheckedThrowingContinuation { captureWaiting = $0 }
    }
    func upload(url: URL, operation: UUID, progress: @escaping NativeFileProgress) async throws -> NativeFileReceipt { throw NativeFileError.unsupported }
    func download(entry: NativeFileEntry, destination: URL, operation: UUID, progress: @escaping NativeFileProgress) async throws -> URL {
        active += 1; peak = max(peak, active); calls += 1; destinations.append(destination)
        let url = try await withCheckedThrowingContinuation { downloads.append($0) }
        active -= 1; return url
    }
    func hasCapture() -> Bool { captureWaiting != nil }
    func finishCapture() { let value = captureWaiting; captureWaiting = nil; value?.resume(returning: NativeFileListing(entries: captured, truncated: false)) }
    func downloadCount() -> Int { calls }
    func peakCount() -> Int { peak }
    func finishDownload() { guard !downloads.isEmpty else { return }; downloads.removeFirst().resume(returning: destinations.removeFirst()) }
}

@Test @MainActor func fileModelCapturesSeparateSingleUseExportsAndSerializesPromiseFulfillments() async throws {
    let entries = try (0..<3).map { try NativeFileEntry(id: String(format: "%032x", $0 + 1), name: "file-\($0)", size: 0) }
    let worker = CapturedFileWorker(entries), gate = FileRunGate(), model = FileTransferModel(rootName: "Synthetic", client: worker, gate: gate)
    let capture = Task { try await model.captureExplorer(nonce: String(repeating: "a", count: 32)) }
    for _ in 0..<100 { if await worker.hasCapture() { break }; await Task.yield() }
    try #require(await worker.hasCapture()); await worker.finishCapture()
    #expect(try await capture.value == entries && model.entries.isEmpty)
    let tasks = entries.map { entry in Task { try await model.receive(entry, destination: URL(fileURLWithPath: "/synthetic-not-accessed/" + entry.name)) } }
    for count in 1...3 {
        for _ in 0..<1000 { if await worker.downloadCount() == count { break }; await Task.yield() }
        #expect(await worker.downloadCount() == count); #expect(await worker.peakCount() == 1)
        await worker.finishDownload()
    }
    for task in tasks { _ = try await task.value }
    do { _ = try await model.receive(entries[0], destination: URL(fileURLWithPath: "/synthetic-not-accessed/replay")); Issue.record("Export ID was reused") } catch {}
    #expect(await worker.downloadCount() == 3)
}

@Test @MainActor func fileModelRejectsLateExplorerCaptureAfterCancelOrCloseBeforeAnyDestinationWork() async throws {
    let entry = try NativeFileEntry(id: String(repeating: "c", count: 32), name: "fresh", size: 0)
    for close in [false, true] {
        let worker = CapturedFileWorker([entry]), gate = FileRunGate(), model = FileTransferModel(rootName: "Synthetic", client: worker, gate: gate)
        let nonce = String(repeating: "a", count: 32), pending = Task { try await model.captureExplorer(nonce: nonce) }
        for _ in 0..<100 { if await worker.hasCapture() { break }; await Task.yield() }
        try #require(await worker.hasCapture())
        if close { model.close() } else { model.cancelExplorer(nonce: nonce) }
        await worker.finishCapture()
        if case .success = await pending.result { Issue.record("Late capture registered exported IDs") }
        do { _ = try await model.receive(entry, destination: URL(fileURLWithPath: "/synthetic-not-accessed/late")); Issue.record("Late export touched a destination") } catch {}
        #expect(await worker.downloadCount() == 0)
    }
}

@Test func fileTreeCancelAtEndNeverPublishesAndUploadSourceMutationStopsBeforeTreeEnd() async throws {
    let root = try ownedClientDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let node = try NativeFileNode(id: 1, parent: 0, name: "leaf", kind: .file, size: 3), bytes = Data([1, 2, 3])
    let packets = try treeDownloadPackets(name: "tree", nodes: [(node, bytes)]), gate = FileRunGate()
    let channel = ScriptedFileChannel(packets, afterRead: { count in if count == packets.count * 2 { gate.close() } })
    let client = NativeFileClient(endpoint: try fileEndpoint(), gate: gate, makeChannel: { _ in channel }), operation = try gate.begin()
    let entry = try NativeFileEntry(id: String(repeating: "a", count: 32), name: "tree", size: 0, kind: .folder)
    do { _ = try await client.download(entry: entry, destination: root.appendingPathComponent("target"), operation: operation, progress: { _, _ in }); Issue.record("Revoked tree was published") }
    catch { #expect(error as? NativeFileError == .closed) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    let source = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    let leaf = source.appendingPathComponent("leaf"); try bytes.write(to: leaf)
    let upload = ScriptedFileChannel([try authorizedFilePacket(), try FilePacket(kind: .accepted, payload: FileWire.json(["name": "source", "size": 3, "kind": "folder", "count": 1]))], afterSend: { packet in
        if packet.kind == .chunk { try? Data([4, 5, 6, 7]).write(to: leaf) }
    })
    let uploadGate = FileRunGate(), uploadID = try uploadGate.begin(), sender = NativeFileClient(endpoint: try fileEndpoint(), gate: uploadGate, makeChannel: { _ in upload })
    do { _ = try await sender.upload(url: source, operation: uploadID, progress: { _, _ in }); Issue.record("Mutated tree was accepted") }
    catch { #expect(error as? NativeFileError == .changed) }
    uploadGate.end(uploadID)
    #expect(!upload.snapshot().contains { $0.kind == .treeEnd })
}

private final class FileExportTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return value }
    func expire() { lock.lock(); value += .seconds(61); lock.unlock() }
}

@Test @MainActor func fileExportExpiryAndQueuedCloseRejectBeforeWorkerDestinationAdmission() async throws {
    let entry = try NativeFileEntry(id: String(repeating: "d", count: 32), name: "fresh", size: 0), clock = FileExportTestClock()
    let worker = CapturedFileWorker([entry]), gate = FileRunGate()
    let model = FileTransferModel(rootName: "Synthetic", client: worker, gate: gate, exportNow: { clock.now() })
    let pending = Task { try await model.captureExplorer(nonce: String(repeating: "a", count: 32)) }
    for _ in 0..<100 { if await worker.hasCapture() { break }; await Task.yield() }
    try #require(await worker.hasCapture()); await worker.finishCapture(); _ = try await pending.value
    clock.expire()
    do { _ = try await model.receive(entry, destination: URL(fileURLWithPath: "/synthetic-not-accessed/expired")); Issue.record("Expired ID was admitted") } catch {}
    #expect(await worker.downloadCount() == 0)
    let shared = FileTransferModel(rootName: "Synthetic", client: worker, gate: gate, entries: [entry])
    let requests = (0..<32).map { number in Task { try await shared.receive(entry, destination: URL(fileURLWithPath: "/synthetic-not-accessed/\(number)")) } }
    for _ in 0..<1000 { if await worker.downloadCount() == 1 { break }; await Task.yield() }
    try #require(await worker.downloadCount() == 1)
    for _ in 0..<100 { await Task.yield() }
    do { _ = try await shared.receive(entry, destination: URL(fileURLWithPath: "/synthetic-not-accessed/overflow")); Issue.record("Promise queue exceeded 32") }
    catch { #expect(error as? NativeFileError == .busy) }
    shared.close(); await worker.finishDownload()
    for request in requests { if case .success = await request.result { Issue.record("Closed queued promise succeeded") } }
    #expect(await worker.downloadCount() == 1)
}

private func clientTreeVectorData(_ object: [String: Any], _ key: String) throws -> Data {
    let encoded = try #require(object[key] as? String)
    return try #require(Data(base64Encoded: encoded))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["KNOT_NATIVE_WINDOWS_FIXTURES"] != nil,
               "Actual Windows tree vectors are generated from fresh fixtures in full CI."))
func actualWindowsTreesDownloadThroughClientToExclusiveQuarantinedMacFolders() async throws {
    let fixtures = try #require(ProcessInfo.processInfo.environment["KNOT_NATIVE_WINDOWS_FIXTURES"])
    let raw = try Data(contentsOf: URL(fileURLWithPath: fixtures).appendingPathComponent("native-file-vectors.json"))
    try #require(raw.count <= 1_048_576)
    let object = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any]), trees = try #require(object["trees"] as? [[String: Any]])
    let root = try ownedClientDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    for (index, tree) in trees.enumerated() {
        let encoded = try clientTreeVectorData(tree, "encodedBase64")
        var packets = [try authorizedFilePacket()], cursor = 0
        while cursor < encoded.count {
            try #require(cursor + 5 <= encoded.count)
            let (kind, count) = try FilePacket.header(encoded.subdata(in: cursor..<(cursor + 5))); cursor += 5
            try #require(cursor + count <= encoded.count)
            packets.append(try FilePacket(kind: kind, payload: encoded.subdata(in: cursor..<(cursor + count)))); cursor += count
        }
        let accepted = try FileWire.accepted(packets[1].payload)
        let entry = try NativeFileEntry(id: String(format: "%032x", index + 1), name: accepted.name, size: 0, kind: .folder)
        let gate = FileRunGate(), channel = ScriptedFileChannel(packets), operation = try gate.begin()
        let client = NativeFileClient(endpoint: try fileEndpoint(), gate: gate, makeChannel: { _ in channel }), destination = root.appendingPathComponent("tree-\(index)")
        #expect(try await client.download(entry: entry, destination: destination, operation: operation, progress: { _, _ in }) == destination); gate.end(operation)
        var paths: [Int: URL] = [0: destination]
        for item in try #require(tree["nodes"] as? [[String: Any]]) {
            let node = try NativeFileNode(try clientTreeVectorData(item, "jsonBase64"))
            let path = try #require(paths[node.parent]).appendingPathComponent(node.name); paths[node.id] = path
            if node.kind == .file {
                let expected = try clientTreeVectorData(item, "bytesBase64")
                #expect(try Data(contentsOf: path) == expected)
                #expect(getxattr(path.path, "com.apple.quarantine", nil, 0, 0, 0) > 0)
            } else { var isDirectory: ObjCBool = false; #expect(FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) && isDirectory.boolValue) }
        }
    }
}

private final class FileAdapterTestCount: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func mark() { lock.lock(); value += 1; lock.unlock() }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

@Test func invalidCompleteTreeSnapshotNeverCreatesNetworkAdapter() async throws {
    let root = try ownedClientDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let tree = root.appendingPathComponent("tree"); try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
    let leaf = tree.appendingPathComponent("leaf"); try Data([1]).write(to: leaf)
    try FileManager.default.createSymbolicLink(at: tree.appendingPathComponent("link"), withDestinationURL: leaf)
    let counter = FileAdapterTestCount(), gate = FileRunGate(), operation = try gate.begin()
    let client = NativeFileClient(endpoint: try fileEndpoint(), gate: gate, makeChannel: { _ in counter.mark(); return ScriptedFileChannel([]) })
    do { _ = try await client.upload(url: tree, operation: operation, progress: { _, _ in }); Issue.record("Incomplete source snapshot was admitted") } catch {}
    gate.end(operation)
    #expect(counter.count() == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["tree"])
}

@Test @MainActor func fileExplorerFixtureCallbacksStayInertAndCountAttempts() async throws {
    let model = FileTransferModel(rootName: "Synthetic")
    do { _ = try await model.captureExplorer(nonce: String(repeating: "a", count: 32)); Issue.record("Fixture captured Explorer") }
    catch { #expect(error as? NativeFileError == .unsupported) }
    model.cancelExplorer(nonce: String(repeating: "a", count: 32))
    #expect(model.fixtureOperationAttempts == 2 && !model.isBusy && model.entries.isEmpty)
}

@Test @MainActor func cancellingExplorerNonceRevokesActiveAndQueuedPromisesBeforeLateCompletion() async throws {
    let entries = try (0..<2).map { try NativeFileEntry(id: String(format: "%032x", $0 + 10), name: "entry-\($0)", size: 0) }
    let worker = CapturedFileWorker(entries), gate = FileRunGate(), model = FileTransferModel(rootName: "Synthetic", client: worker, gate: gate)
    let nonce = String(repeating: "a", count: 32), capture = Task { try await model.captureExplorer(nonce: nonce) }
    for _ in 0..<100 { if await worker.hasCapture() { break }; await Task.yield() }
    try #require(await worker.hasCapture()); await worker.finishCapture(); _ = try await capture.value
    let requests = entries.map { entry in Task { try await model.receive(entry, destination: URL(fileURLWithPath: "/synthetic-not-accessed/" + entry.name)) } }
    for _ in 0..<1000 { if await worker.downloadCount() == 1 { break }; await Task.yield() }
    try #require(await worker.downloadCount() == 1)
    model.cancelExplorer(nonce: nonce); await worker.finishDownload()
    for request in requests { if case .success = await request.result { Issue.record("Revoked exported promise reported success") } }
    #expect(await worker.downloadCount() == 1 && !model.isBusy)
}

@Test func maliciousWindowsPackageFolderMetadataAndNodesNeverPublishAnAppBundle() async throws {
    let root = try ownedClientDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let sentinel = root.appendingPathComponent("unrelated.txt"); try Data("untouched".utf8).write(to: sentinel)
    for name in ["helper.xpc", "program.app", "document.RTFD"] {
        let entry = try NativeFileEntry(id: String(repeating: "a", count: 32), name: "ordinary", size: 0, kind: .folder)
        let acceptedPackage = try FilePacket(kind: .accepted, payload: FileWire.json(["name": name, "size": 0, "kind": "folder", "count": 0]))
        let acceptedOrdinary = try FilePacket(kind: .accepted, payload: FileWire.json(["name": entry.name, "size": 0, "kind": "folder", "count": 2]))
        let first = try FilePacket(kind: .node, payload: NativeFileNode(id: 1, parent: 0, name: "owned", kind: .folder, size: 0).json)
        let malicious = try FilePacket(kind: .node, payload: FileWire.json(["id": 2, "parent": 1, "name": name, "kind": "folder", "size": 0]))
        for replies in [[try authorizedFilePacket(), acceptedPackage], [try authorizedFilePacket(), acceptedOrdinary, first, malicious]] {
            let channel = ScriptedFileChannel(replies), gate = FileRunGate(), operation = try gate.begin()
            let client = NativeFileClient(endpoint: try fileEndpoint(), gate: gate, makeChannel: { _ in channel })
            do { _ = try await client.download(entry: entry, destination: root.appendingPathComponent("received"), operation: operation, progress: { _, _ in }); Issue.record("Package folder was published") }
            catch { #expect(error as? NativeFileError == .protocolViolation) }
            gate.end(operation)
            #expect(!channel.snapshot().contains { $0.kind == .complete })
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["unrelated.txt"])
        }
    }
    #expect(try Data(contentsOf: sentinel) == Data("untouched".utf8))
}

@Test func exactFinderPromiseFolderURLCannotRenameAnOrdinaryTreeIntoAPackage() async throws {
    let root = try ownedClientDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let entry = try NativeFileEntry(id: String(repeating: "b", count: 32), name: "ordinary", size: 0, kind: .folder)
    for name in ["finder-drop.xpc", "finder-drop.APP", "finder-drop.rtfd", "finder-drop.storyboardc"] {
        let channel = ScriptedFileChannel(try treeDownloadPackets(name: entry.name, nodes: [])), gate = FileRunGate(), operation = try gate.begin()
        let client = NativeFileClient(endpoint: try fileEndpoint(), gate: gate, makeChannel: { _ in channel })
        do { _ = try await client.download(entry: entry, destination: root.appendingPathComponent(name), operation: operation, progress: { _, _ in }); Issue.record("Promise destination converted an ordinary tree into a package") }
        catch { #expect(error as? NativeFileError == .unsupported) }
        gate.end(operation)
        #expect(!channel.snapshot().contains { $0.kind == .complete })
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}

@Test func regularInstallerAndExecutableNamedFilesStillReceiveQuarantine() async throws {
    let root = try ownedClientDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    for name in ["installer.pkg", "program.exe"] {
        let bytes = Data("fresh inert fixture".utf8), entry = try NativeFileEntry(id: String(repeating: "c", count: 32), name: name, size: Int64(bytes.count))
        let channel = ScriptedFileChannel(try fileDownloadPackets(entry, bytes: bytes)), gate = FileRunGate(), operation = try gate.begin()
        let client = NativeFileClient(endpoint: try fileEndpoint(), gate: gate, makeChannel: { _ in channel }), destination = root.appendingPathComponent(name)
        #expect(try await client.download(entry: entry, destination: destination, operation: operation, progress: { _, _ in }) == destination)
        gate.end(operation)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(getxattr(destination.path, "com.apple.quarantine", nil, 0, 0, 0) > 0)
    }
}
