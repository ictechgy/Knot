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
    func total() -> Int { lock.lock(); defer { lock.unlock() }; return count }
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
    func testAlreadyCancelledTaskStillConfirmsOwnedChildExit() async throws {
        let stage = try fixture(); defer { try? FileManager.default.removeItem(at: stage) }
        let process = Process(), input = Pipe(), output = Pipe(), nonce = UUID().uuidString + UUID().uuidString
        process.executableURL = URL(fileURLWithPath: "/bin/cat"); process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run(); try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
        let prepared = NativePreparedUpdate(process: process, output: output, input: input, stage: stage, nonce: nonce)
        let caller = Task { await prepared.cancel() }
        caller.cancel()
        let stopped = await caller.value; XCTAssertTrue(stopped); XCTAssertFalse(process.isRunning)
    }
    func testShutdownGraceRunsInsideAlreadyCancelledCaller() async {
        let caller = Task { () -> (Bool, Int, Bool) in
            await Task.detached { () -> (Bool, Int, Bool) in
                var pauses = 0, killed = false
                let result = NativeUpdateChildShutdown.stop(isRunning: { pauses < 3 }, terminate: {}, kill: { killed = true },
                    pause: { pauses += 1 }, polls: 5)
                return (result, pauses, killed)
            }.value
        }
        caller.cancel()
        let result = await caller.value
        XCTAssertTrue(result.0); XCTAssertEqual(result.1, 3); XCTAssertFalse(result.2)
    }
    func testFoundationChildDoesNotInheritParentPipeWriter() async throws {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/cat"); process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run(); try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
        defer { if process.isRunning { process.terminate() }; try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close() }
        let value = Data("fresh synthetic child\n".utf8)
        try input.fileHandleForWriting.write(contentsOf: value); try input.fileHandleForWriting.close()
        let exited = await Task.detached { () -> Bool in
            for _ in 0..<200 { if !process.isRunning { return true }; try? await Task.sleep(for: .milliseconds(10)) }
            return false
        }.value
        XCTAssertTrue(exited); XCTAssertEqual(try output.fileHandleForReading.readToEnd(), value)
    }
    func testOwnedCommandCancellationDrainsChildBeforeCleanupProof() async throws {
        let stage = try fixture(); defer { try? FileManager.default.removeItem(at: stage) }
        let nonce = UUID().uuidString + UUID().uuidString
        // Does not alter the test process's signal handlers. Only the fresh,
        // explicitly owned /bin/sleep command is started and stopped.
        let context = try NativeUpdateHelperContext(stage: stage, nonce: nonce, installSignalHandlers: false)
        let command = Task.detached { try context.command("/bin/sleep", ["10"]) }
        try await Task.sleep(for: .milliseconds(75))
        try Data(nonce.utf8).write(to: stage.appendingPathComponent("cancel-" + nonce))
        do { _ = try await command.value; XCTFail("Cancelled command must fail") } catch { }
        XCTAssertTrue(context.writersConfirmed)
    }
    func testCommittedInstallStopPreservesHelperOwnedStage() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let stage = root.appendingPathComponent("stage"), app = root.appendingPathComponent("Knot Native Preview.app")
        for url in [stage, app] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        let descriptor = NativeUpdateInstallation(app: app, executable: app.appendingPathComponent("synthetic"), configuration: root.appendingPathComponent("synthetic.config"))
        let value = manifest(); var exits = 0, beforeExits = 0
        var model: NativeUpdateModel!
        model = NativeUpdateModel(configuration: configuration(), download: { _ in (value, stage) },
            installation: { descriptor }, prepare: { _, directory, _, _, _, _ in
                NativePreparedUpdate(process: Process(), output: Pipe(), input: Pipe(), stage: directory, nonce: UUID().uuidString + UUID().uuidString)
            }, terminate: { exits += 1 })
        model.check(); try await settle { !model.checking }
        model.install { beforeExits += 1; model.stop() }
        try await settle { !model.checking }
        XCTAssertEqual(exits, 1); XCTAssertEqual(beforeExits, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path)); XCTAssertFalse(model.available)
    }
    func testUnconfirmedInstallRetainsStageAndBlocksFreshWork() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let stage = root.appendingPathComponent("stage"), app = root.appendingPathComponent("Knot Native Preview.app")
        for url in [stage, app] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        let descriptor = NativeUpdateInstallation(app: app, executable: app.appendingPathComponent("synthetic"), configuration: root.appendingPathComponent("synthetic.config"))
        let value = manifest(), state = UpdateFixtureState()
        let model = NativeUpdateModel(configuration: configuration(), download: { _ in _ = state.next(); return (value, stage) },
            installation: { descriptor }, prepare: { _, directory, _, _, _, _ in
                let fake = NativePreparedUpdate(process: Process(), output: Pipe(), input: Pipe(), stage: directory, nonce: UUID().uuidString + UUID().uuidString)
                throw NativeUpdateUnconfirmedCancellation(prepared: fake)
            }, terminate: { XCTFail("Unconfirmed cancellation cannot close app") })
        model.check(); try await settle { !model.checking }
        model.install { XCTFail("Unconfirmed cancellation cannot call beforeExit") }; try await settle { !model.checking }
        model.check(); XCTAssertEqual(state.total(), 1); XCTAssertFalse(model.available)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path)); model.stop()
    }
    func testRecoveryGateHonorsTermAndCancelBeforeAndDuringVerification() throws {
        for mode in 0...4 {
            let stage = try fixture(); defer { try? FileManager.default.removeItem(at: stage) }
            let nonce = UUID().uuidString + UUID().uuidString
            let context = try NativeUpdateHelperContext(stage: stage, nonce: nonce, installSignalHandlers: false)
            if mode == 0 { context.requestTermination() }
            if mode == 1 { try Data(nonce.utf8).write(to: stage.appendingPathComponent("cancel-" + nonce)) }
            var validations = 0, launches = 0
            let reopened = NativeUpdateRecoveryGate.reopen(isRevoked: { context.isRevoked }, validateCanonical: {
                validations += 1
                if mode == 2 { context.requestTermination() } // TERM arrives during a deep signature check
                return mode != 4
            }, relaunch: { launches += 1 })
            XCTAssertEqual(reopened, mode == 3); XCTAssertEqual(launches, mode == 3 ? 1 : 0)
            XCTAssertEqual(validations, mode <= 1 ? 0 : 1)
        }
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
