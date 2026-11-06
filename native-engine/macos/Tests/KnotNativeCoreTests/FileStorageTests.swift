import Foundation
import Darwin
import Testing
import KnotNativeCore
@testable import KnotNativePreview

private func ownedFileDirectory() throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path.hasPrefix("/var/") ? "/private" + FileManager.default.temporaryDirectory.path : FileManager.default.temporaryDirectory.path).appendingPathComponent("knot-owned-files-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
}

@Test func fileSourceRejectsSymlinkDirectoryAndNonregularWithoutBlocking() throws {
    let root = try ownedFileDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let regular = root.appendingPathComponent("source.txt"), link = root.appendingPathComponent("link.txt")
    try Data("source".utf8).write(to: regular); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
    #expect(throws: (any Error).self) { try NativeFileSource(url: link) }
    #expect(throws: (any Error).self) { try NativeFileSource(url: root) }
    let fifo = root.appendingPathComponent("fifo")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    #expect(throws: (any Error).self) { try NativeFileSource(url: fifo) }
    let source = try NativeFileSource(url: regular)
    #expect(try source.read(64) == Data("source".utf8)); try source.requireUnchanged()
    try Data("modified".utf8).write(to: regular)
    #expect(throws: NativeFileError.changed) { try source.requireUnchanged() }
}

@Test func fileDestinationQuarantinesBeforePublishAndNeverOverwritesExactPickerName() throws {
    let root = try ownedFileDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("검증.txt"), payload = Data("synthetic bytes".utf8)
    let destination = try NativeFileDestination(url: target, size: Int64(payload.count))
    let staging = try #require(FileManager.default.contentsOfDirectory(atPath: root.path).first)
    #expect(staging.hasPrefix(".knot-") && !FileManager.default.fileExists(atPath: target.path))
    let stageURL = root.appendingPathComponent(staging)
    let attributes = try FileManager.default.attributesOfItem(atPath: stageURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    let marker = getxattr(stageURL.appendingPathComponent("payload.part").path, "com.apple.quarantine", nil, 0, 0, 0)
    #expect(marker > 0)
    try destination.write(payload); try destination.prepare()
    #expect(try destination.publish() == target)
    #expect(try Data(contentsOf: target) == payload)
    #expect(getxattr(target.path, "com.apple.quarantine", nil, 0, 0, 0) > 0)
    #expect(throws: NativeFileError.exists) { try NativeFileDestination(url: target, size: 0) }
    #expect(try Data(contentsOf: target) == payload)
}

@Test func fileDestinationFailureRemovesOnlyOwnedPartialAndPreservesReplacementOrSymlink() throws {
    let root = try ownedFileDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let final = root.appendingPathComponent("target.txt")
    var receiver: NativeFileDestination? = try NativeFileDestination(url: final, size: 3)
    try receiver?.write(Data([1, 2, 3])); receiver = nil
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    receiver = try NativeFileDestination(url: final, size: 0)
    let stage = root.appendingPathComponent(try #require(FileManager.default.contentsOfDirectory(atPath: root.path).first))
    let partial = stage.appendingPathComponent("payload.part")
    try FileManager.default.removeItem(at: partial)
    try Data("unowned replacement".utf8).write(to: partial)
    #expect(throws: NativeFileError.changed) { try receiver?.publish() }
    receiver = nil
    #expect(try Data(contentsOf: partial) == Data("unowned replacement".utf8))
    let outside = root.appendingPathComponent("outside.txt"); try Data([9]).write(to: outside)
    try FileManager.default.createSymbolicLink(at: final, withDestinationURL: outside)
    #expect(throws: NativeFileError.exists) { try NativeFileDestination(url: final, size: 0) }
    #expect(try Data(contentsOf: outside) == Data([9]))
}

@Test func privateFileStagePinsOriginalBytesWhenItsOuterPathIsRenamedOrReplaced() throws {
    let root = try ownedFileDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("target.txt"), bytes = Data("verified original bytes".utf8)
    var receiver: NativeFileDestination? = try NativeFileDestination(url: destination, size: Int64(bytes.count))
    let stageName = try #require(FileManager.default.contentsOfDirectory(atPath: root.path).first)
    let stage = root.appendingPathComponent(stageName), moved = root.appendingPathComponent("moved-private-stage")
    try receiver?.write(bytes); try receiver?.prepare()
    try FileManager.default.moveItem(at: stage, to: moved)
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
    let replacement = stage.appendingPathComponent("payload.part"); try Data("unverified replacement".utf8).write(to: replacement)
    #expect(try receiver?.publish() == destination)
    receiver = nil
    #expect(try Data(contentsOf: destination) == bytes)
    #expect(try Data(contentsOf: replacement) == Data("unverified replacement".utf8))
}

@Test func sharedWritableDestinationDoesNotRaceRemovalOfItsOuterStagePath() throws {
    let root = try ownedFileDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    #expect(chmod(root.path, 0o777) == 0)
    var receiver: NativeFileDestination? = try NativeFileDestination(url: root.appendingPathComponent("target.txt"), size: 1)
    try receiver?.write(Data([1])); receiver = nil
    let stage = root.appendingPathComponent(try #require(FileManager.default.contentsOfDirectory(atPath: root.path).first))
    #expect(try FileManager.default.contentsOfDirectory(atPath: stage.path).isEmpty)
    #expect((try FileManager.default.attributesOfItem(atPath: stage.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
}

@Test func fileRunRevocationAndCancelledQuotaCannotBeBypassedAtPublish() throws {
    let root = try ownedFileDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let gate = FileRunGate(), operation = try gate.begin()
    try gate.reserve(FileWire.maximumSize, id: operation)
    gate.cancel(operation)
    let next = try gate.begin()
    #expect(throws: NativeFileError.quota) { try gate.reserve(1, id: next) }
    let target = root.appendingPathComponent("late.txt")
    var receiver: NativeFileDestination? = try NativeFileDestination(url: target, size: 0)
    try receiver?.prepare(); gate.close()
    #expect(throws: NativeFileError.closed) { try gate.publish(id: next) { try receiver?.publish() } }
    receiver = nil
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    #expect(throws: NativeFileError.closed) { try gate.begin() }
}

@Test func fileTreesSnapshotEmptyUnicodeAndRejectLinksHardlinksPackagesAndMutation() throws {
    let root = try ownedFileDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("tree")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let empty = try NativeFileTreeSource(url: folder); #expect(empty.items.isEmpty && empty.size == 0)
    let sub = folder.appendingPathComponent("빈 폴더"); try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
    let leaf = sub.appendingPathComponent("검증.txt"); try Data([1, 2, 3]).write(to: leaf)
    let tree = try NativeFileTreeSource(url: folder); #expect(tree.items.count == 2 && tree.size == 3)
    let file = try tree.openFile(try #require(tree.items.last)); #expect(try file.read(3) == Data([1, 2, 3])); try file.requireUnchanged()
    try Data([4, 5, 6]).write(to: leaf)
    #expect(throws: NativeFileError.changed) { try tree.requireUnchanged() }
    let link = folder.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: leaf)
    #expect(throws: (any Error).self) { try NativeFileTreeSource(url: folder) }; try FileManager.default.removeItem(at: link)
    let hard = folder.appendingPathComponent("hard"); try FileManager.default.linkItem(at: leaf, to: hard)
    #expect(throws: (any Error).self) { try NativeFileTreeSource(url: folder) }
    #expect(throws: (any Error).self) { try NativeFileSource(url: leaf) }; try FileManager.default.removeItem(at: hard)
    let package = folder.appendingPathComponent("unsafe.app"); try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) { try NativeFileTreeSource(url: folder) }
    #expect(throws: (any Error).self) { try NativeFileTreeSource(url: package) }
}

@Test func fileTreeStagePublishesOnceWithEveryLeafQuarantinedAndCleansOwnedFailures() throws {
    let root = try ownedFileDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("received")
    var tree: NativeFileTreeDestination? = try NativeFileTreeDestination(url: destination, size: 3)
    let folder = try NativeFileNode(id: 1, parent: 0, name: "빈 폴더", kind: .folder, size: 0)
    let empty = try NativeFileNode(id: 2, parent: 1, name: "empty", kind: .file, size: 0)
    let leaf = try NativeFileNode(id: 3, parent: 0, name: "검증.bin", kind: .file, size: 3)
    try tree?.create(folder); try tree?.create(empty); try tree?.finishFile(); try tree?.create(leaf); try tree?.write(Data([1, 2, 3])); try tree?.finishFile(); try tree?.prepare()
    #expect(!FileManager.default.fileExists(atPath: destination.path)); #expect(try tree?.publish() == destination)
    #expect(try Data(contentsOf: destination.appendingPathComponent(leaf.name)) == Data([1, 2, 3]))
    for path in [destination.appendingPathComponent(leaf.name), destination.appendingPathComponent(folder.name).appendingPathComponent(empty.name)] {
        #expect(getxattr(path.path, "com.apple.quarantine", nil, 0, 0, 0) > 0)
    }
    tree = nil
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["received"])
    #expect(throws: NativeFileError.exists) { try NativeFileTreeDestination(url: destination, size: 0) }
    tree = try NativeFileTreeDestination(url: root.appendingPathComponent("failed"), size: 3)
    try tree?.create(NativeFileNode(id: 1, parent: 0, name: "failed-leaf", kind: .file, size: 3)); tree = nil
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["received"])
}

@Test func fileTreeCleanupPreservesReplacedLeafAndCancelledNodeQuotaIsNotRefunded() throws {
    let root = try ownedFileDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    var tree: NativeFileTreeDestination? = try NativeFileTreeDestination(url: root.appendingPathComponent("target"), size: 0)
    let leaf = try NativeFileNode(id: 1, parent: 0, name: "leaf", kind: .file, size: 0)
    try tree?.create(leaf); try tree?.finishFile()
    let stage = root.appendingPathComponent(try #require(FileManager.default.contentsOfDirectory(atPath: root.path).first))
    let path = stage.appendingPathComponent("payload/leaf")
    try FileManager.default.removeItem(at: path); try Data("replacement".utf8).write(to: path)
    #expect(throws: NativeFileError.changed) { try tree?.prepare() }; tree = nil
    #expect(try Data(contentsOf: path) == Data("replacement".utf8))
    let gate = FileRunGate(), operation = try gate.begin(); try gate.reserve(0, nodes: 8192, id: operation); gate.cancel(operation)
    let next = try gate.begin(); #expect(throws: NativeFileError.quota) { try gate.reserve(0, id: next) }
}

@Test func fileTreesAndDestinationsRejectSymlinkAncestorComponents() throws {
    let root = try ownedFileDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("original"), alias = root.appendingPathComponent("alias")
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
    try Data([1]).write(to: original.appendingPathComponent("leaf"))
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
    #expect(throws: (any Error).self) { try NativeFileSource(url: alias.appendingPathComponent("leaf")) }
    #expect(throws: (any Error).self) { try NativeFileTreeSource(url: alias) }
    #expect(throws: (any Error).self) { try NativeFileDestination(url: alias.appendingPathComponent("received"), size: 0) }
    #expect(throws: (any Error).self) { try NativeFileTreeDestination(url: alias.appendingPathComponent("folder"), size: 0) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: original.path) == ["leaf"])
}

@Test func packageFolderSourcesAndExactReceiveDestinationsFailBeforeStaging() throws {
    let root = try ownedFileDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    for name in ["helper.xpc", "program.APP", "document.rtfd", ".app", "installer.pkg"] {
        let destination = root.appendingPathComponent(name)
        #expect(throws: NativeFileError.unsupported) { try NativeFileTreeDestination(url: destination, size: 0) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    #expect(FileTreeFS.package("compiled.storyboardc"))
    #expect(throws: NativeFileError.unsupported) { try NativeFileTreeDestination(url: root.appendingPathComponent("compiled.storyboardc"), size: 0) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    for name in ["helper.xpc", "program.app", "document.rtfd", ".app"] {
        let source = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        #expect(throws: NativeFileError.unsupported) { try NativeFileTreeSource(url: source) }
    }
}

@Test func localPackageTypedChildIsRejectedAndOnlyOwnedTreeIsCleanedUp() throws {
    let root = try ownedFileDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let sentinel = root.appendingPathComponent("unrelated.txt"); try Data("untouched".utf8).write(to: sentinel)
    var receiver: NativeFileTreeDestination? = try NativeFileTreeDestination(url: root.appendingPathComponent("ordinary"), size: 0)
    try receiver?.create(NativeFileNode(id: 1, parent: 0, name: "owned empty folder", kind: .folder, size: 0))
    let package = try NativeFileNode(id: 2, parent: 1, name: "nested.storyboardc", kind: .folder, size: 0)
    #expect(!FileWire.isPackageFolderName(package.name) && FileTreeFS.package(package.name))
    #expect(throws: NativeFileError.unsupported) { try receiver?.create(package) }
    receiver = nil
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["unrelated.txt"])
    #expect(try Data(contentsOf: sentinel) == Data("untouched".utf8))
}
