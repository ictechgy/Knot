import Foundation
import Combine
import CoreVideo
import KnotNativeCore

@MainActor
final class SessionModel: ObservableObject {
    enum Phase: Equatable { case idle, connecting, approval, decoding, streaming, failed }
    enum ReconnectMethod: Equatable { case number, invitation }
    @Published var phase: Phase = .idle
    @Published var status = "Paste a fresh invitation, review its target and certificate, then connect."
    @Published var invitation: Invitation?
    @Published var videoSize = CGSize(width: 1920, height: 1080)
    @Published var inputRecovery = false
    @Published var textMode = true
    @Published var macShortcuts = true
    @Published var rememberThisPC = false
    @Published var savedDeviceLabel = "Windows PC"
    @Published var autoReconnect = true
    @Published private(set) var savedDevices: [SavedNativeDevice] = []
    @Published private(set) var clipboard: ClipboardModel?
    @Published private(set) var quality: QualityModel?
    private var selectedTrustedDevice: SavedNativeDevice?
    private var pendingRegistration: Invitation?
    private var trustedClient: (any NativeTrustedConnecting)?
    private var trustedTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    var reconnectAttemptCount: Int { reconnectAttempt }
    var hasPendingReconnect: Bool { reconnectTask != nil }
    private let makeTrustedClient: @Sendable (SavedNativeDevice, String) throws -> any NativeTrustedConnecting
    private let waitForReconnect: @MainActor @Sendable (Duration) async throws -> Void
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
    private var decoder: NativeDecoder?
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
    var active: Bool { [.connecting, .approval, .decoding, .streaming].contains(phase) }

    init(makeChannel: @escaping @Sendable (Invitation) throws -> any NativeChannel = { try TLSChannel(invitation: $0) },
         waitForInputDeadline: @escaping @MainActor @Sendable (ContinuousClock.Instant) async throws -> Void = { try await Task.sleep(until: $0) },
         makeTrustedClient: @escaping @Sendable (SavedNativeDevice, String) throws -> any NativeTrustedConnecting = { try NativeTrustedClient(device: $0, viewerName: $1) },
         waitForReconnect: @escaping @MainActor @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         initialSavedDevices: [SavedNativeDevice] = [], initialRegisteredDevice: SavedNativeDevice? = nil) {
        self.makeChannel = makeChannel
        self.waitForInputDeadline = waitForInputDeadline
        self.makeTrustedClient = makeTrustedClient; self.waitForReconnect = waitForReconnect
        // Explicit fixture inputs; initialization never opens Keychain/network.
        savedDevices = Array(initialSavedDevices.prefix(16))
        selectedTrustedDevice = initialRegisteredDevice
    }

    func prepareForUpdate() {
        if autoReconnect, let device = selectedTrustedDevice {
            let preferences = UserDefaults(suiteName: "io.knot.native-preview")
            preferences?.set(device.id, forKey: "updateResumeDevice")
            preferences?.set(Date().addingTimeInterval(300).timeIntervalSince1970, forKey: "updateResumeExpiry")
        }
        disconnect()
    }
    func resumeAfterUpdateIfRequested() {
        let preferences = UserDefaults(suiteName: "io.knot.native-preview")
        let id = preferences?.string(forKey: "updateResumeDevice")
        let expiry = preferences?.double(forKey: "updateResumeExpiry") ?? 0
        preferences?.removeObject(forKey: "updateResumeDevice")
        preferences?.removeObject(forKey: "updateResumeExpiry")
        guard autoReconnect, let id, expiry > Date().timeIntervalSince1970,
              expiry <= Date().addingTimeInterval(300).timeIntervalSince1970 else { return }
        connectSaved(id)
    }
    func refreshSavedDevices() {
        do { savedDevices = try NativeDeviceKeychain.load() }
        catch { status = "등록된 PC를 읽지 못했어요. 키체인 접근을 확인하세요." }
    }
    func connectSaved(_ id: String) {
        guard !active, let device = savedDevices.first(where: { $0.id == id }) else { return }
        reconnectTask?.cancel(); reconnectTask = nil; reconnectAttempt = 0
        selectedTrustedDevice = device; pendingRegistration = nil
        beginTrustedConnection(device)
    }
    private func beginTrustedConnection(_ device: SavedNativeDevice) {
        guard !active else { return }
        let id = UUID(); identity = id; phase = .connecting
        status = "등록된 PC의 인증서를 확인하고 있어요…"
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
                    if (error as? NativeFailure) == .transport {
                        self.close(message: "등록된 PC에 연결하지 못했어요. Windows에서 공유 중인지 확인하세요.", failed: true)
                        self.scheduleReconnect(device)
                    } else {
                        self.close(message: "등록된 PC의 인증서나 연결 권한을 확인하지 못했어요. Windows의 등록 기기를 확인하고 새 번호로 다시 등록하세요.", failed: true)
                    }
                }
            }
        } catch { close(message: "등록된 PC 정보를 확인하지 못했어요. 다시 등록해주세요.", failed: true) }
    }
    func forgetSaved(_ id: String) {
        guard let device = savedDevices.first(where: { $0.id == id }) else { return }
        // The local credential is removed even when the host is offline. The
        // Windows device list offers independent, immediate server revocation.
        do { try NativeDeviceKeychain.remove(id); savedDevices.removeAll { $0.id == id } }
        catch { status = "키체인에서 PC 등록을 해제하지 못했어요."; return }
        if selectedTrustedDevice?.id == id { disconnect() }
        Task { [weak self, viewerLabel] in
            if let client = try? NativeTrustedClient(device: device, viewerName: viewerLabel) {
                _ = try? await client.connect(revoke: true)
            }
            if self?.selectedTrustedDevice?.id == id { self?.disconnect() }
        }
    }
    private func registerConnectedDevice(_ invitation: Invitation) {
        guard rememberThisPC, numberAuthorized, selectedTrustedDevice == nil else { return }
        pendingRegistration = nil
        do {
            let existing = try NativeDeviceKeychain.load().first { $0.certificateSHA256 == invitation.certificateSHA256 && $0.address == invitation.address }
            let device = try existing ?? NativeTrustedClient.newDevice(invitation: invitation, name: savedDeviceLabel)
            let client = try NativeTrustedClient(device: device, viewerName: viewerLabel)
            let run = identity
            registrationTask = Task { [weak self] in
                do {
                    try await client.register(invitation: invitation)
                    guard let self, self.identity == run, !Task.isCancelled else { return }
                    var devices = try NativeDeviceKeychain.load()
                    devices.removeAll { $0.id == device.id }
                    guard devices.count < 16 else { throw NativeFailure.state }
                    devices.append(device); try NativeDeviceKeychain.save(devices)
                    self.savedDevices = devices; self.selectedTrustedDevice = device; self.registrationTask = nil
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
        guard autoReconnect, !active, selectedTrustedDevice?.id == device.id, reconnectAttempt < 6 else { return }
        let delays: [Int64] = [1, 2, 4, 8, 16, 30]
        let delay = delays[reconnectAttempt]; reconnectAttempt += 1
        status = "연결이 끊겼어요. \(delay)초 후 등록된 PC에 다시 연결해요 (\(reconnectAttempt)/6)."
        let run = identity
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.waitForReconnect(.seconds(delay)) } catch { return }
            guard self.identity == run, !Task.isCancelled, !self.active, self.autoReconnect else { return }
            self.reconnectTask = nil; self.beginTrustedConnection(device)
        }
    }
    private func transportFailed() {
        let device = selectedTrustedDevice
        close(message: device == nil ? "Connection ended or validation failed. Ask the host for a new invitation." : "연결이 끊겼어요. Windows의 공유 상태와 네트워크를 확인하세요.", failed: true)
        if let device { scheduleReconnect(device) }
    }
    func review(_ secret: String) {
        guard !active else { return }
        selectedTrustedDevice = nil; pendingRegistration = nil
        reconnectMethod = .invitation
        numberAuthorized = false
        do { invitation = try Invitation(secret); phase = .idle; status = "Review the private address and exact certificate pin below. Trust lasts for this connection only." }
        catch { invitation = nil; phase = .failed; status = "Invalid invitation. Ask the host to create a fresh native invitation." }
    }
    func connect() {
        guard !active else { return }
        selectedTrustedDevice = nil; pendingRegistration = nil
        reconnectMethod = .invitation
        numberAuthorized = false
        startConnection()
    }
    func connectAuthenticated(_ enrollment: AuthenticatedEnrollment) {
        guard !active else { return }
        guard ContinuousClock.now < enrollment.expiresAt, Invitation.validViewerLabel(enrollment.viewerName) else {
            close(message: "Invitation was rejected or expired. Create a new invitation.", failed: true, numberConnection: true); return
        }
        selectedTrustedDevice = nil; reconnectAttempt = 0
        pendingRegistration = rememberThisPC ? enrollment.offer.invitation : nil
        invitation = enrollment.offer.invitation
        viewerLabel = enrollment.viewerName
        numberAuthorized = true
        startConnection()
    }
    private func startConnection() {
        reconnectTask?.cancel(); reconnectTask = nil
        guard !active, let invitation else { return }
        let label = viewerLabel
        guard Invitation.validViewerLabel(label) else { status = "Choose a viewer label of 1–64 UTF-8 bytes without control characters."; return }
        let id = UUID(); identity = id; phase = .connecting; status = "Verifying the host certificate…"
        input = InputBuffer(); inputRecovery = false
        presentationBackpressureSince = nil; displayBehind = false
        connectedAt = .now; lastIncoming = .now; lastHeartbeat = .now
        reader = Task { [weak self] in
            guard let self, !Task.isCancelled, self.identity == id else { return }
            do {
                let transport = try self.makeChannel(invitation); self.channel = transport
                try await transport.start()
                guard self.identity == id, !Task.isCancelled else { transport.close(); return }
                // This write completes before the sole post-Hello writer starts.
                try await transport.send(invitation.hello(name: label))
                guard self.identity == id, !Task.isCancelled else { transport.close(); return }
                self.invitation = nil // one-use token must not become reusable trust
                self.connectedAt = .now
                self.lastIncoming = .now
                self.phase = .approval
                self.status = self.numberAuthorized ? "Number verified. Preparing the host desktop…" : "Certificate verified. Waiting for host approval and native encoder startup…"
                self.startTicker(id: id)
                let packets = NativePacketReader(channel: transport)
                while !Task.isCancelled, self.identity == id {
                    let budget: Duration = self.phase == .approval ? .seconds(65) : .seconds(10)
                    let incoming = try await packets.next(timeout: budget)
                    guard self.identity == id, !Task.isCancelled else { return }
                    self.lastIncoming = .now
                    switch incoming {
                    case .ready(let ready):
                        if ready.clipboardVersion == 1 {
                            self.clipboard = ClipboardModel(send: { [weak self] packet in self?.sendControl(packet) ?? false })
                        }
                        if ready.qualityVersion == 1 {
                            self.quality = QualityModel(send: { [weak self] packet in self?.sendControl(packet) ?? false })
                        }
                        if let offer = ready.files {
                            self.files = try FileTransferModel(invitation: invitation, offer: offer)
                        }
                        self.videoSize = CGSize(width: ready.width, height: ready.height)
                        let decoder = NativeDecoder(width: ready.width, height: ready.height)
                        decoder.onImage = { [weak self] image in
                            guard let self, self.identity == id else { return }
                            self.presentDecodedImage(image)
                        }
                        decoder.onFailure = { [weak self] in
                            guard let self, self.identity == id else { return }
                            self.fail("The native decoder stopped. Create a new invitation to reconnect.")
                        }
                        self.decoder = decoder; self.phase = .decoding
                        self.armPresentationFailure()
                        self.readyAt = .now
                        self.status = "Host approved and encoder ready. Waiting for the first decoded image…"
                    case .video(let video): try await self.decoder?.decode(video.accessUnit)
                    case .error(let code):
                        self.fail(Self.message(code)); return
                    case .clipboard(let response): self.clipboard?.accept(response)
                    case .quality(let response): self.quality?.accept(response)
                    case .heartbeat: break
                    }
                }
            } catch {
                if self.identity == id {
                    if (error as? NativeFailure) == .transport { self.transportFailed() }
                    else { self.fail(self.selectedTrustedDevice == nil ? "Connection ended or validation failed. Ask the host for a new invitation." : "Connection validation failed. Check the registered PC or create a new invitation.") }
                }
            }
        }
    }
    func presentDecodedImage(_ image: CVPixelBuffer, now: ContinuousClock.Instant = .now) {
        guard [.decoding, .streaming].contains(phase) else { return }
        switch surface?.display(image) ?? .backpressure {
        case .presented:
            let statusChanged = phase != .streaming || displayBehind
            presentationBackpressureSince = nil; displayBehind = false
            if phase != .streaming {
                phase = .streaming
                if selectedTrustedDevice != nil { reconnectAttempt = 0 }
                if let pending = pendingRegistration { registerConnectedDevice(pending) }
            }
            if statusChanged { updateStreamingStatus() }
        case .backpressure:
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
        case "timeout": "The connection timed out. Create a new invitation."
        default: "The host closed the connection. Create a new invitation to reconnect."
        }
    }
    private func startTicker(id: UUID) {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.identity == id, !Task.isCancelled else { return }
                let now = ContinuousClock.now
                guard self.checkDeadlines(now: now) else { return }
                if now - self.lastHeartbeat >= .seconds(2) { self.quality?.reportPressure(self.displayBehind); self.pumpWriter() }
            }
        }
    }
    /// Shared by the real ticker and inert lifecycle tests; host activity cannot
    /// indefinitely extend approval or the first decoded-image deadline.
    func checkDeadlines(now: ContinuousClock.Instant) -> Bool {
        guard active else { return false }
        let silence: Duration = phase == .approval ? .seconds(65) : .seconds(10)
        guard now - lastIncoming < silence, phase != .approval || now - connectedAt < .seconds(125) else {
            if phase == .streaming, selectedTrustedDevice != nil { transportFailed() }
            else { fail("The peer or host approval timed out. Create a new invitation.") }
            return false
        }
        guard phase != .decoding || now - readyAt < .seconds(15) else {
            fail("The first decoded image did not arrive. Create a new invitation."); return false
        }
        return true
    }
    @discardableResult func sendControl(_ packet: Packet) -> Bool {
        guard phase == .streaming, !fileUIInputSuspended else { return false }
        do { try input.append(packet); pumpWriter(); return true }
        catch { return false }
    }
    @discardableResult func send(_ packet: Packet) -> Bool {
        guard phase == .streaming, !inputRecovery, !fileUIInputSuspended else { return false }
        do { try input.append(packet); pumpWriter(); return true }
        catch {
            inputEpoch &+= 1
            surface?.forgetHeldKeys()
            inputRecovery = true; status = "Input paused after queue saturation. Click the desktop to resume."; pumpWriter()
            return false
        }
    }
    func captureExplorerDrag(nonce: Data) async throws -> [NativeFileEntry] {
        guard nonce.count == 16, phase == .streaming, let files, !files.isBusy,
              !inputRecovery, !fileUIInputSuspended else { throw NativeFileError.busy }
        let run = identity
        // This barrier shares the bounded ordered input queue with the accepted
        // left-down and moves. The file socket alone cannot authorize a drag.
        guard send(Packet(kind: .explorerDrag, payload: nonce)) else { throw NativeFileError.cancelled }
        let hex = NativeFileClient.hex(nonce)
        let result = try await files.captureExplorer(nonce: hex)
        guard run == identity, phase == .streaming, self.files === files, !Task.isCancelled else {
            files.cancelExplorer(nonce: hex); throw NativeFileError.closed
        }
        return result
    }
    @discardableResult func sendCommittedText(_ text: String) -> Bool {
        // Empty AppKit commits are a no-op, including while input is paused.
        guard !text.isEmpty else { return true }
        guard phase == .streaming, !inputRecovery, !fileUIInputSuspended else { return false }
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
    /// A clipboard gesture may fail before any request reaches the host. Queue
    /// an ordered owned-input release before forgetting local modifier state,
    /// independently of validation, empty clipboards or send admission failure.
    /// Preserve an existing focus/recovery pause without pausing normal typing.
    @discardableResult func prepareClipboardGesture() -> Bool {
        guard phase == .streaming, !fileUIInputSuspended else { return false }
        clipboard?.cancel()
        let wasPaused = inputRecovery
        inputEpoch &+= 1
        input.revoke()
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
        input.recover(); inputRecovery = false
        updateStreamingStatus()
    }
    func setFileUIInputSuspended(_ suspended: Bool) {
        fileUIInputSuspended = suspended
        if suspended { releaseInput() }
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
                    if ContinuousClock.now < self.nextInput { try await self.waitForInputDeadline(self.nextInput) }
                    try Task.checkCancellation()
                    guard self.identity == id else { return }
                    guard self.inputEpoch == epoch else { continue }
                    // Select after pacing so moves received during the wait can
                    // coalesce to the newest position without crossing barriers.
                    let packet: Packet
                    if ContinuousClock.now - self.lastHeartbeat >= .seconds(2) { packet = Packet(kind: .heartbeat) }
                    else if let pending = self.input.pop() { packet = pending }
                    else { break }
                    try await channel.send(packet)
                    guard self.identity == id, !Task.isCancelled else { return }
                    if packet.kind == .heartbeat { self.lastHeartbeat = .now }
                    self.nextInput = .now + .milliseconds(2) // <=500 input envelopes/second
                }
                if self.identity == id { self.writerBusy = false }
            } catch { if self.identity == id { self.transportFailed() } }
        }
    }
    func disconnect() {
        let registered = selectedTrustedDevice != nil
        reconnectTask?.cancel(); reconnectTask = nil; selectedTrustedDevice = nil; reconnectAttempt = 0
        close(message: registered ? "연결을 종료했어요. 등록된 PC를 선택하거나 새 번호로 연결하세요." :
            "Disconnected. Reconnect with a fresh invitation.", failed: false)
    }
    private func fail(_ message: String) { close(message: message, failed: true) }
    private func close(message: String, failed: Bool, numberConnection: Bool? = nil) {
        if let numberConnection { reconnectMethod = numberConnection ? .number : .invitation }
        else if active { reconnectMethod = numberAuthorized ? .number : .invitation }
        identity = UUID(); inputEpoch &+= 1
        reconnectTask?.cancel(); reconnectTask = nil
        trustedTask?.cancel(); trustedTask = nil; trustedClient?.close(); trustedClient = nil
        registrationTask?.cancel(); registrationTask = nil; pendingRegistration = nil
        clipboard?.cancel(); clipboard = nil; quality = nil
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
        presentationBackpressureSince = nil; displayBehind = false
        phase = failed ? .failed : .idle; status = message
    }
}
