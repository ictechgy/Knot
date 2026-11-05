import Foundation
import Darwin
import Testing
import KnotNativeCore
@testable import KnotNativePreview

private func ownedFileDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("knot-owned-files-" + UUID().uuidString)
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
