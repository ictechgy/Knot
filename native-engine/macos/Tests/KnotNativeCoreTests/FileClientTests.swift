import Foundation
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
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("knot-client-file-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); return url
}
private func fileEndpoint() throws -> NativeFileEndpoint {
    let json = try JSONSerialization.data(withJSONObject: ["v": 1, "address": "192.168.50.12", "port": 48631,
        "certificateSHA256": String(repeating: "a", count: 64), "token": Invitation.encodeBase64URL(Data(repeating: 1, count: 32))])
    let invitation = try Invitation("knot-native:v1:" + Invitation.encodeBase64URL(json))
    let offer = try NativeFileOffer(port: 48634, token: Invitation.encodeBase64URL(Data(repeating: 2, count: 32)), rootName: "Knot Files")
    return try NativeFileEndpoint(invitation: invitation, offer: offer)
}
private func authorizedFilePacket() throws -> FilePacket { try FilePacket(kind: .authorized, payload: FileWire.json(["v": 1])) }
private func fileDownloadPackets(_ entry: NativeFileEntry, bytes: Data, badOffset: Bool = false, badHash: Bool = false) throws -> [FilePacket] {
    var packets = [try authorizedFilePacket(), try FilePacket(kind: .accepted, payload: FileWire.json(["name": entry.name, "size": entry.size]))]
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
    let channel = ScriptedFileChannel([try authorizedFilePacket(), try FilePacket(kind: .accepted, payload: FileWire.json(["name": target, "size": bytes.count])),
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
    let channel = ScriptedFileChannel([try authorizedFilePacket(), try FilePacket(kind: .accepted, payload: FileWire.json(["name": "source.txt", "size": 3]))], afterSend: { packet in
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
    let authorized = try authorizedFilePacket(), accepted = try FilePacket(kind: .accepted, payload: FileWire.json(["name": "source.txt", "size": 1]))
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
    let entry = try FilePacket(kind: .entry, payload: FileWire.json(["entry": String(repeating: "a", count: 32), "name": "safe.txt", "size": 0]))
    let end = try FilePacket(kind: .listEnd, payload: FileWire.json(["count": 2, "truncated": false]))
    for replies in [[entry, entry, end], [entry, end]] {
        let channel = ScriptedFileChannel([try authorizedFilePacket()] + replies), gate = FileRunGate()
        let id = try gate.begin(), client = NativeFileClient(endpoint: try fileEndpoint(), gate: gate, makeChannel: { _ in channel })
        do { _ = try await client.list(operation: id); Issue.record("Invalid bounded listing was accepted") } catch {}
        gate.end(id); #expect(channel.isClosed())
    }
}

@Test func fileAuthAndMetadataPayloadsConsumeTheSameAbsoluteHeaderBudget() async throws {
    let entry = try FilePacket(kind: .entry, payload: FileWire.json(["entry": String(repeating: "a", count: 32), "name": "safe.txt", "size": 0]))
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
