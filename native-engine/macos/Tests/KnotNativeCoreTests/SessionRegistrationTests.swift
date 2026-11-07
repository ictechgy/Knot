import CoreVideo
import Foundation
import Testing
import KnotNativeCore
@testable import KnotNativePreview

/// These seams retain only fresh values. They never instantiate Keychain, TLS,
/// discovery, a real presenter, or any user input/output adapter.
@MainActor private final class RegistrationStore {
    var devices: [SavedNativeDevice]
    private(set) var loads = 0
    private(set) var saves = 0
    private(set) var removals = 0
    private(set) var registered: [SavedNativeDevice] = []
    var duringRegistration: (() -> Void)?
    init(_ devices: [SavedNativeDevice]) { self.devices = devices }
    func load() -> [SavedNativeDevice] { loads += 1; return devices }
    func save(_ devices: [SavedNativeDevice]) { saves += 1; self.devices = devices }
    func remove(_ id: String) { removals += 1; devices.removeAll { $0.id == id } }
    func register(_ device: SavedNativeDevice) async throws {
        registered.append(device)
        duringRegistration?()
    }
}

private final class RegistrationChannel: NativeChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [Data] = []
    private var read: CheckedContinuation<Data, any Error>?
    private var closed = false
    func start() async throws {}
    func send(_ packet: Packet) async throws {}
    func readExactly(_ count: Int, timeout: Duration) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed { lock.unlock(); continuation.resume(throwing: NativeFailure.transport) }
            else if !queued.isEmpty {
                let bytes = queued.removeFirst(); lock.unlock()
                if bytes.count == count { continuation.resume(returning: bytes) }
                else { continuation.resume(throwing: NativeFailure.malformed) }
            } else { read = continuation; lock.unlock() }
        }
    }
    func feed(_ bytes: Data) {
        lock.lock(); guard !closed else { lock.unlock(); return }
        let pending = read; read = nil
        if pending == nil { queued.append(bytes) }
        lock.unlock(); pending?.resume(returning: bytes)
    }
    func close() {
        lock.lock(); closed = true
        let pending = read; read = nil; queued = []
        lock.unlock(); pending?.resume(throwing: NativeFailure.transport)
    }
}

@MainActor private final class RegistrationPresenter: NativePresenter {
    var onFailure: (() -> Void)?
    func display(_ image: CVPixelBuffer) -> PresentationResult { .presented }
    func clear() {}
    func forgetHeldKeys() {}
}

private func registrationDevice(_ index: UInt8) throws -> SavedNativeDevice {
    let fields: [String: Any] = [
        "id": Invitation.encodeBase64URL(Data(repeating: index, count: 32)), "name": "Synthetic PC \(index)",
        "address": "192.168.50.\(index)", "certificateSHA256": String(repeating: "a", count: 64),
        "secret": Data(repeating: index + 32, count: 32).base64EncodedString()
    ]
    return try JSONDecoder().decode(SavedNativeDevice.self, from: JSONSerialization.data(withJSONObject: fields)).validated()
}

private func registrationEnrollment(address: String = "192.168.50.200", pin: String = String(repeating: "b", count: 64), token: UInt8 = 6) throws -> AuthenticatedEnrollment {
    let candidate = try EnrollmentCandidate(address: address, port: 48632,
        slot: Data(repeating: 5, count: 16), name: "Synthetic PC")
    let invitation = try JSONSerialization.data(withJSONObject: ["v": 1, "address": address, "port": 48631,
        "certificateSHA256": pin, "token": Invitation.encodeBase64URL(Data(repeating: token, count: 32))])
    let offer: [String: Any] = ["v": 2, "slot": Invitation.encodeBase64URL(candidate.slot),
        "grant": Invitation.encodeBase64URL(Data(repeating: 7, count: 16)),
        "invitation": "knot-native:v1:" + Invitation.encodeBase64URL(invitation), "ttlMs": 30000]
    return AuthenticatedEnrollment(offer: try EnrollmentOffer(JSONSerialization.data(withJSONObject: offer), candidate: candidate),
        viewerName: "Synthetic Mac", expiresAt: .now + .seconds(30))
}

@MainActor private func waitForRegistration(_ predicate: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    try #require(predicate(), sourceLocation: sourceLocation)
}

@MainActor private func registrationModel(_ store: RegistrationStore, channel: RegistrationChannel) -> SessionModel {
    SessionModel(makeChannel: { _ in channel }, initialSavedDevices: store.devices,
        loadSavedDevices: { store.load() }, saveSavedDevices: { store.save($0) },
        registerDevice: { device, _, _ in try await store.register(device) })
}

@MainActor private func presentNumberSession(_ model: SessionModel, channel: RegistrationChannel,
                                           presenter: RegistrationPresenter, enrollment: AuthenticatedEnrollment,
                                           remember: Bool = true) async throws {
    model.surface = presenter; model.rememberThisPC = remember
    model.connectAuthenticated(enrollment)
    try await waitForRegistration { model.phase == .approval }
    let ready = Packet(kind: .ready, payload: Data("{\"v\":1,\"codec\":\"h264-annexb\",\"width\":64,\"height\":64,\"fps\":60,\"bitrate\":1000000,\"hardwareEncoder\":true}".utf8))
    channel.feed(Data(ready.encoded.prefix(5))); channel.feed(ready.payload)
    try await waitForRegistration { model.phase == .decoding }
    var pixel: CVPixelBuffer?
    try #require(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    model.presentDecodedImage(try #require(pixel))
    try #require(model.phase == .streaming)
}

struct SessionRegistrationTests {
    @Test @MainActor func fullLocalStoreRejectsNewRegistrationBeforeRemoteSideEffect() async throws {
        let store = RegistrationStore(try (1...16).map { try registrationDevice(UInt8($0)) })
        let channel = RegistrationChannel(), presenter = RegistrationPresenter()
        let model = registrationModel(store, channel: channel)
        defer { model.disconnect() }
        try await presentNumberSession(model, channel: channel, presenter: presenter, enrollment: registrationEnrollment())
        #expect(store.registered.isEmpty && store.saves == 0 && store.loads == 1)
        #expect(model.savedDevices.count == 16 && model.phase == .streaming)
        #expect(model.status.contains("16대") && model.status.contains("등록을 해제"))
    }

    @Test @MainActor func existingHostCanBeRegisteredAgainAtLocalCapacity() async throws {
        let store = RegistrationStore(try (1...16).map { try registrationDevice(UInt8($0)) })
        let existing = store.devices[3], channel = RegistrationChannel(), presenter = RegistrationPresenter()
        let model = registrationModel(store, channel: channel)
        defer { model.disconnect() }
        try await presentNumberSession(model, channel: channel, presenter: presenter,
            enrollment: registrationEnrollment(address: existing.address, pin: existing.certificateSHA256))
        try await waitForRegistration { store.saves == 1 }
        #expect(store.registered == [existing] && store.loads == 2)
        #expect(store.devices.count == 16 && Set(store.devices.map(\.id)).count == 16)
        #expect(model.savedDevices == store.devices && store.devices.contains(existing))
    }

    @Test @MainActor func registrationRechecksCapacityAfterRemoteCompletion() async throws {
        let store = RegistrationStore(try (1...15).map { try registrationDevice(UInt8($0)) })
        let laterDevice = try registrationDevice(16)
        store.duringRegistration = { store.devices.append(laterDevice) }
        let channel = RegistrationChannel(), presenter = RegistrationPresenter()
        let model = registrationModel(store, channel: channel)
        defer { model.disconnect(); store.duringRegistration = nil }
        try await presentNumberSession(model, channel: channel, presenter: presenter, enrollment: registrationEnrollment())
        try await waitForRegistration { model.status.contains("등록을 저장하지 못했어요") }
        #expect(store.registered.count == 1 && store.loads == 2 && store.saves == 0)
        #expect(store.devices.count == 16 && model.savedDevices.count == 15)
        #expect(model.phase == .streaming && model.status.contains("Windows의 등록 기기"))
    }
}

@MainActor private final class RegistrationWaitGate {
    private var pending: [CheckedContinuation<Void, any Error>] = []
    private(set) var count = 0
    // Deliberately complete cancelled waits late to exercise identity fencing.
    func wait() async throws {
        try await withCheckedThrowingContinuation { count += 1; pending.append($0) }
    }
    func advance() { if !pending.isEmpty { pending.removeFirst().resume() } }
    func releaseAll() { let all = pending; pending = []; for next in all { next.resume() } }
}

private final class RegistrationChannels: @unchecked Sendable {
    private let lock = NSLock()
    private var attempted: [Invitation] = []
    private var created: [RegistrationChannel] = []
    let initialFailure: NativeFailure?
    init(initialFailure: NativeFailure? = nil) { self.initialFailure = initialFailure }
    var invitations: [Invitation] { lock.withLock { attempted } }
    var channels: [RegistrationChannel] { lock.withLock { created } }
    func make(_ invitation: Invitation) throws -> any NativeChannel {
        try lock.withLock {
            attempted.append(invitation)
            if attempted.count == 1, let initialFailure { throw initialFailure }
            let channel = RegistrationChannel(); created.append(channel); return channel
        }
    }
}

private final class RegistrationProof: @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<Invitation, NativeFailure>
    private var attempted: [SavedNativeDevice] = []
    init(_ result: Result<Invitation, NativeFailure>) { self.result = result }
    var devices: [SavedNativeDevice] { lock.withLock { attempted } }
    func make(_ device: SavedNativeDevice) -> any NativeTrustedConnecting { RegistrationProofClient(device, owner: self) }
    func connect(_ device: SavedNativeDevice, revoke: Bool) throws -> Invitation? {
        if revoke { return nil }
        lock.withLock { attempted.append(device) }
        return try result.get()
    }
}
private final class RegistrationProofClient: NativeTrustedConnecting, Sendable {
    let device: SavedNativeDevice
    let owner: RegistrationProof
    init(_ device: SavedNativeDevice, owner: RegistrationProof) { self.device = device; self.owner = owner }
    func connect(revoke: Bool) async throws -> Invitation? { try owner.connect(device, revoke: revoke) }
    func close() {}
}

@MainActor private func recoveryNumberModel(_ store: RegistrationStore, channels: RegistrationChannels,
                                          proof: RegistrationProof, retry: RegistrationWaitGate,
                                          wake: RegistrationWaitGate) -> SessionModel {
    SessionModel(makeChannel: { try channels.make($0) }, makeTrustedClient: { device, _ in proof.make(device) },
        waitForReconnect: { _ in try await retry.wait() }, waitForWakeReadiness: { try await wake.wait() },
        initialSavedDevices: store.devices, removeSavedDevice: { store.remove($0) },
        loadSavedDevices: { store.load() }, saveSavedDevices: { store.save($0) },
        registerDevice: { device, _, _ in try await store.register(device) })
}

@MainActor private func showRecoveryNumberSession(_ model: SessionModel, channels: RegistrationChannels,
                                                presenter: RegistrationPresenter, enrollment: AuthenticatedEnrollment) async throws {
    model.connectAuthenticated(enrollment)
    try await waitForRegistration { model.phase == .approval && channels.channels.count == 1 }
    // Continue the actual number Hello/Ready/first-image path without calling
    // connectAuthenticated again or creating an AppKit/VideoToolbox session.
    model.surface = presenter
    let channel = try #require(channels.channels.first)
    let ready = Packet(kind: .ready, payload: Data("{\"v\":1,\"codec\":\"h264-annexb\",\"width\":64,\"height\":64,\"fps\":60,\"bitrate\":1000000,\"hardwareEncoder\":true}".utf8))
    channel.feed(Data(ready.encoded.prefix(5))); channel.feed(ready.payload)
    try await waitForRegistration { model.phase == .decoding }
    var pixel: CVPixelBuffer?
    try #require(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    model.presentDecodedImage(try #require(pixel))
    try #require(model.phase == .streaming)
}

struct SavedNumberRecoveryTests {
    @Test @MainActor func freshNumberAdoptsExactSavedHostWithoutReadingWritingOrRegisteringCredentials() async throws {
        let store = RegistrationStore(try (1...16).map { try registrationDevice(UInt8($0)) })
        let existing = store.devices[3], channel = RegistrationChannel(), presenter = RegistrationPresenter()
        let model = registrationModel(store, channel: channel)
        defer { model.disconnect() }
        try await presentNumberSession(model, channel: channel, presenter: presenter,
            enrollment: registrationEnrollment(address: existing.address, pin: existing.certificateSHA256), remember: false)
        #expect(NativeCopy.status(model.status).contains("등록된 PC"))
        #expect(!NativeCopy.status(model.status).contains("임시"))
        #expect(store.loads == 0 && store.saves == 0 && store.registered.isEmpty)
        #expect(model.savedDevices == store.devices && model.savedDevices.count == 16)
    }

    @Test(arguments: ["address", "pin", "both", "unknown"])
    @MainActor func unmatchedNumberHostRemainsTemporary(_ mismatch: String) async throws {
        let device = try registrationDevice(1)
        let store = RegistrationStore(mismatch == "unknown" ? [] : [device])
        let channels = RegistrationChannels(), proof = RegistrationProof(.failure(.trust))
        let retry = RegistrationWaitGate(), wake = RegistrationWaitGate(), presenter = RegistrationPresenter()
        let model = recoveryNumberModel(store, channels: channels, proof: proof, retry: retry, wake: wake)
        defer { model.disconnect(); retry.releaseAll(); wake.releaseAll() }
        let address = ["address", "both"].contains(mismatch) ? "192.168.50.200" : device.address
        let pin = ["pin", "both"].contains(mismatch) ? String(repeating: "b", count: 64) : device.certificateSHA256
        try await showRecoveryNumberSession(model, channels: channels, presenter: presenter,
            enrollment: registrationEnrollment(address: address, pin: pin))
        #expect(model.status.contains("Temporary trust"))
        #expect(!model.checkDeadlines(now: .now + .seconds(11)))
        model.systemWillSleep(); model.systemDidWake()
        #expect(!model.hasPendingReconnect && retry.count == 0 && wake.count == 0 && proof.devices.isEmpty)
        #expect(store.loads == 0 && store.saves == 0 && store.registered.isEmpty)
    }

    @Test(arguments: [false, true])
    @MainActor func adoptedNumberTransportRecoveryRequiresFreshSavedProof(_ beforeFirstImage: Bool) async throws {
        let device = try registrationDevice(1), store = RegistrationStore([device])
        let first = try registrationEnrollment(address: device.address, pin: device.certificateSHA256)
        let fresh = try registrationEnrollment(address: device.address, pin: device.certificateSHA256, token: 9).offer.invitation
        let channels = RegistrationChannels(initialFailure: beforeFirstImage ? .transport : nil)
        let proof = RegistrationProof(.success(fresh)), retry = RegistrationWaitGate(), wake = RegistrationWaitGate()
        let presenter = RegistrationPresenter(), model = recoveryNumberModel(store, channels: channels, proof: proof, retry: retry, wake: wake)
        defer { model.disconnect(); retry.releaseAll(); wake.releaseAll() }
        if beforeFirstImage { model.connectAuthenticated(first) }
        else {
            try await showRecoveryNumberSession(model, channels: channels, presenter: presenter, enrollment: first)
            #expect(proof.devices.isEmpty)
            try #require(channels.channels.first).close()
        }
        try await waitForRegistration { retry.count == 1 && model.hasPendingReconnect }
        #expect(proof.devices.isEmpty && model.invitation == nil)
        retry.advance()
        try await waitForRegistration { proof.devices.count == 1 && model.phase == .approval }
        #expect(proof.devices == [device]) // Equality includes the exact original saved secret.
        #expect(channels.invitations.map(\.token) == [first.offer.invitation.token, fresh.token])
        #expect(store.loads == 0 && store.saves == 0 && store.registered.isEmpty && store.devices == [device])
    }

    @Test @MainActor func adoptedNumberSleepWakeWaitsThenUsesFreshSavedProof() async throws {
        let device = try registrationDevice(1), store = RegistrationStore([device])
        let first = try registrationEnrollment(address: device.address, pin: device.certificateSHA256)
        let fresh = try registrationEnrollment(address: device.address, pin: device.certificateSHA256, token: 9).offer.invitation
        let channels = RegistrationChannels(), proof = RegistrationProof(.success(fresh))
        let retry = RegistrationWaitGate(), wake = RegistrationWaitGate(), presenter = RegistrationPresenter()
        let model = recoveryNumberModel(store, channels: channels, proof: proof, retry: retry, wake: wake)
        defer { model.disconnect(); retry.releaseAll(); wake.releaseAll() }
        try await showRecoveryNumberSession(model, channels: channels, presenter: presenter, enrollment: first)
        model.systemWillSleep()
        #expect(model.isSystemSleeping && model.hasPendingReconnect && !model.active && model.invitation == nil)
        model.systemDidWake()
        try await waitForRegistration { wake.count == 1 }
        #expect(proof.devices.isEmpty && retry.count == 0)
        wake.advance()
        try await waitForRegistration { proof.devices.count == 1 && model.phase == .approval }
        #expect(proof.devices == [device] && model.reconnectAttemptCount == 0)
        #expect(channels.invitations.map(\.token) == [first.offer.invitation.token, fresh.token])
        #expect(store.loads == 0 && store.saves == 0 && store.registered.isEmpty)
    }

    @Test(arguments: [false, true])
    @MainActor func disablingRecoveryKeepsAdoptedNumberRegisteredButNeverRetries(_ afterConnection: Bool) async throws {
        let device = try registrationDevice(1), store = RegistrationStore([device])
        let channels = RegistrationChannels(), proof = RegistrationProof(.failure(.trust))
        let retry = RegistrationWaitGate(), wake = RegistrationWaitGate(), presenter = RegistrationPresenter()
        let model = recoveryNumberModel(store, channels: channels, proof: proof, retry: retry, wake: wake)
        defer { model.disconnect(); retry.releaseAll(); wake.releaseAll() }
        model.autoReconnect = afterConnection
        try await showRecoveryNumberSession(model, channels: channels, presenter: presenter,
            enrollment: registrationEnrollment(address: device.address, pin: device.certificateSHA256))
        #expect(NativeCopy.status(model.status).contains("등록된 PC"))
        model.autoReconnect = false
        try #require(channels.channels.first).close()
        try await waitForRegistration { model.phase == .failed }
        #expect(NativeCopy.status(model.status).contains("등록된 PC를 선택해 다시 연결"))
        model.systemWillSleep(); model.systemDidWake()
        #expect(!model.hasPendingReconnect && retry.count == 0 && wake.count == 0 && proof.devices.isEmpty)
        #expect(store.loads == 0 && store.saves == 0 && store.registered.isEmpty)
    }

    @Test(arguments: ["disconnect", "disabled", "forget", "newTarget", "newNumber", "legacyReview"])
    @MainActor func explicitCancellationRejectsLateAdoptedNumberRetry(_ action: String) async throws {
        let device = try registrationDevice(1), store = RegistrationStore([device])
        let fresh = try registrationEnrollment(address: device.address, pin: device.certificateSHA256, token: 9).offer.invitation
        let channels = RegistrationChannels(), proof = RegistrationProof(.success(fresh))
        let retry = RegistrationWaitGate(), wake = RegistrationWaitGate(), presenter = RegistrationPresenter()
        let model = recoveryNumberModel(store, channels: channels, proof: proof, retry: retry, wake: wake)
        defer { model.disconnect(); retry.releaseAll(); wake.releaseAll() }
        try await showRecoveryNumberSession(model, channels: channels, presenter: presenter,
            enrollment: registrationEnrollment(address: device.address, pin: device.certificateSHA256))
        try #require(channels.channels.first).close()
        try await waitForRegistration { retry.count == 1 }
        switch action {
        case "disconnect": model.disconnect()
        case "disabled": model.autoReconnect = false
        case "forget": model.forgetSaved(device.id)
        case "newTarget": model.prepareForNewTarget()
        case "newNumber": model.connectAuthenticated(try registrationEnrollment())
        default: model.review("invalid")
        }
        retry.advance()
        for _ in 0..<30 { await Task.yield() }
        #expect(!model.hasPendingReconnect && proof.devices.isEmpty)
        #expect(store.loads == 0 && store.saves == 0 && store.registered.isEmpty)
        #expect(store.removals == (action == "forget" ? 1 : 0))
    }

    @Test(arguments: [NativeFailure.trust, .certificatePinMismatch, .certificatePolicy, .malformed])
    @MainActor func rejectedAdoptedSavedProofIsTerminalAndNeverRegistersAgain(_ failure: NativeFailure) async throws {
        let device = try registrationDevice(1), store = RegistrationStore([device])
        let channels = RegistrationChannels(), proof = RegistrationProof(.failure(failure))
        let retry = RegistrationWaitGate(), wake = RegistrationWaitGate(), presenter = RegistrationPresenter()
        let model = recoveryNumberModel(store, channels: channels, proof: proof, retry: retry, wake: wake)
        defer { model.disconnect(); retry.releaseAll(); wake.releaseAll() }
        try await showRecoveryNumberSession(model, channels: channels, presenter: presenter,
            enrollment: registrationEnrollment(address: device.address, pin: device.certificateSHA256))
        try #require(channels.channels.first).close()
        try await waitForRegistration { retry.count == 1 }
        retry.advance()
        try await waitForRegistration { model.phase == .failed && proof.devices.count == 1 }
        model.systemWillSleep(); model.systemDidWake()
        for _ in 0..<30 { await Task.yield() }
        #expect(!model.hasPendingReconnect && retry.count == 1 && wake.count == 0 && proof.devices == [device])
        #expect(channels.invitations.count == 1 && store.devices == [device])
        #expect(store.loads == 0 && store.saves == 0 && store.registered.isEmpty)
    }

    @Test(arguments: ["expired", "invalidName"])
    @MainActor func invalidNumberGrantCannotAdoptSavedRecovery(_ invalid: String) async throws {
        let device = try registrationDevice(1), store = RegistrationStore([device])
        let channels = RegistrationChannels(), proof = RegistrationProof(.failure(.trust))
        let retry = RegistrationWaitGate(), wake = RegistrationWaitGate()
        let model = recoveryNumberModel(store, channels: channels, proof: proof, retry: retry, wake: wake)
        defer { model.disconnect(); retry.releaseAll(); wake.releaseAll() }
        let valid = try registrationEnrollment(address: device.address, pin: device.certificateSHA256)
        let invalidGrant = AuthenticatedEnrollment(offer: valid.offer,
            viewerName: invalid == "invalidName" ? "\ninvalid" : valid.viewerName,
            expiresAt: invalid == "expired" ? .now - .seconds(1) : valid.expiresAt)
        model.connectAuthenticated(invalidGrant)
        #expect(model.phase == .failed)
        model.systemWillSleep(); model.systemDidWake()
        #expect(!model.hasPendingReconnect && proof.devices.isEmpty && channels.invitations.isEmpty)
        #expect(store.loads == 0 && store.saves == 0 && store.registered.isEmpty)
    }
}
