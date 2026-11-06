import Foundation
import Testing
import KnotNativeCore
@testable import KnotNativePreview

@MainActor
struct ConvenienceTests {
    @Test func qualityRequestsAreExplicitBoundedAndPressureIsThrottled() {
        var sent: [Packet] = []
        let model = QualityModel { sent.append($0); return true }
        model.choose(.responsive)
        #expect(sent == [Packet(kind: .qualityPreference, payload: Data([2]))])
        model.reportPressure(true, now: .now + .seconds(3))
        model.reportPressure(false, now: .now + .seconds(3))
        #expect(sent.count == 2)
        #expect(sent.last == Packet(kind: .qualityFeedback, payload: Data([1])))
        model.accept(Data([0, 0, 0, 30, 1, 49, 45, 0, 1])) //20Mbps
        #expect(model.status.contains("30fps") && model.status.contains("20Mbps"))
        let old = model.status
        model.accept(Data([0, 0, 0, 255, 1, 49, 45, 0, 1]))
        #expect(model.status == old)
        let rejected = QualityModel { _ in false }
        rejected.choose(.sharp); #expect(rejected.preference == .automatic)
    }

    @Test func retryOmitsAcknowledgedItemsAndCloseRevokesRetry() async throws {
        let worker = RetryFixture(), files = FileTransferModel(rootName: "Synthetic", client: worker, gate: FileRunGate())
        let urls = ["first.txt", "second.txt", "third.txt"].map { URL(fileURLWithPath: "/Synthetic/" + $0) }
        files.send(urls: urls)
        for _ in 0..<100 where files.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!files.isBusy && files.completedItems == 1)
        #expect(files.unfinishedUploads.map(\.lastPathComponent) == ["second.txt", "third.txt"])
        files.retryUnfinishedUploads()
        for _ in 0..<100 where files.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(files.completedItems == 3 && files.unfinishedUploads.isEmpty)
        #expect(await worker.names == ["first.txt", "second.txt", "second.txt", "third.txt"])
        files.close(); #expect(!files.canRetryUploads && files.lastReceivedURL == nil)
    }
}

private actor RetryFixture: NativeFileWorking {
    private(set) var names: [String] = []
    private var failed = false
    func list(operation: UUID) async throws -> NativeFileListing { .init(entries: [], truncated: false) }
    func upload(url: URL, operation: UUID, progress: @escaping NativeFileProgress) async throws -> NativeFileReceipt {
        names.append(url.lastPathComponent)
        if url.lastPathComponent == "second.txt", !failed { failed = true; throw NativeFileError.timeout }
        return .init(name: url.lastPathComponent, size: 0, hash: String(repeating: "0", count: 64))
    }
    func download(entry: NativeFileEntry, destination: URL, operation: UUID, progress: @escaping NativeFileProgress) async throws -> URL { throw NativeFileError.unsupported }
}
