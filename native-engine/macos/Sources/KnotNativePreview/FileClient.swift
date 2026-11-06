import Foundation
import CryptoKit
import Darwin
import KnotNativeCore

struct NativeFileListing: Sendable { let entries: [NativeFileEntry]; let truncated: Bool }
struct NativeFileReceipt: Sendable { let name: String; let size: Int64; let hash: String }
typealias NativeFileProgress = @Sendable (Int64, Int64) async -> Void

protocol NativeFileWorking: Sendable {
    func captureExplorer(nonce: String, operation: UUID) async throws -> NativeFileListing
    func cancelExplorer(nonce: String, operation: UUID) async throws
    func list(operation: UUID) async throws -> NativeFileListing
    func upload(url: URL, operation: UUID, progress: @escaping NativeFileProgress) async throws -> NativeFileReceipt
    func download(entry: NativeFileEntry, destination: URL, operation: UUID, progress: @escaping NativeFileProgress) async throws -> URL
}

extension NativeFileWorking {
    func captureExplorer(nonce: String, operation: UUID) async throws -> NativeFileListing { throw NativeFileError.unsupported }
    func cancelExplorer(nonce: String, operation: UUID) async throws { throw NativeFileError.unsupported }
}

actor NativeFileClient: NativeFileWorking {
    private let endpoint: NativeFileEndpoint
    private let gate: FileRunGate
    private let makeChannel: @Sendable (NativeFileEndpoint) throws -> any NativeFileChannel
    init(endpoint: NativeFileEndpoint, gate: FileRunGate,
         makeChannel: @escaping @Sendable (NativeFileEndpoint) throws -> any NativeFileChannel = { try FileTLSChannel(endpoint: $0) }) {
        self.endpoint = endpoint; self.gate = gate; self.makeChannel = makeChannel
    }
    private func connected(operation: UUID) async throws -> any NativeFileChannel {
        try gate.check(operation)
        let channel = try makeChannel(endpoint)
        try gate.bind(channel, id: operation)
        do {
            let deadline = ContinuousClock.now + .seconds(10)
            try await channel.start(); try gate.check(operation)
            try await channel.send(FilePacket(kind: .hello, payload: FileWire.json(["v": 2, "token": endpoint.token])))
            let reply = try await packet(channel, deadline: deadline)
            guard reply.kind == .authorized,
                  try FileWire.object(reply.payload, keys: ["v"]).integer("v") == 2 else { throw NativeFileError.auth }
            try gate.check(operation); return channel
        } catch { gate.unbind(channel, id: operation); throw error }
    }
    private func packet(_ channel: any NativeFileChannel, deadline: ContinuousClock.Instant? = nil) async throws -> FilePacket {
        let end = min(deadline ?? (.now + .seconds(30)), .now + .seconds(30))
        guard end > .now else { throw NativeFileError.timeout }
        let header = try await channel.readExactly(5, timeout: end - .now)
        let (kind, count) = try FilePacket.header(header)
        guard end > .now else { throw NativeFileError.timeout }
        let body = count == 0 ? Data() : try await channel.readExactly(count, timeout: end - .now)
        let packet = try FilePacket(kind: kind, payload: body)
        if kind == .error { throw try FileWire.remoteError(body) }
        return packet
    }
    func list(operation: UUID) async throws -> NativeFileListing {
        try await withTaskCancellationHandler {
            let channel = try await connected(operation: operation)
            defer { gate.unbind(channel, id: operation) }
            try await channel.send(FilePacket(kind: .list))
            return try await listing(channel, operation: operation, maximum: FileWire.maximumEntries)
        } onCancel: { [gate] in gate.cancel(operation) }
    }
    func captureExplorer(nonce: String, operation: UUID) async throws -> NativeFileListing {
        guard FileWire.isHex(nonce, count: 32) else { throw NativeFileError.protocolViolation }
        return try await withTaskCancellationHandler {
            let channel = try await connected(operation: operation)
            defer { gate.unbind(channel, id: operation) }
            try await channel.send(FilePacket(kind: .explorerCapture, payload: FileWire.json(["nonce": nonce])))
            return try await listing(channel, operation: operation, maximum: 32, capture: true)
        } onCancel: { [gate] in gate.cancel(operation) }
    }
    func cancelExplorer(nonce: String, operation: UUID) async throws {
        guard FileWire.isHex(nonce, count: 32) else { throw NativeFileError.protocolViolation }
        let channel = try await connected(operation: operation)
        defer { gate.unbind(channel, id: operation) }
        try await channel.send(FilePacket(kind: .explorerCancel, payload: FileWire.json(["nonce": nonce])))
    }
    private func listing(_ channel: any NativeFileChannel, operation: UUID, maximum: Int, capture: Bool = false) async throws -> NativeFileListing {
            let deadline = ContinuousClock.now + .seconds(capture ? 6 : 15)
            var values: [NativeFileEntry] = [], identifiers = Set<String>()
            while true {
                try gate.check(operation); let reply = try await packet(channel, deadline: deadline)
                if reply.kind == .entry {
                    let entry = try NativeFileEntry(reply.payload)
                    guard values.count < maximum, identifiers.insert(entry.id).inserted else { throw NativeFileError.protocolViolation }
                    values.append(entry)
                } else if reply.kind == .listEnd {
                    let end = try FileWire.object(reply.payload, keys: ["count", "truncated"])
                    let truncated = try end.boolean("truncated")
                    guard try end.integer("count") == values.count, !capture || (!values.isEmpty && !truncated) else { throw NativeFileError.protocolViolation }
                    return NativeFileListing(entries: values, truncated: try end.boolean("truncated"))
                } else { throw NativeFileError.protocolViolation }
            }
    }
    func upload(url: URL, operation: UUID, progress: @escaping NativeFileProgress) async throws -> NativeFileReceipt {
        try await withTaskCancellationHandler {
            try gate.check(operation)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw NativeFileError.denied }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                return try await uploadTree(source: NativeFileTreeSource(url: url), operation: operation, progress: progress)
            }
            let source = try NativeFileSource(url: url)
            let channel = try await connected(operation: operation)
            defer { gate.unbind(channel, id: operation) }
            try await channel.send(FilePacket(kind: .put, payload: FileWire.json(["name": source.name, "size": source.size])))
            let accepted = try await packet(channel)
            guard accepted.kind == .accepted else { throw NativeFileError.protocolViolation }
            let target = try FileWire.accepted(accepted.payload)
            guard target.kind == .file, target.count == 0, target.size == source.size else { throw NativeFileError.protocolViolation }
            try gate.reserve(source.size, id: operation)
            var hash = SHA256(), offset: Int64 = 0
            let began = ContinuousClock.now
            await progress(0, source.size)
            while offset < source.size {
                try Task.checkCancellation(); try gate.check(operation)
                let bytes = try source.read(Int(min(Int64(FileWire.chunkBytes), source.size - offset)))
                guard !bytes.isEmpty else { throw NativeFileError.changed }
                var payload = Data(); payload.appendBE(UInt64(offset)); payload.append(bytes)
                try await channel.send(FilePacket(kind: .chunk, payload: payload))
                hash.update(data: bytes); offset += Int64(bytes.count)
                try await pace(offset, began: began); await progress(offset, source.size)
            }
            try source.requireUnchanged(); try gate.check(operation)
            let digest = Data(hash.finalize()), hex = Self.hex(digest)
            do {
                try await channel.send(FileWire.finish(size: offset, digest: digest))
                let result = try await packet(channel)
                guard result.kind == .complete else { throw NativeFileError.protocolViolation }
                let completion = try FileWire.completion(result.payload)
                // Windows resolves a collision at exclusive publication, after Accepted.
                // completion() already validates the actual destination basename.
                guard completion.size == offset, completion.hash == hex else { throw NativeFileError.changed }
                try gate.check(operation)
                return NativeFileReceipt(name: completion.name, size: offset, hash: hex)
            } catch {
                // Finish may already have committed on Windows. Missing or
                // invalid Complete is never success and is never replayed.
                try gate.check(operation)
                throw NativeFileError.unconfirmed
            }
        } onCancel: { [gate] in gate.cancel(operation) }
    }
    func download(entry: NativeFileEntry, destination: URL, operation: UUID, progress: @escaping NativeFileProgress) async throws -> URL {
        try await withTaskCancellationHandler {
            let channel = try await connected(operation: operation)
            defer { gate.unbind(channel, id: operation) }
            try await channel.send(FilePacket(kind: .get, payload: FileWire.json(["entry": entry.id])))
            let accepted = try await packet(channel)
            guard accepted.kind == .accepted else { throw NativeFileError.protocolViolation }
            let source = try FileWire.accepted(accepted.payload)
            guard source.name == entry.name, source.kind == entry.kind, source.kind == .folder || source.size == entry.size else { throw NativeFileError.changed }
            try gate.reserve(source.size, nodes: source.kind == .folder ? source.count + 1 : 1, id: operation)
            let scoped = destination.deletingLastPathComponent().startAccessingSecurityScopedResource()
            defer { if scoped { destination.deletingLastPathComponent().stopAccessingSecurityScopedResource() } }
            if source.kind == .folder {
                return try await downloadTree(channel: channel, destination: destination, count: source.count, size: source.size, operation: operation, progress: progress)
            }
            let target = try NativeFileDestination(url: destination, size: source.size)
            var hash = SHA256(), offset: Int64 = 0
            let began = ContinuousClock.now
            await progress(0, source.size)
            while offset < source.size {
                try Task.checkCancellation(); try gate.check(operation)
                let reply = try await packet(channel)
                guard reply.kind == .chunk, reply.payload.readBE(UInt64.self, at: 0) == UInt64(offset) else { throw NativeFileError.protocolViolation }
                let bytes = Data(reply.payload.dropFirst(8))
                guard Int64(bytes.count) <= source.size - offset else { throw NativeFileError.protocolViolation }
                try target.write(bytes); hash.update(data: bytes); offset += Int64(bytes.count)
                try await pace(offset, began: began); await progress(offset, source.size)
            }
            let finish = try await packet(channel)
            guard finish.kind == .finish else { throw NativeFileError.protocolViolation }
            let digest = Data(hash.finalize())
            try FileWire.checkFinish(finish.payload, size: source.size, digest: digest)
            try target.prepare()
            // No await lies between the last live-operation check and rename.
            let saved = try gate.publish(id: operation) { try target.publish() }
            let acknowledgement = try FilePacket(kind: .complete, payload: FileWire.json(["name": saved.lastPathComponent, "size": source.size, "sha256": Self.hex(digest)]))
            do { try await channel.send(acknowledgement) }
            catch {
                // Local receipt is already verified and exclusively published.
                // A failed final transport acknowledgement cannot undo it and
                // must not tell the user to retry into an existing file. The
                // sender may truthfully report an unconfirmed remote receipt.
                guard error as? NativeFailure == .transport || error as? NativeFileError == .timeout || error as? NativeFileError == .io else { throw error }
                try gate.check(operation); return saved
            }
            try gate.check(operation); return saved
        } onCancel: { [gate] in gate.cancel(operation) }
    }
    private func uploadTree(source: NativeFileTreeSource, operation: UUID, progress: @escaping NativeFileProgress) async throws -> NativeFileReceipt {
        try gate.reserve(source.size, nodes: source.items.count + 1, id: operation)
        let channel = try await connected(operation: operation)
        defer { gate.unbind(channel, id: operation) }
        try await channel.send(FilePacket(kind: .treePut, payload: FileWire.json(["name": source.name, "size": source.size, "count": source.items.count])))
        let accepted = try await packet(channel)
        guard accepted.kind == .accepted else { throw NativeFileError.protocolViolation }
        let target = try FileWire.accepted(accepted.payload)
        guard target.kind == .folder, target.size == source.size, target.count == source.items.count else { throw NativeFileError.protocolViolation }
        var treeHash = SHA256(), total: Int64 = 0
        let began = ContinuousClock.now
        await progress(0, source.size)
        for item in source.items {
            try Task.checkCancellation(); try gate.check(operation)
            var length = Data(); length.appendBE(UInt32(item.raw.count)); treeHash.update(data: length); treeHash.update(data: item.raw)
            try await channel.send(FilePacket(kind: .node, payload: item.raw))
            if item.node.kind == .folder { continue }
            let file = try source.openFile(item)
            var hash = SHA256(), offset: Int64 = 0
            while offset < item.node.size {
                try Task.checkCancellation(); try gate.check(operation)
                let bytes = try file.read(Int(min(Int64(FileWire.chunkBytes), item.node.size - offset)))
                guard !bytes.isEmpty else { throw NativeFileError.changed }
                var payload = Data(); payload.appendBE(UInt64(offset)); payload.append(bytes)
                try await channel.send(FilePacket(kind: .chunk, payload: payload))
                hash.update(data: bytes); treeHash.update(data: bytes); offset += Int64(bytes.count); total += Int64(bytes.count)
                try await pace(total, began: began); await progress(total, source.size)
            }
            try file.requireUnchanged(); try gate.check(operation)
            try await channel.send(FileWire.finish(size: offset, digest: Data(hash.finalize())))
        }
        try source.requireUnchanged(); try gate.check(operation)
        let digest = Self.hex(Data(treeHash.finalize()))
        do {
            try await channel.send(FilePacket(kind: .treeEnd, payload: FileWire.json(["count": source.items.count, "size": total, "sha256": digest])))
            let complete = try await packet(channel)
            guard complete.kind == .complete else { throw NativeFileError.protocolViolation }
            let receipt = try FileWire.completion(complete.payload)
            guard receipt.size == total, receipt.hash == digest else { throw NativeFileError.changed }
            try gate.check(operation); return NativeFileReceipt(name: receipt.name, size: total, hash: digest)
        } catch { try gate.check(operation); throw NativeFileError.unconfirmed }
    }
    private func downloadTree(channel: any NativeFileChannel, destination: URL, count: Int, size: Int64,
                              operation: UUID, progress: @escaping NativeFileProgress) async throws -> URL {
        var admission = try NativeFileTreeAdmission(count: count, size: size)
        let target = try NativeFileTreeDestination(url: destination, size: size)
        var treeHash = SHA256(), total: Int64 = 0
        let began = ContinuousClock.now
        await progress(0, size)
        for _ in 0..<count {
            try Task.checkCancellation(); try gate.check(operation)
            let reply = try await packet(channel)
            guard reply.kind == .node else { throw NativeFileError.protocolViolation }
            let node = try admission.append(reply.payload)
            var length = Data(); length.appendBE(UInt32(reply.payload.count)); treeHash.update(data: length); treeHash.update(data: reply.payload)
            try target.create(node)
            if node.kind == .folder { continue }
            var hash = SHA256(), offset: Int64 = 0
            while offset < node.size {
                try Task.checkCancellation(); try gate.check(operation)
                let reply = try await packet(channel)
                guard reply.kind == .chunk, reply.payload.readBE(UInt64.self, at: 0) == UInt64(offset) else { throw NativeFileError.protocolViolation }
                let bytes = Data(reply.payload.dropFirst(8))
                guard Int64(bytes.count) <= node.size - offset else { throw NativeFileError.protocolViolation }
                try target.write(bytes); hash.update(data: bytes); treeHash.update(data: bytes)
                offset += Int64(bytes.count); total += Int64(bytes.count)
                try await pace(total, began: began); await progress(total, size)
            }
            let finish = try await packet(channel)
            guard finish.kind == .finish else { throw NativeFileError.protocolViolation }
            try FileWire.checkFinish(finish.payload, size: node.size, digest: Data(hash.finalize()))
            try target.finishFile()
        }
        try admission.finish()
        let end = try await packet(channel)
        guard end.kind == .treeEnd else { throw NativeFileError.protocolViolation }
        let receipt = try FileWire.treeEnd(end.payload), digest = Self.hex(Data(treeHash.finalize()))
        guard receipt.count == count, receipt.size == size, receipt.hash == digest else { throw NativeFileError.changed }
        try target.prepare()
        let saved = try gate.publish(id: operation) { try target.publish() }
        do { try await channel.send(FilePacket(kind: .complete, payload: FileWire.json(["name": saved.lastPathComponent, "size": size, "sha256": digest]))) }
        catch {
            guard error as? NativeFailure == .transport || error as? NativeFileError == .timeout || error as? NativeFileError == .io else { throw error }
            try gate.check(operation); return saved
        }
        try gate.check(operation); return saved
    }
    private func pace(_ count: Int64, began: ContinuousClock.Instant) async throws {
        let deadline = began + .nanoseconds(count * 1_000_000_000 / FileWire.bytesPerSecond)
        if deadline > .now { try await Task.sleep(until: deadline) }
    }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

private actor DisabledFileClient: NativeFileWorking {
    func list(operation: UUID) async throws -> NativeFileListing { throw NativeFileError.closed }
    func upload(url: URL, operation: UUID, progress: @escaping NativeFileProgress) async throws -> NativeFileReceipt { throw NativeFileError.closed }
    func download(entry: NativeFileEntry, destination: URL, operation: UUID, progress: @escaping NativeFileProgress) async throws -> URL { throw NativeFileError.closed }
}

func disabledFileClient() -> any NativeFileWorking { DisabledFileClient() }
