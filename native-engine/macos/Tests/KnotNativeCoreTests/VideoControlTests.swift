import Foundation
import Testing
@testable import KnotNativeCore
@testable import KnotNativePreview

private let video18Initial = VideoProfile(width: 64, height: 64, fps: 30, bitrate: 1_000_000)
private let video18Requested = VideoProfile(width: 3840, height: 2160, fps: 60, bitrate: 40_000_000)
private func video18Ready(control: Bool = true, quality: Bool = true) -> Data {
    Data((#"{"v":1,"codec":"h264-annexb","width":64,"height":64,"fps":30,"bitrate":1000000,"hardwareEncoder":true"# +
        (quality ? #", "qualityVersion":1"# : "") + (control ? #", "videoControlVersion":1"# : "") + "}").utf8)
}
private func video18Status(_ operation: VideoControlOperation = .profile, id: UInt64 = 1, epoch: UInt64 = 0,
                           outcome: VideoControlOutcome = .preparing, reason: VideoControlReason = .none,
                           state: VideoControlState = .running, actual: VideoProfile = video18Initial, next: UInt64 = 0) -> Data {
    var bytes = Data([1, operation.rawValue]); bytes.appendBE(id); bytes.appendBE(epoch)
    bytes.append(contentsOf: [outcome.rawValue, reason.rawValue, state.rawValue])
    bytes.appendBE(UInt32(actual.width)); bytes.appendBE(UInt32(actual.height)); bytes.appendBE(UInt32(actual.fps)); bytes.appendBE(UInt32(actual.bitrate)); bytes.appendBE(next)
    return bytes
}
private func video18AU(sequence: UInt64, idr: Bool = true, sets: Bool = false) -> Packet {
    var bytes = Data(); bytes.appendBE(sequence); bytes.appendBE(UInt64(10)); bytes.append(idr ? 1 : 0)
    if sets { bytes.append(contentsOf: [0,0,1,0x67,1,0,0,1,0x68,2]) }
    bytes.append(contentsOf: [0,0,1,idr ? 0x65 : 0x41,3])
    return Packet(kind: .video, payload: bytes)
}
private func video18Receiving() throws -> ReceiveState {
    var value = ReceiveState(videoControlVersion: 1)
    _ = try value.accept(Packet(kind: .ready, payload: video18Ready()))
    return value
}
private func video18Hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

@Test func videoControlFixedCrossLanguageVectorsAndExactLengths() throws {
    let request = try VideoControlRequest(operation: .profile, requestID: 0x0102030405060708, profile: video18Requested)
    #expect(video18Hex(request.packet.payload) == "0101010203040506070800000f00000008700000003c02625a00")
    #expect(request.packet.encoded.prefix(5) == Data([0x35,0,0,0,26]))
    #expect(try VideoControlRequest(request.packet.payload) == request)
    let response = video18Status(epoch: 1, outcome: .applied, actual: VideoProfile(width: 1920, height: 1080, fps: 60, bitrate: 20_000_000), next: 2)
    #expect(video18Hex(response) == "01010000000000000001000000000000000101000000000780000004380000003c01312d000000000000000002")
    let parsed = try VideoControlStatus(response)
    #expect(parsed.videoEpoch == 1 && parsed.nextSequence == 2 && parsed.actual.width == 1920)
    #expect(try Packet.serverHeader(Packet(kind: .videoControlStatus, payload: response).encoded.prefix(5)).1 == 45)
    for count in [0, 25, 27, 44, 46] {
        if count != 26 { #expect(throws: (any Error).self) { try VideoControlRequest(Data(repeating: 0, count: count)) } }
        if count != 45 { #expect(throws: (any Error).self) { try VideoControlStatus(Data(repeating: 0, count: count)) } }
    }
    for (offset, byte) in [(0, UInt8(2)), (1, 0), (18, 4), (19, 5), (20, 2)] {
        var bad = response; bad[offset] = byte
        #expect(throws: (any Error).self) { try VideoControlStatus(bad) }
    }
    var pause = try VideoControlRequest(operation: .pause, requestID: 1).packet.payload
    pause[25] = 1
    #expect(throws: (any Error).self) { try VideoControlRequest(pause) }
}

@Test func videoControlReadyNegotiationIsOptionalStrictAndRequiresQuality() throws {
    #expect(try Ready(video18Ready(control: false)).videoControlVersion == 0)
    #expect(try Ready(video18Ready()).videoControlVersion == 1)
    #expect(throws: (any Error).self) { try Ready(video18Ready(quality: false)) }
    var legacy = ReceiveState()
    #expect(throws: (any Error).self) { try legacy.accept(Packet(kind: .ready, payload: video18Ready())) }
    var opted = ReceiveState(videoControlVersion: 1)
    _ = try opted.accept(Packet(kind: .ready, payload: video18Ready(control: false)))
    #expect(throws: (any Error).self) { try opted.accept(Packet(kind: .videoControlStatus, payload: video18Status())) }
    let json = try JSONSerialization.data(withJSONObject: ["v": 1, "address": "192.168.1.2", "port": 48631,
        "certificateSHA256": String(repeating: "a", count: 64), "token": Invitation.encodeBase64URL(Data(repeating: 7, count: 32))])
    let invitation = try Invitation("knot-native:v1:" + Invitation.encodeBase64URL(json))
    let hello = try invitation.hello(videoControlVersion: 1)
    #expect(try StrictJSON.object(hello.payload, keys: ["v", "token", "name", "filesVersion", "videoControlVersion"], limit: 4096).integer("videoControlVersion") == 1)
    #expect(throws: (any Error).self) { try invitation.hello(videoControlVersion: 2) }
}

@Test func videoControlResetRequiresExactNextIDRParameterSetsAndPreservesGlobalSequence() throws {
    for (sequence, idr, sets) in [(UInt64(3), true, true), (2, false, true), (2, true, false)] {
        var receiver = try video18Receiving()
        _ = try receiver.accept(video18AU(sequence: 1))
        try receiver.expectVideoControl(VideoControlRequest(operation: .profile, requestID: 1, profile: video18Requested))
        _ = try receiver.accept(Packet(kind: .videoControlStatus, payload: video18Status()))
        _ = try receiver.accept(Packet(kind: .videoControlStatus, payload: video18Status(epoch: 1, outcome: .applied, next: 2)))
        #expect(throws: (any Error).self) { try receiver.accept(video18AU(sequence: sequence, idr: idr, sets: sets)) }
    }
    var receiver = try video18Receiving()
    _ = try receiver.accept(video18AU(sequence: 1))
    try receiver.expectVideoControl(VideoControlRequest(operation: .profile, requestID: 1, profile: video18Requested))
    _ = try receiver.accept(Packet(kind: .videoControlStatus, payload: video18Status()))
    _ = try receiver.accept(Packet(kind: .videoControlStatus, payload: video18Status(epoch: 1, outcome: .applied, next: 2)))
    #expect(try receiver.accept(video18AU(sequence: 2, sets: true))?.sequence == 2)
    #expect(try receiver.accept(video18AU(sequence: 3, idr: false))?.sequence == 3)
    #expect(receiver.videoControl.epoch == 1 && receiver.sequence == 3)
}

@Test func videoControlRejectsUnsolicitedOverlappingDuplicateAndImpossibleBarriers() throws {
    var receiver = try video18Receiving()
    #expect(throws: (any Error).self) { try receiver.accept(Packet(kind: .videoControlStatus, payload: video18Status())) }
    let request = try VideoControlRequest(operation: .profile, requestID: 1, profile: video18Requested)
    try receiver.expectVideoControl(request)
    #expect(throws: (any Error).self) { try receiver.expectVideoControl(request) }
    _ = try receiver.accept(Packet(kind: .videoControlStatus, payload: video18Status()))
    #expect(throws: (any Error).self) { try receiver.accept(Packet(kind: .videoControlStatus, payload: video18Status())) }
    for invalid in [video18Status(id: 2), video18Status(epoch: 2, outcome: .applied, next: 1),
                    video18Status(epoch: 1, outcome: .applied, next: 2), video18Status(outcome: .applied, actual: video18Requested),
                    video18Status(.pause, outcome: .applied, state: .paused)] {
        #expect(throws: (any Error).self) { try receiver.accept(Packet(kind: .videoControlStatus, payload: invalid)) }
    }
}

@Test func videoControlPauseHasNoSubsequentVideoUntilFreshResumeBarrier() throws {
    var receiver = try video18Receiving()
    _ = try receiver.accept(video18AU(sequence: 1))
    try receiver.expectVideoControl(VideoControlRequest(operation: .pause, requestID: 1))
    _ = try receiver.accept(Packet(kind: .videoControlStatus, payload: video18Status(.pause)))
    _ = try receiver.accept(Packet(kind: .videoControlStatus, payload: video18Status(.pause, outcome: .applied, state: .paused)))
    _ = try receiver.accept(Packet(kind: .hostHeartbeat))
    #expect(receiver.videoControl.state == .paused && receiver.videoControl.epoch == 0)
    #expect(throws: (any Error).self) { try receiver.accept(video18AU(sequence: 2, sets: true)) }
    try receiver.expectVideoControl(VideoControlRequest(operation: .resume, requestID: 2))
    _ = try receiver.accept(Packet(kind: .videoControlStatus, payload: video18Status(.resume, id: 2, state: .paused)))
    _ = try receiver.accept(Packet(kind: .videoControlStatus, payload: video18Status(.resume, id: 2, epoch: 1, outcome: .applied, next: 2)))
    #expect(try receiver.accept(video18AU(sequence: 2, sets: true))?.sequence == 2)
}

@Test func videoControlBoundedInputMailboxSurvivesFocusRevocation() throws {
    var mailbox = InputBuffer()
    try mailbox.append(Input.key(down: true, scan: 0x1e, extended: false))
    let request = try VideoControlRequest(operation: .pause, requestID: 1).packet
    try mailbox.append(request)
    #expect(throws: (any Error).self) { try mailbox.append(request) }
    mailbox.revoke()
    #expect(mailbox.count == 2 && mailbox.byteCount == 36)
    #expect(mailbox.pop()?.kind == .releaseAll && mailbox.pop() == request && mailbox.pop() == nil)
}

@MainActor private final class Video18Clock {
    var value = ContinuousClock.now
    func advance(_ duration: Duration) { value += duration }
}
@Test @MainActor func videoControlModelSerializesAutoPauseReturnAndBusyRetryThenCancelsStaleIntent() throws {
    let clock = Video18Clock(); var writes: [VideoControlRequest] = []
    let model = VideoControlModel(actual: video18Initial, now: { clock.value }, send: { writes.append($0); return true })
    model.pause(manual: false); model.resumeAfterLocalUse()
    #expect(model.isApplying && writes.count == 1 && writes[0].operation == .pause)
    model.accept(try VideoControlStatus(video18Status(.pause, outcome: .applied, state: .paused)))
    #expect(model.isPaused && model.isAutomaticallyPaused && writes.count == 1)
    clock.advance(.seconds(2)); model.tick()
    #expect(writes.map(\.operation) == [.pause, .resume] && model.isApplying)
    model.accept(try VideoControlStatus(video18Status(.resume, id: 2, outcome: .rejected, reason: .busy, state: .paused)))
    model.tick(); #expect(writes.count == 2)
    clock.advance(.seconds(2)); model.tick()
    #expect(writes.count == 3 && writes[2].requestID == 3)
    model.cancel(); clock.advance(.seconds(100)); model.tick(); model.resume()
    #expect(writes.count == 3 && !model.isApplying)
}

@Test @MainActor func videoControlManualPauseNeverResumesFromActivationOrLocalUse() throws {
    let clock = Video18Clock(); var writes: [VideoControlRequest] = []
    let model = VideoControlModel(actual: video18Initial, now: { clock.value }, send: { writes.append($0); return true })
    model.pause(); model.resumeAfterLocalUse()
    model.accept(try VideoControlStatus(video18Status(.pause, outcome: .applied, state: .paused)))
    clock.advance(.seconds(5)); model.resumeAfterLocalUse(); model.tick()
    #expect(model.isPaused && !model.isAutomaticallyPaused && writes.count == 1)
    model.resume(); #expect(writes.count == 2 && writes[1].operation == .resume)
}

@Test @MainActor func videoControlDraftDoesNotClaimAppliedAndFirstImageKeepsInputBlocked() throws {
    let clock = Video18Clock()
    let model = VideoControlModel(actual: video18Initial, now: { clock.value }, send: { _ in true })
    #expect(model.requestProfile(width: 3840, height: 2160, fps: 60, bitrate: 40_000_000))
    #expect(model.actual == video18Initial && model.requested == video18Initial && model.blocksInput)
    #expect(!model.requestProfile(width: 1920, height: 1080, fps: 30, bitrate: 10_000_000))
    model.accept(try VideoControlStatus(video18Status(epoch: 1, outcome: .applied, next: 1)))
    #expect(model.isApplying && model.resetBegan != nil && model.requested == video18Requested)
    model.firstImageArrived(); #expect(!model.isApplying && model.resetBegan == nil)
    clock.advance(.seconds(2)); model.pause(manual: false)
    model.accept(try VideoControlStatus(video18Status(.pause, id: 2, epoch: 1, outcome: .applied, state: .paused)))
    model.pause(manual: true); model.resumeAfterLocalUse()
    #expect(model.isPaused && !model.isAutomaticallyPaused && !model.isApplying)
}

@Test func videoIdleUsesOnlyAppFocusAcceptedInteractionAndConfigurableTimeout() {
    let began = ContinuousClock.now
    var policy = NativeVideoIdlePolicy(now: began)
    #expect(!policy.shouldPause(minutes: 10, backgroundOnly: true, now: began + .seconds(3600)))
    policy.focus(false, now: began + .seconds(3600))
    #expect(!policy.shouldPause(minutes: 10, backgroundOnly: true, now: began + .seconds(4199)))
    #expect(policy.shouldPause(minutes: 10, backgroundOnly: true, now: began + .seconds(4200)))
    policy.interaction(now: began + .seconds(4200))
    #expect(!policy.shouldPause(minutes: 10, backgroundOnly: true, now: began + .seconds(4201)))
    #expect(!policy.shouldPause(minutes: 0, backgroundOnly: false, now: began + .seconds(100000)))
    #expect(!policy.shouldPause(minutes: 2, backgroundOnly: false, now: began + .seconds(100000)))
    policy.focus(true, now: began + .seconds(4201))
    #expect(policy.shouldPause(minutes: 1, backgroundOnly: false, now: began + .seconds(4261)))
    policy.reset(now: began + .seconds(4261))
    #expect(!policy.shouldPause(minutes: 1, backgroundOnly: false, now: began + .seconds(4262)))
}

@Test func videoControlDisruptiveBarrierRequiresPreparingButTrueNoOpDoesNot() throws {
    for operation in [VideoControlOperation.profile, .pause] {
        var receiver = try video18Receiving()
        try receiver.expectVideoControl(VideoControlRequest(operation: operation, requestID: 1, profile: operation == .profile ? video18Requested : nil))
        let status = video18Status(operation, epoch: operation == .profile ? 1 : 0, outcome: .applied,
                                   state: operation == .pause ? .paused : .running, next: operation == .profile ? 1 : 0)
        #expect(throws: (any Error).self) { try receiver.accept(Packet(kind: .videoControlStatus, payload: status)) }
    }
    var receiver = try video18Receiving()
    try receiver.expectVideoControl(VideoControlRequest(operation: .profile, requestID: 1, profile: video18Requested))
    _ = try receiver.accept(Packet(kind: .videoControlStatus, payload: video18Status(outcome: .applied)))
    #expect(receiver.videoControl.pending == nil && receiver.videoControl.epoch == 0)
}
