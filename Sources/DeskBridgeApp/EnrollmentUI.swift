// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import DeskBridgeCore
import Foundation

extension FilesModel {
    /// A fresh key is created only when there is no selected/saved key. An update
    /// or a retry never rotates an existing key, screen certificate or SSH pin.
    func startAutomaticFileSetup() {
        guard canExchangeSetup else { return }
        do {
            try desktopForSetup.assertStorageReady()
            _ = try EndpointPolicy.validatedAddress(desktopForSetup.address)
            if setupAddresses.isEmpty { findSetupAddresses() }
            let addresses = setupAddresses.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if enrollmentBindAddress.isEmpty { enrollmentBindAddress = addresses.first ?? "" }
            guard addresses.contains(enrollmentBindAddress), !enrollmentBindAddress.hasPrefix("169.254.") else {
                throw AppFailure("Mac 주소 찾기로 같은 Wi-Fi 또는 Tailscale 주소를 선택하세요.")
            }
            let expectedAddress = try EndpointPolicy.validatedAddress(desktopForSetup.address)
            let originalIdentity = identityPath, originalAddresses = setupAddresses, bind = enrollmentBindAddress
            let epoch = UUID(); enrollmentGeneration = epoch
            busy = true; errorMessage = nil; enrollmentLink = ""
            status = "Mac 전용 키와 자동 파일 설정 연결을 준비하는 중…"
            enrollmentOperation = Task { [weak self] in
                guard let self else { return }
                do {
                    if originalIdentity.isEmpty {
                        guard desktopForSetup.settings.sshIdentityPath.isEmpty else { throw AppFailure("저장된 Mac 키를 먼저 선택하세요. 기존 키는 자동 교체하지 않습니다.") }
                        let directory = desktopForSetup.store.directory
                        let key = try await Task.detached(priority: .userInitiated) { try SSHKeyManager.generate(in: directory) }.value
                        try Task.checkCancellation()
                        guard enrollmentGeneration == epoch, identityPath == originalIdentity else { throw EnrollmentProtocol.Failure.expired }
                        try desktopForSetup.rememberFileIdentity(path: key.privateKey.path)
                        identityPath = key.privateKey.path; generatedPublicKey = key.publicKey
                    }
                    try Task.checkCancellation()
                    guard enrollmentGeneration == epoch, setupAddresses == originalAddresses,
                          desktopForSetup.address == expectedAddress else { throw EnrollmentProtocol.Failure.peer }
                    let selectedIdentity = identityPath, publicKey = try selectedPublicKey()
                    let request = try SetupExchange.request(clientPublicKey: publicKey, addresses: addresses)
                    let server = try EnrollmentServer(address: bind, windowsAddress: expectedAddress, request: request,
                        onReady: { [weak self] link in Task { @MainActor in
                            guard let self, self.enrollmentGeneration == epoch else { return }
                            self.enrollmentLink = link.text
                            self.status = "2분 안에 Windows Knot 도우미의 자동 파일 설정에 이 연결을 붙여 넣으세요. Windows에서 허용할 Mac 주소와 관리자 요청을 확인합니다."
                        } }, completion: { [weak self] result in Task { @MainActor in
                            guard let self, self.enrollmentGeneration == epoch else { return }
                            self.enrollmentConfirmation = epoch
                            self.enrollmentServer = nil; self.enrollmentLink = ""
                            self.enrollmentOperation = nil
                            defer {
                                if self.enrollmentGeneration == epoch {
                                    self.enrollmentConfirmation = nil; self.busy = false
                                }
                            }
                            do {
                                let data = try result.get()
                                try self.requireEnrollmentConfirmation(epoch: epoch, identity: selectedIdentity, addresses: originalAddresses, expectedAddress: expectedAddress)
                                guard self.desktopForSetup.address == expectedAddress,
                                      try self.selectedPublicKey() == publicKey else { throw EnrollmentProtocol.Failure.peer }
                                let preview = try EnrollmentProtocol.validateReply(data, request: request, expectedWindowsAddress: expectedAddress)
                                try self.confirmEnrollment(preview, epoch: epoch, identity: selectedIdentity, addresses: originalAddresses, publicKey: publicKey)
                            } catch {
                                guard self.enrollmentGeneration == epoch else { return }
                                self.errorMessage = Self.failureMessage(error); self.status = "자동 파일 설정을 마치지 못했습니다. 기존 설정을 유지합니다."
                            }
                        } })
                    guard enrollmentGeneration == epoch else { server.cancel(); return }
                    enrollmentServer = server; enrollmentOperation = nil; server.start()
                } catch {
                    guard enrollmentGeneration == epoch else { return }
                    enrollmentOperation = nil; busy = false; enrollmentLink = ""
                    errorMessage = Self.failureMessage(error); status = "자동 파일 설정을 시작하지 못했습니다."
                }
            }
        } catch { errorMessage = Self.failureMessage(error) }
    }
    func cancelEnrollment() {
        guard enrollmentActive else { return }
        enrollmentGeneration = UUID(); enrollmentConfirmation = nil; enrollmentOperation?.cancel(); enrollmentOperation = nil
        enrollmentServer?.cancel(); enrollmentServer = nil; enrollmentLink = ""; busy = false
        status = "자동 파일 설정을 취소했습니다. Windows에서 이미 승인한 파일 계정은 자동 해제하지 않습니다."
    }
    /// The modal loop can run cancellation/shutdown callbacks. Keep busy and
    /// enrollmentActive true until its owned generation is revalidated.
    func requireEnrollmentConfirmation(epoch: UUID, identity: String, addresses: String, expectedAddress: String) throws {
        guard enrollmentGeneration == epoch, enrollmentConfirmation == epoch, busy,
              identityPath == identity, setupAddresses == addresses,
              desktopForSetup.address == expectedAddress else { throw EnrollmentProtocol.Failure.expired }
    }
    func applyEnrollmentConfirmation(_ preview: SetupExchange.Preview, epoch: UUID, identity: String, addresses: String, publicKey: String) throws {
        try requireEnrollmentConfirmation(epoch: epoch, identity: identity, addresses: addresses, expectedAddress: preview.reply.address)
        guard try selectedPublicKey() == publicKey else { throw EnrollmentProtocol.Failure.peer }
        // No await or modal callback occurs between this admission check and the
        // complete settings transaction. The completion marker remains active.
        busy = false
        try requireSetupExchangeSelection(identityPath: identity, setupAddresses: addresses)
        try applyWindowsConnection(preview)
    }
    private func confirmEnrollment(_ preview: SetupExchange.Preview, epoch: UUID, identity: String, addresses: String, publicKey: String) throws {
        let alert = NSAlert(); alert.messageText = "Windows의 SSH 지문과 비교하세요"
        alert.informativeText = "Windows Knot 도우미에 표시된 SSH 지문이 아래 값과 같은지 직접 확인하세요. 화면 PIN과 별도로 파일 전송에 사용할 PC를 확인합니다.\n\nWindows PC: \(preview.reply.address)"
        let fingerprint = NSTextField(wrappingLabelWithString: preview.fingerprint)
        fingerprint.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        fingerprint.isSelectable = true; fingerprint.frame = NSRect(x: 0, y: 0, width: 440, height: 44)
        fingerprint.setAccessibilityLabel("Windows SSH 호스트 키 지문"); alert.accessoryView = fingerprint
        alert.addButton(withTitle: "취소"); alert.addButton(withTitle: "Windows 지문과 같음 · 등록")
        enrollmentModalActive = true
        let answer = alert.runModal()
        enrollmentModalActive = false
        guard enrollmentGeneration == epoch else { return }
        guard answer == .alertSecondButtonReturn else { status = "SSH 지문 등록을 취소했습니다. 파일 연결은 시작하지 않았습니다."; return }
        try applyEnrollmentConfirmation(preview, epoch: epoch, identity: identity, addresses: addresses, publicKey: publicKey)
    }
}
