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
    private(set) var registered: [SavedNativeDevice] = []
    var duringRegistration: (() -> Void)?
    init(_ devices: [SavedNativeDevice]) { self.devices = devices }
    func load() -> [SavedNativeDevice] { loads += 1; return devices }
    func save(_ devices: [SavedNativeDevice]) { saves += 1; self.devices = devices }
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

private func registrationEnrollment(address: String = "192.168.50.200", pin: String = String(repeating: "b", count: 64)) throws -> AuthenticatedEnrollment {
    let candidate = try EnrollmentCandidate(address: address, port: 48632,
        slot: Data(repeating: 5, count: 16), name: "Synthetic PC")
    let invitation = try JSONSerialization.data(withJSONObject: ["v": 1, "address": address, "port": 48631,
        "certificateSHA256": pin, "token": Invitation.encodeBase64URL(Data(repeating: 6, count: 32))])
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

@MainActor private func presentRegisteredSession(_ model: SessionModel, channel: RegistrationChannel,
                                                presenter: RegistrationPresenter, enrollment: AuthenticatedEnrollment) async throws {
    model.surface = presenter; model.rememberThisPC = true
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
        try await presentRegisteredSession(model, channel: channel, presenter: presenter, enrollment: registrationEnrollment())
        #expect(store.registered.isEmpty && store.saves == 0 && store.loads == 1)
        #expect(model.savedDevices.count == 16 && model.phase == .streaming)
        #expect(model.status.contains("16대") && model.status.contains("등록을 해제"))
    }

    @Test @MainActor func existingHostCanBeRegisteredAgainAtLocalCapacity() async throws {
        let store = RegistrationStore(try (1...16).map { try registrationDevice(UInt8($0)) })
        let existing = store.devices[3], channel = RegistrationChannel(), presenter = RegistrationPresenter()
        let model = registrationModel(store, channel: channel)
        defer { model.disconnect() }
        try await presentRegisteredSession(model, channel: channel, presenter: presenter,
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
        try await presentRegisteredSession(model, channel: channel, presenter: presenter, enrollment: registrationEnrollment())
        try await waitForRegistration { model.status.contains("등록을 저장하지 못했어요") }
        #expect(store.registered.count == 1 && store.loads == 2 && store.saves == 0)
        #expect(store.devices.count == 16 && model.savedDevices.count == 15)
        #expect(model.phase == .streaming && model.status.contains("Windows의 등록 기기"))
    }
}
