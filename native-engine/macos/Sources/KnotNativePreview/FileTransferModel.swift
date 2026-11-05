import Foundation
import Combine
import KnotNativeCore

@MainActor
final class FileTransferModel: ObservableObject {
    let rootName: String
    @Published private(set) var entries: [NativeFileEntry]
    @Published private(set) var isBusy: Bool
    @Published private(set) var status: String
    @Published private(set) var progress: Double?
    @Published private(set) var currentName: String?
    @Published private(set) var truncated: Bool
    private var client: (any NativeFileWorking)?
    private let gate: FileRunGate
    private var work: Task<Void, Never>?
    private var receiver: Task<URL, any Error>?
    private var generation = UUID()
    private var lastProgress = ContinuousClock.now
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
         currentName: String? = nil, truncated: Bool = false) {
        self.rootName = rootName; self.entries = Array(entries.prefix(FileWire.maximumEntries))
        self.isBusy = isBusy; self.status = status; self.progress = progress
        self.currentName = currentName; self.truncated = truncated
        gate = FileRunGate(); client = disabledFileClient()
        fixtureMode = true
    }

    /// Tests inject only fresh in-memory/owned-file workers and their gate.
    init(rootName: String, client: any NativeFileWorking, gate: FileRunGate, entries: [NativeFileEntry] = []) {
        self.rootName = rootName; self.client = client; self.gate = gate; self.entries = entries
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
                    }
                    guard let self, self.generation == id, !Task.isCancelled else { return }
                    // This is the explicit send action's final list refresh,
                    // not a background retry or an automatic media reconnect.
                    if let listing = try? await client.list(operation: operation) {
                        guard self.generation == id, !Task.isCancelled else { return }
                        self.entries = listing.entries; self.truncated = listing.truncated
                    }
                    self.finish(id, status: "\(sent)개 파일을 Windows의 ‘\(self.rootName)’ 폴더로 보냈어요. 원본은 유지돼요.")
                } catch {
                    guard let self, self.generation == id else { return }
                    self.failed(id, error, prefix: sent > 0 ? "\(sent)개는 전송을 완료했어요. " : "")
                }
            }
        } catch { status = NativeFileError.authored(error).message }
    }
    func receive(_ entry: NativeFileEntry, destination: URL) async throws -> URL {
        if fixtureMode { fixtureOperationAttempts += 1 }
        let id: UUID, operation: UUID, client: any NativeFileWorking
        do {
            (id, operation, client) = try begin()
            guard entries.contains(entry) else { gate.end(operation); isBusy = false; throw NativeFileError.missing }
        } catch { status = NativeFileError.authored(error).message; throw error }
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
            finish(id, status: "‘\(saved.lastPathComponent)’ 파일을 Mac에 받았어요. 원본은 유지돼요.")
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
        generation = UUID(); gate.cancel(); work?.cancel(); receiver?.cancel(); work = nil; receiver = nil
        isBusy = false; progress = nil; currentName = nil; status = NativeFileError.cancelled.message
    }
    func close() {
        generation = UUID(); gate.close(); work?.cancel(); receiver?.cancel(); work = nil; receiver = nil; client = nil
        entries = []; isBusy = false; progress = nil; currentName = nil; truncated = false; status = NativeFileError.closed.message
    }
}
