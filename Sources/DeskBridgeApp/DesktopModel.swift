// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 DeskBridge contributors
import AppKit
import Combine
import DeskBridgeCore
import Foundation
import GlimmerEngine

/// App-owned operations keep the engine's cached-session API intact. Synthetic
/// model checks replace these operations without creating a transport or window.
@MainActor
struct DesktopOperations {
    var fetchServerInfo: @MainActor (NetworkClient, String?) async throws -> ServerInfo
    var appList: @MainActor (NetworkClient) async throws -> [HostApp]
    var openStream: @MainActor (DesktopStreamController, NetworkClient, ServerInfo, String, StreamConfiguration) async throws -> Void

    static let live = DesktopOperations(
        fetchServerInfo: { try await $0.fetchServerInfo(requiredUniqueId: $1, timeout: 5, diagnosePinnedFailure: false) },
        appList: { try await $0.appList() },
        openStream: { try await $0.open(network: $1, server: $2, appID: $3, configuration: $4) })
}

@MainActor
final class DesktopModel: ObservableObject {
    @Published var address = "" {
        didSet {
            guard address != oldValue else { return }
            if let previous = try? EndpointPolicy.validatedAddress(oldValue),
               previous == (try? EndpointPolicy.validatedAddress(address)) { return }
            let hadVerifiedTarget = paired || !serverName.isEmpty || settings.host != nil
            invalidateTarget(cancelOperation: true)
            if hadVerifiedTarget { status = "대상 PC가 바뀌었습니다. PC 확인을 다시 하세요." }
            if streaming { Task { await stream.disconnect() } }
        }
    }
    @Published var status = "근처 PC를 선택하거나 Windows의 연결 QR을 가져오세요."
    @Published var pendingInvitation: ConnectionInvitation?
    @Published var errorMessage: String?
    @Published var invitationError: String?
    @Published var busy = false { didSet { peerDesktop?.objectWillChange.send() } }
    @Published var streaming = false
    @Published var serverName = ""
    @Published var pairingPIN: String?
    @Published var apps: [HostApp] = []
    @Published var paired = false
    @Published var fingerprint = ""
    @Published var resolution = 1080
    @Published var frameRate = 60
    @Published var bitrateKbps = 0
    @Published var keyboardMode: DesktopKeyboardMode = .localIME {
        didSet { stream.keyboardMode = keyboardMode }
    }
    @Published private(set) var settings: SavedSettings
    var canForgetHost: Bool { !enrollmentEngaged && !KnotUpdates.shared.installationPending && !shuttingDown && settingsReadable && settings.host != nil && !busy && !streaming && !stream.isEngaged }
    let platform: HostPlatform
    var supportsFiles: Bool { platform == .windows }
    var platformName: String { platform.displayName }
    var pairingTitle: String {
        platform == .windows ? "Windows Knot 창에서 PIN을 승인하세요" : "\(platformName) 브라우저의 Sunshine PIN 페이지에 입력하세요"
    }
    var pairingGuidance: String {
        platform == .windows
            ? "Windows Knot의 ‘연결 준비 · 자동 설정’ 창에서 계정 확인을 마친 뒤 요청한 Mac을 선택하고 위 번호를 승인하세요. 보안 설정 적용으로 Sunshine이 재시작됐다면 Mac에서 취소한 뒤 새 PIN을 만드세요. 수동 설정은 Windows 브라우저의 https://localhost:47990/pin 입니다."
            : "\(platformName)에서 https://localhost:47990/pin 을 열고 위 번호를 입력하세요. Sunshine은 별도 창 없이 백그라운드에서 실행될 수 있습니다."
    }
    weak var peerDesktop: DesktopModel?
    var enrollmentEngaged: Bool { fileActivity?.enrollmentActive == true || peerDesktop?.fileActivity?.enrollmentActive == true }
    var peerEngaged: Bool { peerDesktop.map { $0.busy || $0.stream.isEngaged || $0.fileActivity?.enrollmentActive == true } ?? false }
    let store: SettingsStore
    private let identity: IdentityManager
    private let operations: DesktopOperations
    private var network: NetworkClient?
    private var server: ServerInfo?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var settingsReadable = true
    private var storageReadFailure: String?
    private var shuttingDown = false
    private var targetBinding = TargetBinding()
    let stream: DesktopStreamController
    let nearby = NearbyPCBrowser()
    weak var fileActivity: FilesModel?
    var canChoosePC: Bool { !KnotUpdates.shared.installationPending && !shuttingDown && settingsReadable && !busy && !streaming && !stream.isEngaged && !peerEngaged && fileActivity?.enrollmentModalActive != true && fileActivity?.busy != true && fileActivity?.connected != true }
    var canVerifyCurrentPC: Bool {
        guard !enrollmentEngaged, !KnotUpdates.shared.installationPending, !shuttingDown, settingsReadable, !busy, !streaming, !stream.isEngaged, !peerEngaged, fileActivity?.busy != true else { return false }
        guard fileActivity?.connected == true else { return true }
        guard let checked = try? EndpointPolicy.validatedAddress(address) else { return false }
        return fileActivity?.isConnected(toValidatedAddress: checked) == true
    }

    /// A host name is display metadata, never the identity or certificate pin.
    /// Bound both work and UTF-8 storage before publishing untrusted server text.
    static func displayName(_ input: String, fallback: String) -> String {
        var result = "", bytes = 0
        for scalar in input.unicodeScalars.prefix(256) {
            guard scalar.properties.generalCategory != .control,
                  scalar.properties.generalCategory != .format else { continue }
            let value = String(scalar)
            guard bytes + value.utf8.count <= 256 else { break }
            result.append(value); bytes += value.utf8.count
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    init(storageDirectory: URL? = nil, identitySuite: String? = nil, platform: HostPlatform = .windows,
         operations: DesktopOperations = .live, streamController: DesktopStreamController? = nil) {
        self.operations = operations
        self.platform = platform
        self.stream = streamController ?? DesktopStreamController()
        let base = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(platform == .linux ? "DeskBridgeLinux" : "DeskBridge", isDirectory: true)
        store = SettingsStore(directory: base)
        // This application owns a separate identity. Never import another app's preferences/identity.
        identity = IdentityManager(defaultsSuite: identitySuite ?? (platform == .linux ? "org.deskbridge.app.linux.identity" : "org.deskbridge.app.identity"), supportBase: base,
                                   protectedDataAvailable: { true })
        do { settings = try store.load() }
        catch {
            settings = SavedSettings(); settingsReadable = false
            let message = error is CorePrivateStorageFailure
                ? error.localizedDescription + " 저장된 인증 정보를 자동으로 대체하지 않습니다. 확인한 뒤 앱을 다시 여세요."
                : "설정을 읽지 못했습니다. 저장된 인증 정보를 자동으로 대체하지 않습니다. 기존 설정을 보존하고 파일 형식·크기와 저장 폴더의 접근 권한을 확인한 뒤 앱을 다시 여세요."
            storageReadFailure = message; errorMessage = message
        }
        status = "근처 PC를 선택하거나 \(platform.displayName)의 연결 QR을 가져오세요."
        address = settings.address
        stream.onEngagementChanged = { [weak self] in
            self?.objectWillChange.send(); self?.peerDesktop?.objectWillChange.send()
        }
        stream.onStatus = { [weak self] value in self?.status = value }
        stream.onConnectionChanged = { [weak self] value in self?.streaming = value }
    }

    func saveFileSettings(username: String, port: UInt16, hostKey: String, identityPath: String,
                          address nextAddress: String? = nil) throws {
        try assertFileCapability()
        try assertStorageReady()
        var next = settings
        next.address = try EndpointPolicy.validatedAddress(nextAddress ?? address)
        if next.address != (try? EndpointPolicy.validatedAddress(address)), !canChoosePC {
            throw AppFailure("화면·파일 연결과 정리를 마친 뒤 대상 PC를 바꾸세요.")
        }
        next.sshUsername = username; next.sshPort = port
        next.sshHostPublicKey = hostKey; next.sshIdentityPath = identityPath
        try store.save(next)
        settings = next
        address = next.address
    }
    func rememberFileIdentity(path: String) throws {
        try assertFileCapability()
        try assertStorageReady()
        var next = settings; next.sshIdentityPath = path
        try store.save(next); settings = next
    }
    func assertFileCapability() throws {
        guard supportsFiles else { throw AppFailure("Linux 연결은 화면만 지원합니다. 파일 기능은 Windows 연결에서 사용하세요.") }
    }
    func perform(allowCleanup: Bool = false, _ body: @escaping @MainActor () async throws -> Void) {
        guard !shuttingDown else { return }
        guard allowCleanup || !KnotUpdates.shared.installationPending else {
            errorMessage = "업데이트 설치를 기다리고 있습니다. 연결을 마친 뒤 앱을 다시 여세요."; return
        }
        guard allowCleanup || !enrollmentEngaged else {
            errorMessage = "자동 파일 설정을 마치거나 취소한 뒤 화면 작업을 시작하세요."; return
        }
        guard !busy else { errorMessage = "현재 작업을 마친 뒤 다시 시도하세요."; return }
        guard allowCleanup || !peerEngaged else { errorMessage = "다른 PC의 화면 작업을 마친 뒤 다시 시도하세요."; return }
        errorMessage = nil; busy = true
        let current = UUID(); generation = current
        operation = Task { [weak self] in
            do { try self?.assertStorageReady(); try await body() }
            catch is CancellationError { self?.status = "취소했습니다." }
            catch { self?.errorMessage = Self.failureMessage(error, platform: self?.platform ?? .windows).replacingOccurrences(of: "Windows", with: self?.platformName ?? "PC"); self?.status = "작업을 완료하지 못했습니다." }
            guard self?.generation == current else { return }
            self?.pairingPIN = nil; self?.busy = false; self?.operation = nil
        }
    }
    func cancelOperation() { operation?.cancel(); pairingPIN = nil }
    func beginShutdown() {
        shuttingDown = true
        nearby.stop(); cancelOperation()
    }
    nonisolated static func failureMessage(_ error: any Error, platform: HostPlatform = .windows) -> String {
        if let invitation = error as? ConnectionInvitation.Failure {
            return invitation.localizedDescription
        }
        if let storage = error as? CorePrivateStorageFailure {
            return storage.localizedDescription
        }
        if let storage = error as? IdentityStorageError {
            switch storage {
            case .unsafeStorage:
                return CorePrivateStorageFailure.unsafeStorage.localizedDescription
            case .incompleteIdentity:
                return "이 Mac의 연결 인증 파일이 없거나 일부가 누락되었습니다. 기존 파일을 보존하고 같은 백업의 인증 파일 전체를 복원한 뒤 다시 시도하세요. 백업이 없다면 이 버전에서는 연결 인증을 초기화할 수 없습니다. 대상 PC에서 이 Mac의 연결 권한을 취소한 뒤 설치 안내의 인증 파일 복구 항목을 확인하세요."
            default: break
            }
        }
        if let failure = error as? StreamSecurityPolicy.Failure {
            return securityNegotiationMessage(failure)
        }
        if let pairing = error as? PairingFailure {
            switch pairing {
            case .invalidAddress: return "Windows의 LAN 또는 Tailscale IPv4 주소를 확인하세요."
            case .unreachable: return "Windows와 Sunshine의 실행 상태와 네트워크 연결을 확인한 뒤 PC 확인을 다시 선택하세요."
            case .gameStream: return "지원되는 Sunshine 호스트를 설치하고 다시 연결하세요."
            case .timedOut:
                return platform == .windows
                    ? "PIN 입력 시간이 지났습니다. Mac에서 PIN 연결을 다시 시작한 뒤 Windows Knot의 연결 준비 창에서 '요청 새로고침'을 누르고 요청한 Mac과 새 PIN을 승인하세요."
                    : "PIN 입력 시간이 지났습니다. \(platform.displayName) 브라우저의 Sunshine PIN 페이지를 열고 PIN 연결을 다시 시작하세요."
            case .busy: return "Sunshine에서 다른 PIN 연결을 진행 중입니다. 해당 작업을 마친 뒤 다시 시도하세요."
            case .rejected:
                return platform == .windows
                    ? "Sunshine에서 PIN 연결을 승인하지 않았습니다. 올바른 Windows Knot의 연결 준비 창인지 확인하고 Mac에서 새 PIN으로 다시 시도하세요. Windows의 '요청 새로고침'에서 요청한 Mac을 선택해 승인하세요."
                    : "Sunshine에서 PIN 연결을 승인하지 않았습니다. 올바른 \(platform.displayName) 브라우저의 PIN 페이지인지 확인하고 새 PIN으로 다시 시도하세요."
            }
        }
        switch error as? StreamError {
        case .hostCertChanged:
            return "저장된 Windows PC의 인증서와 다릅니다. 주소와 PC를 직접 확인하세요. PC를 새로 설정했다면 저장된 PC 인증서를 명시적으로 삭제한 뒤 새 PIN으로 페어링하세요."
        case .sunshineNeedsRestart:
            return "Sunshine의 보안 연결에 응답이 없습니다. Windows에서 Sunshine을 다시 시작한 뒤 PC 확인을 다시 선택하세요. 저장된 인증서는 유지됩니다."
        case .pairingFailed, .pairingRejected:
            return "Windows의 연결 권한과 PIN을 확인하세요. PC를 재설정했다면 연결 정보에서 저장된 PC 인증서를 직접 확인·재설정한 뒤 새 PIN으로 연결하세요."
        case .hostUnreachable, .hostTimedOut, .truncatedRead:
            return "Windows와 Sunshine의 실행 상태, LAN·Tailscale 주소와 방화벽을 확인하세요. 저장된 PC라면 Sunshine의 이 Mac 연결 권한도 확인하세요. 인증서는 자동으로 교체하지 않습니다."
        case .gameStreamHost:
            return "지원되는 Sunshine 호스트를 설치하고 PC 확인을 다시 선택하세요."
        case .hostRefused, .launchFailed:
            return "Sunshine에서 Desktop을 열지 못했습니다. Windows의 Sunshine 앱 목록과 실행 상태를 확인하세요."
        case .streamPortsBlocked:
            return "화면 연결에 필요한 통신이 차단됐습니다. Windows 방화벽과 Wi-Fi·Tailscale 연결을 확인하세요."
        case .sessionFailed, .binaryNotFound:
            return "화면 연결을 시작하지 못했습니다. Sunshine을 다시 시작한 뒤 PC를 다시 확인하세요."
        case .decoderFailed:
            return "화면을 표시하지 못했습니다. 화면 연결을 끊고 해상도를 낮춰 다시 연결하세요."
        case .audioFailed:
            return "오디오를 사용할 수 없습니다. Mac과 PC의 오디오 장치·네트워크를 확인한 뒤 다시 연결하세요."
        case .securityNegotiation(let failure):
            return securityNegotiationMessage(failure)
        case .crypto:
            return DesktopSecurityGuidance.unclassified
        default:
            if let local = error as? AppFailure { return local.message }
            if let storage = error as? SettingsStore.Failure { return storage.localizedDescription }
            if error is EndpointPolicy.Failure { return "Windows의 LAN 또는 Tailscale IPv4 주소를 확인하세요." }
            if error is TargetBinding.Failure { return "대상 PC가 바뀌었습니다. 주소를 확인한 뒤 PC 확인을 다시 선택하세요." }
            return "작업을 완료하지 못했습니다. PC 주소와 Sunshine 실행 상태를 확인한 뒤 다시 시도하세요."
        }
    }
    nonisolated static func securityNegotiationMessage(_ failure: StreamSecurityPolicy.Failure) -> String {
        DesktopSecurityGuidance.negotiation(failure)
    }
    func assertStorageReady() throws {
        guard !shuttingDown else { throw AppFailure("앱을 종료하는 중입니다. 새 연결과 설정 변경을 시작하지 않습니다.") }
        guard settingsReadable else { throw AppFailure(storageReadFailure ?? "기존 설정을 읽을 수 없어 연결과 저장을 중단했습니다. 기존 인증 정보를 보존하고 저장 폴더의 접근 권한을 확인한 뒤 앱을 다시 여세요.") }
    }
    func startNearbySearch() {
        guard canChoosePC else { return }
        nearby.start()
    }
    func reviewInvitation(_ invitation: ConnectionInvitation) throws {
        try assertStorageReady()
        guard canChoosePC else { throw AppFailure("화면·파일 연결을 마친 뒤 PC 연결 정보를 가져오세요.") }
        guard invitation.platform == platform || (invitation.platform == nil && platform == .windows) else {
            if invitation.platform == .macos {
                throw AppFailure("이 QR·링크는 Windows의 Knot에서 ‘Mac 화면 열기’로 가져오세요. Mac 앱에서는 Windows·Linux 호스트의 화면에 연결할 수 있습니다.")
            }
            let target = invitation.platform == .linux ? "Linux 화면" : "Windows 화면"
            throw AppFailure("이 QR·링크는 ‘\(target)’ 탭에서 가져오세요. 표시된 대상 OS는 아직 확인되지 않았습니다.")
        }
        pendingInvitation = invitation
        invitationError = nil
    }
    /// Chooses an endpoint only. A caller must explicitly request ordinary PC
    /// verification afterwards; discovery/QR never imports or replaces trust.
    func selectCandidateAddress(_ input: String) throws {
        try assertStorageReady()
        guard canChoosePC else { throw AppFailure("진행 중인 화면·파일 연결을 마친 뒤 PC를 선택하세요.") }
        let checked = try EndpointPolicy.validatedAddress(input)
        nearby.stop()
        address = checked
        pendingInvitation = nil
        invitationError = nil
        errorMessage = nil
    }
    private func invalidateTarget(cancelOperation: Bool) {
        targetBinding.invalidate()
        server = nil; network = nil; paired = false; apps = []
        fingerprint = ""; serverName = ""; pairingPIN = nil
        if cancelOperation { operation?.cancel() }
    }

    func connect() {
        guard settingsReadable else {
            errorMessage = storageReadFailure ?? CorePrivateStorageFailure.unsafeStorage.localizedDescription
            return
        }
        guard canVerifyCurrentPC else {
            errorMessage = "화면·파일 작업을 마친 뒤 PC를 다시 확인하세요. 파일 연결 중에는 같은 주소의 PC만 확인할 수 있습니다."
            return
        }
        perform { [self] in
            guard !streaming else { throw AppFailure("먼저 현재 화면 연결을 끊으세요.") }
            invalidateTarget(cancelOperation: false)
            let attempt = try targetBinding.begin(input: address)
            defer { targetBinding.failed(attempt) }
            let host = attempt.address
            // A new LAN/Tailscale address does not authorize replacing this single PC's identity.
            let saved = settings.host
            var initial = ServerInfo(address: host, uniqueId: saved?.uniqueID ?? "", serverName: Self.displayName(saved?.name ?? host, fallback: host))
            if let saved {
                initial.serverCertPEM = saved.certificatePEM
                initial.httpPort = saved.httpPort; initial.httpsPort = saved.httpsPort
            }
            let client = NetworkClient(server: initial, identity: identity, deviceName: "Knot")
            status = saved == nil ? "PC를 확인하는 중…" : "저장된 인증서로 PC를 확인하는 중…"
            var verified = try await operations.fetchServerInfo(client, saved?.uniqueID)
            try Task.checkCancellation()
            guard !verified.uniqueId.isEmpty, verified.uniqueId.utf8.count <= 128, !verified.isRealGFE
            else { throw AppFailure("지원되는 Sunshine 호스트를 확인하지 못했습니다.") }
            guard verified.address == host else { throw TargetBinding.Failure.changed }
            verified.serverName = Self.displayName(verified.serverName, fallback: host)
            try targetBinding.accept(attempt, currentInput: address)
            if settings.address != host || (settings.host != nil && settings.host?.address != host) {
                settings = try store.updating(settings) {
                    $0.address = host
                    $0.host?.address = host
                }
            }
            server = verified; network = client; serverName = verified.serverName
            paired = verified.serverCertPEM != nil && verified.pairStatus == .paired
            fingerprint = verified.serverCertPEM.flatMap(CertFingerprint.sha256(forPEM:)) ?? ""
            apps = []
            if paired { try await loadApps() }
            else {
                status = saved == nil ? "PC를 찾았습니다. PIN으로 이 Mac을 연결하세요."
                    : "대상 PC에서 이 Mac의 연결 권한을 확인하세요. 다시 페어링하려면 연결 정보에서 저장된 PC 인증서를 명시적으로 재설정하세요."
            }
        }
    }
    func pair() {
        perform { [self] in
            guard settings.host == nil else {
                throw AppFailure("저장된 PC의 인증서를 먼저 삭제한 뒤 새 PIN으로 페어링하세요. 주소가 바뀐 같은 PC는 PC 확인을 선택하세요.")
            }
            guard let server, let network, server.serverCertPEM == nil else {
                throw AppFailure("먼저 PC를 확인하세요. 기존 인증서가 있는 PC는 자동으로 다시 신뢰하지 않습니다.")
            }
            try targetBinding.require(input: address, expectedAddress: server.address)
            let pin = String(format: "%04d", Int.random(in: 0...9999))
            pairingPIN = pin
            status = pairingGuidance
            var result = try await PairingClient(network: network, server: server).pair(pin: pin, expectedUniqueId: server.uniqueId)
            try Task.checkCancellation()
            try targetBinding.require(input: address, expectedAddress: server.address)
            guard let cert = result.serverCertPEM, let fp = CertFingerprint.sha256(forPEM: cert),
                  result.uniqueId == server.uniqueId, result.pairStatus == .paired
            else { throw AppFailure("인증된 페어링 결과를 확인하지 못했습니다.") }
            result.serverName = Self.displayName(result.serverName, fallback: server.address)
            settings = try store.updating(settings) {
                $0.host = SavedHost(address: result.address, uniqueID: result.uniqueId, name: result.serverName,
                                   certificatePEM: cert, httpPort: result.httpPort, httpsPort: result.httpsPort)
            }
            self.server = result; paired = true; fingerprint = fp; pairingPIN = nil
            try await loadApps()
        }
    }
    private func loadApps() async throws {
        guard let network, let server else { throw AppFailure("PC에 먼저 연결하세요.") }
        try targetBinding.require(input: address, expectedAddress: server.address)
        let listed = try await operations.appList(network)
        try Task.checkCancellation()
        try targetBinding.require(input: address, expectedAddress: server.address)
        apps = listed.filter { !$0.hidden }
        status = apps.isEmpty ? "Sunshine에서 Desktop 앱을 추가한 뒤 다시 연결하세요." : "연결할 Desktop 또는 앱을 선택하세요."
    }
    func start(_ app: HostApp) {
        guard !enrollmentEngaged else { errorMessage = "자동 파일 설정을 마치거나 취소한 뒤 화면 작업을 시작하세요."; return }
        guard !stream.isEngaged, !peerEngaged else { errorMessage = "현재 PC의 화면 연결과 정리를 마친 뒤 다른 화면을 여세요."; return }
        let requestedResolution = resolution, requestedFrameRate = frameRate, requestedBitrate = bitrateKbps
        perform { [self] in
            guard paired, let network, let server else { throw AppFailure("먼저 PC를 페어링하세요.") }
            let video = try DesktopVideoPolicy(resolution: requestedResolution,
                frameRate: requestedFrameRate, bitrateKbps: requestedBitrate)
            try targetBinding.require(input: address, expectedAddress: server.address)
            // Disconnect leaves the Windows application running. Refresh occupancy
            // through the existing certificate pin before choosing launch vs resume.
            status = "저장된 인증서로 \(platformName) 실행 상태를 확인하는 중…"
            var refreshed = try await operations.fetchServerInfo(network, server.uniqueId)
            try Task.checkCancellation()
            try targetBinding.require(input: address, expectedAddress: server.address)
            guard refreshed.address == server.address, refreshed.uniqueId == server.uniqueId,
                  refreshed.serverCertPEM != nil, refreshed.serverCertPEM == server.serverCertPEM,
                  refreshed.pairStatus == .paired, !refreshed.isRealGFE else {
                throw AppFailure("저장된 PC의 연결 권한을 확인하지 못했습니다. PC 확인을 다시 선택하세요.")
            }
            refreshed.serverName = Self.displayName(refreshed.serverName, fallback: server.address)
            self.server = refreshed
            let config = StreamConfiguration(width: video.width, height: video.height, fps: video.frameRate,
                                             bitrateKbps: video.bitrateKbps,
                                             remote: refreshed.address.hasPrefix("100."))
            do {
                try await operations.openStream(stream, network, refreshed, String(app.id), config)
                try Task.checkCancellation()
                try targetBinding.require(input: address, expectedAddress: server.address)
            } catch {
                await stream.disconnect()
                throw error
            }
        }
    }
    func disconnect() {
        perform(allowCleanup: true) { [self] in
            await stream.disconnect()
            streaming = false
            status = "화면 연결을 끊었습니다. \(platformName) 앱은 계속 실행됩니다."
        }
    }
    /// Only an already authenticated target can be restored after an actual
    /// newer build starts. The normal connect path still verifies its saved pin.
    func prepareUpdateReconnect(build: String, now: Date = Date()) throws {
        guard settingsReadable else { return }
        let receipt = UpdateReconnectStore(directory: store.directory)
        try receipt.clear()
        guard paired, !busy, let host = settings.host,
              host.address == address, let digest = CertFingerprint.sha256(forPEM: host.certificatePEM),
              let intent = UpdateReconnectIntent(endpoint: address, hostUniqueID: host.uniqueID,
                  certificateSHA256: digest.replacingOccurrences(of: ":", with: ""), now: now) else { return }
        try receipt.save(intent, previousBuild: build)
    }
    func consumeUpdateReconnect(build: String, now: Date = Date()) throws -> Bool {
        guard settingsReadable else { return false }
        let receipt = UpdateReconnectStore(directory: store.directory)
        let host = settings.host
        let intent = try receipt.consume(currentBuild: build, endpoint: address, hostUniqueID: host?.uniqueID ?? "",
            certificateSHA256: host.flatMap { CertFingerprint.sha256(forPEM: $0.certificatePEM) }?.replacingOccurrences(of: ":", with: "") ?? "", now: now)
        return intent != nil
    }
    func forgetHost() {
        guard canForgetHost else { return }
        do {
            try assertStorageReady()
            var next = settings
            next.host = nil
            try store.save(next)
            settings = next
            invalidateTarget(cancelOperation: false)
            errorMessage = nil
            status = "이 Mac의 저장된 PC 인증서를 삭제했습니다. 대상 PC에서도 연결 권한을 취소할 수 있습니다."
        } catch {
            errorMessage = (error as? AppFailure)?.message ?? "저장된 PC 인증서를 삭제하지 못했습니다. 설정 파일의 접근 권한을 확인한 뒤 다시 시도하세요."
        }
    }
}
struct AppFailure: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

