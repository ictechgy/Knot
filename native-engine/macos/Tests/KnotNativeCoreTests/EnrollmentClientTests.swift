import Foundation
import Testing
@testable import KnotNativeCore
@testable import KnotNativePreview

private func testCandidate(_ suffix: String = "12") throws -> EnrollmentCandidate {
    try EnrollmentCandidate(address: "192.168.50." + suffix, port: 48632, slot: Data(repeating: 1, count: 16), name: "Synthetic PC")
}
private func testOffer(_ candidate: EnrollmentCandidate) throws -> Data {
    let invitation = try JSONSerialization.data(withJSONObject: ["v": 1, "address": candidate.address, "port": 48631,
        "certificateSHA256": String(repeating: "a", count: 64), "token": Invitation.encodeBase64URL(Data(repeating: 9, count: 32))])
    return try JSONSerialization.data(withJSONObject: ["v": 2, "slot": Invitation.encodeBase64URL(candidate.slot),
        "grant": Invitation.encodeBase64URL(Data(repeating: 2, count: 16)),
        "invitation": "knot-native:v1:" + Invitation.encodeBase64URL(invitation), "ttlMs": 30000])
}

/// Inert byte stream; no Network connection, keys, capture or input are created.
private final class ScriptedEnrollmentSocket: EnrollmentSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data
    private var sent: [Data] = []
    private var closed = false
    init(_ bytes: Data) { self.bytes = bytes }
    func start() async throws {}
    private func take(_ count: Int) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard !closed, bytes.count >= count else { throw EnrollmentFailure.transport }
        let result = Data(bytes.prefix(count)); bytes.removeFirst(count); return result
    }
    func readExactly(_ count: Int) async throws -> Data { try take(count) }
    private func append(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }; guard !closed else { throw EnrollmentFailure.cancelled }; sent.append(data)
    }
    func send(_ data: Data) async throws { try append(data) }
    func close() { lock.lock(); closed = true; lock.unlock() }
    func snapshot() -> ([Data], Bool) { lock.lock(); defer { lock.unlock() }; return (sent, closed) }
}

/// Stages the ownership contract only; real PAKE/AEAD vectors are separate tests.
private final class ScriptedEnrollmentCrypto: EnrollmentCryptography, @unchecked Sendable {
    let message = Data(repeating: 4, count: 32)
    let plaintext: Data
    let rejectOffer: Bool
    private let lock = NSLock()
    private var confirmed: Data?
    private var closed = false
    init(plaintext: Data, rejectOffer: Bool = false) { self.plaintext = plaintext; self.rejectOffer = rejectOffer }
    func process(_ peer: Data) throws { guard peer.count == 32 else { throw EnrollmentFailure.authentication } }
    func seal(kind: UInt8, plaintext: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard !closed, kind == 3 else { throw EnrollmentFailure.authentication }
        confirmed = plaintext; return Data(repeating: 7, count: 29)
    }
    func open(kind: UInt8, sealed: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !rejectOffer, kind == 4 else { throw EnrollmentFailure.authentication }
        return plaintext
    }
    func close() { lock.lock(); closed = true; lock.unlock() }
    func snapshot() -> (Data?, Bool) { lock.lock(); defer { lock.unlock() }; return (confirmed, closed) }
}

@Test func enrollmentReturnsInvitationOnlyAfterAuthenticatedOfferAndClosesProvisioning() async throws {
    let candidate = try testCandidate()
    let serverHello = try EnrollmentFrame(kind: .serverHello,
        payload: EnrollmentWire.hello(slot: candidate.slot, message: Data(repeating: 5, count: 32)))
    let offer = try EnrollmentFrame(kind: .serverOffer, payload: Data(repeating: 8, count: 29))
    let socket = ScriptedEnrollmentSocket(serverHello.encoded + offer.encoded)
    let crypto = ScriptedEnrollmentCrypto(plaintext: try testOffer(candidate))
    let client = try EnrollmentClient(candidate: candidate, password: EnrollmentWire.password("00001234"),
        makeSocket: { _ in socket }, makeCrypto: { _, _ in crypto })
    let result = try await client.authenticate(name: "Fixture Mac")
    #expect(result.offer.invitation.address == candidate.address)
    #expect(result.offer.invitation.certificateSHA256 == String(repeating: "a", count: 64))
    #expect(result.viewerName == "Fixture Mac" && ContinuousClock.now < result.expiresAt)
    let (sent, socketClosed) = socket.snapshot(), (confirmed, cryptoClosed) = crypto.snapshot()
    #expect(socketClosed && cryptoClosed && sent.count == 3 && sent.first == EnrollmentWire.preamble)
    let body = try StrictJSON.object(#require(confirmed), keys: ["v", "slot", "name", "permissions"], limit: 484)
    #expect(try body.string("permissions") == "screen,input")
    #expect(try body.string("name") == result.viewerName)
    await #expect(throws: (any Error).self) { try await client.authenticate(name: "Replay") }
}

@Test func processSuccessWithBadOfferTagNeverProducesAnInvitation() async throws {
    let candidate = try testCandidate()
    let hello = try EnrollmentFrame(kind: .serverHello,
        payload: EnrollmentWire.hello(slot: candidate.slot, message: Data(repeating: 5, count: 32)))
    let offer = try EnrollmentFrame(kind: .serverOffer, payload: Data(repeating: 8, count: 29))
    let socket = ScriptedEnrollmentSocket(hello.encoded + offer.encoded)
    let crypto = ScriptedEnrollmentCrypto(plaintext: try testOffer(candidate), rejectOffer: true)
    let client = try EnrollmentClient(candidate: candidate, password: EnrollmentWire.password("00001234"),
        makeSocket: { _ in socket }, makeCrypto: { _, _ in crypto })
    await #expect(throws: EnrollmentFailure.authentication) { try await client.authenticate(name: "Fixture Mac") }
    #expect(socket.snapshot().1 && crypto.snapshot().1)
}

private final class DelayedDiscovery: EnrollmentDiscovering, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<[EnrollmentCandidate], any Error>?
    private var began = false
    func discover(address: String?) async throws -> [EnrollmentCandidate] {
        try await withCheckedThrowingContinuation { value in lock.lock(); began = true; waiting = value; lock.unlock() }
    }
    func close() {} // Intentionally ignores cancellation to probe generation guards.
    var started: Bool { lock.lock(); defer { lock.unlock() }; return began }
    func finish(_ values: [EnrollmentCandidate]) {
        lock.lock(); let value = waiting; waiting = nil; lock.unlock(); value?.resume(returning: values)
    }
}
private final class DelayedEnrollment: EnrollmentAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<AuthenticatedEnrollment, any Error>?
    private var began = false
    func authenticate(name: String) async throws -> AuthenticatedEnrollment {
        try await withCheckedThrowingContinuation { value in lock.lock(); began = true; waiting = value; lock.unlock() }
    }
    func close() {}
    var started: Bool { lock.lock(); defer { lock.unlock() }; return began }
    func finish(_ result: AuthenticatedEnrollment) {
        lock.lock(); let value = waiting; waiting = nil; lock.unlock(); value?.resume(returning: result)
    }
}

@Test @MainActor func cancelledDiscoveryCannotPublishLateCandidates() async throws {
    let delayed = DelayedDiscovery()
    let candidate = try testCandidate()
    let model = EnrollmentModel(makeDiscovery: { delayed }, makeClient: { _, _ in throw EnrollmentFailure.cancelled })
    defer { delayed.finish([]) }
    let operation = try #require(model.find())
    let deadline = ContinuousClock.now + .seconds(1)
    while !delayed.started, ContinuousClock.now < deadline { await Task.yield() }
    try #require(delayed.started)
    model.cancel(); delayed.finish([candidate]); await operation.value
    #expect(model.candidates.isEmpty && model.selected == nil && model.code.isEmpty && model.phase == .idle)
}

@Test @MainActor func retargetingDropsTheOldAuthenticatedGrantAndClearsTheCode() async throws {
    let first = try testCandidate(), second = try testCandidate("13")
    let delayed = DelayedEnrollment()
    let result = AuthenticatedEnrollment(offer: try EnrollmentOffer(testOffer(first), candidate: first),
        viewerName: "Fixture Mac", expiresAt: .now + .seconds(30))
    let model = EnrollmentModel(makeDiscovery: { DelayedDiscovery() }, makeClient: { _, _ in delayed }, initialCandidates: [first, second])
    defer { delayed.finish(result) }
    var completed = 0
    model.select(first.id); model.code = "00001234"
    let operation = try #require(model.connect(name: "Fixture Mac") { _ in completed += 1 })
    let deadline = ContinuousClock.now + .seconds(1)
    while !delayed.started, ContinuousClock.now < deadline { await Task.yield() }
    try #require(delayed.started)
    model.select(second.id); delayed.finish(result); await operation.value
    #expect(completed == 0 && model.selectedID == second.id && model.code.isEmpty && model.phase == .idle)
}

private final class InvitationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var invitation: Invitation?
    func capture(_ value: Invitation) { lock.lock(); invitation = value; lock.unlock() }
    var value: Invitation? { lock.lock(); defer { lock.unlock() }; return invitation }
}
private final class StopBeforeNetworkChannel: NativeChannel, @unchecked Sendable {
    func start() async throws { throw NativeFailure.transport }
    func readExactly(_ count: Int, timeout: Duration) async throws -> Data { throw NativeFailure.transport }
    func send(_ packet: Packet) async throws { throw NativeFailure.transport }
    func close() {}
}

@Test @MainActor func authenticatedProvisioningCreatesANewMediaChannelWithExactPinAndConfirmedName() async throws {
    let candidate = try testCandidate()
    let result = AuthenticatedEnrollment(offer: try EnrollmentOffer(testOffer(candidate), candidate: candidate),
        viewerName: "Confirmed Mac", expiresAt: .now + .seconds(30))
    let recorder = InvitationRecorder()
    let media = SessionModel(makeChannel: { invitation in recorder.capture(invitation); return StopBeforeNetworkChannel() })
    media.viewerLabel = "Old unconfirmed name"
    media.connectAuthenticated(result)
    #expect(media.numberAuthorized && media.phase == .connecting && media.viewerLabel == "Confirmed Mac")
    let deadline = ContinuousClock.now + .seconds(1)
    while recorder.value == nil, ContinuousClock.now < deadline { await Task.yield() }
    let target = try #require(recorder.value)
    #expect(target == result.offer.invitation && target.certificateSHA256 == String(repeating: "a", count: 64))
    media.disconnect()
}

@Test @MainActor func expiredProvisioningNeverCreatesAMediaChannel() throws {
    let candidate = try testCandidate()
    let result = AuthenticatedEnrollment(offer: try EnrollmentOffer(testOffer(candidate), candidate: candidate),
        viewerName: "Confirmed Mac", expiresAt: .now - .seconds(1))
    let recorder = InvitationRecorder()
    let media = SessionModel(makeChannel: { invitation in recorder.capture(invitation); return StopBeforeNetworkChannel() })
    media.connectAuthenticated(result)
    #expect(recorder.value == nil && media.phase == .failed && !media.numberAuthorized)
}

private final class RejectedEnrollment: EnrollmentAuthenticating, @unchecked Sendable {
    func authenticate(name: String) async throws -> AuthenticatedEnrollment { throw EnrollmentFailure.authentication }
    func close() {}
}

@Test @MainActor func wrongNumberKeepsTheUnverifiedCandidateForAnExplicitFreshRetry() async throws {
    let candidate = try testCandidate()
    let model = EnrollmentModel(makeDiscovery: { DelayedDiscovery() },
        makeClient: { _, _ in RejectedEnrollment() }, initialCandidates: [candidate])
    var completed = 0
    for _ in 0..<2 {
        model.code = "00001234"
        let operation = try #require(model.connect(name: "Fixture Mac") { _ in completed += 1 })
        await operation.value
        #expect(model.phase == .failed && model.selected == candidate && model.candidates == [candidate])
        #expect(model.code.isEmpty && completed == 0)
    }
    model.cancel()
    #expect(model.candidates.isEmpty && model.selected == nil)
}
