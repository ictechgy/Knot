import Foundation
import Combine
import CoreVideo
import KnotNativeCore

@MainActor
final class SessionModel: ObservableObject {
    typealias ClipboardFactory = @MainActor (@escaping (Packet) -> Bool) -> ClipboardModel
    enum Phase: Equatable { case idle, connecting, approval, decoding, streaming, failed }
    enum ReconnectMethod: Equatable { case registered, number, invitation }
    @Published var phase: Phase = .idle
    @Published var status = "Paste a fresh invitation, review its target and certificate, then connect."
    @Published var invitation: Invitation?
    @Published var videoSize = CGSize(width: 1920, height: 1080)
    @Published var inputRecovery = false
    @Published var textMode = true
    @Published var macShortcuts = true
    @Published var rememberThisPC = false
    @Published var savedDeviceLabel = "Windows PC"
    @Published var autoReconnect = true {
        didSet {
            if !autoReconnect {
                let wasRecovering: Bool
                switch registeredRecovery { case .transient, .suspended: wasRecovering = true; default: wasRecovering = false }
                clearAutomaticRecovery()
                if !active {
                    endConnectionActivity()
                    if wasRecovering { status = "자동 재연결을 껐어요. ‘내 PC’에서 직접 다시 연결할 수 있어요." }
                }
            }
            else if active, let device = selectedTrustedDevice, savedDevices.contains(device) {
                registeredRecovery = .current(device)
            }
        }
    }
    @Published private(set) var savedDevices: [SavedNativeDevice] = []
    @Published private(set) var clipboard: ClipboardModel?
    @Published private(set) var quality: QualityModel?
    @Published private(set) var videoControl: VideoControlModel?
    @Published var idleVideoMinutes = 10 {
        didSet { if !NativeVideoIdlePolicy.allowedMinutes.contains(idleVideoMinutes) { idleVideoMinutes = 10 } }
    }
    @Published var idleVideoBackgroundOnly = true
    private var videoIdle = NativeVideoIdlePolicy()
    private var videoEpoch: UInt64 = 0
    private var packetReader: NativePacketReader?
    private var videoControlObservation: AnyCancellable?
    @Published private(set) var audio: NativeAudioSession?
    private let makeClipboard: ClipboardFactory
    private let makeAudioSession: (@MainActor @Sendable (Invitation) throws -> NativeAudioSession)?
    private let makeConnectionActivity: (@MainActor () -> any NativeConnectionActivityHolding)?
    private var connectionActivity: (any NativeConnectionActivityHolding)?
    let diagnostics = NativeConnectionDiagnostics()
    private let writeUpdateResume: @MainActor @Sendable (String?, TimeInterval) -> Void
    private let takeUpdateResume: @MainActor @Sendable () -> (String, TimeInterval)?
    private var selectedTrustedDevice: SavedNativeDevice?
    private var pendingRegistration: Invitation?
    private var trustedClient: (any NativeTrustedConnecting)?
    private var trustedTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var wakeReconnectTask: Task<Void, Never>?
    // Selection is presentation state and can survive a terminal failure. Only
    // this explicit intent authorizes automatic recovery of the current PC.
    private enum RegisteredRecovery {
        case current(SavedNativeDevice), transient(SavedNativeDevice), suspended(SavedNativeDevice)
        var device: SavedNativeDevice {
            switch self { case .current(let device), .transient(let device), .suspended(let device): device }
        }
    }
    private var registeredRecovery: RegisteredRecovery?
    @Published private(set) var isSystemSleeping = false
    private var reconnectAttempt = 0
    var reconnectAttemptCount: Int { reconnectAttempt }
    var hasPendingReconnect: Bool {
        if reconnectTask != nil || wakeReconnectTask != nil { return true }
        // No task runs while asleep, but the suspended intent still owns the
        // connection UI until wake or an explicit cancellation.
        guard isSystemSleeping, case .suspended = registeredRecovery else { return false }
        return recoveryDevice != nil
    }
    private let makeTrustedClient: @Sendable (SavedNativeDevice, String) throws -> any NativeTrustedConnecting
    private let waitForReconnect: @MainActor @Sendable (Duration) async throws -> Void
    private let waitForWakeReadiness: @MainActor @Sendable () async throws -> Void
    private let removeSavedDevice: @MainActor @Sendable (String) throws -> Void
    private let loadSavedDevices: @MainActor @Sendable () throws -> [SavedNativeDevice]
    private let saveSavedDevices: @MainActor @Sendable ([SavedNativeDevice]) throws -> Void
    private let registerDevice: @MainActor @Sendable (SavedNativeDevice, String, Invitation) async throws -> Void
    @Published var showFullscreenControls = false
    @Published private(set) var numberAuthorized = false
    @Published private(set) var files: FileTransferModel?
    private(set) var fileUIInputSuspended = false
    // Presentation guidance survives revocation; it is never authorization.
    private(set) var reconnectMethod: ReconnectMethod = .number
    @Published var viewerLabel = "My Mac"
    weak var surface: (any NativePresenter)? {
        didSet {
            oldValue?.onFailure = nil
            if [.decoding, .streaming].contains(phase) { armPresentationFailure() }
        }
    }
    private var channel: (any NativeChannel)?
    private let makeChannel: @Sendable (Invitation) throws -> any NativeChannel
    private let waitForInputDeadline: @MainActor @Sendable (ContinuousClock.Instant) async throws -> Void
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var decoder: (any NativeVideoDecoding)?
    private let makeDecoder: @MainActor (VideoProfile) -> any NativeVideoDecoding
    private var input = InputBuffer()
    private var identity = UUID()
    private var connectedAt = ContinuousClock.now
    private var lastIncoming = ContinuousClock.now
    private var lastHeartbeat = ContinuousClock.now
    private var readyAt = ContinuousClock.now
    private var nextInput = ContinuousClock.now
    private var writerBusy = false
    private var inputEpoch: UInt64 = 0
    var inputRevision: UInt64 { inputEpoch }
    private var presentationBackpressureSince: ContinuousClock.Instant?
    private var displayBehind = false
    private var receiverPressure = ReceiverPressureWindow()
    var active: Bool { [.connecting, .approval, .decoding, .streaming].contains(phase) }

    init(makeDecoder: @escaping @MainActor (VideoProfile) -> any NativeVideoDecoding = { NativeDecoder(width: $0.width, height: $0.height) },
         makeChannel: @escaping @Sendable (Invitation) throws -> any NativeChannel = { try TLSChannel(invitation: $0) },
         waitForInputDeadline: @escaping @MainActor @Sendable (ContinuousClock.Instant) async throws -> Void = { deadline in
             if ContinuousClock.now < deadline { try await Task.sleep(until: deadline) }
         },
         makeTrustedClient: @escaping @Sendable (SavedNativeDevice, String) throws -> any NativeTrustedConnecting = { try NativeTrustedClient(device: $0, viewerName: $1) },
         waitForReconnect: @escaping @MainActor @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         waitForWakeReadiness: @escaping @MainActor @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(2)) },
         initialSavedDevices: [SavedNativeDevice] = [], initialRegisteredDevice: SavedNativeDevice? = nil,
         removeSavedDevice: @escaping @MainActor @Sendable (String) throws -> Void = { try NativeDeviceKeychain.remove($0) },
         loadSavedDevices: @escaping @MainActor @Sendable () throws -> [SavedNativeDevice] = { try NativeDeviceKeychain.load() },
         saveSavedDevices: @escaping @MainActor @Sendable ([SavedNativeDevice]) throws -> Void = { try NativeDeviceKeychain.save($0) },
         registerDevice: @escaping @MainActor @Sendable (SavedNativeDevice, String, Invitation) async throws -> Void = { device, name, invitation in
             try await NativeTrustedClient(device: device, viewerName: name).register(invitation: invitation)
         },
         makeAudioSession: (@MainActor @Sendable (Invitation) throws -> NativeAudioSession)? = nil,
         makeConnectionActivity: (@MainActor () -> any NativeConnectionActivityHolding)? = nil,
         writeUpdateResume: @escaping @MainActor @Sendable (String?, TimeInterval) -> Void = { id, expiry in
             let defaults = UserDefaults(suiteName: "io.knot.native-preview")
             defaults?.removeObject(forKey: "updateResumeDevice"); defaults?.removeObject(forKey: "updateResumeExpiry")
             if let id { defaults?.set(id, forKey: "updateResumeDevice"); defaults?.set(expiry, forKey: "updateResumeExpiry") }
         },
         takeUpdateResume: @escaping @MainActor @Sendable () -> (String, TimeInterval)? = {
             let defaults = UserDefaults(suiteName: "io.knot.native-preview")
             let id = defaults?.string(forKey: "updateResumeDevice"), expiry = defaults?.double(forKey: "updateResumeExpiry") ?? 0
             defaults?.removeObject(forKey: "updateResumeDevice"); defaults?.removeObject(forKey: "updateResumeExpiry")
             return id.map { ($0, expiry) }
         },
         makeClipboard: @escaping ClipboardFactory = { ClipboardModel(send: $0) }) {
        self.makeDecoder = makeDecoder
        self.makeClipboard = makeClipboard
        self.writeUpdateResume = writeUpdateResume; self.takeUpdateResume = takeUpdateResume
        self.makeChannel = makeChannel
        self.makeAudioSession = makeAudioSession
        self.makeConnectionActivity = makeConnectionActivity
        self.waitForInputDeadline = waitForInputDeadline
        self.makeTrustedClient = makeTrustedClient; self.waitForReconnect = waitForReconnect
        self.waitForWakeReadiness = waitForWakeReadiness; self.removeSavedDevice = removeSavedDevice
        self.loadSavedDevices = loadSavedDevices; self.saveSavedDevices = saveSavedDevices; self.registerDevice = registerDevice
        // Explicit fixture inputs; initialization never opens Keychain/network.
        savedDevices = Array(initialSavedDevices.prefix(16))
        selectedTrustedDevice = initialRegisteredDevice
        if initialRegisteredDevice != nil { reconnectMethod = .registered }
        registeredRecovery = initialRegisteredDevice.map(RegisteredRecovery.current)
    }

    func prepareForUpdate() {
        // UI selection may outlive a terminal failure. It does not authorize
        // reconnecting after the updater restarts the app.
        let candidate: SavedNativeDevice?
        switch registeredRecovery {
        case .current: candidate = active ? recoveryDevice : nil
        case .transient, .suspended: candidate = hasPendingReconnect ? recoveryDevice : nil
        default: candidate = nil
        }
        writeUpdateResume(candidate?.id, candidate == nil ? 0 : Date().addingTimeInterval(300).timeIntervalSince1970)
        disconnect()
    }
    func resumeAfterUpdateIfRequested() {
        guard let (id, expiry) = takeUpdateResume(), autoReconnect,
              expiry > Date().timeIntervalSince1970,
              expiry <= Date().addingTimeInterval(300).timeIntervalSince1970 else { return }
        connectSaved(id)
    }
    func refreshSavedDevices() {
        do {
            savedDevices = try loadSavedDevices()
            // A successful refresh can observe a removal or replacement made
            // by another app instance. Retire the old target immediately so a
            // completed retry task cannot keep its UI/activity ownership alive.
            if let selectedTrustedDevice, !savedDevices.contains(selectedTrustedDevice) {
                diagnostics.record(.trust)
                close(message: "등록된 PC 정보가 변경되어 연결과 자동 복구를 종료했어요. ‘내 PC’를 확인하고 다시 연결하세요.", failed: true)
                self.selectedTrustedDevice = nil
            }
        }
        catch { status = "등록된 PC를 읽지 못했어요. 키체인 접근을 확인하세요." }
    }
    func connectSaved(_ id: String) {
        guard !active, !isSystemSleeping, let device = savedDevices.first(where: { $0.id == id }) else { return }
        clearAutomaticRecovery(); endConnectionActivity(); reconnectAttempt = 0
        guard Invitation.validViewerLabel(viewerLabel) else {
            phase = .failed; status = "Choose a viewer label of 1–64 UTF-8 bytes without control characters."; return
        }
        reconnectMethod = .registered
        selectedTrustedDevice = device; pendingRegistration = nil
        beginTrustedConnection(device)
    }
    func prepareForNewTarget() {
        guard !active, !isSystemSleeping else { return }
        // Discovery/selection is an explicit departure from the old target,
        // including its continuing transport recovery.
        disconnect(); invitation = nil; numberAuthorized = false
    }
    private func beginTrustedConnection(_ device: SavedNativeDevice) {
        guard !active, !isSystemSleeping else { return }
        beginConnectionActivity()
        registeredRecovery = autoReconnect ? .current(device) : nil
        let id = UUID(); identity = id; phase = .connecting
        status = "등록된 PC와 보안 연결을 확인하고 있어요…"
        do {
            let client = try makeTrustedClient(device, viewerLabel); trustedClient = client
            trustedTask = Task { [weak self] in
                do {
                    guard let invitation = try await client.connect() else { throw NativeFailure.trust }
                    guard let self, self.identity == id, !Task.isCancelled else { return }
                    self.trustedClient = nil; self.trustedTask = nil
                    self.invitation = invitation; self.numberAuthorized = true; self.phase = .idle
                    self.startConnection()
                } catch {
                    guard let self, self.identity == id, !Task.isCancelled else { return }
                    self.connectionFailed(error)
                }
            }
        } catch { connectionFailed(error) }
    }
    func forgetSaved(_ id: String) {
        guard let device = savedDevices.first(where: { $0.id == id }) else { return }
        let wasSelected = selectedTrustedDevice?.id == id
        // Revoke this connection/recovery immediately on the owner's request,
        // even if removing the persistent local credential subsequently fails.
        if wasSelected { disconnect() }
        // The local credential is removed even when the host is offline. The
        // Windows device list offers independent, immediate server revocation.
        do { try removeSavedDevice(id); savedDevices.removeAll { $0.id == id } }
        catch {
            if wasSelected {
                phase = .failed
                status = "연결은 종료했지만 키체인에서 PC 등록을 해제하지 못했어요. 다시 시도하세요."
            } else { status = "키체인에서 PC 등록을 해제하지 못했어요." }
            return
        }
        Task { [weak self, viewerLabel, makeTrustedClient] in
            if let client = try? makeTrustedClient(device, viewerLabel) {
                _ = try? await client.connect(revoke: true)
            }
            if self?.selectedTrustedDevice?.id == id { self?.disconnect() }
        }
    }
    private func registerConnectedDevice(_ invitation: Invitation) {
        guard rememberThisPC, numberAuthorized, selectedTrustedDevice == nil else { return }
        pendingRegistration = nil
        do {
            let stored = try loadSavedDevices()
            let existing = stored.first { $0.certificateSHA256 == invitation.certificateSHA256 && $0.address == invitation.address }
            guard existing != nil || stored.count < 16 else {
                status = "등록된 PC는 16대까지 저장할 수 있어요. 기존 PC 등록을 해제한 뒤 다시 시도하세요."
                return
            }
            let device = try existing ?? NativeTrustedClient.newDevice(invitation: invitation, name: savedDeviceLabel)
            let run = identity
            registrationTask = Task { [weak self, registerDevice, viewerLabel] in
                do {
                    try await registerDevice(device, viewerLabel, invitation)
                    guard let self, self.identity == run, !Task.isCancelled else { return }
                    var devices = try self.loadSavedDevices()
                    devices.removeAll { $0.id == device.id }
                    guard devices.count < 16 else { throw NativeFailure.state }
                    devices.append(device); try self.saveSavedDevices(devices)
                    self.savedDevices = devices; self.selectedTrustedDevice = device; self.registrationTask = nil
                    self.registeredRecovery = self.autoReconnect ? .current(device) : nil
                    self.updateStreamingStatus()
                } catch {
                    guard let self, self.identity == run, !Task.isCancelled else { return }
                    self.status = "화면은 연결됐지만 PC 등록을 저장하지 못했어요. Windows의 등록 기기를 확인해주세요."
                    self.registrationTask = nil
                }
            }
        } catch { status = "PC 등록을 준비하지 못했어요. 화면 연결은 계속돼요." }
    }
    private func scheduleReconnect(_ device: SavedNativeDevice) {
        guard !isSystemSleeping, !active, recoveryDevice == device else { return }
        let delays: [Int64] = [1, 2, 4, 8, 16, 30]
        let delay = delays[min(reconnectAttempt, delays.count - 1)]
        // Saturate the backoff counter. An extended outage must not exhaust
        // recovery or overflow a counter, and only one retry task exists.
        reconnectAttempt = min(reconnectAttempt + 1, delays.count)
        beginConnectionActivity()
        status = "연결이 끊겼어요. \(delay)초 후 등록된 PC에 다시 연결해요. 복구될 때까지 계속 시도해요."
        let run = identity
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.waitForReconnect(.seconds(delay)) } catch { return }
            guard self.identity == run, !Task.isCancelled, !self.isSystemSleeping,
                  !self.active, self.recoveryDevice == device else { return }
            self.reconnectTask = nil; self.beginTrustedConnection(device)
        }
    }
    private func transportFailed(reason: NativeConnectionIssue = .transport) {
        diagnostics.record(reason)
        let device = recoveryDevice
        let message: String
        if device != nil { message = "연결이 끊겼어요. Windows의 공유 상태와 네트워크를 확인하세요." }
        else if selectedTrustedDevice != nil { message = "연결이 끊겼어요. Windows의 공유 상태와 네트워크를 확인한 뒤 등록된 PC를 선택해 다시 연결하세요." }
        else { message = "The network connection stopped. Check Windows sharing and the network before reconnecting." }
        close(message: message, failed: true, retainingActivity: device != nil && !isSystemSleeping)
        if let device, !isSystemSleeping { registeredRecovery = .transient(device); scheduleReconnect(device) }
    }
    private var recoveryDevice: SavedNativeDevice? {
        guard autoReconnect, let device = registeredRecovery?.device,
              selectedTrustedDevice == device, savedDevices.contains(device) else { return nil }
        return device
    }
    private func clearAutomaticRecovery() {
        registeredRecovery = nil
        reconnectTask?.cancel(); reconnectTask = nil
        wakeReconnectTask?.cancel(); wakeReconnectTask = nil
    }
    private func beginConnectionActivity() {
        guard connectionActivity == nil, !isSystemSleeping else { return }
        connectionActivity = makeConnectionActivity?()
    }
    private func endConnectionActivity() {
        connectionActivity?.stop(); connectionActivity = nil
    }
    func systemWillSleep() {
        guard !isSystemSleeping else { return }
        let candidate: SavedNativeDevice?
        switch registeredRecovery {
        case .current: candidate = active ? recoveryDevice : nil
        case .transient: candidate = recoveryDevice
        case .suspended: candidate = wakeReconnectTask != nil ? recoveryDevice : nil
        default: candidate = nil
        }
        let hadConnection = active || hasPendingReconnect || candidate != nil
        isSystemSleeping = true
        if hadConnection {
            close(message: candidate == nil ? "잠자기로 연결을 종료했어요. 새 번호로 다시 연결하세요." :
                "Mac이 잠자기 상태예요. 복귀하면 등록된 PC에 다시 연결해요.", failed: false)
        } else { clearAutomaticRecovery() }
        if let candidate { registeredRecovery = .suspended(candidate) }
    }
    func systemDidWake() {
        guard isSystemSleeping else { return }
        isSystemSleeping = false
        guard case .suspended = registeredRecovery, let device = recoveryDevice else {
            clearAutomaticRecovery(); return
        }
        let run = UUID(); identity = run
        beginConnectionActivity()
        status = "네트워크 복귀를 기다린 뒤 등록된 PC에 다시 연결해요…"
        wakeReconnectTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.waitForWakeReadiness() } catch { return }
            guard self.identity == run, !Task.isCancelled, !self.isSystemSleeping,
                  !self.active, case .suspended = self.registeredRecovery,
                  self.recoveryDevice == device else { return }
            self.wakeReconnectTask = nil; self.reconnectAttempt = 0
            // The trusted client issues a fresh challenge; no one-use invitation
            // or previous media/sidecar capability survives close().
            self.beginTrustedConnection(device)
        }
    }
    private func connectionFailed(_ error: any Error) {
        switch error as? NativeFailure {
        case .transport:
            transportFailed()
        case .certificatePinMismatch:
            diagnostics.record(.certificatePin)
            selectedTrustedDevice = nil
            fail(NativeCopy.certificatePinMismatchGuidance)
        case .certificatePolicy:
            diagnostics.record(.certificatePolicy)
            fail(NativeCopy.certificatePolicyGuidance)
        case .trust:
            diagnostics.record(.trust)
            fail(selectedTrustedDevice == nil ? "Invitation was rejected or expired. Create a new invitation." :
                "등록된 PC의 연결 권한을 확인하지 못했어요. Windows의 등록 기기를 확인하고 새 번호로 다시 등록하세요.")
        case .decoder:
            diagnostics.record(.decoder)
            fail("The native decoder stopped. Create a new invitation to reconnect.")
        default:
            diagnostics.record(.protocolFailure)
            fail(selectedTrustedDevice == nil ? "Connection ended or validation failed. Ask the host for a new invitation." :
                "등록된 PC의 화면 연결 정보를 처리하지 못했어요. 두 기기의 앱 버전과 Windows 공유 상태를 확인하고 ‘내 PC’에서 다시 연결하세요.")
        }
    }
    func review(_ secret: String) {
        guard !active, !isSystemSleeping else { return }
        clearAutomaticRecovery(); endConnectionActivity(); identity = UUID(); reconnectAttempt = 0
        selectedTrustedDevice = nil; pendingRegistration = nil
        reconnectMethod = .invitation
        numberAuthorized = false
        do { invitation = try Invitation(secret); phase = .idle; status = "Review the private address and exact certificate pin below. Trust lasts for this connection only." }
        catch { invitation = nil; phase = .failed; status = "Invalid invitation. Ask the host to create a fresh native invitation." }
    }
    func connect() {
        guard !active, !isSystemSleeping else { return }
        clearAutomaticRecovery(); endConnectionActivity(); identity = UUID(); reconnectAttempt = 0
        selectedTrustedDevice = nil; pendingRegistration = nil
        reconnectMethod = .invitation
        numberAuthorized = false
        startConnection()
    }
    func connectAuthenticated(_ enrollment: AuthenticatedEnrollment) {
        guard !active, !isSystemSleeping else { return }
        clearAutomaticRecovery(); endConnectionActivity(); identity = UUID()
        guard ContinuousClock.now < enrollment.expiresAt, Invitation.validViewerLabel(enrollment.viewerName) else {
            close(message: "Invitation was rejected or expired. Create a new invitation.", failed: true, numberConnection: true); return
        }
        let authenticatedInvitation = enrollment.offer.invitation
        // A fresh number authenticates this host, but must not recreate or
        // rotate a saved key that Windows may have revoked. Reconnect will
        // still require a fresh proof using that exact existing credential.
        selectedTrustedDevice = rememberThisPC ? nil : savedDevices.first {
            $0.address == authenticatedInvitation.address && $0.certificateSHA256 == authenticatedInvitation.certificateSHA256
        }
        registeredRecovery = autoReconnect ? selectedTrustedDevice.map(RegisteredRecovery.current) : nil
        reconnectAttempt = 0
        pendingRegistration = rememberThisPC ? authenticatedInvitation : nil
        invitation = authenticatedInvitation
        viewerLabel = enrollment.viewerName
        numberAuthorized = true
        startConnection()
    }
    private func startConnection() {
        guard !isSystemSleeping else { return }
        reconnectTask?.cancel(); reconnectTask = nil
        guard !active, let invitation else { return }
        let label = viewerLabel
        guard Invitation.validViewerLabel(label) else {
            fail("Choose a viewer label of 1–64 UTF-8 bytes without control characters."); return
        }
        beginConnectionActivity()
        let id = UUID(); identity = id; phase = .connecting; status = "Checking the secure connection…"
        input = InputBuffer(); inputRecovery = false
        videoEpoch = 0; videoIdle.reset(now: .now)
        presentationBackpressureSince = nil; displayBehind = false; receiverPressure.reset()
        connectedAt = .now; lastIncoming = .now; lastHeartbeat = .now
        reader = Task { [weak self] in
            guard let self, !Task.isCancelled, self.identity == id else { return }
            do {
                let transport = try self.makeChannel(invitation); self.channel = transport
                try await transport.start()
                guard self.identity == id, !Task.isCancelled else { transport.close(); return }
                self.status = "Sending the connection request…"
                // This write completes before the sole post-Hello writer starts.
                try await transport.send(invitation.hello(name: label, videoControlVersion: 1))
                guard self.identity == id, !Task.isCancelled else { transport.close(); return }
                self.invitation = nil // one-use token must not become reusable trust
                self.connectedAt = .now
                self.lastIncoming = .now
                self.phase = .approval
                self.status = self.numberAuthorized ? "Number verified. Preparing the host desktop…" : "Certificate verified. Waiting for host approval and native encoder startup…"
                self.startTicker(id: id)
                let packets = NativePacketReader(channel: transport, videoControlVersion: 1)
                self.packetReader = packets
                while !Task.isCancelled, self.identity == id {
                    let budget: Duration = self.phase == .approval ? .seconds(65) : self.videoControl?.pending != nil ? .seconds(30) : .seconds(10)
                    let incoming = try await packets.next(timeout: budget)
                    guard self.identity == id, !Task.isCancelled else { return }
                    self.lastIncoming = .now
                    switch incoming {
                    case .ready(let ready):
                        if ready.clipboardVersion == 1 {
                            self.clipboard = self.makeClipboard({ [weak self] packet in self?.sendControl(packet) ?? false })
                        }
                        if ready.qualityVersion == 1 {
                            self.quality = QualityModel(send: { [weak self] packet in self?.sendControl(packet) ?? false })
                        }
                        if let offer = ready.files {
                            self.files = try FileTransferModel(invitation: invitation, offer: offer)
                        }
                        let profile = VideoProfile(width: ready.width, height: ready.height, fps: ready.fps, bitrate: ready.bitrate)
                        if ready.videoControlVersion == 1 {
                            let control = VideoControlModel(actual: profile, onInteraction: { [weak self] in self?.acceptedLocalInteraction(resumeAutomatically: false) }, send: { [weak self] request in self?.sendVideoControl(request) ?? false })
                            self.videoControl = control
                            self.videoControlObservation = control.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
                        }
                        self.installDecoder(profile: profile, sessionID: id, epoch: 0)
                        self.phase = .decoding
                        self.armPresentationFailure()
                        self.readyAt = .now
                        self.status = "Host approved and encoder ready. Waiting for the first decoded image…"
                        // Optional child service: audio failure never tears down video.
                        // Tests have no default audio factory and cannot open audio IO.
                        if let makeAudioSession = self.makeAudioSession {
                            self.audio = try? makeAudioSession(invitation)
                            self.audio?.start()
                        }
                    case .video(let video): try await self.decoder?.decode(video.accessUnit)
                    case .error(let code):
                        self.handleHostError(code); return
                    case .clipboard(let response): self.clipboard?.accept(response)
                    case .quality(let response): self.quality?.accept(response); self.videoControl?.acceptQuality(response)
                    case .videoControl(let response): try await self.acceptVideoControl(response, sessionID: id)
                    case .heartbeat: break
                    }
                }
            } catch {
                if self.identity == id {
                    self.connectionFailed(error)
                }
            }
        }
    }
    private func installDecoder(profile: VideoProfile, sessionID: UUID, epoch: UInt64) {
        videoSize = CGSize(width: profile.width, height: profile.height)
        let next = makeDecoder(profile)
        next.onPerformanceEvent = { [weak self] event in
            guard let self, self.identity == sessionID, self.videoEpoch == epoch, [.decoding, .streaming].contains(self.phase) else { return }
            self.receiverPressure.decode(event, at: .now)
        }
        next.onImage = { [weak self] image in
            guard let self, self.identity == sessionID, self.videoEpoch == epoch else { return }
            self.presentDecodedImage(image)
        }
        next.onFailure = { [weak self] in
            guard let self, self.identity == sessionID, self.videoEpoch == epoch else { return }
            self.diagnostics.record(.decoder)
            self.fail("The native decoder stopped. Create a new invitation to reconnect.")
        }
        decoder = next
    }
    private func acceptVideoControl(_ response: VideoControlStatus, sessionID: UUID) async throws {
        let receivedAt = ContinuousClock.now
        guard identity == sessionID, let control = videoControl else { throw NativeFailure.state }
        if response.requiresReset || response.state == .paused {
            if let old = decoder {
                // Admission covers queued pixel delivery as well as VideoToolbox.
                // A cancelled or overdue drain cannot retain a second decoder.
                try await NativeVideoDecoderDrain.wait(old)
                guard identity == sessionID, !Task.isCancelled else { throw CancellationError() }
                old.stop(); decoder = nil
            }
            guard identity == sessionID, !Task.isCancelled else { throw CancellationError() }
            receiverPressure.reset(); presentationBackpressureSince = nil; displayBehind = false
            videoEpoch = response.videoEpoch
            if response.state == .running { installDecoder(profile: response.actual, sessionID: sessionID, epoch: videoEpoch) }
        }
        control.accept(response, receivedAt: receivedAt)
        if !control.blocksInput, !inputRecovery { input.recover() }
    }
    private func sendVideoControl(_ request: VideoControlRequest) -> Bool {
        guard phase == .streaming, packetReader != nil else { return false }
        clipboard?.cancel(); inputEpoch &+= 1
        input.revoke(); if !inputRecovery { input.recover() }
        surface?.forgetHeldKeys()
        do { try input.append(request.packet); pumpWriter(); return true }
        catch { return false }
    }
    func acceptedLocalInteraction(now: ContinuousClock.Instant = .now, resumeAutomatically: Bool = true) {
        videoIdle.interaction(now: now)
        if resumeAutomatically { videoControl?.resumeAfterLocalUse() }
    }
    func setApplicationActive(_ active: Bool, now: ContinuousClock.Instant = .now) {
        videoIdle.focus(active, now: now)
        if active { videoControl?.resumeAfterLocalUse() }
    }
    func presentDecodedImage(_ image: CVPixelBuffer, now: ContinuousClock.Instant = .now) {
        guard [.decoding, .streaming].contains(phase) else { return }
        switch surface?.display(image) ?? .backpressure {
        case .presented:
            receiverPressure.presentation(accepted: true, at: now)
            videoControl?.firstImageArrived()
            let beganStreaming = phase != .streaming
            let statusChanged = beganStreaming || displayBehind
            presentationBackpressureSince = nil; displayBehind = false
            if beganStreaming {
                phase = .streaming
                if selectedTrustedDevice != nil { reconnectAttempt = 0 }
            }
            if statusChanged { updateStreamingStatus() }
            if beganStreaming, let pending = pendingRegistration { registerConnectedDevice(pending) }
        case .backpressure:
            receiverPressure.presentation(accepted: false, at: now)
            let began = presentationBackpressureSince ?? now
            presentationBackpressureSince = began
            if phase == .streaming, !displayBehind, now - began >= .seconds(2) {
                displayBehind = true; updateStreamingStatus()
            }
        case .failed: presentationFailed()
        }
    }
    private func updateStreamingStatus() {
        let reception = displayBehind ? "Display is behind; still receiving decoded images." : "Receiving the host desktop."
        let value = reception + (inputRecovery ? " Input paused; click the desktop to resume." : (selectedTrustedDevice == nil ? " Temporary trust; no saved pairing." : " Registered device; encrypted connection."))
        if status != value { status = value }
    }
    private func presentationFailed() {
        guard [.decoding, .streaming].contains(phase) else { return }
        diagnostics.record(.presentation)
        fail("The native display stopped. Create a new invitation to reconnect.")
    }
    private func armPresentationFailure() {
        let id = identity
        surface?.onFailure = { [weak self] in
            guard let self, self.identity == id else { return }
            self.presentationFailed()
        }
    }
    private static func message(_ code: String) -> String {
        switch code {
        case "auth", "expired": "Invitation was rejected or expired. Create a new invitation."
        case "declined": "The host declined the request. Create a new invitation to try again."
        case "busy": "The host is already handling another request."
        case "capture": "Host capture is unavailable. Check its logged-in SDR primary display."
        case "encoder": "The host hardware H.264 encoder could not start."
        case "input": "The host stopped accepting input. Create a new invitation."
        case "protocol": "연결 중 화질 조절에는 Mac과 Windows 앱 모두 Native.18 이상이 필요해요. 두 앱을 업데이트한 뒤 새 번호로 연결하세요."
        case "timeout": "The connection timed out. Create a new invitation."
        default: "The host closed the connection. Create a new invitation to reconnect."
        }
    }
    func handleHostError(_ code: String) {
        // A registered grant can race the host's short preclaim admission
        // budget. The host remains ready in that case: authenticate afresh.
        // Ready/streaming errors, temporary invitations and trust failures do
        // not acquire this recovery permission.
        let issue: NativeConnectionIssue = code == "timeout" ? .hostTimeout : .hostFailure
        if phase == .approval, recoveryDevice != nil, ["timeout", "busy"].contains(code) {
            transportFailed(reason: issue)
        } else {
            diagnostics.record(issue)
            fail(Self.message(code))
        }
    }
    private func startTicker(id: UUID) {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.identity == id, !Task.isCancelled else { return }
                let now = ContinuousClock.now
                guard self.checkDeadlines(now: now) else { return }
                if now - self.lastHeartbeat >= .seconds(2) { self.reportReceiverPressure(now: now); self.pumpWriter() }
            }
        }
    }
    /// The feedback interval is separate from the UI's continuous-stall notice.
    /// Keeping the existing one-byte protocol avoids changing stream schemas.
    func reportReceiverPressure(now: ContinuousClock.Instant = .now) {
        guard phase == .streaming, videoControl?.blocksInput != true else { return }
        quality?.reportPressure(displayBehind || receiverPressure.isOverloaded(at: now), now: now)
    }
    /// Shared by the real ticker and inert lifecycle tests; host activity cannot
    /// indefinitely extend approval or the first decoded-image deadline.
    func checkDeadlines(now: ContinuousClock.Instant) -> Bool {
        guard active else { return false }
        // Startup caps are terminal media/approval policy, independently of
        // transport silence. Keep the result independent of which timer wins.
        guard phase != .approval || now - connectedAt < .seconds(125) else {
            diagnostics.record(.approvalDeadline)
            fail("The peer or host approval timed out. Create a new invitation."); return false
        }
        guard phase != .decoding || now - readyAt < .seconds(15) else {
            diagnostics.record(.firstImageDeadline)
            fail("The first decoded image did not arrive. Create a new invitation."); return false
        }
        if let pendingBegan = videoControl?.pendingBegan, now - pendingBegan >= .seconds(30) {
            diagnostics.record(.protocolFailure)
            fail("화면 변경 응답이 30초 안에 도착하지 않았어요. 새 연결로 다시 시도하세요."); return false
        }
        if let resetBegan = videoControl?.resetBegan, now - resetBegan >= .seconds(15) {
            diagnostics.record(.firstImageDeadline)
            fail("변경된 화면의 첫 이미지가 15초 안에 도착하지 않았어요. 새 연결로 다시 시도하세요."); return false
        }
        videoControl?.tick()
        if phase == .streaming, let control = videoControl, !control.isApplying, !control.isPaused,
           videoIdle.shouldPause(minutes: idleVideoMinutes, backgroundOnly: idleVideoBackgroundOnly, now: now) {
            control.pause(manual: false)
        }
        let silence: Duration = phase == .approval ? .seconds(65) : videoControl?.pending != nil ? .seconds(30) : .seconds(10)
        guard now - lastIncoming < silence else {
            transportFailed(reason: .silenceDeadline)
            return false
        }
        return true
    }
    @discardableResult func sendControl(_ packet: Packet) -> Bool {
        guard [.clipboardRequest, .qualityPreference, .qualityFeedback].contains(packet.kind),
              phase == .streaming, !fileUIInputSuspended,
              packet.kind != .clipboardRequest || videoControl?.blocksInput != true else { return false }
        do {
            try input.append(packet)
            if packet.kind != .qualityFeedback { acceptedLocalInteraction() }
            pumpWriter(); return true
        }
        catch {
            if input.needsRecovery { inputQueueSaturated() }
            return false
        }
    }
    @discardableResult func send(_ packet: Packet) -> Bool {
        guard packet.kind != .videoControl, phase == .streaming, !inputRecovery, !fileUIInputSuspended, videoControl?.blocksInput != true else { return false }
        do { try input.append(packet); acceptedLocalInteraction(); pumpWriter(); return true }
        catch {
            inputQueueSaturated()
            return false
        }
    }
    private func inputQueueSaturated() {
        inputEpoch &+= 1
        surface?.forgetHeldKeys()
        inputRecovery = true; status = "Input paused after queue saturation. Click the desktop to resume."; pumpWriter()
    }
    func captureExplorerDrag(nonce: Data) async throws -> [NativeFileEntry] {
        guard nonce.count == 16, phase == .streaming, let files, !files.isBusy,
              !inputRecovery, !fileUIInputSuspended, videoControl?.blocksInput != true else { throw NativeFileError.busy }
        let run = identity
        // This barrier shares the bounded ordered input queue with the accepted
        // left-down and moves. The file socket alone cannot authorize a drag.
        let hex = NativeFileClient.hex(nonce)
        let result = try await files.captureExplorer(nonce: hex) {
            guard run == identity, phase == .streaming, self.files === files,
                  send(Packet(kind: .explorerDrag, payload: nonce)) else { throw NativeFileError.cancelled }
        }
        guard run == identity, phase == .streaming, self.files === files, !Task.isCancelled else {
            files.cancelExplorer(nonce: hex); throw NativeFileError.closed
        }
        return result
    }
    @discardableResult func sendCommittedText(_ text: String) -> Bool {
        // Empty AppKit commits are a no-op, including while input is paused.
        guard !text.isEmpty else { return true }
        guard phase == .streaming, !inputRecovery, !fileUIInputSuspended, videoControl?.blocksInput != true else { return false }
        let packet: Packet
        do { packet = try Input.text(text) }
        catch {
            // Reject the whole commit rather than silently dropping or splitting
            // it. Revoke queued/held input until an explicit desktop click.
            releaseInput()
            status = "Text was too long or contained unsupported characters. Click the desktop and enter smaller parts."
            return false
        }
        return send(packet)
    }
    /// Menus and presenter keyboard routing share this session-owned boundary.
    /// Preparation occurs even if local clipboard validation rejects the action.
    func performClipboardGesture(paste: Bool, clipboard override: ClipboardModel? = nil) {
        guard let clipboard = override ?? self.clipboard, prepareClipboardGesture() else { return }
        if paste { clipboard.pasteToRemote() } else { clipboard.copyFromRemote() }
    }
    /// A clipboard gesture may fail before any request reaches the host. Queue
    /// an ordered owned-input release before forgetting local modifier state,
    /// independently of validation, empty clipboards or send admission failure.
    /// Preserve an existing focus/recovery pause without pausing normal typing.
    @discardableResult func prepareClipboardGesture() -> Bool {
        guard phase == .streaming, !fileUIInputSuspended, videoControl?.blocksInput != true else { return false }
        acceptedLocalInteraction()
        clipboard?.cancel()
        let wasPaused = inputRecovery
        inputEpoch &+= 1
        do { try input.appendReleaseBarrier() }
        catch {
            inputRecovery = true; surface?.forgetHeldKeys(); pumpWriter()
            status = "Input paused after queue saturation. Click the desktop to resume."
            return false
        }
        if !wasPaused { input.recover() }
        surface?.forgetHeldKeys()
        pumpWriter()
        return true
    }
    func releaseInput() {
        clipboard?.cancel()
        guard active else { return }
        inputEpoch &+= 1
        input.revoke(); inputRecovery = true; surface?.forgetHeldKeys(); pumpWriter()
        if phase == .streaming {
            if displayBehind { updateStreamingStatus() }
            else { status = "Input paused. Click the desktop to resume." }
        }
    }
    func recoverInput() {
        guard !fileUIInputSuspended else { return }
        guard phase == .streaming else { return }
        acceptedLocalInteraction()
        // The gesture that resumes video is consumed locally, never replayed.
        guard videoControl?.blocksInput != true else { return }
        input.recover(); inputRecovery = false
        updateStreamingStatus()
    }
    func setFileUIInputSuspended(_ suspended: Bool) {
        fileUIInputSuspended = suspended
        if suspended { acceptedLocalInteraction(); releaseInput() }
    }
    private func pumpWriter() {
        guard !writerBusy, let channel, [.approval, .decoding, .streaming].contains(phase) else { return }
        writerBusy = true
        let id = identity
        writer = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled, self.identity == id {
                    guard self.input.count > 0 || ContinuousClock.now - self.lastHeartbeat >= .seconds(2) else { break }
                    let epoch = self.inputEpoch
                    // The default scheduler returns immediately for an elapsed
                    // deadline. Always cross this seam so an injected barrier
                    // cannot disappear when a busy executor misses that window.
                    try await self.waitForInputDeadline(self.nextInput)
                    try Task.checkCancellation()
                    guard self.identity == id else { return }
                    guard self.inputEpoch == epoch else { continue }
                    // Select after pacing so moves received during the wait can
                    // coalesce to the newest position without crossing barriers.
                    let packet: Packet
                    if ContinuousClock.now - self.lastHeartbeat >= .seconds(2) { packet = Packet(kind: .heartbeat) }
                    else if let pending = self.input.pop() { packet = pending }
                    else { break }
                    if packet.kind == .videoControl {
                        guard let packetReader = self.packetReader else { throw NativeFailure.state }
                        try await packetReader.expectVideoControl(VideoControlRequest(packet.payload))
                        guard self.identity == id, !Task.isCancelled else { return }
                    }
                    try await channel.send(packet)
                    guard self.identity == id, !Task.isCancelled else { return }
                    if packet.kind == .heartbeat { self.lastHeartbeat = .now }
                    self.nextInput = .now + .milliseconds(2) // <=500 input envelopes/second
                }
                if self.identity == id { self.writerBusy = false }
            } catch { if self.identity == id { self.transportFailed(reason: .writeTransport) } }
        }
    }
    func disconnect() {
        let registered = selectedTrustedDevice != nil
        reconnectTask?.cancel(); reconnectTask = nil; reconnectAttempt = 0
        close(message: registered ? "연결을 종료했어요. 등록된 PC를 선택하거나 새 번호로 연결하세요." :
            "Disconnected. Reconnect with a fresh invitation.", failed: false)
        selectedTrustedDevice = nil
    }
    private func fail(_ message: String) { close(message: message, failed: true) }
    private func close(message: String, failed: Bool, numberConnection: Bool? = nil, retainingActivity: Bool = false) {
        if let numberConnection { reconnectMethod = numberConnection ? .number : .invitation }
        else if active { reconnectMethod = selectedTrustedDevice != nil ? .registered : numberAuthorized ? .number : .invitation }
        identity = UUID(); inputEpoch &+= 1
        clearAutomaticRecovery()
        trustedTask?.cancel(); trustedTask = nil; trustedClient?.close(); trustedClient = nil
        registrationTask?.cancel(); registrationTask = nil; pendingRegistration = nil
        clipboard?.cancel(); clipboard = nil; quality = nil
        videoControl?.cancel(); videoControl = nil; videoControlObservation = nil
        packetReader = nil; videoEpoch = 0; videoIdle.reset(now: .now)
        audio?.onChange = nil; audio?.stop(); audio = nil
        files?.close(); files = nil
        fileUIInputSuspended = false
        input = InputBuffer()
        ticker?.cancel(); reader?.cancel(); writer?.cancel()
        ticker = nil; reader = nil; writer = nil; writerBusy = false
        // Revocation closes TLS synchronously, including an in-flight Hello or
        // blocked input write. Host EOF cleanup releases accepted input. Waiting
        // to send a final packet could otherwise keep a revoked session alive.
        channel?.close(); channel = nil
        decoder?.stop(); decoder = nil; surface?.onFailure = nil; surface?.clear(); surface?.forgetHeldKeys()
        invitation = nil; input = InputBuffer(); inputRecovery = false
        showFullscreenControls = false
        numberAuthorized = false
        presentationBackpressureSince = nil; displayBehind = false; receiverPressure.reset()
        phase = failed ? .failed : .idle; status = message
        if !retainingActivity { endConnectionActivity() }
    }
}
