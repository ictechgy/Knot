// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import DeskBridgeCore
import SwiftUI

struct ConnectionChooser: View {
    @EnvironmentObject private var files: FilesModel
    @ObservedObject var model: DesktopModel
    @ObservedObject var discovery: NearbyPCBrowser
    @State private var cameraPresented = false
    @State private var captured: ConnectionInvitation?
    @State private var readingQR = false
    private var canChoosePC: Bool { model.canChoosePC && !files.busy && !files.connected }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("근처 Sunshine PC · \(model.platformName) 선택", systemImage: "wifi").font(.headline)
                Spacer()
                if discovery.searching { ProgressView().controlSize(.small).accessibilityLabel("근처 PC 검색 중") }
                Button(discovery.searching ? "검색 중지" : "다시 찾기") {
                    if discovery.searching { discovery.stop() } else { model.startNearbySearch() }
                }.disabled(!canChoosePC)
            }
            Text(discovery.status).font(.callout).foregroundStyle(.secondary)
            ForEach(discovery.hosts) { host in
                HStack(spacing: 12) {
                    Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(host.name).font(.callout.weight(.semibold))
                        Text(host.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("이 PC 확인") {
                        do { try model.selectCandidateAddress(host.address); model.connect() }
                        catch { model.invitationError = error.localizedDescription }
                    }.disabled(!canChoosePC).accessibilityLabel("\(host.name), \(host.address) PC 확인")
                }.padding(12).quietPanel()
            }
            Divider()
            Text("목록에 없거나 Tailscale로 연결하나요?").font(.callout.weight(.medium))
            HStack {
                Button(readingQR ? "QR 읽는 중…" : "QR 이미지 열기…") {
                    guard !readingQR else { return }
                    readingQR = true
                    Task { @MainActor in
                        defer { readingQR = false }
                        do { if let invitation = try await ConnectionQRReader.chooseImage() { try model.reviewInvitation(invitation) } }
                        catch { model.invitationError = error.localizedDescription }
                    }
                }.disabled(readingQR)
                Button("카메라로 QR 스캔…") { cameraPresented = true }
                Button("연결 링크 입력…") { importLink() }
            }.disabled(!canChoosePC)
            QuietHelp(text: "\(model.platformName)의 Knot에서 연결 QR / 링크를 가져오세요. 검색 결과의 OS는 확인되지 않았습니다. 사용하려는 PC를 직접 선택하고 PIN으로 확인하세요.")
        }
        .sheet(isPresented: $cameraPresented, onDismiss: {
            guard let invitation = captured else { return }
            captured = nil
            do { try model.reviewInvitation(invitation) } catch { model.invitationError = error.localizedDescription }
        }) { ConnectionCameraSheet { captured = $0 } }
    }

    private func importLink() {
        let alert = NSAlert()
        alert.messageText = "\(model.platformName) 연결 링크"
        alert.informativeText = "공유할 PC에서 복사한 연결 링크를 붙여 넣으세요. PC 이름·주소를 확인한 뒤 PIN으로 페어링합니다."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 440, height: 48))
        field.placeholderString = "deskbridge://connect?…"
        alert.accessoryView = field
        alert.addButton(withTitle: "연결 정보 확인"); alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try model.reviewInvitation(.init(text: field.stringValue)) }
        catch { model.invitationError = error.localizedDescription }
    }
}

struct ConnectionInvitationSheet: View {
    @EnvironmentObject private var files: FilesModel
    @ObservedObject var model: DesktopModel
    let invitation: ConnectionInvitation
    @State private var address: String
    @Environment(\.dismiss) private var dismiss
    private var canChoosePC: Bool { model.canChoosePC && !files.busy && !files.connected }

    init(model: DesktopModel, invitation: ConnectionInvitation) {
        self.model = model; self.invitation = invitation
        _address = State(initialValue: invitation.addresses[0])
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("이 \(model.platformName) PC에 연결할까요?", systemImage: "desktopcomputer").font(.title2.weight(.semibold))
            Text(invitation.name).font(.headline).textSelection(.enabled)
            Picker("연결 주소", selection: $address) {
                ForEach(invitation.addresses, id: \.self) { value in
                    Text(value + (value.hasPrefix("100.") ? " · VPN / CGNAT" : " · 로컬 네트워크")).tag(value)
                }
            }
            QuietHelp(text: "아직 PC 신원을 확인하지 않았습니다. 다음 단계에서 PIN으로 페어링하거나 저장된 인증서를 확인합니다. QR로 화면·파일 접속 권한이 자동 등록되지는 않습니다.", symbol: "lock")
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("이 PC 확인") {
                    do { try model.selectCandidateAddress(address); dismiss(); model.connect() }
                    catch { model.invitationError = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!canChoosePC)
            }
        }.padding(26).frame(width: 500)
    }
}
