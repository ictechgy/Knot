// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import DeskBridgeCore
import Foundation

@MainActor struct MacHostOperations {
    var installed: () -> Bool
    var addresses: () -> [MacHostAddress]
    var start: (String, String, String) async throws -> any MacHostOwnedProcess
    var download: (URL) async throws -> Void
    static var live: Self { .init(installed: MacHostRuntime.installed, addresses: MacHostRuntime.addresses,
                                  start: MacHostRuntime.start, download: MacHostRuntime.download) }
}

@MainActor final class MacHostModel: ObservableObject {
    enum Phase: Equatable { case stopped, starting, running, stopping }
    @Published private(set) var phase: Phase = .stopped
    @Published private(set) var shuttingDown = false
    @Published private(set) var terminationAdmissionPaused = false
    var activityAllowed: Bool { !terminationAdmissionPaused && !KnotUpdates.shared.installationPending && !shuttingDown }
    @Published private(set) var installed = false
    @Published private(set) var addresses: [MacHostAddress] = []
    @Published var selectedAddress = ""
    @Published var acknowledged = false
    @Published private(set) var downloading = false
    @Published private(set) var downloadedURL: URL?
    @Published private(set) var status = "공유 꺼짐 · Windows에서 이 Mac을 제어하려면 직접 시작하세요."
    @Published var errorMessage: String?
    @Published var adminName = "deskbridge"
    @Published var adminPassword = ""
    let name = "Knot Mac"
    private let operations: MacHostOperations
    private var process: (any MacHostOwnedProcess)?
    private var task: Task<Void, Never>?
    private var forcedStop: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private let activation = DesktopNotificationListener()
    init(operations: MacHostOperations = .live, activationCenter: NotificationCenter = .default) {
        self.operations = operations
        activation.install(center: activationCenter, name: NSApplication.didBecomeActiveNotification, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshInstallation() }
        }
    }
    var busy: Bool { phase == .starting || phase == .stopping }
    var canDownload: Bool { activityAllowed && phase == .stopped && !downloading }
    var canStart: Bool { activityAllowed && phase == .stopped && !downloading && acknowledged }
    var invitation: ConnectionInvitation? {
        guard phase == .running, addresses.contains(where: { $0.address == selectedAddress }) else { return nil }
        return try? ConnectionInvitation(name: name, addresses: [selectedAddress], platform: .macos)
    }
    func refresh() {
        guard activityAllowed else { return }
        refreshInstallation()
        addresses = MacHostAddress.selected(operations.addresses())
        if !addresses.contains(where: { $0.address == selectedAddress }) { selectedAddress = addresses.first?.address ?? "" }
    }
    /// Returning from Finder must refresh installation without replacing a running share's status or address.
    private func refreshInstallation() {
        guard activityAllowed else { return }
        installed = operations.installed()
    }
    func start() {
        guard canStart else { return }
        guard addresses.contains(where: { $0.address == selectedAddress }) else {
            errorMessage = "사용할 LAN 또는 Tailscale IPv4 주소를 선택하세요. 네트워크가 연결된 뒤 주소를 새로 고치세요."; return
        }
        errorMessage = nil; phase = .starting; status = "공유 프로세스 시작 중…"
        let username = adminName, password = adminPassword
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            do {
                let child = try await operations.start(name, username, password)
                adminPassword = ""
                process = child
                child.onExit = { [weak self, weak child] in
                    guard let self, let child, self.process === child else { return }
                    let requested = self.phase == .stopping
                    self.process = nil; self.phase = .stopped; self.forcedStop?.cancel()
                    self.status = "공유 꺼짐"
                    if !requested { self.errorMessage = MacHostPolicy.Failure.exited.localizedDescription }
                }
                guard child.running else {
                    process = nil
                    if Task.isCancelled || phase == .stopping { phase = .stopped; status = "공유 꺼짐"; return }
                    throw MacHostPolicy.Failure.exited
                }
                if Task.isCancelled || phase == .stopping { beginStopping(child); return }
                phase = .running
                status = "공유 프로세스 실행 중 · 기존 웹 관리자 계정은 유지됩니다. 권한 승인과 Windows 페어링은 별도로 확인하세요."
                refresh()
            } catch {
                phase = .stopped; process = nil
                status = "공유 꺼짐"
                if !(error is CancellationError) { errorMessage = fixedMessage(error) }
            }
        }
    }
    func stop() {
        guard phase != .stopped else { return }
        phase = .stopping; status = "이 앱이 시작한 공유 프로세스를 종료하는 중…"; errorMessage = nil
        task?.cancel()
        if let process { beginStopping(process) }
    }
    private func beginStopping(_ child: any MacHostOwnedProcess) {
        child.stop()
        forcedStop?.cancel()
        forcedStop = Task { [weak self, weak child] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, let child, self.process === child, child.running else { return }
            child.forceStop()
        }
    }
    func download(to destination: URL) {
        guard canDownload else { return }
        downloading = true; downloadedURL = nil; errorMessage = nil; status = "공식 Sunshine DMG 다운로드·검증 중…"
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer { downloading = false; downloadTask = nil }
            do {
                try await operations.download(destination)
                guard !shuttingDown else { throw CancellationError() }
                downloadedURL = destination; installed = operations.installed()
                status = Task.isCancelled ? "취소를 요청했지만 DMG 저장을 마쳤습니다."
                    : "DMG 크기·SHA256 확인 완료 · DMG를 열고 Sunshine을 Applications로 옮기세요."
            } catch is CancellationError { status = "다운로드 취소됨" }
            catch { errorMessage = fixedMessage(error); status = phase == .running ? "공유 프로세스 실행 중" : "공유 꺼짐" }
        }
    }
    func cancelDownload() { downloadTask?.cancel() }
    func setTerminationAdmissionPaused(_ paused: Bool) { terminationAdmissionPaused = paused }
    func beginShutdown() {
        shuttingDown = true
        activation.remove()
        cancelDownload(); stop()
    }
    func shutdown() async {
        beginShutdown()
        // Real child stop escalates after three seconds. No unrelated process is
        // killed, and no persisted PID or existing Sunshine instance is adopted.
        for _ in 0..<400 where phase != .stopped { try? await Task.sleep(for: .milliseconds(10)) }
    }
    private func fixedMessage(_ error: any Error) -> String {
        (error as? SunshineWebCredentials.Failure)?.localizedDescription ?? (error as? MacHostPolicy.Failure)?.localizedDescription ?? "공유 준비를 완료하지 못했습니다. 설치·저장 위치·네트워크를 확인하고 다시 시도하세요."
    }
}
