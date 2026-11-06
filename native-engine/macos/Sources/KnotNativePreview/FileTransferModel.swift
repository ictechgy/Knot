import Foundation
import Combine
import KnotNativeCore
import AppKit

@MainActor
final class FileTransferModel: ObservableObject {
    let rootName: String
    @Published private(set) var entries: [NativeFileEntry]
    @Published private(set) var isBusy: Bool
    @Published private(set) var status: String
    @Published private(set) var progress: Double?
    @Published private(set) var currentName: String?
    @Published private(set) var truncated: Bool
    @Published private(set) var unfinishedUploads: [URL] = []
    @Published private(set) var lastReceivedURL: URL?
    @Published private(set) var completedItems = 0
    var canRetryUploads: Bool { !isBusy && client != nil && !unfinishedUploads.isEmpty }
    func retryUnfinishedUploads() { guard canRetryUploads else { return }; send(urls: unfinishedUploads) }
    func revealLastReceived() { if fixtureMode { fixtureOperationAttempts += 1; return }; if let lastReceivedURL { NSWorkspace.shared.activateFileViewerSelecting([lastReceivedURL]) } }
    private var client: (any NativeFileWorking)?
    private let gate: FileRunGate
    private var work: Task<Void, Never>?
    private var receiver: Task<URL, any Error>?
    private var generation = UUID()
    private var lastProgress = ContinuousClock.now
    private var lifetime = UUID()
    private var receiveTail: Task<Void, Never>?
    private var queuedReceives: [UUID: Task<URL, any Error>] = [:]
    private struct Export { let entry: NativeFileEntry; let nonce: String; let expires: ContinuousClock.Instant }
    private var exports: [String: Export] = [:]
    private var usedExportIDs = Set<String>()
    private var exportNow: @Sendable () -> ContinuousClock.Instant = { .now }
    private var exportNonces: [String: ContinuousClock.Instant] = [:]
    private var captureWork: Task<NativeFileListing, any Error>?
    private var captureOperation: UUID?
    private var captureNonce: String?
    private var receivingExportNonce: String?
    private var receivingExportOperation: UUID?
    private var fixtureMode = false
    private(set) var fixtureOperationAttempts = 0

    init(invitation: Invitation, offer: NativeFileOffer,
         makeChannel: @escaping @Sendable (NativeFileEndpoint) throws -> any NativeFileChannel = { try FileTLSChannel(endpoint: $0) }) throws {
        let gate = FileRunGate()
        self.gate = gate; rootName = offer.rootName
        client = NativeFileClient(endpoint: try NativeFileEndpoint(invitation: invitation, offer: offer), gate: gate, makeChannel: makeChannel)
        entries = []; isBusy = false; status = "Windows 공유 폴더의 파일을 확인하세요."
        progress = nil; currentName = nil; truncated = false
    }

    /// Explicit inert presentation seam. No connection, file lookup or adapter
    /// creation happens while a synthetic view is being rendered.
    init(rootName: String, entries: [NativeFileEntry] = [], isBusy: Bool = false,
         status: String = "Windows 공유 폴더의 파일을 확인하세요.", progress: Double? = nil,
         currentName: String? = nil, truncated: Bool = false, completedItems: Int = 0,
         unfinishedUploads: [URL] = [], lastReceivedURL: URL? = nil) {
        self.rootName = rootName; self.entries = Array(entries.prefix(FileWire.maximumEntries))
        self.isBusy = isBusy; self.status = status; self.progress = progress
        self.currentName = currentName; self.truncated = truncated
        self.completedItems = max(0, completedItems); self.unfinishedUploads = Array(unfinishedUploads.prefix(32)); self.lastReceivedURL = lastReceivedURL
        gate = FileRunGate(); client = disabledFileClient()
        fixtureMode = true
    }

    /// Tests inject only fresh in-memory/owned-file workers and their gate.
    init(rootName: String, client: any NativeFileWorking, gate: FileRunGate, entries: [NativeFileEntry] = [],
         exportNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.rootName = rootName; self.client = client; self.gate = gate; self.entries = entries; self.exportNow = exportNow
        isBusy = false; status = "Windows 공유 폴더의 파일을 확인하세요."
        progress = nil; currentName = nil; truncated = false
    }

    private func begin() throws -> (UUID, UUID, any NativeFileWorking) {
        guard let client else { throw NativeFileError.closed }
        guard !isBusy else { throw NativeFileError.busy }
        let operation = try gate.begin(), id = UUID(); generation = id
        isBusy = true; progress = nil; currentName = nil; lastProgress = .now
        return (id, operation, client)
    }
    func refresh() {
        if fixtureMode { fixtureOperationAttempts += 1 }
        do {
            let (id, operation, client) = try begin()
            status = "Windows 공유 폴더를 확인하고 있어요…"
            work = Task { [weak self, gate] in
                defer { gate.end(operation) }
                do {
                    let listing = try await client.list(operation: operation)
                    guard let self, self.generation == id, !Task.isCancelled else { return }
                    self.entries = listing.entries; self.truncated = listing.truncated
                    self.finish(id, status: listing.entries.isEmpty ? "공유 폴더가 비어 있어요. Mac 파일을 끌어 보내거나 Windows에서 이 폴더에 파일을 넣어주세요." : "파일을 골라 받거나 Finder로 끌어오세요.")
                } catch { self?.failed(id, error) }
            }
        } catch { status = NativeFileError.authored(error).message }
    }
    func send(urls: [URL]) {
        if fixtureMode { fixtureOperationAttempts += 1 }
        guard !urls.isEmpty, urls.count <= 32, urls.allSatisfy({ $0.isFileURL && FileWire.validName($0.lastPathComponent) }) else {
            status = urls.count > 32 ? "한 번에 파일 32개까지 보낼 수 있어요." : NativeFileError.unsupported.message; return
        }
        do {
            let (id, operation, client) = try begin()
            status = "Windows의 ‘\(rootName)’ 폴더로 보내고 있어요…"
            unfinishedUploads = urls
            work = Task { [weak self, gate] in
                defer { gate.end(operation) }
                var sent = 0
                do {
                    for url in urls {
                        guard let self, self.generation == id, !Task.isCancelled else { return }
                        self.currentName = url.lastPathComponent
                        _ = try await client.upload(url: url, operation: operation) { [weak self] bytes, total in
                            await self?.record(bytes: bytes, total: total, id: id)
                        }
                        sent += 1
                        guard self.generation == id, !Task.isCancelled else { return }
                        self.unfinishedUploads = Array(urls.dropFirst(sent)); self.completedItems += 1
                    }
                    guard let self, self.generation == id, !Task.isCancelled else { return }
                    // This is the explicit send action's final list refresh,
                    // not a background retry or an automatic media reconnect.
                    if let listing = try? await client.list(operation: operation) {
                        guard self.generation == id, !Task.isCancelled else { return }
                        self.entries = listing.entries; self.truncated = listing.truncated
                    }
                    self.finish(id, status: "\(sent)개 항목을 Windows의 ‘\(self.rootName)’ 폴더로 보냈어요. 원본은 유지돼요.")
                } catch {
                    guard let self, self.generation == id else { return }
                    self.failed(id, error, prefix: sent > 0 ? "\(sent)개는 전송을 완료했어요. " : "")
                }
            }
        } catch { status = NativeFileError.authored(error).message }
    }
    func captureExplorer(nonce: String) async throws -> [NativeFileEntry] {
        if fixtureMode { fixtureOperationAttempts += 1; status = NativeFileError.unsupported.message; throw NativeFileError.unsupported }
        guard FileWire.isHex(nonce, count: 32) else { throw NativeFileError.protocolViolation }
        guard queuedReceives.isEmpty else { throw NativeFileError.busy }
        pruneExports()
        let (id, operation, client) = try begin(), live = lifetime
        captureNonce = nonce; captureOperation = operation
        status = "Windows 탐색기에서 끌어온 항목을 확인하고 있어요…"
        let task = Task { try await client.captureExplorer(nonce: nonce, operation: operation) }
        captureWork = task
        defer {
            gate.end(operation)
            if captureOperation == operation { captureOperation = nil; captureNonce = nil; captureWork = nil }
        }
        do {
            let listing = try await withTaskCancellationHandler { try await task.value } onCancel: { [gate] in task.cancel(); gate.cancel(operation) }
            try gate.check(operation)
            guard lifetime == live, generation == id, captureNonce == nonce, !Task.isCancelled,
                  !listing.entries.isEmpty, listing.entries.count <= 32, !listing.truncated else { throw NativeFileError.cancelled }
            guard Set(listing.entries.map(\.id)).count == listing.entries.count,
                  listing.entries.allSatisfy({ item in !entries.contains(where: { $0.id == item.id }) && exports[item.id] == nil && !usedExportIDs.contains(item.id) }) else { throw NativeFileError.protocolViolation }
            let expires = exportNow() + .seconds(60)
            exportNonces[nonce] = expires
            for entry in listing.entries { exports[entry.id] = Export(entry: entry, nonce: nonce, expires: expires) }
            finish(id, status: "Finder의 저장 위치로 끌어 놓으세요. 항목은 복사돼요.")
            return listing.entries
        } catch {
            let authored = NativeFileError.authored(error)
            if [.missing, .unsupported, .denied, .timeout].contains(authored) {
                finish(id, status: "Windows 탐색기에서 파일·폴더를 끈 채 다시 시도하세요. 파일 패널로도 받을 수 있어요.")
            } else { failed(id, error) }
            throw error
        }
    }
    private func pruneExports() {
        let now = exportNow()
        exports = exports.filter { $0.value.expires > now }
        exportNonces = exportNonces.filter { $0.value > now }
    }
    /// Synchronous local revocation precedes the best-effort authenticated cancellation.
    func cancelExplorer(nonce: String) {
        if fixtureMode { fixtureOperationAttempts += 1; return }
        exports = exports.filter { $0.value.nonce != nonce }; exportNonces.removeValue(forKey: nonce)
        if captureNonce == nonce {
            generation = UUID(); captureWork?.cancel()
            if let operation = captureOperation { gate.cancel(operation) }
            captureOperation = nil; captureNonce = nil; captureWork = nil
            isBusy = false; progress = nil; currentName = nil
        }
        if receivingExportNonce == nonce {
            generation = UUID(); receiver?.cancel()
            if let operation = receivingExportOperation { gate.cancel(operation) }
            receivingExportNonce = nil; receivingExportOperation = nil; receiver = nil
            isBusy = false; progress = nil; currentName = nil
        }
        status = "탐색기 끌어오기를 취소했어요. 화면 연결은 유지돼요."
        sendExplorerCancellation([nonce])
    }
    private func sendExplorerCancellation(_ nonces: [String]) {
        guard !nonces.isEmpty, let client, nonces.allSatisfy({ FileWire.isHex($0, count: 32) }), let operation = try? gate.begin() else { return }
        Task { [gate] in
            defer { gate.end(operation) }
            for nonce in nonces { try? await client.cancelExplorer(nonce: nonce, operation: operation) }
        }
    }
    /// Finder may fulfill every promise concurrently. Bound and serialize those
    /// callbacks before admitting a file operation or touching a destination.
    func receive(_ entry: NativeFileEntry, destination: URL) async throws -> URL {
        if fixtureMode { fixtureOperationAttempts += 1; throw NativeFileError.unsupported }
        guard client != nil else { throw NativeFileError.closed }
        pruneExports()
        guard queuedReceives.count < 32 else { throw NativeFileError.busy }
        let exported = exports[entry.id]
        if let exported {
            guard exported.entry == entry, exported.expires > exportNow(), exportNonces[exported.nonce] != nil else { throw NativeFileError.missing }
            usedExportIDs.insert(entry.id)
            exports.removeValue(forKey: entry.id) // claimed once, including cancellation
        } else { guard !usedExportIDs.contains(entry.id), entries.contains(entry) else { throw NativeFileError.missing } }
        let previous = receiveTail, live = lifetime, request = UUID()
        let task = Task { [weak self] () throws -> URL in
            await previous?.value
            try Task.checkCancellation()
            guard let self, self.lifetime == live, self.client != nil else { throw NativeFileError.closed }
            if let exported {
                guard exported.expires > self.exportNow(), self.exportNonces[exported.nonce] != nil else { throw NativeFileError.missing }
            } else { guard self.entries.contains(entry) else { throw NativeFileError.missing } }
            return try await self.receiveNow(entry, destination: destination, exportNonce: exported?.nonce)
        }
        queuedReceives[request] = task
        receiveTail = Task { _ = await task.result }
        defer { queuedReceives.removeValue(forKey: request) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func receiveNow(_ entry: NativeFileEntry, destination: URL, exportNonce: String?) async throws -> URL {

        if fixtureMode { fixtureOperationAttempts += 1 }
        let id: UUID, operation: UUID, client: any NativeFileWorking
        do {
            (id, operation, client) = try begin()
        } catch { status = NativeFileError.authored(error).message; throw error }
        receivingExportNonce = exportNonce; receivingExportOperation = operation
        defer { if receivingExportOperation == operation { receivingExportNonce = nil; receivingExportOperation = nil } }
        currentName = entry.name; status = "Mac에 파일을 받고 있어요…"
        let task = Task { [weak self] in
            try await client.download(entry: entry, destination: destination, operation: operation) { [weak self] bytes, total in
                await self?.record(bytes: bytes, total: total, id: id)
            }
        }
        receiver = task
        defer { gate.end(operation) }
        do {
            let saved = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel(); self.gate.cancel(operation) }
            guard generation == id, !Task.isCancelled else { throw NativeFileError.closed }
            finish(id, status: "‘\(saved.lastPathComponent)’ 항목을 Mac에 받았어요. 원본은 유지돼요.")
            lastReceivedURL = saved; completedItems += 1
            return saved
        } catch { failed(id, error); throw error }
    }
    private func record(bytes: Int64, total: Int64, id: UUID) {
        guard generation == id, isBusy else { return }
        let now = ContinuousClock.now
        guard bytes == 0 || bytes == total || now - lastProgress >= .milliseconds(100) else { return }
        lastProgress = now; progress = total == 0 ? 1 : min(1, Double(bytes) / Double(total))
    }
    private func finish(_ id: UUID, status: String) {
        guard generation == id else { return }
        work = nil; receiver = nil; isBusy = false; currentName = nil; progress = nil; self.status = status
    }
    private func failed(_ id: UUID, _ error: any Error, prefix: String = "") {
        finish(id, status: prefix + NativeFileError.authored(error).message)
    }
    func cancel() {
        let nonces = Array(Set(exportNonces.keys).union([captureNonce, receivingExportNonce].compactMap { $0 }))
        lifetime = UUID(); exports = [:]; exportNonces = [:]
        for task in queuedReceives.values { task.cancel() }
        queuedReceives = [:]; receiveTail = nil
        captureWork?.cancel(); captureWork = nil; captureNonce = nil; captureOperation = nil
        generation = UUID(); gate.cancel(); work?.cancel(); receiver?.cancel(); work = nil; receiver = nil
        receivingExportNonce = nil; receivingExportOperation = nil
        sendExplorerCancellation(nonces)
        isBusy = false; progress = nil; currentName = nil; status = NativeFileError.cancelled.message
    }
    func close() {
        unfinishedUploads = []; lastReceivedURL = nil
        lifetime = UUID(); exports = [:]; exportNonces = [:]
        for task in queuedReceives.values { task.cancel() }
        queuedReceives = [:]; receiveTail = nil
        captureWork?.cancel(); captureWork = nil; captureNonce = nil; captureOperation = nil
        generation = UUID(); gate.close(); work?.cancel(); receiver?.cancel(); work = nil; receiver = nil; client = nil
        receivingExportNonce = nil; receivingExportOperation = nil
        entries = []; isBusy = false; progress = nil; currentName = nil; truncated = false; status = NativeFileError.closed.message
    }
}
