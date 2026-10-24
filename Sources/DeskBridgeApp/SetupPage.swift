// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 DeskBridge contributors
import AppKit
import Foundation
import SwiftUI

struct SetupPage: View {
    var onDesktop: () -> Void = {}
    var onFiles: () -> Void = {}
    @State private var windowsDetailsExpanded = false
    @State private var fileDetailsExpanded = false
    @ObservedObject private var updates = KnotUpdates.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                QuietPageHeader(title: "처음 설정", subtitle: "내 PC를 한 번 연결하면, 다음부터는 바로 열 수 있어요.")

                VStack(spacing: 12) {
                    step(number: "1", title: "Windows 준비", subtitle: nil) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Windows에서 Sunshine을 실행하세요. Mac과 같은 Wi-Fi 또는 Tailscale로 연결할 수 있어요.")
                                .foregroundStyle(.secondary)
                            DisclosureGroup("준비 방법 보기", isExpanded: $windowsDetailsExpanded) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("동봉된 Windows quick-setup EXE를 두 번 클릭하세요. ‘연결 준비 · 자동 설정’을 누르면 필요한 Sunshine 설치와 계정·보안·PIN 창으로 이어집니다. 파일 설정은 나중에 추가할 수 있어요.")
                                    Link("Sunshine 공식 프로젝트", destination: URL(string: "https://github.com/LizardByte/Sunshine")!)
                                    QuietHelp(text: "Windows 도우미의 ‘모니터 없이 사용’에서 안내를 확인하세요. 가상 화면 자동 설치는 드라이버 보안 검토로 현재 보류 중입니다. 최초 설정에는 모니터나 다른 접속 수단이 필요합니다.", symbol: "display")
                                    QuietHelp(text: "최신 Windows Knot의 간편 연결에서 필수 암호화를 적용하세요. 고급·수동 설정에서는 Sunshine의 LAN/WAN 암호화 모드를 모두 ‘모든 사용자에게 필수’(Required for all clients)로 Save → Apply합니다.", symbol: "lock")
                                    HStack(spacing: 12) {
                                        Button("설정 안내 열기") { openGuide() }
                                    }
                                }
                                .padding(.top, 12)
                            }
                        }
                    }

                    step(number: "2", title: "화면 페어링", subtitle: nil) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("원격 화면에서 근처 PC를 선택하세요. 검색되지 않거나 Tailscale을 쓴다면 Windows 도우미의 QR 이미지·카메라 스캔·연결 링크로 주소를 가져올 수 있어요. 이어서 Windows Knot의 ‘연결 준비’ 창에서 Mac 요청을 선택하고 표시된 PIN을 승인하세요. 고급·수동 설정은 Windows 브라우저의 https://localhost:47990/pin 입니다.")
                                .foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                Button("PC 찾기 / QR 연결", action: onDesktop)
                                Text("페어링한 뒤 Sunshine의 Desktop을 열면 됩니다.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                    }

                    step(number: "3", title: "파일 연결", subtitle: "선택 사항 · 화면 연결과 별도") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("파일 탭의 자동 파일 설정으로 Windows 도우미와 연결하세요. Windows의 승인 후 파일 전용 계정을 준비하고 SSH 호스트 키 지문을 직접 비교해 등록합니다.")
                                .foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                Button("파일 연결 설정", action: onFiles)
                                Button("설정 안내 열기") { openGuide() }
                            }
                            DisclosureGroup("파일 연결 준비 과정", isExpanded: $fileDetailsExpanded) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("1. Mac의 파일 탭에서 자동 파일 설정을 시작하세요. 처음에는 Mac 전용 키를 만들고 사용할 Mac 주소를 선택합니다.")
                                    Text("2. 일회용 연결 링크를 Windows Knot 도우미에 붙여 넣고 Mac 키·허용 주소와 UAC 요청을 확인하세요.")
                                    Text("3. Windows가 자동으로 보낸 연결 정보의 SSH 지문을 두 화면에서 비교한 뒤 등록하세요. JSON 설정 파일 교환도 대체 방법으로 사용할 수 있습니다.")
                                    Text("직접 설정한 OpenSSH를 사용한다면, Mac 공개 키를 Windows에 등록하고 Windows 호스트 공개 키를 Mac의 파일 탭에 직접 입력할 수 있습니다.")
                                        .foregroundStyle(.secondary)
                                    QuietHelp(text: "파일 계정은 지정한 공유 폴더 안에서만 사용하도록 설정합니다. 화면 전체 제어 권한은 이 폴더 제한과 별개입니다.", symbol: "folder.badge.person.crop")
                                    Button("Windows 수동 설정 파일 보기") { openSetupFolder() }
                                }
                                .padding(.top, 12)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    QuietHelp(text: "전체 화면으로 열면 Windows가 하나의 Space가 됩니다. Control + ↑로 Mission Control을 열고, Control + ← / →로 Mac과 Windows를 오가세요.", symbol: "rectangle.3.group")
                    QuietHelp(text: "기본 입력 모드는 Mac 입력기입니다. Windows 입력기는 영문으로 두세요. 필요하면 원격 화면에서 물리 키보드 모드로 바꿀 수 있어요.", symbol: "keyboard")
                    Text("모니터 입력을 바꾼 뒤에도 Windows가 화면을 제공하는지는 PC에서 확인해야 합니다.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(16)
                .quietPanel()

                VStack(alignment: .leading, spacing: 12) {
                    Text("앱 업데이트").font(.headline)
                    Text(updates.status).font(.callout).foregroundStyle(.secondary)
                    Button("업데이트 확인…") { updates.checkForUpdates() }
                        .disabled(updates.installationPending)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16).quietPanel()

                Text(versionNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(QuietStyle.canvas)
        .font(.system(size: 13))
        .navigationTitle("시작하기")
    }

    private func step<Content: View>(number: String, title: String, subtitle: String?, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(number)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(QuietStyle.canvas, in: Circle())
                .overlay(Circle().stroke(QuietStyle.border))
                .accessibilityLabel("\(number)단계")
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title).font(.system(size: 14, weight: .semibold))
                        if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 14, weight: .semibold))
                        if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                }
                .padding(.top, 4)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .quietPanel()
    }

    private var versionNote: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "DeskBridgeVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let name = version.map { "Knot \($0)" } ?? "Knot"
        return "\(name) · macOS 26+ · GPLv3\nGlimmerEngine / Moonlight 기여자들의 소스를 사용합니다. Windows 연결, 한글 입력과 성능은 실제 기기에서 확인이 필요합니다."
    }

    private func openGuide() {
        if let url = Bundle.main.url(forResource: "WINDOWS_SETUP", withExtension: "md") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openSetupFolder() {
        if let root = Bundle.main.resourceURL {
            NSWorkspace.shared.open(root.appendingPathComponent("WindowsSetup", isDirectory: true))
        }
    }
}
