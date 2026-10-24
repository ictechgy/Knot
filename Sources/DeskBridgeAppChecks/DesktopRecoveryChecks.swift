// SPDX-License-Identifier: GPL-3.0-only
import GlimmerEngine

func runDesktopRecoveryChecks() throws -> Int {
    var count = 0
    func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ModelCheckFailure(message: message) }; count += 1
    }
    var state = DesktopRecoveryPresentation()
    try expect(state.message != nil, "connecting did not show an in-window status")
    state.receive(.connectionEstablished)
    try expect(state.message != nil, "control connection hid video wait before first frame")
    try expect(!state.status.contains("연결됨"), "transport success falsely published connected before fresh video")
    state.receive(.waitingForVideo(true)); state.receive(.waitingForVideo(false))
    try expect(state.phase == .waiting && state.message != nil, "wait reset falsely proved the first video frame")
    state.receive(.firstFrame)
    try expect(state.message == nil, "first frame did not clear connecting status")
    try expect(state.status == "화면 연결됨", "first frame did not publish connected status")
    state.receive(.audioFailed("synthetic untrusted network detail"))
    try expect(state.phase == .live && state.message?.contains("오디오 장치·네트워크") == true,
               "nonfatal audio failure is invisible in the fullscreen surface")
    try expect(!state.status.contains("synthetic") && state.message?.contains("synthetic") == false,
               "audio diagnostics leaked into shell or accessibility copy")
    guard let audioNotice = state.audioNoticeID else {
        throw ModelCheckFailure(message: "audio failure did not identify its bounded notice")
    }
    state.receive(.audioFailed("duplicate synthetic error"))
    try expect(state.audioNoticeID == audioNotice, "duplicate audio failures rearmed the current notice")
    state.receive(.waitingForVideo(true))
    try expect(state.phase == .waiting && state.message != nil, "live video stall was invisible")
    state.acknowledgeAudioNotice(audioNotice)
    try expect(state.phase == .waiting && state.message?.contains("영상을 기다리는") == true,
               "audio expiry hid the actual video wait")
    state.receive(.waitingForVideo(false))
    try expect(state.message == nil && state.status.contains("오디오를 사용할 수 없습니다"),
               "audio expiry removed persistent status or left a fullscreen notice")
    for _ in 0..<20 {
        state.receive(.waitingForVideo(true)); state.receive(.waitingForVideo(false))
        state.receive(.audioFailed("repeated synthetic detail"))
        try expect(state.message == nil && state.audioNoticeID == nil,
                   "video recovery replayed a consumed audio notice")
    }
    state.receive(.reconnecting)
    state.receive(.stageFailed(name: "synthetic retry", errorCode: -1))
    state.receive(.stageStarting(name: "synthetic reconnect"))
    state.receive(.waitingForVideo(false))
    try expect(state.phase == .reconnecting && state.message?.contains("마지막 화면") == true,
               "reconnect lost its frozen-picture explanation")
    state.receive(.reconnected)
    try expect(state.phase == .waiting, "transport recovery falsely proved fresh video")
    try expect(!state.status.contains("연결됨"), "reconnected transport falsely published live video")
    state.receive(.waitingForVideo(false))
    try expect(state.phase == .waiting && state.message != nil, "wait reset hid recovery before fresh video")
    state.receive(.firstFrame)
    try expect(state.message == nil, "fresh recovery frame did not clear status")
    state.receive(.audioFailed("synthetic receive failure"))
    guard let recoveredNotice = state.audioNoticeID else {
        throw ModelCheckFailure(message: "reconnect did not rearm its own audio notice")
    }
    state.acknowledgeAudioNotice(audioNotice)
    try expect(recoveredNotice != audioNotice && state.audioNoticeID == recoveredNotice && state.message != nil,
               "late prior-attempt audio expiry dismissed the new notice")
    state.acknowledgeAudioNotice(recoveredNotice)
    try expect(state.message == nil && state.status.contains("오디오를 사용할 수 없습니다"),
               "current-attempt expiry changed the persistent audio status")
    state.receive(.reconnecting); state.receive(.firstFrame); state.receive(.reconnected)
    try expect(state.message == nil, "late reconnected event restored a stale waiting card")
    for terminal in [StreamEvent.stopped, .connectionTerminated(errorCode: -1)] {
        var ended = DesktopRecoveryPresentation()
        ended.receive(.reconnecting); ended.receive(terminal); ended.receive(.firstFrame); ended.receive(.reconnecting)
        try expect(ended.phase == .ended && ended.message == nil, "terminal presentation accepted stale recovery events")
    }
    for reconnecting in [false, true] {
        var ended = DesktopRecoveryPresentation()
        ended.receive(.firstFrame)
        if reconnecting { ended.receive(.reconnecting) }
        ended.receive(.connectionTerminated(errorCode: 0, error: nil))
        try expect(ended.status == "PC에서 화면 공유를 종료했습니다." && ended.phase == .ended && ended.message == nil,
                   "clean PC closure was presented as a fault or left a recovery overlay")
        let status = ended.status
        ended.receive(.stopped); ended.receive(.firstFrame); ended.receive(.reconnecting)
        try expect(ended.status == status, "late events replaced the clean PC closure status")
    }
    for (code, text): (Int32, String) in [
        (-100, "영상을 받지 못했습니다"), (-101, "해상도를 낮춰"), (-1, "연결이 끊겼습니다"),
        (Int32(bitPattern: 0x800E9302), "보호된 콘텐츠"),
        (Int32(bitPattern: 0x800E9403), "HDR·해상도"), (42, "Sunshine 상태")
    ] {
        var ended = DesktopRecoveryPresentation()
        ended.receive(.connectionTerminated(errorCode: code))
        let status = ended.status
        try expect(status.contains(text), "typed termination reason lost its actionable fixed guidance")
        ended.receive(.stopped); ended.receive(.firstFrame)
        try expect(ended.status == status, "late stop or stale video replaced the termination guidance")
    }
    var resumed = DesktopRecoveryPresentation()
    resumed.receive(.firstFrame); resumed.receive(.reconnecting)
    resumed.receive(.connectionTerminated(errorCode: -100))
    try expect(resumed.status.contains("다시 시작되지"),
               "termination after a prior frame lost video-resume guidance")
    for (error, guidance): (StreamError, String) in [
        (.hostUnreachable("synthetic secret"), "Wi-Fi·Tailscale"),
        (.hostCertChanged("synthetic secret"), "인증서는 자동으로 교체하지"),
        (.crypto("synthetic secret"), "[S03]"),
        (.securityNegotiation(.plaintextSignalling), "[S01]"),
        (.securityNegotiation(.missingEncryption(2)), "Required for all clients")
    ] {
        for code: Int32 in [-1, 0] {
            var ended = DesktopRecoveryPresentation()
            ended.receive(.connectionTerminated(errorCode: code, error: error))
            try expect(!ended.status.contains("synthetic") && ended.status.contains(guidance),
                       "typed failure was hidden by a clean code or exposed arbitrary error text")
        }
    }
    count += try runDesktopVisibilityChecks()
    return count
}

@MainActor func runDesktopTerminationChecks() async throws -> Int {
    var count = 0
    for delayed in [false, true] {
        let termination = DesktopTermination()
        var replies = 0
        var revocations = 0
        var cleanupOrderingFailed = false
        termination.begin(timeout: .milliseconds(10), revoke: { revocations += 1 }, cleanup: {
            guard revocations == 1 else { cleanupOrderingFailed = true; return }
            if delayed { try? await Task.sleep(for: .seconds(30)) }
        }, reply: { replies += 1 })
        termination.begin(revoke: { revocations += 100 }, cleanup: {}, reply: { replies += 100 })
        guard revocations == 1 else { throw ModelCheckFailure(message: "sharing revocation deferred behind async cleanup") }
        for _ in 0..<1000 {
            if termination.finished { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        guard termination.finished && replies == 1 && !cleanupOrderingFailed && revocations == 1 else { throw ModelCheckFailure(message: "Quit deadline or reentrant reply failed") }
        await Task.yield()
        guard replies == 1 else { throw ModelCheckFailure(message: "late cleanup replied twice") }
        count += 3
    }
    var release: CheckedContinuation<Void, Never>?
    var completed = Set<Int>()
    let cleanup = Task { @MainActor in
        await DesktopTermination.cleanupOwners([
            { await withCheckedContinuation { release = $0 }; completed.insert(0) },
            { completed.insert(1) }, { completed.insert(2) }, { completed.insert(3) }
        ])
    }
    for _ in 0..<1000 where release == nil || completed.count < 3 { await Task.yield() }
    guard release != nil && completed == [1, 2, 3] else { throw ModelCheckFailure(message: "one suspended owner blocked other cleanup") }
    release?.resume(); await cleanup.value
    guard completed == [0, 1, 2, 3] else { throw ModelCheckFailure(message: "parallel owner cleanup was skipped") }
    count += 2
    return count
}
