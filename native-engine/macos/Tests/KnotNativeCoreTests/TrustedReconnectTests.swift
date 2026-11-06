import Foundation
import Network
import Testing
@testable import KnotNativeCore
@testable import KnotNativePreview

private func inertSavedDevice() throws -> SavedNativeDevice {
    let fields: [String: Any] = ["id": Invitation.encodeBase64URL(Data(repeating: 1, count: 32)), "name": "Synthetic PC",
        "address": "192.168.50.20", "certificateSHA256": String(repeating: "a", count: 64),
        "secret": Data(repeating: 2, count: 32).base64EncodedString()]
    return try JSONDecoder().decode(SavedNativeDevice.self, from: JSONSerialization.data(withJSONObject: fields)).validated()
}
private final class TrustedAttemptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func attempt() { lock.withLock { calls += 1 } }
}
private final class FailingTrustedClient: NativeTrustedConnecting, @unchecked Sendable {
    let failure: NativeFailure
    let recorder: TrustedAttemptRecorder
    init(_ failure: NativeFailure, _ recorder: TrustedAttemptRecorder) { self.failure = failure; self.recorder = recorder }
    func connect(revoke: Bool) async throws -> Invitation? { recorder.attempt(); throw failure }
    func close() {}
}
private final class SuccessfulTrustedClient: NativeTrustedConnecting, Sendable {
    let invitation: Invitation
    init(_ invitation: Invitation) { self.invitation = invitation }
    func connect(revoke: Bool) async throws -> Invitation? { invitation }
    func close() {}
}
private final class FailedHelloChannel: NativeChannel, Sendable {
    func start() async throws {}
    func readExactly(_ count: Int, timeout: Duration) async throws -> Data { throw NativeFailure.transport }
    func send(_ packet: Packet) async throws { throw NativeFailure.transport }
    func close() {}
}
private func inertInvitation() throws -> Invitation {
    let fields: [String: Any] = ["v": 1, "address": "192.168.50.20", "port": 48631,
        "certificateSHA256": String(repeating: "a", count: 64),
        "token": Invitation.encodeBase64URL(Data(repeating: 3, count: 32))]
    return try Invitation("knot-native:v1:" + Invitation.encodeBase64URL(JSONSerialization.data(withJSONObject: fields)))
}
@MainActor private final class InertRetryWait {
    private var pending: CheckedContinuation<Void, any Error>?
    var waiting: Bool { pending != nil }
    func wait(_ delay: Duration) async throws {
        try await withCheckedThrowingContinuation { pending = $0 }
    }
    func advance() { let waiter = pending; pending = nil; waiter?.resume() }
}
@MainActor private func waitForTrustedState(_ predicate: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
    return predicate()
}

struct TrustedReconnectTests {
    @Test @MainActor func registeredStreamingSilenceSchedulesRetryAndManualStopCancelsIt() async throws {
        let device = try inertSavedDevice(), attempts = TrustedAttemptRecorder(), gate = InertRetryWait()
        let model = SessionModel(makeTrustedClient: { _, _ in FailingTrustedClient(.transport, attempts) },
            waitForReconnect: { try await gate.wait($0) }, initialSavedDevices: [device], initialRegisteredDevice: device)
        model.phase = .streaming
        #expect(!model.checkDeadlines(now: .now + .seconds(11)))
        #expect(model.reconnectAttemptCount == 1)
        #expect(model.hasPendingReconnect)
        #expect(await waitForTrustedState { gate.waiting })
        model.disconnect()
        #expect(model.phase == .idle)
        #expect(!model.hasPendingReconnect)
        gate.advance()
        for _ in 0..<20 { await Task.yield() }
        #expect(attempts.count == 0)
    }
    @Test @MainActor func transientFailuresStopAtSixRetriesWithoutOSAdapters() async throws {
        let device = try inertSavedDevice(), attempts = TrustedAttemptRecorder()
        let model = SessionModel(makeTrustedClient: { _, _ in FailingTrustedClient(.transport, attempts) },
            waitForReconnect: { _ in await Task.yield() }, initialSavedDevices: [device])
        model.connectSaved(device.id)
        #expect(await waitForTrustedState { attempts.count == 7 && model.phase == .failed && !model.hasPendingReconnect })
        #expect(model.reconnectAttemptCount == 6)
        for _ in 0..<20 { await Task.yield() }
        #expect(attempts.count == 7)
        model.disconnect()
    }
    @Test @MainActor func trustAndMalformedFailuresNeverScheduleRetry() async throws {
        let device = try inertSavedDevice()
        for failure in [NativeFailure.trust, .malformed, .unsupported] {
            let attempts = TrustedAttemptRecorder()
            let model = SessionModel(makeTrustedClient: { _, _ in FailingTrustedClient(failure, attempts) },
                waitForReconnect: { _ in Issue.record("Authentication failure must not arm a retry") }, initialSavedDevices: [device])
            model.connectSaved(device.id)
            #expect(await waitForTrustedState { attempts.count == 1 && model.phase == .failed })
            #expect(!model.hasPendingReconnect)
            #expect(model.reconnectAttemptCount == 0)
            #expect(model.status.contains("새 번호로 다시 등록"))
            model.disconnect()
        }
    }
    @Test @MainActor func certificateFailuresAreTerminalBeforeOrAfterSavedAuthentication() async throws {
        let device = try inertSavedDevice(), invitation = try inertInvitation()
        for failure in [NativeFailure.certificatePinMismatch, .certificatePolicy] {
            for authenticated in [false, true] {
                let attempts = TrustedAttemptRecorder()
                let model = SessionModel(makeChannel: { _ in throw failure },
                    makeTrustedClient: { _, _ in
                        if authenticated { return SuccessfulTrustedClient(invitation) }
                        return FailingTrustedClient(failure, attempts)
                    }, waitForReconnect: { _ in Issue.record("Certificate failures must not schedule retry") }, initialSavedDevices: [device])
                model.connectSaved(device.id)
                #expect(await waitForTrustedState { model.phase == .failed })
                #expect(!model.hasPendingReconnect && model.reconnectAttemptCount == 0)
                #expect(model.savedDevices == [device]) // A mismatch never silently replaces the saved pin.
                let guidance = NativeCopy.status(model.status, reconnectMethod: model.reconnectMethod)
                if failure == .certificatePinMismatch {
                    #expect(guidance.contains("달라") && guidance.contains("새 8자리 번호로 다시 등록"))
                    #expect(!guidance.contains("호환 인증서"))
                } else {
                    #expect(guidance.contains("macOS") && guidance.contains("native.12") && guidance.contains("호환 인증서로 전환하고 공유"))
                }
                for _ in 0..<20 { await Task.yield() }
                #expect(!model.hasPendingReconnect)
                model.disconnect()
            }
        }
    }
    @Test @MainActor func freshConnectionAndHelloFailuresKeepPreciseRecoveryGuidance() async throws {
        let invitation = try inertInvitation()
        for failure in [NativeFailure.certificatePinMismatch, .certificatePolicy, .transport] {
            let model = SessionModel(makeChannel: { _ in throw failure })
            model.invitation = invitation; model.connect()
            #expect(NativeCopy.status(model.status) == "보안 연결을 확인하고 있어요.")
            #expect(await waitForTrustedState { model.phase == .failed })
            let guidance = NativeCopy.status(model.status, reconnectMethod: model.reconnectMethod)
            switch failure {
            case .certificatePinMismatch:
                #expect(guidance.contains("새 8자리 번호로 다시 등록") && !guidance.contains("호환 인증서"))
            case .certificatePolicy:
                #expect(guidance.contains("호환 인증서로 전환하고 공유") && guidance.contains("native.12"))
            default:
                #expect(guidance.contains("네트워크") && guidance.contains("방화벽") && guidance.contains("새 연결 코드"))
                #expect(!guidance.contains("인증서"))
            }
            #expect(!guidance.contains(invitation.address) && !guidance.contains(invitation.certificateSHA256) && !guidance.contains(invitation.token))
        }
        let hello = SessionModel(makeChannel: { _ in FailedHelloChannel() })
        hello.invitation = invitation; hello.connect()
        #expect(await waitForTrustedState { hello.phase == .failed })
        let guidance = NativeCopy.status(hello.status)
        #expect(guidance.contains("네트워크") && !guidance.contains("인증서"))
    }
    @Test func authenticatedRejectionAndTLSFailureClassification() throws {
        #expect(throws: NativeFailure.trust) {
            try NativeTrustedClient.response(kind: 0x7f, payload: Data("{\"code\":\"rejected\"}".utf8), keys: ["nonce"])
        }
        #expect(throws: NativeFailure.transport) {
            try NativeTrustedClient.response(kind: 0x7f, payload: Data("{\"code\":\"busy\"}".utf8), keys: ["nonce"])
        }
        #expect(throws: NativeFailure.malformed) {
            try NativeTrustedClient.response(kind: 0x7f, payload: Data("{\"code\":\"bad-proof-details\"}".utf8), keys: ["nonce"])
        }
        #expect(TLSChannel.startFailure(.tls(-9807)) == .transport)
        #expect(TLSChannel.startFailure(.tls(-9807), verificationFailure: .certificatePinMismatch) == .certificatePinMismatch)
        #expect(TLSChannel.startFailure(.tls(-9807), verificationFailure: .certificatePolicy) == .certificatePolicy)
        #expect(TLSChannel.startFailure(.posix(.ECONNREFUSED)) == .transport)
    }
}
