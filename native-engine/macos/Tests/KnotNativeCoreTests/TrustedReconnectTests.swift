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
    private(set) var delays: [Duration] = []
    var waiting: Bool { pending != nil }
    func wait(_ delay: Duration) async throws {
        delays.append(delay)
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
    @Test @MainActor func longOutageKeepsCappedBackoffAndRecoversAfterTheFormerSixRetryLimit() async throws {
        let device = try inertSavedDevice(), invitation = try inertInvitation()
        let attempts = TrustedAttemptRecorder(), gate = InertRetryWait(), channel = HeldReconnectChannel()
        let model = SessionModel(makeChannel: { _ in channel }, makeTrustedClient: { _, _ in
            if attempts.count < 12 { return FailingTrustedClient(.transport, attempts) }
            return SuccessfulTrustedClient(invitation)
        }, waitForReconnect: { try await gate.wait($0) }, initialSavedDevices: [device])
        defer { model.disconnect(); gate.advance() }
        model.connectSaved(device.id)
        for attempt in 1...12 {
            #expect(await waitForTrustedState { attempts.count == attempt && gate.waiting })
            #expect(model.hasPendingReconnect && model.reconnectAttemptCount == min(attempt, 6))
            #expect(!model.status.contains("/6"))
            gate.advance()
        }
        #expect(await waitForTrustedState { model.phase == .approval && channel.isReading })
        #expect(gate.delays == [1, 2, 4, 8, 16, 30, 30, 30, 30, 30, 30, 30].map { Duration.seconds($0) })
        #expect(!model.hasPendingReconnect && attempts.count == 12)
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
            #expect(failure == .trust ? model.status.contains("새 번호로 다시 등록") : !model.status.contains("새 번호로 다시 등록"))
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


@MainActor private final class InertUpdateResume {
    var writes: [(String?, TimeInterval)] = []
    var value: (String, TimeInterval)?
    func write(_ id: String?, _ expiry: TimeInterval) { writes.append((id, expiry)); value = id.map { ($0, expiry) } }
    func take() -> (String, TimeInterval)? { defer { value = nil }; return value }
}

@Test @MainActor func registeredStartupSilenceUsesSameRecoveryAsTransportButCapsStayTerminal() async throws {
    let device = try inertSavedDevice()
    for phase in [SessionModel.Phase.connecting, .approval, .decoding] {
        let gate = InertRetryWait()
        let attempts = TrustedAttemptRecorder()
        let model = SessionModel(makeTrustedClient: { _, _ in FailingTrustedClient(.transport, attempts) },
            waitForReconnect: { try await gate.wait($0) }, initialSavedDevices: [device], initialRegisteredDevice: device)
        model.phase = phase
        let silence = phase == .approval ? 66 : 11
        #expect(!model.checkDeadlines(now: .now + .seconds(silence)))
        #expect(model.hasPendingReconnect && model.reconnectAttemptCount == 1)
        #expect(await waitForTrustedState { gate.waiting })
        model.disconnect(); gate.advance()
        #expect(attempts.count == 0)
    }
    for (phase, age) in [(SessionModel.Phase.approval, 126), (.decoding, 16)] {
        let attempts = TrustedAttemptRecorder()
        let model = SessionModel(makeTrustedClient: { _, _ in FailingTrustedClient(.transport, attempts) },
            waitForReconnect: { _ in Issue.record("Startup cap must remain terminal") }, initialSavedDevices: [device], initialRegisteredDevice: device)
        model.phase = phase
        #expect(!model.checkDeadlines(now: .now + .seconds(age)))
        #expect(!model.hasPendingReconnect && model.reconnectAttemptCount == 0)
        #expect(!NativeCopy.status(model.status, reconnectMethod: model.reconnectMethod).contains("8자리"))
    }
}

@Test @MainActor func registeredMediaErrorsKeepCredentialsAndNeverRequestReregistration() async throws {
    let device = try inertSavedDevice(), invitation = try inertInvitation()
    for failure in [NativeFailure.decoder, .malformed, .oversized, .state, .unsupported] {
        let model = SessionModel(makeChannel: { _ in throw failure }, makeTrustedClient: { _, _ in SuccessfulTrustedClient(invitation) },
            waitForReconnect: { _ in Issue.record("Protocol/media errors remain terminal") }, initialSavedDevices: [device])
        model.connectSaved(device.id)
        #expect(await waitForTrustedState { model.phase == .failed })
        #expect(model.savedDevices == [device] && !model.hasPendingReconnect)
        let copy = NativeCopy.status(model.status, reconnectMethod: model.reconnectMethod)
        #expect(model.reconnectMethod == .registered && !copy.contains("8자리") && !copy.contains("다시 등록"))
        #expect(copy.contains("내 PC"))
        model.disconnect()
    }
}

@Test @MainActor func updateResumeRequiresLiveRecoveryIntentAndUsesOnlyInjectedStore() async throws {
    let device = try inertSavedDevice()
    for live in [false, true] {
        let store = InertUpdateResume()
        let attempts = TrustedAttemptRecorder()
        let model = SessionModel(makeTrustedClient: { _, _ in FailingTrustedClient(.transport, attempts) },
            initialSavedDevices: [device], initialRegisteredDevice: device,
            writeUpdateResume: { store.write($0, $1) }, takeUpdateResume: { store.take() })
        model.phase = live ? .streaming : .failed
        model.prepareForUpdate()
        #expect(store.writes.count == 1)
        #expect(store.writes[0].0 == (live ? device.id : nil))
        #expect(!model.hasPendingReconnect && model.phase == .idle)
    }
    let store = InertUpdateResume(), attempts = TrustedAttemptRecorder()
    store.value = (device.id, Date().addingTimeInterval(60).timeIntervalSince1970)
    let model = SessionModel(makeTrustedClient: { _, _ in FailingTrustedClient(.trust, attempts) }, initialSavedDevices: [device],
        writeUpdateResume: { store.write($0, $1) }, takeUpdateResume: { store.take() })
    model.resumeAfterUpdateIfRequested()
    #expect(await waitForTrustedState { attempts.count == 1 && model.phase == .failed })
    model.resumeAfterUpdateIfRequested()
    #expect(store.value == nil && attempts.count == 1)
}

@Test @MainActor func savedConnectValidatesLabelBeforeCreatingAnyAdapterAndRefreshUsesInjection() throws {
    let device = try inertSavedDevice(), attempts = TrustedAttemptRecorder()
    let model = SessionModel(makeTrustedClient: { _, _ in FailingTrustedClient(.trust, attempts) }, loadSavedDevices: { [device] })
    model.refreshSavedDevices()
    #expect(model.savedDevices == [device])
    model.viewerLabel = ""
    model.connectSaved(device.id)
    #expect(model.phase == .failed && attempts.count == 0 && !model.hasPendingReconnect)
    #expect(model.status == "Choose a viewer label of 1–64 UTF-8 bytes without control characters.")
}


@Test @MainActor func updaterRestoresPendingRecoveryAcrossAnExtendedOutage() async throws {
    let device = try inertSavedDevice(), pending = InertRetryWait(), activeStore = InertUpdateResume()
    let attempts = TrustedAttemptRecorder()
    let waiting = SessionModel(makeTrustedClient: { _, _ in FailingTrustedClient(.transport, attempts) },
        waitForReconnect: { try await pending.wait($0) }, initialSavedDevices: [device],
        writeUpdateResume: { activeStore.write($0, $1) }, takeUpdateResume: { activeStore.take() })
    waiting.connectSaved(device.id)
    #expect(await waitForTrustedState { pending.waiting })
    waiting.prepareForUpdate(); pending.advance()
    #expect(activeStore.value?.0 == device.id && !waiting.hasPendingReconnect)
    let extendedStore = InertUpdateResume(), extendedAttempts = TrustedAttemptRecorder(), extendedWait = InertRetryWait()
    let extended = SessionModel(makeTrustedClient: { _, _ in FailingTrustedClient(.transport, extendedAttempts) },
        waitForReconnect: { try await extendedWait.wait($0) }, initialSavedDevices: [device],
        writeUpdateResume: { extendedStore.write($0, $1) }, takeUpdateResume: { extendedStore.take() })
    defer { extended.disconnect(); extendedWait.advance() }
    extended.connectSaved(device.id)
    for attempt in 1...8 {
        #expect(await waitForTrustedState { extendedAttempts.count == attempt && extendedWait.waiting })
        if attempt < 8 { extendedWait.advance() }
    }
    #expect(extended.hasPendingReconnect && extended.reconnectAttemptCount == 6)
    extended.prepareForUpdate(); extendedWait.advance()
    #expect(extendedStore.writes.count == 1 && extendedStore.value?.0 == device.id)
    #expect(!extended.hasPendingReconnect)
}


private func inertNumberEnrollment() throws -> AuthenticatedEnrollment {
    let candidate = try EnrollmentCandidate(address: "192.168.50.20", port: 48632,
        slot: Data(repeating: 8, count: 16), name: "Synthetic PC")
    let invitation = try JSONSerialization.data(withJSONObject: ["v": 1, "address": candidate.address, "port": 48631,
        "certificateSHA256": String(repeating: "a", count: 64), "token": Invitation.encodeBase64URL(Data(repeating: 3, count: 32))])
    let offer = try JSONSerialization.data(withJSONObject: ["v": 2, "slot": Invitation.encodeBase64URL(candidate.slot),
        "grant": Invitation.encodeBase64URL(Data(repeating: 4, count: 16)),
        "invitation": "knot-native:v1:" + Invitation.encodeBase64URL(invitation), "ttlMs": 30000])
    return AuthenticatedEnrollment(offer: try EnrollmentOffer(offer, candidate: candidate), viewerName: "Fixture Mac", expiresAt: .now + .seconds(30))
}

@Test @MainActor func silenceTimerAndTransportFailureKeepCopyAndAuthorityParityForEveryConnectionMode() async throws {
    let device = try inertSavedDevice(), invitation = try inertInvitation(), number = try inertNumberEnrollment()
    for (registered, automatic, numberMode) in [(true, true, false), (true, false, false), (false, true, false), (false, true, true)] {
        let timerGate = InertRetryWait(), readerGate = InertRetryWait()
        let timer = SessionModel(makeChannel: { _ in FailedHelloChannel() }, makeTrustedClient: { _, _ in SuccessfulTrustedClient(invitation) },
            waitForReconnect: { try await timerGate.wait($0) }, initialSavedDevices: registered ? [device] : [], initialRegisteredDevice: registered ? device : nil)
        let reader = SessionModel(makeChannel: { _ in FailedHelloChannel() }, makeTrustedClient: { _, _ in SuccessfulTrustedClient(invitation) },
            waitForReconnect: { try await readerGate.wait($0) }, initialSavedDevices: registered ? [device] : [])
        timer.autoReconnect = automatic; reader.autoReconnect = automatic
        if registered { timer.phase = .streaming; reader.connectSaved(device.id) }
        else if numberMode { timer.connectAuthenticated(number); reader.connectAuthenticated(number) }
        else { timer.invitation = invitation; timer.connect(); reader.invitation = invitation; reader.connect() }
        #expect(!timer.checkDeadlines(now: .now + .seconds(11)))
        #expect(await waitForTrustedState { reader.phase == .failed })
        let shouldRetry = registered && automatic
        #expect(timer.hasPendingReconnect == shouldRetry && reader.hasPendingReconnect == shouldRetry)
        #expect(timer.reconnectAttemptCount == (shouldRetry ? 1 : 0))
        #expect(reader.reconnectAttemptCount == (shouldRetry ? 1 : 0))
        #expect(NativeCopy.status(timer.status, reconnectMethod: timer.reconnectMethod) == NativeCopy.status(reader.status, reconnectMethod: reader.reconnectMethod))
        if shouldRetry { #expect(await waitForTrustedState { timerGate.waiting && readerGate.waiting }) }
        timer.disconnect(); reader.disconnect(); timerGate.advance(); readerGate.advance()
    }
}

@Test @MainActor func updateResumeConsumesExpiredFutureOrDisabledIntentWithoutAuthentication() throws {
    let device = try inertSavedDevice()
    for (offset, enabled) in [(-60.0, true), (301.0, true), (60.0, false)] {
        let store = InertUpdateResume(), attempts = TrustedAttemptRecorder()
        store.value = (device.id, Date().addingTimeInterval(offset).timeIntervalSince1970)
        let model = SessionModel(makeTrustedClient: { _, _ in
            attempts.attempt(); Issue.record("Expired or disabled update intent must not authenticate")
            return FailingTrustedClient(.trust, attempts)
        }, initialSavedDevices: [device], writeUpdateResume: { store.write($0, $1) }, takeUpdateResume: { store.take() })
        model.autoReconnect = enabled
        model.resumeAfterUpdateIfRequested()
        #expect(store.value == nil && attempts.count == 0 && !model.hasPendingReconnect && model.phase == .idle)
    }
    let store = InertUpdateResume(), attempts = TrustedAttemptRecorder()
    let active = SessionModel(makeTrustedClient: { _, _ in FailingTrustedClient(.transport, attempts) },
        initialSavedDevices: [device], initialRegisteredDevice: device,
        writeUpdateResume: { store.write($0, $1) }, takeUpdateResume: { store.take() })
    active.phase = .streaming; active.autoReconnect = false
    active.prepareForUpdate()
    #expect(store.value == nil && store.writes.count == 1 && attempts.count == 0)
}

// Synthetic blocked transport: no sockets, OS capture, clipboard or activity IO.
private final class HeldReconnectChannel: NativeChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CheckedContinuation<Data, any Error>?
    private var closed = false
    var isReading: Bool { lock.withLock { pending != nil } }
    func start() async throws {}
    func send(_ packet: Packet) async throws {}
    func readExactly(_ count: Int, timeout: Duration) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed { lock.unlock(); continuation.resume(throwing: NativeFailure.transport) }
            else { pending = continuation; lock.unlock() }
        }
    }
    func close() {
        lock.lock(); closed = true; let owned = pending; pending = nil; lock.unlock()
        owned?.resume(throwing: NativeFailure.transport)
    }
}
private final class ActivityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0, stops = 0
    var counts: (Int, Int) { lock.withLock { (starts, stops) } }
    func make() -> NativeConnectionActivity {
        NativeConnectionActivity(begin: { self.lock.withLock { self.starts += 1 }; return NSObject() },
                                 end: { _ in self.lock.withLock { self.stops += 1 } })
    }
}

@Test func connectionActivityEndsExactlyOnceAndAllowsIdleSystemSleep() {
    let recorder = ActivityRecorder()
    var lease: NativeConnectionActivity? = recorder.make()
    #expect(recorder.counts == (1, 0))
    lease?.stop(); lease?.stop(); lease = nil
    #expect(recorder.counts == (1, 1))
    do { let scoped = recorder.make(); withExtendedLifetime(scoped) {} }
    #expect(recorder.counts == (2, 2))
    #expect(NativeConnectionActivity.options == .userInitiatedAllowingIdleSystemSleep)
    #expect(!NativeConnectionActivity.options.contains(.idleSystemSleepDisabled))
    #expect(!NativeConnectionActivity.options.contains(.idleDisplaySleepDisabled))
}

@Test(arguments: ["disconnect", "autoOff", "forget", "newTarget"])
@MainActor func extendedRecoveryActivityEndsOnOwnerCancellationAndRejectsLateRetry(_ action: String) async throws {
    let device = try inertSavedDevice(), attempts = TrustedAttemptRecorder(), retry = InertRetryWait()
    let activities = ActivityRecorder()
    let model = SessionModel(makeTrustedClient: { _, _ in FailingTrustedClient(.transport, attempts) },
        waitForReconnect: { try await retry.wait($0) }, initialSavedDevices: [device], removeSavedDevice: { _ in },
        makeConnectionActivity: { activities.make() })
    defer { model.disconnect(); retry.advance() }
    model.connectSaved(device.id)
    for attempt in 1...8 {
        #expect(await waitForTrustedState { attempts.count == attempt && retry.waiting })
        if attempt < 8 { retry.advance() }
    }
    #expect(activities.counts == (1, 0) && model.hasPendingReconnect)
    switch action {
    case "disconnect": model.disconnect()
    case "autoOff": model.autoReconnect = false
    case "forget": model.forgetSaved(device.id)
    default: model.prepareForNewTarget()
    }
    #expect(activities.counts == (1, 1) && !model.hasPendingReconnect)
    retry.advance()
    for _ in 0..<30 { await Task.yield() }
    #expect(!model.active && !model.hasPendingReconnect && activities.counts == (1, 1))
}

@Test @MainActor func activeConnectionKeepsActivityWithAutomaticReconnectOffAndSleepReleasesIt() async throws {
    let device = try inertSavedDevice(), invitation = try inertInvitation(), channel = HeldReconnectChannel()
    let activities = ActivityRecorder(), wake = InertRetryWait()
    let model = SessionModel(makeChannel: { _ in channel }, makeTrustedClient: { _, _ in SuccessfulTrustedClient(invitation) },
        waitForWakeReadiness: { try await wake.wait(.seconds(2)) }, initialSavedDevices: [device],
        makeConnectionActivity: { activities.make() })
    defer { model.disconnect(); wake.advance() }
    model.connectSaved(device.id)
    #expect(await waitForTrustedState { model.phase == .approval && channel.isReading })
    model.autoReconnect = false
    #expect(activities.counts == (1, 0)) // The live heartbeat still needs timely scheduling.
    model.autoReconnect = true
    model.systemWillSleep()
    #expect(activities.counts == (1, 1) && model.isSystemSleeping && model.hasPendingReconnect)
    model.systemDidWake()
    #expect(await waitForTrustedState { wake.waiting })
    #expect(activities.counts == (2, 1))
    model.disconnect(); wake.advance()
    for _ in 0..<20 { await Task.yield() }
    #expect(activities.counts == (2, 2) && !model.active && !model.hasPendingReconnect)
}

@Test @MainActor func terminalFailuresReleaseConnectionActivityWithoutRetry() async throws {
    let device = try inertSavedDevice()
    for failure in [NativeFailure.trust, .certificatePinMismatch, .certificatePolicy, .malformed, .decoder] {
        let activities = ActivityRecorder(), attempts = TrustedAttemptRecorder()
        let model = SessionModel(makeTrustedClient: { _, _ in FailingTrustedClient(failure, attempts) },
            waitForReconnect: { _ in Issue.record("Terminal failure cannot recover") }, initialSavedDevices: [device],
            makeConnectionActivity: { activities.make() })
        model.connectSaved(device.id)
        #expect(await waitForTrustedState { model.phase == .failed })
        #expect(!model.hasPendingReconnect && activities.counts == (1, 1))
        model.systemWillSleep(); model.systemDidWake()
        #expect(activities.counts == (1, 1) && !model.hasPendingReconnect)
        model.disconnect()
    }
}

@Test @MainActor func onlyCurrentRegisteredPreReadyBusyAndTimeoutResponsesKeepRecovery() async throws {
    let device = try inertSavedDevice()
    for phase in [SessionModel.Phase.approval, .decoding, .streaming] {
        for registered in [false, true] {
            for code in ["timeout", "busy", "auth", "expired", "capture", "input", "protocol"] {
                let retry = InertRetryWait()
                let model = SessionModel(waitForReconnect: { try await retry.wait($0) },
                    initialSavedDevices: registered ? [device] : [], initialRegisteredDevice: registered ? device : nil)
                defer { model.disconnect(); retry.advance() }
                model.phase = phase
                model.handleHostError(code)
                let recovers = registered && phase == .approval && ["timeout", "busy"].contains(code)
                #expect(model.hasPendingReconnect == recovers)
                #expect(model.phase == .failed)
                if recovers { #expect(await waitForTrustedState { retry.waiting }) }
            }
        }
    }
    let disabled = SessionModel(initialSavedDevices: [device], initialRegisteredDevice: device)
    disabled.autoReconnect = false; disabled.phase = .approval; disabled.handleHostError("timeout")
    #expect(!disabled.hasPendingReconnect)
}

private final class ReconnectErrorChannel: NativeChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data
    init(_ code: String) { bytes = Packet(kind: .error, payload: Data("{\"code\":\"\(code)\"}".utf8)).encoded }
    func start() async throws {}
    func send(_ packet: Packet) async throws {}
    func readExactly(_ count: Int, timeout: Duration) async throws -> Data {
        try lock.withLock {
            guard count <= bytes.count else { throw NativeFailure.transport }
            let value = Data(bytes.prefix(count)); bytes.removeFirst(count); return value
        }
    }
    func close() { lock.withLock { bytes.removeAll() } }
}

@Test @MainActor func framedPreReadyTimeoutUsesFreshTrustedRecoveryWithoutDiscardingSavedCredential() async throws {
    let device = try inertSavedDevice(), invitation = try inertInvitation()
    let retry = InertRetryWait(), activities = ActivityRecorder()
    let model = SessionModel(makeChannel: { _ in ReconnectErrorChannel("timeout") },
        makeTrustedClient: { _, _ in SuccessfulTrustedClient(invitation) },
        waitForReconnect: { try await retry.wait($0) }, initialSavedDevices: [device],
        makeConnectionActivity: { activities.make() })
    defer { model.disconnect(); retry.advance() }
    model.connectSaved(device.id)
    #expect(await waitForTrustedState { model.phase == .failed && retry.waiting })
    #expect(model.hasPendingReconnect && model.savedDevices == [device])
    #expect(activities.counts == (1, 0))
    model.disconnect(); retry.advance()
    for _ in 0..<20 { await Task.yield() }
    #expect(!model.active && !model.hasPendingReconnect && activities.counts == (1, 1))
}
