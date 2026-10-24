// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import GlimmerEngine
import DeskBridgeCore

/// Exercise the actual operation catch path with typed synthetic failures.
@MainActor
func runDesktopFailureGuidanceChecks(temporary: URL) async throws -> Int {
    var count = 0
    func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ModelCheckFailure(message: message) }; count += 1
    }
    let suite = "org.deskbridge.synthetic." + UUID().uuidString
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let model = DesktopModel(storageDirectory: temporary.appendingPathComponent("desktop-guidance"), identitySuite: suite)
    try expect(model.pairingTitle.contains("Windows Knot") && model.pairingGuidance.contains("연결 준비") &&
               model.pairingGuidance.contains("새 PIN") && model.pairingGuidance.contains("https://localhost:47990/pin"),
               "Windows PIN guidance must lead to native approval, retain manual fallback and explain restart recovery")
    let raw = "synthetic-untrusted-detail-192.0.2.1-private-path"
    let cases: [(any Error, String)] = [
        (ConnectionInvitation.Failure.invalid, "새 연결 QR"),
        (CorePrivateStorageFailure.unsafeStorage, "저장 폴더"),
        (IdentityStorageError.unsafeStorage, "저장 폴더"),
        (IdentityStorageError.incompleteIdentity, "인증 파일 전체를 복원"),
        (StreamSecurityPolicy.Failure.plaintextSignalling, "필수 화면 암호화"),
        (StreamSecurityPolicy.Failure.missingEncryption(7), "필수 화면 암호화"),
        (StreamError.securityNegotiation(.plaintextSignalling), "[S01]"),
        (StreamError.securityNegotiation(.missingEncryption(2)), "[S02]"),
        (PairingFailure.invalidAddress, "IPv4 주소"),
        (PairingFailure.unreachable, "네트워크 연결"),
        (PairingFailure.gameStream, "Sunshine 호스트"),
        (PairingFailure.timedOut, "PIN 입력 시간"),
        (PairingFailure.busy, "다른 PIN 연결"),
        (PairingFailure.rejected, "승인하지 않았습니다"),
        (StreamError.hostCertChanged(raw), "인증서와 다릅니다"),
        (StreamError.sunshineNeedsRestart(raw), "Sunshine을 다시 시작"),
        (StreamError.pairingFailed(raw), "연결 권한과 PIN"),
        (StreamError.pairingRejected, "연결 권한과 PIN"),
        (StreamError.hostUnreachable(raw), "방화벽"),
        (StreamError.hostTimedOut, "방화벽"),
        (StreamError.truncatedRead(raw), "방화벽"),
        (StreamError.gameStreamHost, "Sunshine 호스트"),
        (StreamError.hostRefused(message: raw, code: 403), "Desktop을 열지 못했습니다"),
        (StreamError.launchFailed(raw), "Desktop을 열지 못했습니다"),
        (StreamError.streamPortsBlocked(proto: raw, port: 47998), "통신이 차단"),
        (StreamError.sessionFailed(-9876), "화면 연결을 시작하지 못했습니다"),
        (StreamError.binaryNotFound, "화면 연결을 시작하지 못했습니다"),
        (StreamError.decoderFailed(raw), "해상도를 낮춰"),
        (StreamError.audioFailed(raw), "오디오 장치·네트워크"),
        (StreamError.crypto(raw), "보안 연결"),
    ]
    for (error, guidance) in cases {
        model.pairingPIN = "1234"
        model.perform { throw error }
        for _ in 0..<1000 {
            if !model.busy { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try expect(!model.busy && model.errorMessage?.contains(guidance) == true,
                   "typed desktop failure did not display the corresponding Korean recovery guidance")
        try expect(model.errorMessage?.contains(raw) == false,
                   "untrusted low-level host detail escaped into desktop error guidance")
        try expect(model.pairingPIN == nil && model.status == "작업을 완료하지 못했습니다.",
                   "failed desktop operation retained its PIN or busy status")
    }
    let localMessage = "합성 설정 오류를 확인하세요."
    let missingVideo = DesktopModel.failureMessage(StreamError.securityNegotiation(.missingEncryption(2)))
    try expect(missingVideo.contains("연결 대상 PC의 브라우저") && missingVideo.contains("Required for all clients") && missingVideo.contains("Save → Apply") && !missingVideo.contains("Mandatory"),
               "video encryption failure lost the actual pinned Sunshine settings labels and device context")
    // Asynchronous recovery publishes through the controller callback, bypassing
    // the operation catch's platform substitution. Cover both real model routes.
    for platform in [HostPlatform.windows, .linux] {
        let controller = DesktopStreamController()
        let target = DesktopModel(storageDirectory: temporary.appendingPathComponent("recovery-guidance-\(platform.rawValue)"),
                                  identitySuite: suite, platform: platform, streamController: controller)
        if platform == .linux {
            try expect(target.pairingTitle.contains("Linux 브라우저") && !target.pairingGuidance.contains("Windows Knot"),
                       "Linux PIN guidance must retain its own browser workflow")
        }
        for (failure, code) in [(StreamSecurityPolicy.Failure.plaintextSignalling, "[S01]"), (.missingEncryption(2), "[S02]")] {
            var recovery = DesktopRecoveryPresentation()
            recovery.receive(.firstFrame)
            recovery.receive(.reconnecting)
            recovery.receive(.connectionTerminated(errorCode: -1, error: .securityNegotiation(failure)))
            controller.onStatus?(recovery.status)
            try expect(target.status.contains("연결 대상 PC") && !target.status.contains("Windows") && target.status.contains(code),
                       "asynchronous security recovery assumed Windows for a shared host platform")
            try expect(target.status.contains("PIN 페어링") && (code != "[S02]" ||
                       (target.status.contains("https://localhost:47990/config#lan_encryption_mode") && target.status.contains("Save → Apply"))),
                       "platform-neutral recovery lost preserved pairing or actionable target-PC settings")
        }
    }
    try expect(!DesktopModel.failureMessage(StreamError.crypto(raw)).contains("암호화 설정"),
               "unrelated crypto failures must not claim a missing Sunshine encryption setting")
    try expect(DesktopModel.failureMessage(AppFailure(localMessage)) == localMessage,
               "local actionable app errors must retain their specific guidance")
    let unknown = DesktopModel.failureMessage(NSError(domain: raw, code: -1, userInfo: [NSLocalizedDescriptionKey: raw]))
    try expect(unknown.contains("작업을 완료하지 못했습니다") && !unknown.contains(raw),
               "unknown framework errors must use fixed Korean guidance")
    let recovery = DesktopModel.failureMessage(IdentityStorageError.incompleteIdentity)
    try expect(recovery.contains("초기화할 수 없습니다") && !recovery.contains("수동으로 새 연결"),
               "missing identity offered an unsupported reset path")
    let files = FilesModel(desktop: model)
    files.perform { throw NSError(domain: raw, code: -1, userInfo: [NSLocalizedDescriptionKey: raw]) }
    for _ in 0..<1000 {
        if !files.busy { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    try expect(!files.busy && files.errorMessage?.contains("개인 키의 접근 권한") == true && files.errorMessage?.contains(raw) == false,
               "file operations exposed raw framework storage details")
    try expect(FilesModel.failureMessage(AppFailure(localMessage)) == localMessage,
               "file operations lost actionable local guidance")
    try expect(FilesModel.failureMessage(CorePrivateStorageFailure.unsafeStorage).contains("저장 폴더"),
               "file credential storage refusal lost actionable local guidance")
    let denied = temporary.appendingPathComponent("startup-storage-guidance")
    try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var saved = SavedSettings(); saved.address = "192.168.1.21"; saved.sshHostPublicKey = "SYNTHETIC PRESERVED PIN"
    let deniedStore = SettingsStore(directory: denied); try deniedStore.save(saved)
    let savedFile = denied.appendingPathComponent("settings.json")
    let before = try Data(contentsOf: savedFile)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied.path)
    let deniedModel = DesktopModel(storageDirectory: denied, identitySuite: suite)
    try expect(deniedModel.errorMessage?.contains("접근 권한") == true && deniedModel.errorMessage?.contains("설정 파일을 복구") == false,
               "startup permission refusal lost typed storage guidance")
    let startupMessage = deniedModel.errorMessage
    deniedModel.connect()
    try expect(deniedModel.errorMessage == startupMessage && !deniedModel.busy,
               "PC verification replaced startup storage refusal with unrelated busy guidance")
    do { try deniedModel.assertStorageReady(); throw ModelCheckFailure(message: "unsafe startup allowed operations") }
    catch let error as AppFailure { try expect(error.message == startupMessage, "later operations changed the startup recovery guidance") }
    let deniedFiles = FilesModel(desktop: deniedModel)
    deniedFiles.perform { try deniedModel.assertStorageReady() }
    for _ in 0..<1000 { if !deniedFiles.busy { break }; try await Task.sleep(for: .milliseconds(1)) }
    try expect(deniedFiles.errorMessage == startupMessage, "file operation lost the same storage refusal")
    try expect(try Data(contentsOf: savedFile) == before, "storage guidance modified saved credentials")
    return count
}
