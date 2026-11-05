import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import KnotNativeCore
@testable import KnotNativePreview

@Suite(.serialized)
@MainActor
struct NativeFileUITests {
    @Test func dragReadsOnlyBoundedExplicitFileURLItems() {
        // This is a new, uniquely named synthetic pasteboard; never general.
        let pasteboard = NSPasteboard(name: .init("KnotFileFixture-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("file:///Synthetic/not-opened.txt", forType: .fileURL)
        pasteboard.writeObjects([item])
        #expect(NativeFileDrop.urls(from: pasteboard)?.map(\.lastPathComponent) == ["not-opened.txt"])
        pasteboard.clearContents()
        let web = NSPasteboardItem(); web.setString("https://example.invalid/not-a-file", forType: .fileURL)
        pasteboard.writeObjects([web])
        #expect(NativeFileDrop.urls(from: pasteboard) == nil)
        pasteboard.clearContents()
        let tooMany = (0..<33).map { index -> NSPasteboardItem in
            let item = NSPasteboardItem(); item.setString("file:///Synthetic/\(index).txt", forType: .fileURL); return item
        }
        pasteboard.writeObjects(tooMany)
        #expect(NativeFileDrop.urls(from: pasteboard) == nil)
    }

    @Test func nativePromisesRetainDelegatesWithBoundedCapacityWithoutStartingWork() throws {
        let entry = try NativeFileEntry(id: String(repeating: "a", count: 32), name: "synthetic.txt", size: 3)
        let files = FileTransferModel(rootName: "Synthetic", entries: [entry])
        let owner = NativeFilePromiseOwner()
        var ids: [UUID] = []
        for _ in 0..<32 {
            let (id, provider) = try #require(owner.provider(entry: entry, files: files))
            ids.append(id)
            #expect(provider.delegate != nil)
            #expect(provider.delegate?.filePromiseProvider(provider, fileNameForType: UTType.data.identifier) == entry.name)
        }
        #expect(owner.provider(entry: entry, files: files) == nil)
        #expect(files.fixtureOperationAttempts == 0)
        ids.forEach(owner.finish)
        #expect(owner.provider(entry: entry, files: files) != nil)
    }

    @Test func lateNativePromiseAfterSessionCloseFailsBeforeAnyFileOperation() async throws {
        let entry = try NativeFileEntry(id: String(repeating: "b", count: 32), name: "synthetic.txt", size: 3)
        let files = FileTransferModel(rootName: "Synthetic", entries: [entry])
        let owner = NativeFilePromiseOwner()
        let (_, provider) = try #require(owner.provider(entry: entry, files: files))
        let delegate = try #require(provider.delegate)
        files.close()
        let failed: Bool = await withCheckedContinuation { continuation in
            delegate.filePromiseProvider(provider, writePromiseTo: URL(fileURLWithPath: "/Synthetic/never-created.txt")) { error in
                continuation.resume(returning: error != nil)
            }
        }
        #expect(failed)
        #expect(files.fixtureOperationAttempts == 1)
        #expect(!files.isBusy)
    }
}
