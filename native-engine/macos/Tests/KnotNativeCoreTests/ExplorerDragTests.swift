import Foundation
import Testing
import AppKit
import UniformTypeIdentifiers
import KnotNativeCore
@testable import KnotNativePreview

@Test func explorerBarrierPreservesDownMoveOrderingAndCannotCoalesceAcrossCapture() throws {
    var queue = InputBuffer()
    let down = try Input.pointer(action: 1, x: 10, y: 20)
    let before = try Input.pointer(action: 0, x: 30, y: 40)
    let barrier = Packet(kind: .explorerDrag, payload: Data(repeating: 7, count: 16))
    let after = try Input.pointer(action: 0, x: 50, y: 60)
    for packet in [down, before, barrier, after] { try queue.append(packet) }
    #expect([queue.pop(), queue.pop(), queue.pop(), queue.pop()] == [down, before, barrier, after])
    #expect(throws: NativeFailure.malformed) { try queue.append(Packet(kind: .explorerDrag, payload: Data(count: 15))) }
    try queue.append(barrier); queue.revoke()
    #expect(queue.pop()?.kind == .releaseAll)
    #expect(queue.pop() == nil)
}

@Test func explorerHandoffRequiresOwnedLeftAndAnActualImageBoundaryCrossing() {
    let down = CGPoint(x: 100, y: 100), outside = CGPoint(x: -8, y: 120)
    #expect(ExplorerDragGesture.shouldHandoff(origin: down, point: outside, ownsLeft: true, insideImage: false, available: true))
    #expect(!ExplorerDragGesture.shouldHandoff(origin: nil, point: outside, ownsLeft: true, insideImage: false, available: true))
    #expect(!ExplorerDragGesture.shouldHandoff(origin: down, point: outside, ownsLeft: false, insideImage: false, available: true))
    #expect(!ExplorerDragGesture.shouldHandoff(origin: down, point: outside, ownsLeft: true, insideImage: true, available: true))
    #expect(!ExplorerDragGesture.shouldHandoff(origin: down, point: outside, ownsLeft: true, insideImage: false, available: false))
    #expect(!ExplorerDragGesture.shouldHandoff(origin: down, point: CGPoint(x: 101, y: 101), ownsLeft: true, insideImage: false, available: true))
    #expect(!ExplorerDragGesture.shouldHandoff(origin: down, point: CGPoint(x: Double.nan, y: 0), ownsLeft: true, insideImage: false, available: true))
}

@MainActor @Test func nativeFolderPromiseUsesFolderTypeWithoutStartingAFileAdapter() throws {
    let entry = try NativeFileEntry(id: String(repeating: "c", count: 32), name: "Synthetic folder", size: 0, kind: .folder)
    let model = FileTransferModel(rootName: "Synthetic", entries: [entry])
    let owner = NativeFilePromiseOwner()
    let (id, provider) = try #require(owner.provider(entry: entry, files: model))
    #expect(provider.fileType == UTType.folder.identifier)
    #expect(provider.delegate?.filePromiseProvider(provider, fileNameForType: UTType.folder.identifier) == entry.name)
    #expect(model.fixtureOperationAttempts == 0)
    owner.finish(id)
}
