// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import Foundation
import Darwin
@testable import KnotNativePreview

@MainActor final class NativeUpdateHandoffTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("knot-update-handoff-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func app(_ root: URL, _ name: String, version: String) throws -> URL {
        let url = root.appendingPathComponent(name), contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "org.knot.native-preview.synthetic", "KnotNativeVersion": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        return url
    }
    private func version(_ app: URL) throws -> String {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        return try XCTUnwrap(value?["KnotNativeVersion"] as? String)
    }
    func testAtomicExchangeKeepsCanonicalAppAndRetainsOldCopy() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let installed = try app(root, "Knot Native Preview.app", version: "old"), candidate = try app(root, "candidate.app", version: "new")
        let transaction = try NativeUpdateTransaction.prepare(candidate: candidate, destination: installed) { copied in
            XCTAssertEqual(try self.version(copied), "new")
        }
        XCTAssertEqual(try version(installed), "old")
        try transaction.publish()
        XCTAssertEqual(try version(installed), "new"); XCTAssertEqual(try version(transaction.replacement), "old")
        transaction.discardPreparedCopy(); XCTAssertEqual(try version(installed), "new")
    }
    func testInterruptedPreparationAndFailedPublicationLeaveOriginalPresent() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let installed = try app(root, "Knot Native Preview.app", version: "old"), candidate = try app(root, "candidate.app", version: "new")
        let transaction = try NativeUpdateTransaction.prepare(candidate: candidate, destination: installed) { _ in }
        // Interruption before publication leaves the canonical path untouched.
        XCTAssertEqual(try version(installed), "old")
        XCTAssertThrowsError(try transaction.publish(exchange: { _, _ in throw NativeUpdateError.installation }))
        XCTAssertEqual(try version(installed), "old"); XCTAssertEqual(try version(transaction.replacement), "new")
        transaction.discardPreparedCopy(); XCTAssertEqual(try version(installed), "old")
    }
    func testValidationAndUnsupportedSwapFailBeforeReadyWithoutReplacingApp() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let installed = try app(root, "Knot Native Preview.app", version: "old"), candidate = try app(root, "candidate.app", version: "new")
        XCTAssertThrowsError(try NativeUpdateTransaction.prepare(candidate: candidate, destination: installed) { _ in throw NativeUpdateError.installation })
        XCTAssertThrowsError(try NativeUpdateTransaction.prepare(candidate: candidate, destination: installed,
            probe: { _ in throw NativeUpdateError.installation }, validate: { _ in XCTFail("Candidate cannot be admitted without atomic publication support") }))
        XCTAssertEqual(try version(installed), "old")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), Set(["Knot Native Preview.app", "candidate.app"]))
    }
    func testChangedInstalledDirectoryIdentityRefusesPublication() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let installed = try app(root, "Knot Native Preview.app", version: "old"), candidate = try app(root, "candidate.app", version: "new")
        let transaction = try NativeUpdateTransaction.prepare(candidate: candidate, destination: installed) { _ in }
        try FileManager.default.moveItem(at: installed, to: root.appendingPathComponent("original.app"))
        _ = try app(root, installed.lastPathComponent, version: "concurrent")
        XCTAssertThrowsError(try transaction.publish()); XCTAssertEqual(try version(installed), "concurrent")
    }
    func testArchiveTraversalLinksDuplicatesAndBombLimitsAreRejected() throws {
        let prefix = "Knot Native Preview.app/", name = prefix + "Contents/Info.plist"
        let ordinary = "-rw-r--r--  2.0 unx 10 b- 10 stor 26-Nov-06 00:00 " + name + "\n"
        XCTAssertNoThrow(try NativeUpdateArchiveInventory.validate(names: name + "\n", listing: ordinary))
        for invalid in ["../escape\n", prefix + "../escape\n", prefix + "./Contents/a\n", prefix + "/Contents/a\n", "/" + name + "\n", name + "\n" + name + "\n", name + "\n" + name.uppercased() + "\n"] {
            XCTAssertThrowsError(try NativeUpdateArchiveInventory.validate(names: invalid, listing: ordinary))
        }
        for row in [ordinary.replacingOccurrences(of: "-rw", with: "lrw"), ordinary.replacingOccurrences(of: " 10 b-", with: " 1073741825 b-")] {
            XCTAssertThrowsError(try NativeUpdateArchiveInventory.validate(names: name + "\n", listing: row))
        }
    }
    func testOwnedPipeAcceptsExactNonceReceipt() async throws {
        let pipe = Pipe(), nonce = UUID().uuidString + UUID().uuidString
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        XCTAssertTrue(NativeUpdateAcknowledgement.validNonce(nonce))
        let expected = NativeUpdateAcknowledgement.receipt(nonce), fd = pipe.fileHandleForWriting.fileDescriptor
        let writer = Task.detached {
            try await Task.sleep(for: .milliseconds(50))
            try expected.withUnsafeBytes { data in
                guard Darwin.write(fd, data.baseAddress, data.count) == data.count else { throw NativeUpdateError.installation }
            }
        }
        try await NativeUpdateAcknowledgement.wait(readDescriptor: pipe.fileHandleForReading.fileDescriptor, expected: expected, timeout: .seconds(1))
        try await writer.value
    }
    func testWrongReadyNonceEofAndTimeoutRetainParent() async throws {
        for mode in 0...2 {
            let pipe = Pipe(); defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
            let expected = NativeUpdateAcknowledgement.receipt(UUID().uuidString + UUID().uuidString)
            if mode == 0 { try pipe.fileHandleForWriting.write(contentsOf: NativeUpdateAcknowledgement.receipt(UUID().uuidString + UUID().uuidString)) }
            if mode == 1 { try pipe.fileHandleForWriting.close() }
            var failed = false
            do { try await NativeUpdateAcknowledgement.wait(readDescriptor: pipe.fileHandleForReading.fileDescriptor, expected: expected, timeout: .milliseconds(75)) }
            catch { failed = true }
            XCTAssertTrue(failed)
        }
    }
}
