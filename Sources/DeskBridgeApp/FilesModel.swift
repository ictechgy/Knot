// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 DeskBridge contributors
import AppKit
import Combine
import DeskBridgeCore
import Foundation

@MainActor
final class FilesModel: ObservableObject {
    @Published var username: String
    @Published var port: String
    @Published var identityPath: String
    @Published var pinnedHostKey: String
    @Published var generatedPublicKey = ""
    @Published var setupAddresses = ""
    @Published var enrollmentBindAddress = ""
    @Published var enrollmentLink = ""
    var enrollmentServer: EnrollmentServer?
    var enrollmentOperation: Task<Void, Never>?
    var enrollmentGeneration = UUID()
    @Published var enrollmentConfirmation: UUID?
    @Published var enrollmentModalActive = false
    var enrollmentActive: Bool { enrollmentServer != nil || enrollmentOperation != nil || enrollmentConfirmation != nil || enrollmentModalActive }
    var activityAllowed: Bool { !KnotUpdates.shared.installationPending && !enrollmentModalActive }
    var keyFingerprint: String {
        // Reuse exactly the transport's key parser, independently of unfinished
        // address/user/key-file drafts. This constructor performs no I/O.
        (try? SFTPConnectionConfiguration(host: "synthetic.invalid", username: "deskbridge-transfer",
            identityFile: URL(fileURLWithPath: "/unused-key-preview"), pinnedHostPublicKey: pinnedHostKey).hostKeyFingerprint) ?? ""
    }
    @Published var currentPath = "/files"
    @Published var entries: [SFTPEntry] = []
    @Published var selection: String?
    @Published var connected = false
    @Published var busy = false
    @Published var progress: TransferProgress?
    @Published var status = "Windows OpenSSH 설정 후 접속 정보를 입력하세요."
    @Published var errorMessage: String?
    private var client: SFTPClient?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var connectedAddress: String?
    private var committedTransfer: String?
    private var shuttingDown = false
    private let desktop: DesktopModel
    var desktopForSetup: DesktopModel { desktop }
    static func failureMessage(_ error: any Error) -> String {
        if error is SFTPError || error is AppFailure || error is EndpointPolicy.Failure || error is BoundedRegularFile.Failure || error is SettingsStore.Failure || error is CorePrivateStorageFailure || error is EnrollmentProtocol.Failure {
            return error.localizedDescription
        }
        return "파일 작업을 완료하지 못했습니다. 설정 파일과 개인 키의 접근 권한을 확인한 뒤 다시 시도하세요."
    }
    var canExchangeSetup: Bool { activityAllowed && !shuttingDown && desktop.supportsFiles && !busy && !connected && desktop.canChoosePC }
    struct KeyReplacementSnapshot: Equatable {
        let savedPath: String
        let draftPath: String
        var requiresConfirmation: Bool {
            [savedPath, draftPath].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }
    var keyReplacementSnapshot: KeyReplacementSnapshot {
        .init(savedPath: desktop.settings.sshIdentityPath, draftPath: identityPath)
    }
    var requiresKeyReplacementConfirmation: Bool { keyReplacementSnapshot.requiresConfirmation }
    func requireKeyReplacementSelection(_ snapshot: KeyReplacementSnapshot) throws {
        guard keyReplacementSnapshot == snapshot else {
            throw AppFailure("저장된 SSH 키나 입력 중인 키가 바뀌었습니다. 현재 키를 확인한 뒤 다시 시도하세요.")
        }
    }
    static func connectionMatches(connected: Bool, connectedAddress: String?, validatedAddress: String) -> Bool {
        guard connected, let connectedAddress,
              let canonical = try? EndpointPolicy.validatedAddress(validatedAddress), canonical == validatedAddress else { return false }
        return connectedAddress == canonical
    }
    func isConnected(toValidatedAddress address: String) -> Bool {
        Self.connectionMatches(connected: connected, connectedAddress: connectedAddress, validatedAddress: address)
    }

    init(desktop: DesktopModel) {
        self.desktop = desktop
        let s = desktop.settings
        username = s.sshUsername; port = String(s.sshPort); identityPath = s.sshIdentityPath
        pinnedHostKey = s.sshHostPublicKey
        desktop.fileActivity = self
    }
    var selectedEntry: SFTPEntry? { entries.first { $0.path == selection } }
    func perform(allowDuringUpdate: Bool = false, _ body: @escaping @MainActor () async throws -> Void) {
        guard !shuttingDown, desktop.supportsFiles, !busy, (allowDuringUpdate || activityAllowed) else { return }
        busy = true; errorMessage = nil; progress = nil; committedTransfer = nil
        let current = UUID(); generation = current
        operation = Task { [weak self] in
            do { try await body(); try Task.checkCancellation() }
            catch {
                guard let self, generation == current else { return }
                let terminal = SFTPError.requiresReconnect(after: error)
                if terminal { await clearConnection() }
                guard generation == current else { return }
                if let committedTransfer {
                    status = committedTransfer + (terminal ? " · 파일 연결이 끊어졌습니다. 다시 접속해 목록을 확인하세요." : " · 목록을 다시 확인하세요.")
                    errorMessage = nil
                } else if error is CancellationError || (error as? SFTPError) == .cancelled {
                    status = "취소했습니다. 다시 접속해서 파일 목록을 확인하세요."
                } else {
                    errorMessage = Self.failureMessage(error)
                    status = terminal ? "파일 연결이 끊어졌습니다. 다시 접속하세요." : "파일 작업을 완료하지 못했습니다."
                }
            }
            guard self?.generation == current else { return }
            self?.progress = nil; self?.busy = false; self?.operation = nil
        }
    }
    func recordCommittedTransfer(_ message: String) { committedTransfer = message }
    func connect(address input: String? = nil) {
        guard activityAllowed, !shuttingDown, desktop.supportsFiles, !busy, !connected else { return }
        let host: String
        do {
            try desktop.assertStorageReady()
            guard !identityPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppFailure("파일 연결에 사용할 Mac 개인 키를 먼저 만들거나 선택하세요.")
            }
            host = try EndpointPolicy.validatedAddress(input ?? desktop.address)
            if host != (try? EndpointPolicy.validatedAddress(desktop.address)) {
                // Commit an explicitly submitted draft before files become busy, using the shared target guard.
                try desktop.selectCandidateAddress(host)
            } else if desktop.busy {
                throw AppFailure("진행 중인 PC 확인을 마친 뒤 파일에 연결하세요.")
            }
            // The same canonical PC remains usable for files while its screen is streaming.
        } catch {
            errorMessage = Self.failureMessage(error); status = "파일 연결 정보를 확인하세요."
            return
        }
        perform { [self] in
            try desktop.assertStorageReady()
            guard let port = UInt16(port), port > 0 else { throw AppFailure("SSH 포트를 확인하세요.") }
            let config = try SFTPConnectionConfiguration(host: host, port: port, username: username,
                                                        identityFile: URL(fileURLWithPath: identityPath),
                                                        pinnedHostPublicKey: pinnedHostKey)
            await clearConnection()
            let newClient = SFTPClient(configuration: config); client = newClient
            status = "등록한 SSH 호스트 키로 PC를 확인하는 중…"
            do {
                try await newClient.connect()
                let listed = try await newClient.list(path: "/files")
                try Task.checkCancellation()
                try desktop.saveFileSettings(username: username, port: port, hostKey: pinnedHostKey, identityPath: identityPath, address: host)
                connectedAddress = host; currentPath = "/files"; entries = listed; connected = true
            } catch {
                // The first listing is part of establishing a usable connection,
                // even when its failure is an otherwise recoverable remote status.
                await clearConnection()
                throw error
            }
            status = "파일 연결 완료 · \(host)"
        }
    }
    func refresh(path: String? = nil) {
        perform { [self] in
            let client = try checkedClient()
            let next = path ?? currentPath
            let listed = try await client.list(path: next)
            entries = listed; currentPath = next; selection = nil
            status = "표시된 \(listed.count)개 항목"
        }
    }
    func parent() {
        let parts = currentPath.split(separator: "/").dropLast()
        refresh(path: "/" + parts.joined(separator: "/"))
    }
    private func checkedClient() throws -> SFTPClient {
        try desktop.assertFileCapability()
        guard connected, let client else { throw SFTPError.disconnected }
        guard connectedAddress == (try? EndpointPolicy.validatedAddress(desktop.address)) else {
            throw SFTPError.targetChanged
        }
        return client
    }
    private func clearConnection() async {
        let previous = client
        client = nil; connected = false; connectedAddress = nil
        entries = []; selection = nil; progress = nil
        if let previous { await previous.disconnect() }
    }
    func upload() {
        guard activityAllowed, desktop.supportsFiles, !busy, connected else { return }
        let targetAddress = connectedAddress
        let panel = NSOpenPanel()
        panel.title = "Windows로 보낼 파일"; panel.canChooseDirectories = false
        panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard activityAllowed, desktop.supportsFiles, !busy, connected, connectedAddress == targetAddress else { return }
        perform { [self] in
            let client = try checkedClient()
            status = "Windows로 보내는 중…"
            let remote = try await client.upload(localURL: url, remoteDirectory: currentPath, progress: progressHandler())
            recordCommittedTransfer("보내기 완료: \(remote)")
            entries = try await client.list(path: currentPath)
            status = "보내기 완료: \(remote)"
        }
    }
    func download() {
        guard activityAllowed, desktop.supportsFiles, !busy, connected, let entry = selectedEntry, entry.kind == .file else { return }
        let targetAddress = connectedAddress
        let panel = NSOpenPanel()
        panel.title = "Mac에 받을 폴더"
        panel.message = "‘\(entry.name)’ 파일을 이 폴더에 받습니다. 같은 이름의 기존 파일은 덮어쓰지 않습니다."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let url = folder.appendingPathComponent(entry.name)
        guard activityAllowed, desktop.supportsFiles, !busy, connected, connectedAddress == targetAddress else { return }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = SFTPError.destinationExists.localizedDescription
            return
        }
        perform { [self] in
            let client = try checkedClient()
            status = "Mac으로 받는 중…"
            try await client.download(remotePath: entry.path, destinationURL: url, progress: progressHandler())
            recordCommittedTransfer("받기 완료: \(url.lastPathComponent)")
            status = "받기 완료: \(url.lastPathComponent)"
        }
    }
    private func progressHandler() -> @Sendable (TransferProgress) -> Void {
        let epoch = generation
        let gate = TransferProgressGate()
        return { [weak self] update in
            guard gate.accept(bytes: update.bytesTransferred, total: update.totalBytes) else { return }
            Task { @MainActor [weak self] in
                guard let self, generation == epoch, busy, connected else { return }
                if let progress, update.bytesTransferred < progress.bytesTransferred { return }
                progress = update
            }
        }
    }
    func cancel() {
        if enrollmentActive { cancelEnrollment(); return }
        operation?.cancel(); client?.cancel(); connected = false
        connectedAddress = nil; entries = []; selection = nil; progress = nil
        status = "취소 중…"
    }
    func disconnect() {
        guard !busy else { cancel(); return }
        perform(allowDuringUpdate: true) { [self] in
            await clearConnection()
            status = "파일 연결을 끊었습니다."
        }
    }
    func generateKey(replacingIdentity confirmedIdentity: KeyReplacementSnapshot? = nil) {
        guard activityAllowed, !shuttingDown, desktop.supportsFiles, !busy, !connected else { return }
        let requestedIdentity = keyReplacementSnapshot
        guard !requestedIdentity.requiresConfirmation || confirmedIdentity == requestedIdentity else {
            errorMessage = "설정된 SSH 키를 바꾸려면 먼저 확인하세요. 새 공개 키는 Windows에 다시 등록해야 합니다."
            return
        }
        perform { [self] in
            try desktop.assertStorageReady()
            try requireKeyReplacementSelection(requestedIdentity)
            let directory = desktop.store.directory
            let result = try await Task.detached(priority: .userInitiated) { try SSHKeyManager.generate(in: directory) }.value
            try Task.checkCancellation()
            guard !connected else { throw AppFailure("파일 연결을 끊은 뒤 키를 변경하세요.") }
            try requireKeyReplacementSelection(requestedIdentity)
            try desktop.rememberFileIdentity(path: result.privateKey.path)
            identityPath = result.privateKey.path; generatedPublicKey = result.publicKey
            status = "Mac 전용 키를 만들었습니다. 아래 공개 키를 Windows 설정 도우미에 등록하세요."
        }
    }
    func chooseKey() {
        guard activityAllowed, !shuttingDown, desktop.supportsFiles, !busy, !connected else { return }
        let panel = NSOpenPanel()
        panel.title = "이 연결에 사용할 SSH 개인 키"; panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try applySelectedIdentity(url)
            } catch { errorMessage = Self.failureMessage(error) }
        }
    }
    /// Recheck after the modal run loop; publish only after storage succeeds.
    func applySelectedIdentity(_ url: URL) throws {
        try desktop.assertFileCapability()
        guard activityAllowed, !shuttingDown, desktop.supportsFiles, !busy, !connected else { throw AppFailure("파일 작업과 연결을 마친 뒤 키를 변경하세요.") }
        guard url.isFileURL else { throw AppFailure("이 연결에 사용할 Mac의 키 파일을 선택하세요.") }
        guard url.pathExtension.lowercased() != "pub" else {
            throw AppFailure(".pub 공개 키가 아닌 개인 키 파일을 선택하세요. 공개 키는 설정 파일을 만들 때 따로 읽습니다.")
        }
        try desktop.rememberFileIdentity(path: url.path)
        identityPath = url.path; generatedPublicKey = ""
        errorMessage = nil
    }
    func beginShutdown() {
        cancelEnrollment()
        shuttingDown = true
        generation = UUID()
        operation?.cancel(); client?.revoke()
        connected = false; connectedAddress = nil; entries = []; selection = nil; progress = nil
    }
    func shutdown() async {
        beginShutdown()
        await clearConnection()
        busy = false; operation = nil
    }
}

