// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 DeskBridge contributors
import DeskBridgeCore
import Foundation
import SwiftUI

struct FilesPage: View {
    @EnvironmentObject private var desktop: DesktopModel
    @EnvironmentObject private var model: FilesModel
    @State private var configurationExpanded = true
    @State private var exchangeExpanded = false
    @State private var manualTrustExpanded = false
    @State private var addressDraft = ""
    @State private var confirmingKeyReplacement = false
    @State private var identityToReplace: FilesModel.KeyReplacementSnapshot?

    private var settingsLocked: Bool { model.busy || model.connected || !model.activityAllowed }
    private var targetLocked: Bool { settingsLocked || desktop.busy || desktop.streaming }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 16) {
                    QuietPageHeader(title: "파일", subtitle: "Windows PC와 필요한 파일을 주고받으세요.")
                    Spacer(minLength: 0)
                    if model.connected {
                        QuietBadge(title: "파일 연결됨", symbol: "folder.badge.checkmark", tint: .green)
                    }
                }

                if model.connected {
                    fileBrowser
                    QuietHelp(text: "보낼 파일은 Mac의 파일 선택기에서, 받을 위치는 저장 창에서 고릅니다. 파일은 한 번에 하나씩 전송합니다.")
                } else {
                    connectionIntroduction
                }

                if !model.connected { automaticSetup }

                connectionSettings

                if let progress = model.progress { transferProgress(progress) }

                VStack(alignment: .leading, spacing: 12) {
                    StatusPanel(status: model.status, error: model.errorMessage, busy: model.busy)
                    HStack(spacing: 12) {
                        if model.busy { Button("취소") { model.cancel() } }
                        if model.connected {
                            Button("파일 연결 끊기") { model.disconnect() }.disabled(model.busy)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(QuietStyle.canvas)
        .font(.system(size: 13))
        .navigationTitle("파일")
        .onAppear { configurationExpanded = !model.connected; addressDraft = desktop.address }
        .onChange(of: desktop.address) { _, address in addressDraft = address }
        .onChange(of: model.connected) { _, connected in configurationExpanded = !connected }
        .confirmationDialog("설정된 SSH 키를 바꿀까요?", isPresented: $confirmingKeyReplacement, titleVisibility: .visible) {
            Button("새 키 만들고 연결 설정 변경", role: .destructive) {
                guard let identityToReplace else { return }
                model.generateKey(replacingIdentity: identityToReplace)
            }
            Button("취소", role: .cancel) {}
        } message: {
            if let identityToReplace {
                Text("저장된 키: \(identityToReplace.savedPath.isEmpty ? "없음" : identityToReplace.savedPath)\n입력 중인 키: \(identityToReplace.draftPath.isEmpty ? "없음" : identityToReplace.draftPath)\n새 공개 키를 Windows에 다시 등록해야 파일을 연결할 수 있습니다. 기존 키 파일은 지우지 않습니다.")
            }
        }
    }

    private var automaticSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("자동 파일 설정", systemImage: "link").font(.headline)
            Text("Mac 키와 설정을 안전하게 전달합니다. Windows에서 한 번 승인한 뒤 두 화면의 SSH 지문을 비교하세요.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("허용할 Mac 주소 · 쉼표로 구분", text: $model.setupAddresses)
                    .textFieldStyle(.roundedBorder)
                Button("Mac 주소 찾기") { model.findSetupAddresses() }
            }.disabled(!model.canExchangeSetup)
            HStack {
                Text("설정에 사용할 Mac 주소")
                TextField("Wi-Fi 또는 Tailscale IPv4", text: $model.enrollmentBindAddress)
                    .textFieldStyle(.roundedBorder)
            }.disabled(!model.canExchangeSetup)
            Text("Windows 대상을 Tailscale 주소로 골랐다면 Mac 주소도 Tailscale 주소를 사용하세요. 같은 Wi-Fi라면 두 기기의 Wi-Fi 주소를 선택하세요.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if model.enrollmentLink.isEmpty {
                Button("자동 파일 설정 시작") { model.startAutomaticFileSetup() }
                    .buttonStyle(.borderedProminent).disabled(!model.canExchangeSetup)
            } else {
                Text("Windows Knot 도우미 → 파일 전송 → 자동 파일 설정에 아래 연결을 2분 안에 붙여 넣으세요. 인증 후 설정에는 최대 10분이 주어집니다.")
                Text(model.enrollmentLink).font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .privacySensitive()
                if let qr = EnrollmentQR.image(model.enrollmentLink) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 200, height: 200)
                        .accessibilityLabel("일회용 파일 설정 연결 QR 코드").privacySensitive()
                }
                Button("자동 설정 취소") { model.cancelEnrollment() }
            }
            Text("이 설정 연결은 받은 PC가 1회 사용할 수 있습니다. 신뢰하는 Windows에만 전달하세요. 개인 키와 암호는 보내지 않습니다.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(16).quietPanel()
    }

    private var connectionIntroduction: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("파일 연결을 준비하세요").font(.headline)
                Text("화면 연결과 별도로 Windows OpenSSH와 SSH 키를 사용합니다.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("파일 연결") { model.connect(address: addressDraft) }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy || desktop.busy)
        }
        .padding(16)
        .quietPanel()
    }

    private var fileBrowser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { model.parent() } label: { Image(systemName: "arrow.up") }
                    .help("상위 폴더 열기")
                    .accessibilityLabel("상위 폴더 열기")
                    .disabled(model.currentPath == "/")
                Text(model.currentPath)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(model.currentPath)
                Spacer(minLength: 8)
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("파일 목록 새로고침")
                    .accessibilityLabel("파일 목록 새로고침")
                Button("파일 보내기…") { model.upload() }
                    .buttonStyle(.borderedProminent)
                Button("파일 받기…") { model.download() }
                    .disabled(model.selectedEntry?.kind != .file)
            }
            .padding(12)
            .disabled(model.busy)

            Divider()
            HStack {
                Text("이름")
                Spacer()
                Text("크기").frame(width: 84, alignment: .trailing)
                Color.clear.frame(width: 48, height: 1)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(QuietStyle.canvas)
            Divider()

            if model.entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder").font(.system(size: 28, weight: .light))
                    Text(model.busy ? "파일 목록을 확인하는 중…" : "표시할 수 있는 항목이 없습니다.")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                List(model.entries, id: \.path, selection: $model.selection) { entry in
                    fileRow(entry).tag(entry.path)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: 300)
            }

            Divider()
            HStack(spacing: 12) {
                Text("표시된 \(model.entries.count)개 항목")
                Spacer()
                if let entry = model.selectedEntry {
                    Text("\(entry.name) 선택됨").lineLimit(1).truncationMode(.middle)
                } else {
                    Text("받을 파일을 목록에서 선택하세요.")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(12)
            Text("지원하지 않는 이름·경로의 항목은 생략됩니다. Windows에서 이름이나 폴더 위치를 바꾼 뒤 새로고침하세요.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .quietPanel()
    }

    private func fileRow(_ entry: SFTPEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.kind == .directory ? "folder" : entry.kind == .symlink ? "link" : "doc")
                .foregroundStyle(.tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(entry.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Group {
                if let size = entry.size, entry.kind == .file {
                    Text(byteCount(size))
                } else {
                    Text(entry.kind == .directory ? "폴더" : entry.kind == .symlink ? "링크" : "—")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(width: 84, alignment: .trailing)
            Group {
                if entry.kind == .directory {
                    Button("열기") { model.refresh(path: entry.path) }
                        .buttonStyle(.borderless)
                        .disabled(model.busy)
                        .accessibilityLabel("\(entry.name) 폴더 열기")
                } else {
                    Color.clear.frame(height: 1).accessibilityHidden(true)
                }
            }
            .frame(width: 48)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .help(entry.name)
    }

    private var connectionSettings: some View {
        DisclosureGroup(isExpanded: $configurationExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                QuietHelp(text: "화면의 PIN 페어링과 파일의 SSH 키 확인은 별개입니다. Windows 설정 도우미에서 OpenSSH와 파일 전용 계정을 먼저 준비하세요.", symbol: "key")

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        Text("PC 주소").foregroundStyle(.secondary)
                        TextField("같은 Wi-Fi 또는 Tailscale IPv4", text: $addressDraft)
                            .disabled(targetLocked)
                    }
                    GridRow {
                        Text("파일 계정").foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            TextField("Windows 파일 전용 계정", text: $model.username)
                            Text("포트").foregroundStyle(.secondary)
                            TextField("22", text: $model.port).frame(width: 64)
                                .accessibilityLabel("SSH 포트")
                        }
                    }
                    GridRow {
                        Text("Mac 개인 키").foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            TextField("SSH 개인 키 파일", text: $model.identityPath)
                                .help("이 Mac에서 사용할 SSH 개인 키 파일 경로")
                            Button("선택…") { model.chooseKey() }
                        }
                    }
                }
                .textFieldStyle(.roundedBorder)
                .disabled(settingsLocked)

                HStack {
                    Button("Mac 전용 키 만들기") {
                        if model.requiresKeyReplacementConfirmation {
                            identityToReplace = model.keyReplacementSnapshot
                            confirmingKeyReplacement = true
                        } else { model.generateKey() }
                    }
                        .disabled(settingsLocked)
                    Text("개인 키는 이 Mac에만 보관하세요.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if !model.generatedPublicKey.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Windows에 등록할 Mac 공개 키").font(.system(size: 12, weight: .medium))
                        Text(model.generatedPublicKey)
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(QuietStyle.canvas, in: RoundedRectangle(cornerRadius: 6))
                }

                Divider()
                setupExchange
                Divider()
                manualHostTrust

                Text("보낸 파일은 새 전송 폴더에 저장되며 기존 파일을 덮어쓰지 않습니다. 폴더와 여러 파일을 한꺼번에 보내는 기능은 지원하지 않습니다.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.top, 16)
        } label: {
            HStack(spacing: 8) {
                Label("파일 연결 정보", systemImage: "key")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                if model.connected { Text("OpenSSH · SFTP").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
        .padding(16)
        .quietPanel()
    }

    private var setupExchange: some View {
        DisclosureGroup("설정 파일로 복구 · 수동 교환", isExpanded: $exchangeExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text("1. Mac 키를 만든 뒤, Windows에서 허용할 이 Mac의 IPv4 주소를 확인하세요.")
                HStack(spacing: 8) {
                    TextField("허용할 Mac IPv4 주소 · 쉼표로 구분", text: $model.setupAddresses)
                        .textFieldStyle(.roundedBorder)
                    Button("Mac 주소 찾기") { model.findSetupAddresses() }
                }
                Button("Windows 설정 파일 저장…") { model.exportWindowsSetup() }
                Text("2. 공개 설정 파일을 Windows 도우미에 전달하세요. 개인 키는 포함되지 않습니다.")
                    .foregroundStyle(.secondary)
                Text("3. Windows가 만든 연결 파일을 가져오고, Windows 화면에 표시된 SSH 지문과 직접 비교하세요.")
                Button("Windows 연결 파일 불러오기…") { model.importWindowsConnection() }
                Text("연결 파일을 불러오는 것만으로 파일 연결이나 화면 페어링이 시작되지는 않습니다.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.top, 12)
            .disabled(!model.canExchangeSetup)
        }
    }

    private var manualHostTrust: some View {
        DisclosureGroup("SSH 호스트 키 직접 등록", isExpanded: $manualTrustExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Windows에서 확인한 호스트 공개 키를 입력하세요. Mac 공개 키와 다른 값입니다.")
                    .foregroundStyle(.secondary)
                TextEditor(text: $model.pinnedHostKey)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(height: 60)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(QuietStyle.border))
                    .accessibilityLabel("Windows SSH 호스트 공개 키, ssh-ed25519로 시작하는 값")
                    .disabled(settingsLocked)
                if !model.keyFingerprint.isEmpty {
                    Text("SSH 호스트 키 지문 · " + model.keyFingerprint)
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Windows 도우미에 표시된 값과 직접 확인한 키만 등록하세요. 키가 달라졌다면 변경 이유를 먼저 확인하세요.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.top, 12)
        }
    }

    private func transferProgress(_ progress: TransferProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if progress.totalBytes > 0 {
                ProgressView(value: progress.fractionCompleted)
                Text("\(byteCount(progress.bytesTransferred)) / \(byteCount(progress.totalBytes)) 전송")
            } else {
                ProgressView()
                Text("\(byteCount(progress.bytesTransferred)) 전송")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(16)
        .quietPanel()
    }

    private func byteCount(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }
}
