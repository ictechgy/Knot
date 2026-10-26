// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import DeskBridgeCore
import SwiftUI
import UniformTypeIdentifiers

struct MacHostPage: View {
    @EnvironmentObject private var host: MacHostModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                QuietPageHeader(title: "이 Mac 공유", subtitle: "Windows에서 이 Mac의 화면과 키보드·마우스를 사용합니다. Sunshine의 Mac 호스트는 실험 단계입니다.")
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("1. Sunshine 준비").font(.headline)
                        Spacer()
                        QuietBadge(title: host.installed ? "앱 파일 있음 · 시작할 때 서명 확인" : "설치 필요", symbol: "shippingbox")
                    }
                    Text("공식 고정 버전 \(MacHostPolicy.sunshineVersion)의 DMG를 받은 뒤, Sunshine을 Applications 폴더로 옮기세요. DMG의 앱을 직접 실행하지 말고 아래에서 공유를 시작하세요.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Sunshine DMG 받기") { chooseDownload() }.disabled(!host.canDownload)
                        if host.downloading {
                            ProgressView().controlSize(.small)
                            Button("다운로드 취소") { host.cancelDownload() }
                        }
                        if let url = host.downloadedURL { Button("검증된 DMG 열기") { open(url) } }
                        Button("설치 상태 새로 고침") { host.refresh() }.disabled(!host.activityAllowed || host.busy)
                    }
                    QuietHelp(text: "기존 Sunshine이 실행 중이면 직접 종료하세요. 기존 Sunshine 설정·인증서·키를 가져오거나 로그인 시 자동 실행을 등록하지 않습니다.")
                }.padding(16).quietPanel()

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("2. 공유 시작과 권한 승인").font(.headline)
                        Spacer()
                        QuietBadge(title: phaseTitle, symbol: host.phase == .running ? "display" : "display.trianglebadge.exclamationmark")
                    }
                    Text("아래 ‘이 Mac 공유 시작’으로 실행한 뒤, macOS 권한 요청이나 시스템 설정에 실제로 표시된 앱(Knot 또는 Sunshine)의 화면 및 시스템 오디오 기록·손쉬운 사용 권한을 직접 승인하세요. 승인 후 ‘공유 끄기’ → ‘이 Mac 공유 시작’으로 다시 시작하세요. 전체 디스크 접근·원격 로그인·클립보드 동기화는 켜지 않습니다.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("화면 기록 설정") { openSettings("Privacy_ScreenCapture") }
                        Button("손쉬운 사용 설정") { openSettings("Privacy_Accessibility") }
                    }
                    Toggle("이 Mac의 화면·키보드·마우스 원격 제어를 허용합니다. 확인 후 ‘이 Mac 공유 시작’을 누르세요.", isOn: $host.acknowledged)
                        .disabled(!host.activityAllowed || host.phase != .stopped)
                    Text("최초 공유 전에 웹 관리자 계정을 준비합니다. 기존 계정은 유지하며 아래 입력으로 변경하지 않습니다. 비밀번호는 평문 저장하거나 QR에 넣지 않습니다.").foregroundStyle(.secondary)
                    Text("최초 공유용 관리자 계정").font(.subheadline.weight(.medium))
                    TextField("최초 공유용 관리자 이름 (영문·숫자·_·-)", text: $host.adminName).disabled(!host.activityAllowed || host.phase != .stopped)
                    SecureField("최초 공유용 관리자 비밀번호 (16~128바이트)", text: $host.adminPassword).disabled(!host.activityAllowed || host.phase != .stopped)
                    HStack {
                        if host.phase == .stopped {
                            Button("이 Mac 공유 시작") { host.start() }
                                .buttonStyle(.borderedProminent).disabled(!host.canStart || !host.installed)
                        } else {
                            Button(host.phase == .stopping ? "공유 종료 중…" : "공유 끄기") { host.stop() }
                                .disabled(host.phase == .stopping)
                        }
                        Button("Sunshine 초기 설정 / PIN") { open(MacHostPolicy.webURL) }.disabled(host.phase != .running)
                    }
                    StatusPanel(status: host.status, error: host.errorMessage, busy: host.busy || host.downloading)
                    QuietHelp(text: "공유는 이 앱이 켠 프로세스에만 적용됩니다. Knot를 종료하면 함께 끕니다. Sunshine 웹의 Restart 대신 여기서 공유 끄기 → 다시 시작을 사용하세요.")
                }.padding(16).quietPanel()

                VStack(alignment: .leading, spacing: 14) {
                    Text("3. Windows에서 연결").font(.headline)
                    Text("같은 Wi-Fi 또는 기존 Tailscale로 연결하세요. Windows Knot의 ‘Mac 열기’에서 ‘QR 이미지 가져오기…’를 누르거나, 연결 링크 내용을 붙여 넣고 ‘링크 미리보기’를 누르세요. 주소를 확인한 뒤 ‘선택한 주소 사용’을 누르세요.")
                        .foregroundStyle(.secondary)
                    Text("Windows에서 ‘화면 엔진 받기’ → ‘PIN으로 Mac 연결’을 진행하세요. Moonlight 창의 PIN을 이 Mac의 ‘Sunshine 초기 설정 / PIN’에서 승인한 뒤 Windows의 ‘Mac 화면 열기’를 누르세요.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Picker("연결 주소", selection: $host.selectedAddress) {
                            if host.addresses.isEmpty { Text("사용 가능한 주소 없음").tag("") }
                            ForEach(host.addresses) { Text($0.label).tag($0.address) }
                        }.frame(maxWidth: 440).disabled(!host.activityAllowed)
                        Button("주소 새로 고침") { host.refresh() }.disabled(!host.activityAllowed || host.busy)
                    }
                    if let invitation = host.invitation {
                        HStack(alignment: .top, spacing: 20) {
                            if let image = MacHostQR.image(invitation) {
                                Image(nsImage: image).interpolation(.none).resizable().frame(width: 184, height: 184)
                                    .accessibilityLabel("Windows 연결 주소 QR 코드. 아래에서 PNG로 저장할 수 있습니다.")
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                Text(invitation.url.absoluteString).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack {
                                    Button("QR 이미지 저장…") { saveQR(invitation) }
                                    Button("연결 링크 저장…") { saveLink(invitation) }
                                }
                                QuietHelp(text: "QR·링크에는 주소만 들어 있습니다. 인증 정보나 파일 권한은 없으며, 페어링을 자동 승인하지 않습니다.", symbol: "qrcode")
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text("공유를 시작하고 유효한 LAN 또는 Tailscale 주소를 선택하면 QR·링크가 나타납니다.")
                            .foregroundStyle(.secondary)
                    }
                    QuietHelp(text: "최초 localhost 설정 페이지의 자체 서명 인증서는 이 Mac의 고정 주소인지 확인하세요. 공유기를 통한 포트 포워딩은 설정하지 마세요. LAN/WAN 스트림 암호화는 필수, UPnP는 꺼짐, 웹 설정은 이 Mac에서만 허용됩니다.", symbol: "lock")
                    QuietHelp(text: "Windows 클라이언트에서 전체 화면의 ‘Windows 키를 Mac Command로 보내기’를 켜면 Windows 키가 Command로 전달됩니다. Alt는 Option, Ctrl은 Control이며 자동 교환하지 않습니다. Ctrl+Alt+Shift+K로 시스템 키 전달을 전환하고 Ctrl+Alt+Shift+Q로 연결을 닫습니다. 한/영 전환은 실제 기기에서 확인하세요.", symbol: "keyboard")
                    QuietHelp(text: "지금은 화면 연결만 제공합니다. Windows → Mac 파일 전송, 잠금·로그인 전 화면, 절전 복귀, 한/영·Command 키 동작과 소리는 실제 기기 확인이 필요합니다.", symbol: "checklist")
                }.padding(16).quietPanel()
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.background(QuietStyle.canvas).font(.system(size: 13)).onAppear { host.refresh() }
    }
    private var phaseTitle: String {
        switch host.phase { case .stopped: "공유 꺼짐"; case .starting: "시작 중"; case .running: "프로세스 실행 중"; case .stopping: "종료 중" }
    }
    private func chooseDownload() {
        guard host.canDownload else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.diskImage]
        panel.nameFieldStringValue = "Sunshine-\(MacHostPolicy.sunshineVersion)-\(MacHostPolicy.currentDownload.architecture).dmg"
        panel.message = "공식 파일 크기와 SHA256을 확인한 뒤 저장합니다. 같은 이름의 파일은 덮어쓰지 않습니다."
        guard panel.runModal() == .OK, let url = panel.url, host.canDownload else { return }
        do { try MacHostFileWork.requireAbsent(url); host.download(to: url) }
        catch { host.errorMessage = (error as? MacHostPolicy.Failure)?.localizedDescription ?? "저장 위치를 확인하고 다른 이름이나 폴더를 선택하세요." }
    }
    private func open(_ url: URL) {
        guard host.activityAllowed else { return }
        if !NSWorkspace.shared.open(url) { host.errorMessage = "선택한 파일 또는 설정 페이지를 열지 못했습니다. 위치를 확인하고 다시 시도하세요." }
    }
    private func openSettings(_ pane: String) { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { open(url) } }
    private func saveQR(_ invitation: ConnectionInvitation) {
        guard let data = MacHostQR.png(invitation) else { host.errorMessage = "QR 이미지를 만들지 못했습니다."; return }
        save(data, type: .png, name: "Knot-Mac-연결.png")
    }
    private func saveLink(_ invitation: ConnectionInvitation) { save(Data(invitation.url.absoluteString.utf8), type: .plainText, name: "Knot-Mac-연결.txt") }
    private func save(_ data: Data, type: UTType, name: String) {
        guard host.activityAllowed else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [type]; panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url, host.activityAllowed else { return }
        do { try data.write(to: url, options: .withoutOverwriting) }
        catch { host.errorMessage = "연결 파일을 저장하지 못했습니다. 다른 이름이나 폴더를 선택하세요." }
    }
}
