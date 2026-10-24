// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 DeskBridge contributors
import DeskBridgeCore
import GlimmerEngine
import SwiftUI

struct DesktopPage: View {
    @EnvironmentObject private var model: DesktopModel
    @EnvironmentObject private var files: FilesModel
    @State private var forgetConfirmation = false
    @State private var connectionDetails = false
    @State private var selectedAppID: Int?
    @State private var manualAddress = false
    @State private var addressDraft = ""
    var onSetup: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                QuietPageHeader(title: "원격 화면", subtitle: "Mac에서 \(model.platformName) 작업을 이어가세요.")
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                        .foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16).quietPanel()
                }
                if let error = model.invitationError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                }
                if !model.paired && model.serverName.isEmpty && model.settings.host == nil {
                    firstConnection
                } else { hostCard }
                if let pin = model.pairingPIN {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(model.pairingTitle, systemImage: "key").font(.headline)
                        Text(pin).font(.system(size: 42, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                        Text(model.pairingGuidance)
                            .textSelection(.enabled)
                            .font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(20).quietPanel()
                }
                if model.paired { screenSettings }
                if model.settings.host != nil || !model.serverName.isEmpty { connectionInfo }
                HStack(alignment: .top, spacing: 16) {
                    StatusPanel(status: model.status, error: nil, busy: model.busy)
                    if model.busy { Button("취소") { model.cancelOperation() } }
                }
                QuietHelp(text: "연결 후 Control + ← / →로 Mac과 \(model.platformName) Space를 전환하세요.")
            }.padding(30).frame(maxWidth: 1040, alignment: .leading).frame(maxWidth: .infinity)
        }
        .confirmationDialog("\(model.settings.host?.name ?? "저장된 PC")의 화면 인증서를 지울까요?",
                            isPresented: $forgetConfirmation, titleVisibility: .visible) {
            Button("\(model.settings.host?.name ?? "저장된 PC") 인증서 지우기", role: .destructive) { model.forgetHost() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("이 Mac의 화면 페어링 정보를 지웁니다. 다시 연결하려면 PIN으로 페어링하세요. 파일 연결의 SSH 키는 유지됩니다.")
        }
        .onChange(of: model.errorMessage) { _, error in
            if error != nil && model.settings.host != nil { connectionDetails = true }
        }
        .onAppear {
            addressDraft = model.address
            if model.errorMessage != nil && model.settings.host != nil { connectionDetails = true }
        }
        .onChange(of: model.address) { _, value in addressDraft = value }
        .onChange(of: model.apps.map(\.id)) { _, ids in
            if let selectedAppID, !ids.contains(selectedAppID) { self.selectedAppID = nil }
        }
    }
    private var firstConnection: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(model.platformName)를\n하나의 Space로.").font(.system(size: 27, weight: .bold))
                    Text("\(model.platformName) PC를 연결하고,\n익숙한 단축키로 Mac과 오가세요.")
                        .foregroundStyle(.secondary).lineSpacing(3)
                }.frame(maxWidth: .infinity, alignment: .leading)
                MonitorIllustration(platform: model.platformName).frame(width: 190)
            }
            ConnectionChooser(model: model, discovery: model.nearby)
            DisclosureGroup("주소 직접 입력", isExpanded: $manualAddress) {
                VStack(alignment: .leading, spacing: 12) {
                    addressField
                    Button("PC 확인") { verifyDraft() }.buttonStyle(.borderedProminent)
                        .disabled(!canVerifyDraft)
                }.padding(.top, 12)
            }
            Button("처음 설정 안내") { onSetup() }
        }.padding(24).quietPanel()
    }
    private var hostCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer").font(.system(size: 24))
                    .foregroundStyle(Color.accentColor).frame(width: 44, height: 44)
                    .background(QuietStyle.canvas, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(hostName).font(.headline).lineLimit(2)
                    Text(model.address).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer(minLength: 12)
                QuietBadge(title: hostStatus, symbol: hostSymbol,
                           tint: model.errorMessage != nil ? .orange : model.paired ? .green : .secondary)
            }.padding(20)
            Divider()
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(model.platformName)를\n하나의 Space로.").font(.system(size: 25, weight: .bold))
                    Text(model.streaming ? "화면 연결이 열려 있습니다." : "전체 화면으로 열고,\n익숙한 단축키로 Mac과 오가세요.")
                        .font(.callout).foregroundStyle(.secondary).lineSpacing(3)
                    primaryAction.padding(.top, 3)
                    if model.paired && model.apps.count > 1 {
                        Picker("열 화면", selection: appSelection) {
                            if launchApp == nil { Text("화면 선택").tag(Optional<Int>.none) }
                            ForEach(model.apps) { app in Text(app.name).tag(Optional(app.id)) }
                        }.frame(maxWidth: 260).disabled(model.busy || model.stream.isEngaged || model.peerEngaged || model.enrollmentEngaged)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                MonitorIllustration(platform: model.platformName).frame(width: 190)
            }.padding(26)
        }.quietPanel()
    }
    @ViewBuilder private var primaryAction: some View {
        if model.streaming {
            Button("화면 연결 끊기") { model.disconnect() }.disabled(model.busy)
        } else if model.paired {
            Button { if let app = launchApp { model.start(app) } } label: {
                Label(launchApp?.name.localizedCaseInsensitiveContains("desktop") == false ? "앱 열기" : "\(model.platformName) 열기",
                      systemImage: "arrow.up.left.and.arrow.down.right")
                    .padding(.horizontal, 5).padding(.vertical, 4)
            }.buttonStyle(.borderedProminent).disabled(model.busy || model.stream.isEngaged || model.peerEngaged || model.enrollmentEngaged || launchApp == nil)
            if model.apps.isEmpty {
                Text("Sunshine에 Desktop 앱을 추가한 뒤 PC를 다시 확인하세요.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else if !model.serverName.isEmpty && model.settings.host != nil {
            Button("저장된 PC 다시 확인") { model.connect() }
                .buttonStyle(.borderedProminent).disabled(!model.canVerifyCurrentPC)
        } else if !model.serverName.isEmpty {
            Button("PIN으로 연결") { model.pair() }.buttonStyle(.borderedProminent).disabled(model.busy || model.enrollmentEngaged)
        } else {
            Button(model.settings.host == nil ? "PC 확인" : "저장된 PC 확인") { model.connect() }
                .buttonStyle(.borderedProminent).disabled(!model.canVerifyCurrentPC || model.address.isEmpty)
        }
    }
    private var screenSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("화면 설정").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
              HStack(spacing: 0) {
                setting("해상도") {
                    Picker("해상도", selection: $model.resolution) {
                        ForEach(DesktopVideoPolicy.resolutions, id: \.self) { value in
                            Text(value == 2160 ? "4K (2160p)" : "\(value)p").tag(value)
                        }
                    }
                }.disabled(model.busy || model.stream.isEngaged || model.streaming)
                Divider().padding(.vertical, 12)
                setting("프레임") {
                    Picker("프레임", selection: $model.frameRate) {
                        ForEach(DesktopVideoPolicy.frameRates, id: \.self) { value in
                            Text("\(value) fps").tag(value)
                        }
                    }
                }.disabled(model.busy || model.stream.isEngaged || model.streaming)
              }.fixedSize(horizontal: false, vertical: true)
              Divider()
              HStack(spacing: 0) {
                setting("비트레이트") {
                    Picker("비트레이트", selection: $model.bitrateKbps) {
                        ForEach(DesktopVideoPolicy.bitratesKbps, id: \.self) { value in
                            Text(value == 0 ? "자동 (해상도 기준)" : "\(value / 1000) Mbps").tag(value)
                        }
                    }
                }.disabled(model.busy || model.stream.isEngaged || model.streaming)
                Divider().padding(.vertical, 12)
                setting("키보드") {
                    Picker("키보드 입력", selection: $model.keyboardMode) {
                        Text("Mac 입력기").tag(DesktopKeyboardMode.localIME)
                        Text("물리 키보드").tag(DesktopKeyboardMode.physicalKeys)
                    }
                }.disabled(model.busy)
              }.fixedSize(horizontal: false, vertical: true)
            }.quietPanel()
            Text("4K는 상대 PC의 화면·캡처·인코더 지원이 필요합니다. 비트레이트를 높이면 네트워크 사용량이 늘어납니다. 화질 설정은 다음 화면 연결에 적용됩니다.")
                .font(.callout).foregroundStyle(.secondary)
            Text(model.platform == .linux ? "Linux 입력기를 영문으로 두고 Mac 입력기를 사용하거나 물리 키보드 모드를 선택하세요. Linux 한·영 전환은 해당 데스크톱의 입력기 설정을 확인하세요." : model.keyboardMode == .localIME
                 ? "Mac 입력기를 쓸 때는 Windows 입력기를 영문으로 두세요. Option+문자는 Mac 특수문자를 입력합니다. Windows Alt 단축키는 물리 키보드 모드를 선택하세요."
                 : "Windows 한·영 전환은 Alt+Shift 또는 Windows에서 설정한 입력 언어 단축키를 사용하세요. 전용 한/영 키는 보내지 않습니다.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
    private func setting<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content().labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
    }
    private var connectionInfo: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.bottom, 14)
            DisclosureGroup(isExpanded: $connectionDetails) {
                VStack(alignment: .leading, spacing: 16) {
                    ConnectionChooser(model: model, discovery: model.nearby)
                    addressField
                    Button("PC 다시 확인") { verifyDraft() }.disabled(!canVerifyDraft)
                    if let saved = model.settings.host {
                        Divider()
                        Label("\(saved.name) · 저장된 화면 인증서", systemImage: "lock").font(.callout.weight(.semibold))
                        Text(saved.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                        if !model.fingerprint.isEmpty {
                            Text(model.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        QuietHelp(text: "Sunshine 재설치 등으로 인증서가 바뀌었다면 변경 이유를 확인한 뒤 저장된 인증을 지우고 다시 페어링하세요.")
                        Button("\(saved.name) 인증서 재설정…", role: .destructive) { forgetConfirmation = true }
                            .disabled(!model.canForgetHost)
                    }
                }.padding(.top, 16)
            } label: {
                HStack {
                    Label("연결 정보", systemImage: "lock").font(.callout)
                    Spacer()
                    if !model.address.isEmpty { Text(model.address).font(.caption.monospaced()) }
                }.foregroundStyle(.secondary)
            }
        }
    }
    private var addressField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(model.platformName) PC 주소").font(.callout.weight(.medium))
            TextField("192.168.1.20 또는 Tailscale IPv4", text: $addressDraft).textFieldStyle(.roundedBorder)
                .disabled(!model.canChoosePC || files.busy || files.connected)
                .onSubmit { if canVerifyDraft { verifyDraft() } }
        }
    }
    private var canVerifyDraft: Bool {
        guard !addressDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return model.canChoosePC || (model.canVerifyCurrentPC &&
            (try? EndpointPolicy.validatedAddress(addressDraft)) == (try? EndpointPolicy.validatedAddress(model.address)))
    }
    private func verifyDraft() {
        do {
            let checked = try EndpointPolicy.validatedAddress(addressDraft)
            if checked != (try? EndpointPolicy.validatedAddress(model.address)) {
                try model.selectCandidateAddress(checked)
            }
            addressDraft = model.address
            model.invitationError = nil
            model.connect()
        } catch { model.invitationError = DesktopModel.failureMessage(error).replacingOccurrences(of: "Windows", with: model.platformName) }
    }
    private var hostName: String {
        if !model.serverName.isEmpty { return model.serverName }
        return model.settings.host?.name ?? "\(model.platformName) PC"
    }
    private var hostStatus: String {
        if model.streaming { return "화면 연결 중" }
        if model.busy { return "확인 중" }
        if model.errorMessage != nil { return "연결 확인 필요" }
        return model.paired ? "페어링됨" : model.settings.host == nil ? "페어링 필요" : "저장된 PC"
    }
    private var hostSymbol: String {
        if model.errorMessage != nil { return "exclamationmark.triangle" }
        return model.paired ? "checkmark.circle" : "info.circle"
    }
    private var launchApp: HostApp? {
        if let selectedAppID { return model.apps.first { $0.id == selectedAppID } }
        if let desktop = model.apps.first(where: { $0.name.caseInsensitiveCompare("Desktop") == .orderedSame }) { return desktop }
        return model.apps.count == 1 ? model.apps.first : nil
    }
    private var appSelection: Binding<Int?> {
        Binding(get: { selectedAppID ?? launchApp?.id }, set: { selectedAppID = $0 })
    }
}
private struct MonitorIllustration: View {
    var platform: String
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 9) {
                Image(systemName: "rectangle.split.2x2.fill").font(.system(size: 38))
                    .foregroundStyle(Color.accentColor.opacity(0.65))
                Text(platform.uppercased()).font(.system(size: 8, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
            }.frame(width: 176, height: 106).background(QuietStyle.canvas)
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary, lineWidth: 5) }
            Rectangle().fill(.secondary).frame(width: 12, height: 18)
            RoundedRectangle(cornerRadius: 2).fill(.secondary).frame(width: 62, height: 4)
            Text("전체 화면으로 연결").font(.caption).foregroundStyle(.secondary).padding(.top, 10)
        }.accessibilityHidden(true)
    }
}
