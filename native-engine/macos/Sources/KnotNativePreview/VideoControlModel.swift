import Foundation
import Combine
import KnotNativeCore

/// One bounded user transaction. Draft controls live in the view; these values
/// describe selected bounds and host-confirmed encoder settings separately.
@MainActor
final class VideoControlModel: ObservableObject {
    @Published private(set) var actual: VideoProfile
    @Published private(set) var requested: VideoProfile
    @Published private(set) var isApplying = false
    @Published private(set) var isPaused = false
    @Published private(set) var isAutomaticallyPaused = false
    @Published private(set) var status = "연결 중에도 해상도 · FPS · 목표 전송률을 바꿀 수 있어요."
    private(set) var pending: VideoControlRequest?
    private(set) var pendingBegan: ContinuousClock.Instant?
    private(set) var resetBegan: ContinuousClock.Instant?
    private let send: (VideoControlRequest) -> Bool
    private let now: () -> ContinuousClock.Instant
    private let onInteraction: () -> Void
    private var requestID: UInt64 = 0
    private var lastSubmitted: ContinuousClock.Instant?
    private var automaticPausePending = false
    private var resumeDesired = false
    private var live = true
    var blocksInput: Bool { isPaused || isApplying }
    var canResumeAutomatically: Bool { isAutomaticallyPaused || automaticPausePending }
    func resumeAfterLocalUse() { if canResumeAutomatically { resume(manual: false) } }

    init(actual: VideoProfile, now: @escaping () -> ContinuousClock.Instant = { .now }, onInteraction: @escaping () -> Void = {}, send: @escaping (VideoControlRequest) -> Bool) {
        self.actual = actual; self.requested = actual; self.now = now; self.onInteraction = onInteraction; self.send = send
    }
    @discardableResult
    func requestProfile(width: Int, height: Int, fps: Int, bitrate: Int) -> Bool {
        let profile = VideoProfile(width: width, height: height, fps: fps, bitrate: bitrate)
        guard profile.isRequestedProfile, !isPaused else { return false }
        guard submit(.profile, profile: profile) else { return false }
        onInteraction(); return true
    }
    func pause(manual: Bool = true) {
        if manual, pending?.operation == .pause {
            automaticPausePending = false; resumeDesired = false; onInteraction(); return
        }
        if isPaused {
            if manual { isAutomaticallyPaused = false; resumeDesired = false; onInteraction(); status = "화면과 원격 입력을 일시 정지했어요. ‘화면 재개’를 누르세요." }
            return
        }
        guard submit(.pause) else { return }
        automaticPausePending = !manual; resumeDesired = false
        if manual { onInteraction() }
    }
    func resume(manual: Bool = true) {
        guard live else { return }
        if pending?.operation == .pause, automaticPausePending {
            resumeDesired = true; if manual { onInteraction() }; return
        }
        guard isPaused, !isApplying else { return }
        if manual { onInteraction() }
        resumeDesired = true
        attemptDesiredResume()
    }
    private func attemptDesiredResume() {
        guard resumeDesired, isPaused, pending == nil, !isApplying else { return }
        if submit(.resume) { resumeDesired = false }
    }
    private func submit(_ operation: VideoControlOperation, profile: VideoProfile? = nil) -> Bool {
        let instant = now()
        guard live, !isApplying, pending == nil, requestID != UInt64.max else { return false }
        if let lastSubmitted, instant - lastSubmitted < .seconds(2) {
            let message = operation == .resume ? "화면 재개를 기다리고 있어요. 이전 변경 후 2초가 지나면 재개해요." : "이전 화면 변경 직후예요. 2초 뒤 다시 시도하세요."
            if status != message { status = message }
            return false
        }
        guard let request = try? VideoControlRequest(operation: operation, requestID: requestID + 1, profile: profile) else { return false }
        // Set the input gate before handing the packet to the ordered writer.
        pending = request; isApplying = true; pendingBegan = instant; resetBegan = nil
        guard send(request) else {
            pending = nil; isApplying = false; pendingBegan = nil
            status = "화면 변경을 보내지 못했어요. 잠시 뒤 다시 시도하세요."; return false
        }
        requestID = request.requestID; lastSubmitted = instant
        status = operation == .pause ? "화면을 일시 정지하고 있어요…" : operation == .resume ? "화면을 다시 준비하고 있어요…" : "새 화질을 적용하고 있어요…"
        return true
    }
    /// Wire/state validation occurs before this method on NativePacketReader.
    func accept(_ response: VideoControlStatus, receivedAt: ContinuousClock.Instant? = nil) {
        guard live, let request = pending, request.requestID == response.requestID, request.operation == response.operation else { return }
        if response.outcome == .preparing { return }
        pending = nil; pendingBegan = nil
        switch response.outcome {
        case .preparing: break
        case .rejected:
            isApplying = false; automaticPausePending = false
            resumeDesired = request.operation == .resume && response.reason == .busy
            if resumeDesired { lastSubmitted = receivedAt ?? now() }
            switch response.reason {
            case .unsupported: status = "요청한 해상도/FPS 조합을 지원하지 않아요. 현재 설정을 유지해요."
            case .outOfPolicy: status = "허용 범위를 벗어난 설정이에요. 현재 화면을 유지해요."
            case .busy: status = "호스트가 다른 화면 변경을 처리하고 있어요. 잠시 뒤 다시 시도하세요."
            default: status = "화면을 준비하지 못했어요. 현재 상태를 유지해요."
            }
        case .applied, .rolledBack:
            if response.outcome == .applied, request.operation == .profile, let profile = request.profile { requested = profile }
            actual = response.actual; isPaused = response.state == .paused
            if isPaused {
                isAutomaticallyPaused = automaticPausePending; automaticPausePending = false
                isApplying = false; resetBegan = nil
                status = isAutomaticallyPaused ? "자리를 비워 화면과 원격 입력을 일시 정지했어요. 이 앱을 사용하면 재개해요." : "화면과 원격 입력을 일시 정지했어요. ‘화면 재개’를 누르세요."
                attemptDesiredResume()
            } else {
                isAutomaticallyPaused = false; automaticPausePending = false
                isApplying = response.requiresReset; resetBegan = response.requiresReset ? (receivedAt ?? now()) : nil
                status = response.outcome == .rolledBack ? "새 설정을 준비하지 못해 이전 화질로 복구했어요." : response.requiresReset ? "새 화질의 첫 화면을 기다리고 있어요…" : "요청한 화질을 유지하고 있어요."
            }
        }
    }
    func acceptQuality(_ payload: Data) {
        guard live, payload.count == 9 else { return }
        actual = VideoProfile(width: actual.width, height: actual.height,
                              fps: Int(payload.readBE(UInt32.self, at: 0)), bitrate: Int(payload.readBE(UInt32.self, at: 4)))
    }
    func firstImageArrived() {
        guard live, resetBegan != nil else { return }
        resetBegan = nil; isApplying = false
        if !status.contains("복구") { status = "호스트가 확인한 설정을 적용했어요." }
    }
    func tick() { attemptDesiredResume() }
    func cancel() {
        live = false; pending = nil; pendingBegan = nil; resetBegan = nil
        resumeDesired = false; automaticPausePending = false; isApplying = false
    }
}
