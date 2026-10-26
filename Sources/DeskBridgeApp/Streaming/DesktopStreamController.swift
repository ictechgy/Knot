// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import AVFoundation
import GlimmerEngine

struct StreamConfiguration: Sendable {
    var width: Int
    var height: Int
    var fps: Int
    var bitrateKbps: Int
    var remote: Bool
    init(width: Int = 1920, height: Int = 1080, fps: Int = 60, bitrateKbps: Int = 20_000, remote: Bool = false) {
        self.width = width; self.height = height; self.fps = fps
        self.bitrateKbps = bitrateKbps; self.remote = remote
    }
}

@MainActor final class DesktopStreamController: NSObject, NSWindowDelegate {
    private static weak var engagedController: DesktopStreamController?
    private var stopping = 0 { didSet { onEngagementChanged?() } }
    var onEngagementChanged: (() -> Void)?
    var isEngaged: Bool { opening || session != nil || stopping != 0 }
    private let stopSession: @MainActor (StreamSession?) async -> Void
    init(stopSession: @escaping @MainActor (StreamSession?) async -> Void = { await $0?.stop() }) {
        self.stopSession = stopSession
        super.init()
    }
    var onStatus: ((String) -> Void)?
    var onConnectionChanged: ((Bool) -> Void)?
    var keyboardMode: DesktopKeyboardMode = .localIME { didSet { view?.keyboardMode = keyboardMode } }
    private(set) var window: NSWindow?
    private var session: StreamSession?
    private var view: DesktopInputView?
    private var decoder: VideoDecoder?
    private var audioPlatform: DesktopAudio?
    private var events: Task<Void, Never>?
    private var recovery = DesktopRecoveryPresentation()
    private var inputBlocked = false
    private var recoveryMessage: String? {
        if inputBlocked, recovery.phase == .live {
            return "입력 전송이 밀려 일부 입력을 보내지 못했습니다. 다른 창으로 전환한 뒤 이 화면으로 돌아와 내용을 확인하고 다시 입력하세요."
        }
        return recovery.message
    }
    private var recoveryStatus: String {
        inputBlocked && recovery.phase == .live ? "화면 연결됨 · 입력을 일시 중지했습니다." : recovery.status
    }
    private var audioNoticeTask: Task<Void, Never>?
    private var timedAudioNotice: UUID?
    private var generation = UUID()
    private var opening = false { didSet { onEngagementChanged?() } }
    private var openRequest: UUID?
    private var visibility = DesktopPresentationVisibility()
    private var pendingFullScreen = false

    func open(network: NetworkClient, server: ServerInfo, appID: String, configuration: StreamConfiguration) async throws {
        guard !opening, stopping == 0, Self.engagedController == nil || Self.engagedController === self || Self.engagedController?.isEngaged == false else { throw StreamConnection.Failure.alreadyStarted }
        Self.engagedController = self
        opening = true
        let request = UUID()
        openRequest = request
        defer { opening = false; if openRequest == request { openRequest = nil } }
        await stopCurrentSession(reportDisconnected: false)
        guard openRequest == request else { throw CancellationError() }
        guard let id = Int(appID), id > 0 else { throw StreamConnection.Failure.invalidConfiguration }
        dimensions = (configuration.width, configuration.height, configuration.fps)
        let epoch = UUID()
        generation = epoch
        let configuration = StreamConnection.Configuration(width: configuration.width, height: configuration.height,
            fps: configuration.fps, bitrateKbps: configuration.bitrateKbps,
            videoFormats: [.h264, .hevc], audio: .stereo, remote: configuration.remote,
            routeMTU: configuration.remote ? 1280 : nil, sdrColorMode: .desktopSRGB)
        let picture = DesktopInputView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        let win = NSWindow(contentRect: picture.frame, styleMask: [.titled,.closable,.miniaturizable,.resizable],
                           backing: .buffered, defer: false)
        win.title = "Knot — \(server.serverName)"
        win.contentView = picture
        win.collectionBehavior = [.fullScreenPrimary]
        win.acceptsMouseMovedEvents = true
        win.isReleasedWhenClosed = false
        win.delegate = self
        window = win
        view = picture
        picture.keyboardMode = keyboardMode
        recovery = DesktopRecoveryPresentation()
        inputBlocked = false
        picture.showRecovery(recoveryMessage)
        let video = VideoDecoder(configuration: configuration, displayInfo: { [weak picture] in
            guard let screen = picture?.window?.screen else { return nil }
            return VideoDisplayInfo(currentHeadroom: screen.maximumExtendedDynamicRangeColorComponentValue,
                potentialHeadroom: screen.maximumPotentialExtendedDynamicRangeColorComponentValue,
                name: screen.localizedName, maximumFramesPerSecond: screen.maximumFramesPerSecond)
        })
        decoder = video
        visibility = DesktopPresentationVisibility()
        video.attach(to: picture.videoLayer)
        let audioAdapter = DesktopAudio()
        audioPlatform = audioAdapter
        let audio = AudioDecoder(platform: audioAdapter.platform())
        let media = StreamSession.PreparedMedia(video: video, audio: audio,
            quiesce: { [weak picture] in picture?.releaseInput() },
            finalDispose: { [weak self, weak win] in
                win?.delegate = nil
                win?.orderOut(nil)
                win?.close()
                if self?.generation == epoch { self?.window = nil; self?.view = nil; self?.decoder = nil; self?.audioPlatform = nil }
            })
        let pair = StreamSession.make(media: media, network: network, hostDisposition: .disconnectOnly,
                                      lifecycle: DesktopSessionLifecycle().hooks())
        session = pair.session
        picture.input = pair.input
        // Read dimensions from the validated public configuration selected by the caller.
        picture.hostSize = CGSize(width: dimensions.0, height: dimensions.1)

        refreshPresentationVisibility()
        win.center()
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(picture)
        refreshPresentationVisibility()
        video.startPacing(display: PacerDisplay(makeLink: { [weak picture] target, selector in
            picture?.displayLink(target: target, selector: selector)
        }, screen: { [weak picture] in
            let screen = picture?.window?.screen
            return PacerScreen(identity: screen?.localizedName ?? "display", maximumHz: Double(screen?.maximumFramesPerSecond ?? 60),
                minimumHz: nil, scale: Double(screen?.backingScaleFactor ?? 1))
        }, tickOffMain: { true }, prepareTickThread: {}), configuredFps: Int32(dimensions.2))
        let updates = pair.session.events
        events = Task { [weak self] in
            var publishedStatus = self?.recoveryStatus
            for await update in updates {
                guard let self, self.generation == epoch else { break }
                if case .input(.desktopInputBlocked(let blocked)) = update.event { self.inputBlocked = blocked }
                self.recovery.receive(update.event)
                picture.showRecovery(self.recoveryMessage)
                self.refreshAudioNoticeTimer(epoch: epoch)
                if self.recoveryStatus != publishedStatus {
                    publishedStatus = self.recoveryStatus
                    self.onStatus?(self.recoveryStatus)
                }
                switch update.event {
                case .connectionEstablished:
                    picture.input?.setFocused(win.isKeyWindow && self.visibility.suppressed == false)
                    self.onConnectionChanged?(true)
                case .stopped:
                    await self.stopCurrentSession(reportDisconnected: false)
                default: break
                }
            }
        }
        onStatus?("화면에 연결하는 중…")
        do {
            try await pair.session.start(appID: id, configuration: configuration)
            try Task.checkCancellation()
            guard generation == epoch else { await pair.session.stop(); throw CancellationError() }
            pendingFullScreen = true
            enterPendingFullScreen()
            onConnectionChanged?(true)
        }
        catch {
            if generation == epoch { await stopCurrentSession(reportDisconnected: false) }
            throw error
        }
    }
    // Populated by the public request snapshot; no engine internals are exposed to the shell.
    private var dimensions = (1920, 1080, 60)

    func disconnect() async {
        openRequest = nil
        await stopCurrentSession()
    }
    private func stopCurrentSession(reportDisconnected: Bool = true) async {
        stopping += 1
        defer { stopping -= 1 }
        let stoppedEpoch = UUID()
        generation = stoppedEpoch
        let oldSession = session
        let oldEvents = events
        let oldWindow = window
        let oldView = view
        let oldAudioPlatform = audioPlatform
        audioNoticeTask?.cancel(); audioNoticeTask = nil; timedAudioNotice = nil
        // Revoke and detach before the await. An older teardown never owns replacement resources.
        session = nil; events = nil; window = nil; view = nil; decoder = nil; audioPlatform = nil
        pendingFullScreen = false
        inputBlocked = false
        oldEvents?.cancel()
        oldView?.releaseInput()
        oldView?.showRecovery(nil)
        oldWindow?.delegate = nil
        oldWindow?.orderOut(nil)
        onConnectionChanged?(false)
        await stopSession(oldSession)
        withExtendedLifetime(oldAudioPlatform) {}
        oldWindow?.close()
        if reportDisconnected, generation == stoppedEpoch { onStatus?("화면 연결을 끊었습니다.") }
    }
    private func refreshAudioNoticeTimer(epoch: UUID) {
        guard let notice = recovery.audioNoticeID else {
            audioNoticeTask?.cancel(); audioNoticeTask = nil; timedAudioNotice = nil
            return
        }
        // Start the single bounded notice when fresh video makes it visible.
        // A stall does not restart this timer or replay a consumed notice.
        guard recovery.phase == .live, timedAudioNotice != notice else { return }
        audioNoticeTask?.cancel()
        timedAudioNotice = notice
        audioNoticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, !Task.isCancelled, self.generation == epoch,
                  self.timedAudioNotice == notice, self.recovery.audioNoticeID == notice else { return }
            self.recovery.acknowledgeAudioNotice(notice)
            self.timedAudioNotice = nil; self.audioNoticeTask = nil
            self.view?.showRecovery(self.recoveryMessage)
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { await disconnect() }
        return false
    }
    private func ownsWindow(_ notification: Notification) -> Bool {
        guard let notified = notification.object as? NSWindow, let window else { return false }
        return notified === window
    }
    private func refreshPresentationVisibility() {
        guard let window, let decoder,
              let suppressed = visibility.update(isVisible: window.isVisible, isMiniaturized: window.isMiniaturized,
                  isOcclusionVisible: window.occlusionState.contains(.visible)) else { return }
        decoder.setPresentSuppressed(suppressed)
        if suppressed { view?.releaseInput() }
        else if window.isKeyWindow { view?.input?.setFocused(true) }
        // The actor reads the decoder's latest state, so queued duplicate or stale notifications
        // cannot restore an old assertion state. Its lifecycle guard rejects refresh after stop.
        if let session { Task { await session.refreshPresentationActivity() } }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        guard ownsWindow(notification) else { return }
        enterPendingFullScreen()
        refreshPresentationVisibility()
        if visibility.suppressed == false { view?.input?.setFocused(true) }
    }
    private func enterPendingFullScreen() {
        guard pendingFullScreen, session != nil, let window, window.isKeyWindow else { return }
        pendingFullScreen = false
        if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }
    func windowDidResignKey(_ notification: Notification) {
        guard ownsWindow(notification) else { return }
        view?.releaseInput()
        refreshPresentationVisibility()
    }
    func windowDidMiniaturize(_ notification: Notification) {
        guard ownsWindow(notification) else { return }; refreshPresentationVisibility()
    }
    func windowDidDeminiaturize(_ notification: Notification) {
        guard ownsWindow(notification) else { return }; refreshPresentationVisibility()
    }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard ownsWindow(notification) else { return }; refreshPresentationVisibility()
    }
    func windowDidChangeScreen(_ notification: Notification) { decoder?.pacingScreenDidChange() }
    func windowDidEnterFullScreen(_ notification: Notification) { if let view { window?.makeFirstResponder(view) } }
}
