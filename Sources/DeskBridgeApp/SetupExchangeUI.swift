// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Darwin
import DeskBridgeCore
import Foundation
import UniformTypeIdentifiers

extension FilesModel {
    /// Publish an approved import only after its entire settings transaction persists.
    func applyWindowsConnection(_ preview: SetupExchange.Preview) throws {
        guard canExchangeSetup else {
            throw AppFailure("진행 중인 연결을 마친 뒤 다시 불러오세요.")
        }
        try commitWindowsConnection(preview)
    }
    /// The caller has admitted a new import or revalidated an already-owned enrollment.
    private func commitWindowsConnection(_ preview: SetupExchange.Preview) throws {
        try desktopForSetup.saveFileSettings(username: preview.reply.username, port: preview.reply.port,
            hostKey: preview.reply.serverPublicKey, identityPath: identityPath, address: preview.reply.address)
        username = preview.reply.username; port = String(preview.reply.port)
        pinnedHostKey = preview.reply.serverPublicKey
        errorMessage = nil
        status = "파일 접속 정보를 채웠습니다. 파일 연결을 선택하세요. 화면 PIN 페어링은 별도로 진행합니다."
    }
    func applyEnrollmentConfirmation(_ preview: SetupExchange.Preview, epoch: UUID, identity: String, addresses: String, publicKey: String) throws {
        try requireEnrollmentConfirmation(epoch: epoch, identity: identity, addresses: addresses, expectedAddress: preview.reply.address)
        guard try selectedPublicKey() == publicKey else { throw EnrollmentProtocol.Failure.peer }
        // No await or modal callback occurs between this admission check and the
        // complete settings transaction. The completion marker remains active.
        busy = false
        guard canCompleteSetupExchange else { throw EnrollmentProtocol.Failure.expired }
        try commitWindowsConnection(preview)
    }
    /// Modal panels keep processing app events. Validate the selection again before using it.
    func requireSetupExchangeSelection(identityPath expectedIdentityPath: String, setupAddresses expectedAddresses: String? = nil) throws {
        guard canExchangeSetup else { throw AppFailure("진행 중인 화면·파일 작업과 연결을 마친 뒤 설정 파일을 다시 선택하세요.") }
        guard identityPath == expectedIdentityPath, expectedAddresses.map({ setupAddresses == $0 }) ?? true else {
            throw AppFailure("설정 파일을 선택하는 동안 Mac 키나 허용 주소가 바뀌었습니다. 현재 정보로 다시 시작하세요.")
        }
    }
    /// Reads only the .pub companion of the identity explicitly selected in this UI.
    func selectedPublicKey() throws -> String {
        guard !identityPath.isEmpty else { throw AppFailure("먼저 Mac 전용 키를 만들거나 선택하세요.") }
        let url = URL(fileURLWithPath: identityPath).appendingPathExtension("pub")
        let data: Data
        do { data = try BoundedRegularFile.read(url, maximumBytes: 4096) }
        catch { throw AppFailure("선택한 개인 키와 같은 폴더에 있는 .pub 공개 키 파일을 확인하세요. 공개 키 파일 자체가 아닌 개인 키를 선택해야 합니다.") }
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppFailure("선택한 키의 .pub 공개 키 파일을 확인하세요.")
        }
        return try SetupExchange.canonicalKey(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    func findSetupAddresses() {
        guard canExchangeSetup else { return }
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { errorMessage = "Mac 주소를 확인하지 못했습니다."; return }
        defer { freeifaddrs(first) }
        var result: [String] = []; var current = first
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard let addr = item.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  item.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0,
               let end = buffer.firstIndex(of: 0),
               let ip = String(bytes: buffer[..<end].map { UInt8(bitPattern: $0) }, encoding: .utf8) { result.append(ip) }
        }
        let suggestions = SetupExchange.suggestAddresses(result)
        setupAddresses = suggestions.addresses.joined(separator: ", ")
        if suggestions.addresses.isEmpty {
            status = "연결된 Wi-Fi 또는 Tailscale의 Mac IPv4 주소를 직접 입력하세요."
        } else if suggestions.omittedCount > 0 {
            status = "Mac 주소 8개를 채웠고 \(suggestions.omittedCount)개는 생략했습니다. Windows에 허용할 주소를 확인하고 필요하면 바꾸세요."
        } else {
            status = "Windows에서 허용할 Mac 주소를 확인하세요. 사용하지 않는 주소는 지울 수 있습니다."
        }
    }
    func exportWindowsSetup() {
        guard canExchangeSetup else { return }
        do {
            let selectedIdentity = identityPath, selectedAddresses = setupAddresses
            let publicKey = try selectedPublicKey()
            let addresses = setupAddresses.split(separator: ",", omittingEmptySubsequences: true).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            let request = try SetupExchange.request(clientPublicKey: publicKey, addresses: addresses)
            let panel = NSSavePanel(); panel.title = "Windows로 전달할 설정 파일"; panel.nameFieldStringValue = "Knot-Mac-Setup.json"
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try requireSetupExchangeSelection(identityPath: selectedIdentity, setupAddresses: selectedAddresses)
            guard try selectedPublicKey() == publicKey else { throw AppFailure("선택한 Mac 공개 키가 바뀌었습니다. 현재 키로 설정 파일 저장을 다시 시작하세요.") }
            try SetupExchange.encode(request).write(to: url, options: [.atomic])
            errorMessage = nil
            status = "공개 설정 파일을 저장했습니다. Windows 도우미에서 불러오세요. 개인 키는 포함하지 않습니다."
        } catch { errorMessage = error.localizedDescription }
    }
    func importWindowsConnection() {
        guard canExchangeSetup else { return }
        do {
            let selectedIdentity = identityPath
            let publicKey = try selectedPublicKey()
            let panel = NSOpenPanel(); panel.title = "Windows가 만든 연결 파일"; panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try requireSetupExchangeSelection(identityPath: selectedIdentity)
            guard try selectedPublicKey() == publicKey else { throw AppFailure("선택한 Mac 공개 키가 바뀌었습니다. 현재 키로 연결 파일을 다시 불러오세요.") }
            let data = try BoundedRegularFile.read(url, maximumBytes: 16_384)
            let preview = try SetupExchange.preview(data, clientPublicKey: publicKey)
            let alert = NSAlert(); alert.messageText = "Windows 화면의 SSH 지문과 비교하세요"
            alert.informativeText = "Windows PC: \(preview.reply.address)\n\n아래 SSH 지문을 Windows 설정 도우미에 표시된 값과 직접 비교한 뒤 등록하세요. 이 파일 자체는 PC의 신원을 보증하지 않습니다. 기존 파일 접속 설정을 바꿉니다."
            let fingerprint = NSTextField(wrappingLabelWithString: preview.fingerprint)
            fingerprint.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
            fingerprint.isSelectable = true
            fingerprint.setAccessibilityLabel("Windows SSH 호스트 키 지문")
            fingerprint.frame = NSRect(x: 0, y: 0, width: 440, height: 44)
            alert.accessoryView = fingerprint
            if preview.reply.address != desktopForSetup.address {
                alert.informativeText += "\n\n화면과 파일의 공통 연결 주소도 \(desktopForSetup.address.isEmpty ? "미설정" : desktopForSetup.address)에서 \(preview.reply.address)로 바뀝니다. 화면 PC 확인을 다시 해야 하며 저장된 화면 인증서는 유지됩니다."
            }
            alert.addButton(withTitle: "취소"); alert.addButton(withTitle: "Windows 지문과 같음 · 등록")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            try requireSetupExchangeSelection(identityPath: selectedIdentity)
            guard try selectedPublicKey() == publicKey else { throw AppFailure("선택한 Mac 공개 키가 바뀌었습니다. 현재 키로 연결 파일을 다시 불러오세요.") }
            try applyWindowsConnection(preview)
        } catch { errorMessage = error.localizedDescription }
    }
}
