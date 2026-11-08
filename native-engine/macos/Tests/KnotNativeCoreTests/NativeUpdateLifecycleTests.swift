// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import Foundation
@testable import KnotNativePreview

private final class UpdateFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Int64 = 100, count = 0, finished = false
    func now() -> Int64 { lock.lock(); defer { lock.unlock() }; return instant }
    func advance() { lock.lock(); instant = 201; lock.unlock() }
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    func complete() { lock.lock(); finished = true; lock.unlock() }
    func completed() -> Bool { lock.lock(); defer { lock.unlock() }; return finished }
}

@MainActor final class NativeUpdateLifecycleTests: XCTestCase {
    private func configuration() -> NativeUpdateConfiguration {
        NativeUpdateConfiguration(version: "0.1.0-native.10", macFeed: "https://example.invalid/mac.feed",
            windowsFeed: "https://example.invalid/windows.feed", modulus: Data(repeating: 255, count: 256), exponent: Data([1, 0, 1]))
    }
    private func manifest() -> NativeUpdateManifest {
        NativeUpdateManifest(version: "0.1.0-native.11", build: 4_294_967_307, platform: "macos-arm64",
            url: URL(string: "https://example.invalid/Knot-Native-0.1.0-native.11-macos-arm64.zip")!, bytes: 5,
            sha256: String(repeating: "a", count: 64), expires: 200)
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knot-update-lifecycle-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Synthetic updater failed to settle")
    }
    func testExpiredPendingAllowsFreshCheckAndShutdownDeletesOnlyOwnedStage() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second"), sentinel = root.appendingPathComponent("unrelated")
        for directory in [first, second] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
        try Data("keep".utf8).write(to: sentinel)
        let state = UpdateFixtureState(), value = manifest()
        let model = NativeUpdateModel(configuration: configuration(), download: { _ in
            return (value, state.next() == 1 ? first : second)
        }, now: { state.now() })
        model.check(); try await settle { !model.checking }; XCTAssertTrue(model.available)
        state.advance(); model.check(); try await settle { !model.checking }
        try await settle { !FileManager.default.fileExists(atPath: first.path) }
        XCTAssertTrue(model.available)
        model.stop()
        XCTAssertFalse(model.available); XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }
    func testLateCancelledDownloadCannotPublishPendingAndCleansItsOwnStage() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let stage = root.appendingPathComponent("late")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let value = manifest(), state = UpdateFixtureState()
        let model = NativeUpdateModel(configuration: configuration(), download: { _ in
            _ = state.next()
            try? await Task.sleep(for: .milliseconds(100)) // adapter deliberately returns after cancellation
            return (value, stage)
        })
        model.check(); model.stop()
        try await settle { !FileManager.default.fileExists(atPath: stage.path) }
        XCTAssertFalse(model.available); XCTAssertFalse(model.checking)
    }
    func testCommitRequiresExactNonceAndActualLifetimePipeEof() async throws {
        let pipe = Pipe(), nonce = UUID().uuidString + UUID().uuidString, state = UpdateFixtureState()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let fd = pipe.fileHandleForReading.fileDescriptor
        try pipe.fileHandleForWriting.write(contentsOf: NativeUpdateAcknowledgement.commit(nonce))
        let helper = Task.detached {
            try NativeUpdateAcknowledgement.waitForCommitAndParentExit(readDescriptor: fd, nonce: nonce, timeout: 2)
            state.complete()
        }
        try await Task.sleep(for: .milliseconds(75)); XCTAssertFalse(state.completed())
        try pipe.fileHandleForWriting.close()
        try await helper.value; XCTAssertTrue(state.completed())
    }
    func testEofWithoutCommitWrongNonceAndUnclosedParentFailClosed() throws {
        for mode in 0...2 {
            let pipe = Pipe(); defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
            let nonce = UUID().uuidString + UUID().uuidString
            if mode == 1 { try pipe.fileHandleForWriting.write(contentsOf: NativeUpdateAcknowledgement.commit(UUID().uuidString + UUID().uuidString)) }
            if mode < 2 { try pipe.fileHandleForWriting.close() }
            XCTAssertThrowsError(try NativeUpdateAcknowledgement.waitForCommitAndParentExit(readDescriptor: pipe.fileHandleForReading.fileDescriptor, nonce: nonce, timeout: 0.075))
        }
    }
}
