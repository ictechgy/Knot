import AppKit
import CoreVideo
import Foundation
import Testing
@testable import KnotNativeCore
@testable import KnotNativePreview

// All fixtures below are in-memory. No workspace center, app, store, device,
// network transport, audio output, or one-use real credential is opened.
private func sleepDevice(_ byte: UInt8 = 1) throws -> SavedNativeDevice {
    let fields: [String: Any] = ["id": Invitation.encodeBase64URL(Data(repeating: byte, count: 32)),
        "name": "Synthetic PC", "address": "192.168.50.\(20 + byte)",
        "certificateSHA256": String(repeating: "a", count: 64),
        "secret": Data(repeating: byte + 1, count: 32).base64EncodedString()]
    return try JSONDecoder().decode(SavedNativeDevice.self, from: JSONSerialization.data(withJSONObject: fields)).validated()
}
private func sleepInvitation(_ byte: UInt8 = 3) throws -> Invitation {
    let fields: [String: Any] = ["v": 1, "address": "192.168.50.21", "port": 48631,
        "certificateSHA256": String(repeating: "a", count: 64),
        "token": Invitation.encodeBase64URL(Data(repeating: byte, count: 32))]
    return try Invitation("knot-native:v1:" + Invitation.encodeBase64URL(JSONSerialization.data(withJSONObject: fields)))
}
private func sleepSecret(_ byte: UInt8 = 3) throws -> String {
    let fields: [String: Any] = ["v": 1, "address": "192.168.50.21", "port": 48631,
        "certificateSHA256": String(repeating: "a", count: 64),
        "token": Invitation.encodeBase64URL(Data(repeating: byte, count: 32))]
    return "knot-native:v1:" + Invitation.encodeBase64URL(try JSONSerialization.data(withJSONObject: fields))
}
private func sleepEnrollment() throws -> AuthenticatedEnrollment {
    let candidate = try EnrollmentCandidate(address: "192.168.50.22", port: 48632,
        slot: Data(repeating: 5, count: 16), name: "Other synthetic PC")
    let invitation = try JSONSerialization.data(withJSONObject: ["v": 1, "address": candidate.address, "port": 48631,
        "certificateSHA256": String(repeating: "b", count: 64),
        "token": Invitation.encodeBase64URL(Data(repeating: 6, count: 32))])
    let fields: [String: Any] = ["v": 2, "slot": Invitation.encodeBase64URL(candidate.slot),
        "grant": Invitation.encodeBase64URL(Data(repeating: 7, count: 16)),
        "invitation": "knot-native:v1:" + Invitation.encodeBase64URL(invitation), "ttlMs": 30000]
    return AuthenticatedEnrollment(offer: try EnrollmentOffer(JSONSerialization.data(withJSONObject: fields), candidate: candidate),
        viewerName: "Other synthetic Mac", expiresAt: .now + .seconds(30))
}
private final class SleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<Void, any Error>] = []
    private var waits = 0
    var count: Int { lock.withLock { waits } }
    var pendingCount: Int { lock.withLock { pending.count } }
    // Intentionally ignores cancellation: callers must reject late completion.
    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { waits += 1; pending.append(continuation) }
        }
    }
    func advance() {
        let next = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        next?.resume()
    }
    func releaseAll() {
        let all = lock.withLock { let all = pending; pending = []; return all }
        for continuation in all { continuation.resume() }
    }
}
private enum SleepTrustedOutcome: Sendable {
    case success(Invitation), failure(NativeFailure), held(SleepGate, Invitation)
}
private final class SleepTrustedFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let outcomes: [SleepTrustedOutcome]
    private var createdIDs: [String] = []
    private var calls = 0
    private var revocations = 0
    private var closes = 0
    init(_ outcomes: [SleepTrustedOutcome]) { self.outcomes = outcomes }
    var deviceIDs: [String] { lock.withLock { createdIDs } }
    var normalCalls: Int { lock.withLock { calls } }
    var closeCount: Int { lock.withLock { closes } }
    func make(_ device: SavedNativeDevice) -> any NativeTrustedConnecting {
        let outcome = lock.withLock {
            let outcome = outcomes[min(createdIDs.count, outcomes.count - 1)]
            createdIDs.append(device.id); return outcome
        }
        return SleepTrustedClient(outcome, owner: self)
    }
    func called(revoke: Bool) { lock.withLock { if revoke { revocations += 1 } else { calls += 1 } } }
    func closed() { lock.withLock { closes += 1 } }
}
private final class SleepTrustedClient: NativeTrustedConnecting, Sendable {
    let outcome: SleepTrustedOutcome
    let owner: SleepTrustedFactory
    init(_ outcome: SleepTrustedOutcome, owner: SleepTrustedFactory) { self.outcome = outcome; self.owner = owner }
    func connect(revoke: Bool) async throws -> Invitation? {
        owner.called(revoke: revoke)
        if revoke { return nil }
        switch outcome {
        case .success(let invitation): return invitation
        case .failure(let error): throw error
        case .held(let gate, let invitation): try await gate.wait(); return invitation
        }
    }
    func close() { owner.closed() }
}
private final class SleepChannel: NativeChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CheckedContinuation<Data, any Error>?
    private var closed = false
    private var closes = 0
    var isReading: Bool { lock.withLock { pending != nil } }
    var closeCount: Int { lock.withLock { closes } }
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
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true; closes += 1
        let reader = pending; pending = nil
        lock.unlock(); reader?.resume(throwing: NativeFailure.transport)
    }
}
private final class SleepChannels: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String] = []
    private var transports: [SleepChannel] = []
    var invitations: [String] { lock.withLock { tokens } }
    var channels: [SleepChannel] { lock.withLock { transports } }
    func make(_ invitation: Invitation) -> any NativeChannel {
        let channel = SleepChannel()
        lock.withLock { tokens.append(invitation.token); transports.append(channel) }
        return channel
    }
}
@MainActor private final class SleepPresenter: NativePresenter {
    var onFailure: (() -> Void)?
    var cleared = 0, forgotten = 0
    func display(_ image: CVPixelBuffer) -> PresentationResult { .presented }
    func clear() { cleared += 1 }
    func forgetHeldKeys() { forgotten += 1 }
}
@MainActor private func sleepEventually(_ predicate: () -> Bool) async -> Bool {
    // This bounds an assertion failure, not reconnect latency. Cooperate with
    // parallel MainActor suites instead of saturating the executor with yields.
    let deadline = ContinuousClock.now + .seconds(10)
    while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    return predicate()
}
@MainActor private func sleepDrain() async { for _ in 0..<30 { await Task.yield() } }

struct SystemSleepReconnectTests {
    @Test @MainActor func sleepSynchronouslyClosesTransportAndReleasesPresentation() async throws {
        let device = try sleepDevice(), factory = SleepTrustedFactory([.success(try sleepInvitation())])
        let channels = SleepChannels(), wake = SleepGate(), presenter = SleepPresenter()
        let model = SessionModel(makeChannel: { channels.make($0) }, makeTrustedClient: { device, _ in factory.make(device) },
            waitForWakeReadiness: { try await wake.wait() }, initialSavedDevices: [device])
        defer { model.disconnect(); wake.releaseAll() }
        model.surface = presenter; model.connectSaved(device.id)
        #expect(await sleepEventually { model.phase == .approval && channels.channels.first?.isReading == true })
        model.phase = .streaming
        let revision = model.inputRevision
        model.systemWillSleep()
        #expect(model.isSystemSleeping && !model.active && model.hasPendingReconnect)
        #expect(channels.channels.first?.closeCount == 1)
        #expect(presenter.cleared == 1 && presenter.forgotten == 1 && model.inputRevision > revision)
        #expect(model.invitation == nil && model.files == nil && model.audio == nil && model.clipboard == nil)
        model.systemWillSleep()
        await sleepDrain()
        #expect(factory.normalCalls == 1 && wake.count == 0)
        #expect(channels.channels.first?.closeCount == 1)
    }

    @Test @MainActor func wakeWaitsThenStartsExactlyOneFreshChallengeAndInvitation() async throws {
        let device = try sleepDevice(), first = try sleepInvitation(3), fresh = try sleepInvitation(4)
        let factory = SleepTrustedFactory([.success(first), .success(fresh)]), channels = SleepChannels(), wake = SleepGate()
        let model = SessionModel(makeChannel: { channels.make($0) }, makeTrustedClient: { device, _ in factory.make(device) },
            waitForWakeReadiness: { try await wake.wait() }, initialSavedDevices: [device])
        defer { model.disconnect(); wake.releaseAll() }
        model.connectSaved(device.id)
        #expect(await sleepEventually { model.phase == .approval })
        model.systemWillSleep(); model.systemDidWake()
        #expect(await sleepEventually { wake.count == 1 })
        #expect(factory.normalCalls == 1 && model.hasPendingReconnect)
        model.systemDidWake(); model.systemDidWake(); await sleepDrain()
        #expect(wake.count == 1)
        wake.advance()
        #expect(await sleepEventually { factory.normalCalls == 2 && model.phase == .approval })
        #expect(channels.invitations == [first.token, fresh.token])
        #expect(factory.deviceIDs == [device.id, device.id] && model.reconnectAttemptCount == 0)
    }

    @Test @MainActor func sleepingCancelsRetryAndRejectsItsLateCompletion() async throws {
        let device = try sleepDevice(), factory = SleepTrustedFactory([.failure(.transport)])
        let retry = SleepGate(), wake = SleepGate()
        let model = SessionModel(makeTrustedClient: { device, _ in factory.make(device) },
            waitForReconnect: { _ in try await retry.wait() }, waitForWakeReadiness: { try await wake.wait() }, initialSavedDevices: [device])
        defer { model.disconnect(); retry.releaseAll(); wake.releaseAll() }
        model.connectSaved(device.id)
        #expect(await sleepEventually { retry.count == 1 })
        model.systemWillSleep(); retry.advance(); await sleepDrain()
        #expect(factory.normalCalls == 1 && model.hasPendingReconnect)
        model.systemDidWake()
        #expect(await sleepEventually { wake.count == 1 })
        #expect(factory.normalCalls == 1)
        wake.advance()
        #expect(await sleepEventually { factory.normalCalls == 2 && retry.count == 2 })
        #expect(model.reconnectAttemptCount == 1)
    }

    @Test @MainActor func wakeResetsTheBackoffAfterAnExtendedTransientOutage() async throws {
        let device = try sleepDevice(), challenge = SleepGate(), wake = SleepGate(), retry = SleepGate()
        let outcomes = Array(repeating: SleepTrustedOutcome.failure(.transport), count: 7) + [.held(challenge, try sleepInvitation())]
        let factory = SleepTrustedFactory(outcomes)
        let model = SessionModel(makeTrustedClient: { device, _ in factory.make(device) },
            waitForReconnect: { _ in try await retry.wait() }, waitForWakeReadiness: { try await wake.wait() }, initialSavedDevices: [device])
        defer { model.disconnect(); retry.releaseAll(); wake.releaseAll(); challenge.releaseAll() }
        model.connectSaved(device.id)
        for attempt in 1...7 {
            #expect(await sleepEventually { factory.normalCalls == attempt && retry.count == attempt })
            if attempt < 7 { retry.advance() }
        }
        #expect(model.phase == .failed && model.hasPendingReconnect)
        #expect(model.reconnectAttemptCount == 6)
        model.systemWillSleep(); model.systemDidWake()
        retry.advance(); await sleepDrain()
        #expect(await sleepEventually { wake.count == 1 })
        wake.advance()
        #expect(await sleepEventually { factory.normalCalls == 8 && challenge.count == 1 })
        #expect(model.active && model.reconnectAttemptCount == 0)
    }

    @Test(arguments: ["savedCurrent", "savedOther", "review", "invalidReview", "connect", "authenticated", "newTarget"])
    @MainActor func connectionActionsDuringSleepPreserveTheSuspendedTarget(_ action: String) async throws {
        let device = try sleepDevice(), other = try sleepDevice(2)
        let first = try sleepInvitation(3), fresh = try sleepInvitation(4)
        let factory = SleepTrustedFactory([.success(first), .success(fresh)]), channels = SleepChannels(), wake = SleepGate()
        let model = SessionModel(makeChannel: { channels.make($0) }, makeTrustedClient: { device, _ in factory.make(device) },
            waitForWakeReadiness: { try await wake.wait() }, initialSavedDevices: [device, other])
        defer { model.disconnect(); wake.releaseAll() }
        model.connectSaved(device.id)
        #expect(await sleepEventually { model.phase == .approval })
        model.phase = .streaming; model.systemWillSleep()
        let status = model.status, revision = model.inputRevision
        #expect(model.isSystemSleeping && model.hasPendingReconnect && !model.active)
        switch action {
        case "savedCurrent": model.connectSaved(device.id)
        case "savedOther": model.connectSaved(other.id)
        case "review": model.review(try sleepSecret(8))
        case "invalidReview": model.review("invalid")
        case "connect": model.connect()
        case "authenticated": model.connectAuthenticated(try sleepEnrollment())
        default: model.prepareForNewTarget()
        }
        await sleepDrain()
        #expect(model.isSystemSleeping && model.hasPendingReconnect && !model.active)
        #expect(model.status == status && model.inputRevision == revision)
        #expect(model.invitation == nil && !model.numberAuthorized && model.viewerLabel == "My Mac")
        #expect(factory.normalCalls == 1 && wake.count == 0 && channels.invitations == [first.token])
        model.systemDidWake()
        #expect(await sleepEventually { wake.count == 1 })
        wake.advance()
        #expect(await sleepEventually { factory.normalCalls == 2 && model.phase == .approval })
        #expect(factory.deviceIDs == [device.id, device.id] && channels.invitations == [first.token, fresh.token])
    }

    @Test @MainActor func unregisteredSleepDoesNotInventPendingRecovery() async throws {
        let factory = SleepTrustedFactory([.failure(.transport)]), wake = SleepGate()
        let model = SessionModel(makeTrustedClient: { device, _ in factory.make(device) }, waitForWakeReadiness: { try await wake.wait() })
        defer { model.disconnect(); wake.releaseAll() }
        model.phase = .streaming; model.systemWillSleep()
        #expect(model.isSystemSleeping && !model.active && !model.hasPendingReconnect)
        model.systemDidWake(); await sleepDrain()
        #expect(!model.isSystemSleeping && !model.hasPendingReconnect && factory.normalCalls == 0 && wake.count == 0)
    }

    @Test(arguments: ["disconnect", "disabled", "forget"])
    @MainActor func cancellationWhileAsleepRevokesTheSuspendedConnection(_ action: String) async throws {
        let device = try sleepDevice(), factory = SleepTrustedFactory([.failure(.transport)]), wake = SleepGate()
        let model = SessionModel(makeTrustedClient: { device, _ in factory.make(device) },
            waitForWakeReadiness: { try await wake.wait() }, initialSavedDevices: [device], initialRegisteredDevice: device,
            removeSavedDevice: { _ in })
        defer { model.disconnect(); wake.releaseAll() }
        model.phase = .streaming; model.systemWillSleep()
        #expect(model.hasPendingReconnect)
        switch action {
        case "disconnect": model.disconnect()
        case "disabled": model.autoReconnect = false
        default: model.forgetSaved(device.id)
        }
        #expect(model.isSystemSleeping && !model.hasPendingReconnect)
        model.systemDidWake(); await sleepDrain()
        #expect(!model.hasPendingReconnect && factory.normalCalls == 0 && wake.count == 0)
    }

    @Test(arguments: [false, true])
    @MainActor func failedCredentialRemovalStillRevokesConnectionAndRecovery(_ whileSleeping: Bool) async throws {
        let device = try sleepDevice(), factory = SleepTrustedFactory([.success(try sleepInvitation())])
        let channels = SleepChannels(), wake = SleepGate()
        let model = SessionModel(makeChannel: { channels.make($0) }, makeTrustedClient: { device, _ in factory.make(device) },
            waitForWakeReadiness: { try await wake.wait() }, initialSavedDevices: [device], removeSavedDevice: { _ in throw NativeFailure.state })
        defer { model.disconnect(); wake.releaseAll() }
        model.connectSaved(device.id)
        #expect(await sleepEventually { model.phase == .approval && channels.channels.first?.isReading == true })
        model.phase = .streaming
        if whileSleeping { model.systemWillSleep(); #expect(model.hasPendingReconnect) }
        model.forgetSaved(device.id)
        #expect(model.phase == .failed && !model.hasPendingReconnect && model.savedDevices == [device])
        #expect(model.status == "연결은 종료했지만 키체인에서 PC 등록을 해제하지 못했어요. 다시 시도하세요.")
        #expect(channels.channels.first?.closeCount == 1)
        if !whileSleeping { model.systemWillSleep() }
        model.systemDidWake(); await sleepDrain()
        #expect(factory.normalCalls == 1 && wake.count == 0 && !model.hasPendingReconnect)
    }

    @Test @MainActor func terminalFailuresNeverAcquireWakeRecoveryFromSelection() async throws {
        let device = try sleepDevice()
        for error in [NativeFailure.trust, .malformed, .unsupported, .certificatePinMismatch, .certificatePolicy, .decoder, .state] {
            let factory = SleepTrustedFactory([.failure(error)]), wake = SleepGate()
            let model = SessionModel(makeTrustedClient: { device, _ in factory.make(device) },
                waitForReconnect: { _ in Issue.record("Terminal error armed a retry") },
                waitForWakeReadiness: { try await wake.wait() }, initialSavedDevices: [device])
            model.connectSaved(device.id)
            #expect(await sleepEventually { model.phase == .failed })
            model.systemWillSleep(); model.systemDidWake(); await sleepDrain()
            #expect(factory.normalCalls == 1 && wake.count == 0 && !model.hasPendingReconnect)
            model.disconnect(); wake.releaseAll()
        }
    }

    @Test @MainActor func choosingNewDiscoveryDuringExtendedRecoveryRevokesOldWakeIntent() async throws {
        let device = try sleepDevice(), factory = SleepTrustedFactory([.failure(.transport)]), wake = SleepGate(), retry = SleepGate()
        let model = SessionModel(makeTrustedClient: { device, _ in factory.make(device) },
            waitForReconnect: { _ in try await retry.wait() }, waitForWakeReadiness: { try await wake.wait() }, initialSavedDevices: [device])
        defer { model.disconnect(); retry.releaseAll(); wake.releaseAll() }
        model.connectSaved(device.id)
        for attempt in 1...8 {
            #expect(await sleepEventually { factory.normalCalls == attempt && retry.count == attempt })
            if attempt < 8 { retry.advance() }
        }
        #expect(model.phase == .failed && model.hasPendingReconnect)
        // The user leaves the old saved target to search/select an unverified
        // candidate. No enrollment or live network adapter is needed to do so.
        model.prepareForNewTarget()
        retry.advance(); await sleepDrain()
        #expect(model.phase == .idle && model.invitation == nil && !model.numberAuthorized)
        model.systemWillSleep(); model.systemDidWake(); await sleepDrain()
        #expect(factory.normalCalls == 8 && wake.count == 0 && !model.hasPendingReconnect)
    }

    @Test @MainActor func disabledDisconnectedForgottenOrReviewedRetryCannotRecover() async throws {
        let device = try sleepDevice(), secret = try sleepSecret(8)
        for action in ["disabled", "disconnect", "forget", "review", "invalidReview"] {
            let factory = SleepTrustedFactory([.failure(.transport)]), retry = SleepGate(), wake = SleepGate()
            let model = SessionModel(makeTrustedClient: { device, _ in factory.make(device) },
                waitForReconnect: { _ in try await retry.wait() }, waitForWakeReadiness: { try await wake.wait() },
                initialSavedDevices: [device], removeSavedDevice: { _ in })
            model.connectSaved(device.id)
            #expect(await sleepEventually { retry.count == 1 })
            switch action {
            case "disabled": model.autoReconnect = false
            case "disconnect": model.disconnect()
            case "forget": model.forgetSaved(device.id)
            case "review": model.review(secret)
            default: model.review("invalid")
            }
            model.systemWillSleep(); model.systemDidWake(); retry.advance(); await sleepDrain()
            #expect(factory.normalCalls == 1 && wake.count == 0 && !model.hasPendingReconnect)
            model.disconnect(); retry.releaseAll(); wake.releaseAll()
        }
    }

    @Test @MainActor func userActionDuringWakeDelayRevokesSuspendedIntent() async throws {
        let device = try sleepDevice(), secret = try sleepSecret(8)
        for action in ["disabled", "disconnect", "forget", "review"] {
            let factory = SleepTrustedFactory([.failure(.transport)]), wake = SleepGate()
            let model = SessionModel(makeTrustedClient: { device, _ in factory.make(device) },
                waitForWakeReadiness: { try await wake.wait() }, initialSavedDevices: [device], initialRegisteredDevice: device,
                removeSavedDevice: { _ in })
            model.phase = .streaming; model.systemWillSleep(); model.systemDidWake()
            #expect(await sleepEventually { wake.count == 1 })
            switch action {
            case "disabled": model.autoReconnect = false
            case "disconnect": model.disconnect()
            case "forget": model.forgetSaved(device.id)
            default: model.review(secret)
            }
            wake.advance(); await sleepDrain()
            #expect(factory.normalCalls == 0 && !model.hasPendingReconnect)
            model.disconnect(); wake.releaseAll()
        }
    }

    @Test @MainActor func savedIdleDeviceNeverAutoConnectsOnWake() async throws {
        let device = try sleepDevice(), factory = SleepTrustedFactory([.failure(.transport)]), wake = SleepGate()
        for selected in [false, true] {
            let model = SessionModel(makeTrustedClient: { device, _ in factory.make(device) },
                waitForWakeReadiness: { try await wake.wait() }, initialSavedDevices: [device], initialRegisteredDevice: selected ? device : nil)
            model.systemWillSleep(); model.systemDidWake(); await sleepDrain()
            #expect(factory.normalCalls == 0 && wake.count == 0 && !model.hasPendingReconnect)
            model.disconnect()
        }
    }

    @Test @MainActor func secondSleepInvalidatesFirstWakeDelay() async throws {
        let device = try sleepDevice(), challenge = SleepGate(), wake = SleepGate()
        let factory = SleepTrustedFactory([.held(challenge, try sleepInvitation())])
        let model = SessionModel(makeTrustedClient: { device, _ in factory.make(device) },
            waitForWakeReadiness: { try await wake.wait() }, initialSavedDevices: [device], initialRegisteredDevice: device)
        defer { model.disconnect(); wake.releaseAll(); challenge.releaseAll() }
        model.phase = .streaming; model.systemWillSleep(); model.systemDidWake()
        #expect(await sleepEventually { wake.count == 1 })
        model.systemWillSleep(); model.systemDidWake()
        #expect(await sleepEventually { wake.count == 2 })
        wake.advance(); await sleepDrain()
        #expect(factory.normalCalls == 0 && model.hasPendingReconnect)
        wake.advance()
        #expect(await sleepEventually { factory.normalCalls == 1 && challenge.count == 1 })
    }

    @Test @MainActor func lateTrustedGrantCannotResurrectPreSleepConnection() async throws {
        let device = try sleepDevice(), challenge = SleepGate(), wake = SleepGate(), channels = SleepChannels()
        let stale = try sleepInvitation(3), fresh = try sleepInvitation(4)
        let factory = SleepTrustedFactory([.held(challenge, stale), .success(fresh)])
        let model = SessionModel(makeChannel: { channels.make($0) }, makeTrustedClient: { device, _ in factory.make(device) },
            waitForWakeReadiness: { try await wake.wait() }, initialSavedDevices: [device])
        defer { model.disconnect(); wake.releaseAll(); challenge.releaseAll() }
        model.connectSaved(device.id)
        #expect(await sleepEventually { challenge.count == 1 })
        model.systemWillSleep()
        #expect(factory.closeCount == 1)
        challenge.advance(); await sleepDrain()
        #expect(channels.invitations.isEmpty && !model.active)
        model.systemDidWake()
        #expect(await sleepEventually { wake.count == 1 })
        wake.advance()
        #expect(await sleepEventually { model.phase == .approval })
        #expect(channels.invitations == [fresh.token] && factory.normalCalls == 2)
    }

    @Test @MainActor func oldRetryCannotReplaceNewSavedTarget() async throws {
        let first = try sleepDevice(1), second = try sleepDevice(2), retry = SleepGate(), challenge = SleepGate()
        let factory = SleepTrustedFactory([.failure(.transport), .held(challenge, try sleepInvitation())])
        let model = SessionModel(makeTrustedClient: { device, _ in factory.make(device) },
            waitForReconnect: { _ in try await retry.wait() }, initialSavedDevices: [first, second])
        defer { model.disconnect(); retry.releaseAll(); challenge.releaseAll() }
        model.connectSaved(first.id)
        #expect(await sleepEventually { retry.count == 1 })
        model.connectSaved(second.id)
        #expect(await sleepEventually { challenge.count == 1 })
        retry.advance(); await sleepDrain()
        #expect(factory.deviceIDs == [first.id, second.id] && factory.normalCalls == 2 && model.active)
    }

    @Test @MainActor func powerMonitorCoalescesBindingAndRemovesFromInjectedCenter() async throws {
        let device = try sleepDevice(), wake = SleepGate(), center = NotificationCenter()
        let model = SessionModel(waitForWakeReadiness: { try await wake.wait() }, initialSavedDevices: [device], initialRegisteredDevice: device)
        var monitor: NativePowerMonitor? = NativePowerMonitor()
        defer { model.disconnect(); wake.releaseAll() }
        monitor?.bind(model, notificationCenter: center); monitor?.bind(model, notificationCenter: center)
        model.phase = .streaming
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(model.isSystemSleeping && !model.active)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await sleepEventually { wake.count == 1 })
        monitor = nil; model.disconnect(); wake.advance(); await sleepDrain()
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(!model.isSystemSleeping && !model.hasPendingReconnect)
    }

    @Test @MainActor func powerMonitorRebindingDetachesOldCenterAndModel() throws {
        let first = SessionModel(), second = SessionModel(), firstCenter = NotificationCenter(), secondCenter = NotificationCenter()
        var monitor: NativePowerMonitor? = NativePowerMonitor()
        monitor?.bind(first, notificationCenter: firstCenter)
        monitor?.bind(second, notificationCenter: secondCenter)
        firstCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(!first.isSystemSleeping && !second.isSystemSleeping)
        secondCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(second.isSystemSleeping)
        monitor = nil
        secondCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(second.isSystemSleeping)
    }
}
