import Foundation
import CryptoKit
import KnotNativeCore

struct NativeFileListing: Sendable { let entries: [NativeFileEntry]; let truncated: Bool }
struct NativeFileReceipt: Sendable { let name: String; let size: Int64; let hash: String }
typealias NativeFileProgress = @Sendable (Int64, Int64) async -> Void

protocol NativeFileWorking: Sendable {
    func list(operation: UUID) async throws -> NativeFileListing
    func upload(url: URL, operation: UUID, progress: @escaping NativeFileProgress) async throws -> NativeFileReceipt
    func download(entry: NativeFileEntry, destination: URL, operation: UUID, progress: @escaping NativeFileProgress) async throws -> URL
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
            try await channel.send(FilePacket(kind: .hello, payload: FileWire.json(["v": 1, "token": endpoint.token])))
            let reply = try await packet(channel, deadline: deadline)
            guard reply.kind == .authorized,
                  try FileWire.object(reply.payload, keys: ["v"]).integer("v") == 1 else { throw NativeFileError.auth }
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
            let deadline = ContinuousClock.now + .seconds(15)
            var values: [NativeFileEntry] = [], identifiers = Set<String>()
            while true {
                try gate.check(operation); let reply = try await packet(channel, deadline: deadline)
                if reply.kind == .entry {
                    let entry = try NativeFileEntry(reply.payload)
                    guard values.count < FileWire.maximumEntries, identifiers.insert(entry.id).inserted else { throw NativeFileError.protocolViolation }
                    values.append(entry)
                } else if reply.kind == .listEnd {
                    let end = try FileWire.object(reply.payload, keys: ["count", "truncated"])
                    guard try end.integer("count") == values.count else { throw NativeFileError.protocolViolation }
                    return NativeFileListing(entries: values, truncated: try end.boolean("truncated"))
                } else { throw NativeFileError.protocolViolation }
            }
        } onCancel: { [gate] in gate.cancel(operation) }
    }
    func upload(url: URL, operation: UUID, progress: @escaping NativeFileProgress) async throws -> NativeFileReceipt {
        try await withTaskCancellationHandler {
            try gate.check(operation)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let source = try NativeFileSource(url: url)
            let channel = try await connected(operation: operation)
            defer { gate.unbind(channel, id: operation) }
            try await channel.send(FilePacket(kind: .put, payload: FileWire.json(["name": source.name, "size": source.size])))
            let accepted = try await packet(channel)
            guard accepted.kind == .accepted else { throw NativeFileError.protocolViolation }
            let target = try FileWire.metadata(accepted.payload)
            guard target.size == source.size else { throw NativeFileError.protocolViolation }
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
                guard completion.name == target.name, completion.size == offset, completion.hash == hex else { throw NativeFileError.changed }
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
            let source = try FileWire.metadata(accepted.payload)
            guard source.name == entry.name, source.size == entry.size else { throw NativeFileError.changed }
            try gate.reserve(source.size, id: operation)
            let scoped = destination.deletingLastPathComponent().startAccessingSecurityScopedResource()
            defer { if scoped { destination.deletingLastPathComponent().stopAccessingSecurityScopedResource() } }
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
