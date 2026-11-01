import AppKit
import SwiftUI
import KnotNativeCore

/// Presentation context deliberately contains no invitation token.
struct NativeTarget: Equatable {
    let address: String
    let port: UInt16
    let pin: String
}

struct PreviewWindow: View {
    @ObservedObject var model: SessionModel
    // Only the separately compiled synthetic renderer supplies these values.
    var simulatedDesktop: AnyView? = nil
    var simulatedFullscreen: Bool? = nil
    @StateObject private var windowState = NativeWindowState()
    @StateObject private var enrollment: EnrollmentModel
    @State private var secret = ""
    @State private var showingHelp = false
    @State private var showingOptions = false
    @State private var showingLegacy = false
    @State private var showingManualAddress = false
    @State private var activeTarget: NativeTarget?

    init(model: SessionModel, simulatedDesktop: AnyView? = nil, initialHelp: Bool = false, simulatedFullscreen: Bool? = nil, enrollment: EnrollmentModel? = nil, initialManualAddress: Bool = false) {
        self.model = model
        _enrollment = StateObject(wrappedValue: enrollment ?? EnrollmentModel())
        _showingManualAddress = State(initialValue: initialManualAddress)
        self.simulatedDesktop = simulatedDesktop
        self.simulatedFullscreen = simulatedFullscreen
        _showingHelp = State(initialValue: initialHelp)
        _showingOptions = State(initialValue: model.status == "Choose a viewer label of 1–64 UTF-8 bytes without control characters.")
    }

    private var phaseTitle: String {
        if model.phase == .approval, model.numberAuthorized { return "화면 준비 중" }
        if !model.active, enrollment.busy { return enrollment.phase == .discovering ? "PC 찾는 중" : "번호 확인 중" }
        if !model.active, enrollment.phase == .failed { return "연결 확인 필요" }
        return NativeCopy.phase(model.phase)
    }
    private var reviewedTarget: NativeTarget? {
        guard let value = model.invitation else { return nil }
        return NativeTarget(address: value.address, port: value.port, pin: value.certificateSHA256)
    }
    var body: some View {
        Group {
            if model.active { session }
            else {
                HStack(spacing: 0) {
                    sidebar
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if showingHelp { helpPage }
                            else { connectionPage }
                        }.frame(maxWidth: 760, alignment: .leading)
                            .padding(.horizontal, 32).padding(.top, 32).padding(.bottom, 28)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }.background(NativeStyle.canvas)
                }
            }
        }.frame(minWidth: 880, minHeight: 620)
            .background(NativeStyle.canvas)
            .background(NativeWindowProbe(state: windowState))
            .tint(.blue)
            .onChange(of: windowState.isFullscreen) { _, _ in
                model.showFullscreenControls = false; model.releaseInput()
            }
            .onAppear { windowState.onClose = { [weak enrollmentModel = enrollment] in enrollmentModel?.cancel() } }
            .onDisappear { enrollment.cancel(); secret = ""; windowState.onClose = nil }
            .onChange(of: model.active) { _, active in
                enrollment.cancel()
                if !active { activeTarget = nil }
            }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                NativeBrandMark(size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Knot").font(.system(size: 24, weight: .semibold))
                    Text("Native Preview").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 22).padding(.top, 30).padding(.bottom, 36)
            sidebarButton("원격 데스크톱", symbol: "display", selected: !showingHelp) { showingHelp = false }
            sidebarButton("연결 안내", symbol: "questionmark.circle", selected: showingHelp) { showingHelp = true }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Label("이번 연결만 허용", systemImage: "clock").font(.system(size: 12, weight: .medium))
                Text("연결 기록과 페어링을\n이 Mac에 저장하지 않아요.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                Divider().padding(.vertical, 5)
                Text("컴퓨터를 잇다.\n작업을 이어가다.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            }.padding(22)
        }.frame(width: 220).frame(maxHeight: .infinity).background(NativeStyle.rail)
    }
    private func sidebarButton(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 15)).frame(width: 22)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
            }.foregroundStyle(selected ? Color.blue : Color.primary.opacity(0.75))
                .padding(.horizontal, 12).frame(height: 40)
                .background(selected ? Color.blue.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityValue(selected ? "선택됨" : "")
            .padding(.horizontal, 12).padding(.bottom, 4)
    }

    private var connectionPage: some View {
        Group {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Windows에 연결").font(.system(size: 28, weight: .bold))
                    Text("다른 컴퓨터의 작업을 이 Mac에서 이어가세요.")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                NativeStatusChip(title: phaseTitle,
                    symbol: model.phase == .failed || enrollment.phase == .failed ? "exclamationmark.circle" : enrollment.busy ? "clock" : "circle",
                    tint: model.phase == .failed || enrollment.phase == .failed ? .orange : .secondary)
            }
            if model.phase == .failed || model.status == "Choose a viewer label of 1–64 UTF-8 bytes without control characters." { failurePanel }
            if let target = reviewedTarget { targetCard(target) }
            else {
                enrollmentCard
                DisclosureGroup(isExpanded: $showingManualAddress) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("LAN 검색은 같은 네트워크에서 동작해요. 주소로 찾을 때는 Windows 공유 화면에서 선택한 LAN/Tailscale IPv4 주소를 입력하세요.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        HStack {
                            TextField("192.168.x.x 또는 100.x.x.x", text: $enrollment.manualAddress)
                                .textFieldStyle(.roundedBorder).onSubmit { findPC(manual: true) }
                            Button("주소로 찾기") { findPC(manual: true) }.disabled(enrollment.busy)
                        }
                    }.padding(.top, 12)
                } label: { Label("PC가 보이지 않나요? · LAN/Tailscale 주소", systemImage: "network").font(.system(size: 13)) }
                    .disabled(enrollment.busy).padding(16).nativePanel()
                DisclosureGroup(isExpanded: $showingLegacy) { invitationCard.padding(.top, 12) }
                    label: { Label("긴 연결 코드로 연결 · 호환 모드", systemImage: "link").font(.system(size: 13)) }
                    .disabled(enrollment.busy).padding(16).nativePanel()
            }
            DisclosureGroup(isExpanded: $showingOptions) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Windows에 표시할 Mac 이름", text: $model.viewerLabel).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Windows에 표시할 Mac 이름")
                    Text("이 이름은 연결 요청의 참고 정보예요. 확인된 기기 신원을 뜻하지 않아요.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(.top, 12)
            } label: { Label("내 Mac 이름", systemImage: "laptopcomputer").font(.system(size: 13)) }
                .disabled(enrollment.busy).padding(16).nativePanel()
            HStack(alignment: .top, spacing: 18) {
                NativeStep(number: 1, title: "공유 시작", detail: "Windows에서 8자리 번호 표시")
                NativeStep(number: 2, title: "PC 선택", detail: "같은 Wi-Fi에서 찾거나 주소 입력")
                NativeStep(number: 3, title: "번호로 연결", detail: "Mac에서 8자리 번호 입력")
            }.padding(.top, 2)
            Text("미리보기 · Windows 11 SDR 기본 화면 → Apple Silicon Mac")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    private var enrollmentCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 15) {
                Image(systemName: "desktopcomputer").font(.system(size: 28, weight: .light))
                    .foregroundStyle(.blue).frame(width: 54, height: 54)
                    .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 7) {
                    Text("Windows를 바로 연결하세요").font(.system(size: 19, weight: .semibold))
                    Text("PC를 찾고 Windows에 표시된 8자리 번호만 입력하세요.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                if !enrollment.busy {
                    Button("주변 PC 찾기") { findPC() }.buttonStyle(.bordered)
                }
            }
            if !enrollment.candidates.isEmpty {
                VStack(spacing: 8) {
                    ForEach(enrollment.candidates) { candidate in
                        Button {
                            secret = ""; model.invitation = nil; activeTarget = nil
                            enrollment.select(candidate.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: enrollment.selectedID == candidate.id ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(enrollment.selectedID == candidate.id ? Color.blue : Color.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: candidate.name).font(.system(size: 14, weight: .semibold))
                                    Text(verbatim: candidate.address + " · 인증 전 PC 정보")
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }.padding(12).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(enrollment.busy)
                            .background(enrollment.selectedID == candidate.id ? Color.blue.opacity(0.06) : NativeStyle.canvas,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityValue(enrollment.selectedID == candidate.id ? "선택됨 · 기기 이름은 인증되지 않음" : "기기 이름은 인증되지 않음")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Windows의 8자리 번호").font(.system(size: 12, weight: .medium))
                SecureField("숫자 8자리", text: $enrollment.code)
                    .font(.system(size: 20, design: .monospaced)).textFieldStyle(.plain)
                    .padding(12).background(NativeStyle.canvas, in: RoundedRectangle(cornerRadius: 7))
                    .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(NativeStyle.border, lineWidth: 1) }
                    .accessibilityLabel("Windows에 표시된 8자리 연결 번호")
                    .disabled(enrollment.selected == nil || enrollment.busy).onSubmit { connectNumber() }
            }
            HStack(alignment: .center, spacing: 12) {
                if enrollment.busy { ProgressView().controlSize(.small) }
                Text(enrollment.status).font(.system(size: 12))
                    .foregroundStyle(enrollment.phase == .failed ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                if enrollment.busy { Button("취소") { enrollment.cancel() }.buttonStyle(.bordered) }
                else {
                    Button { connectNumber() } label: { Label("연결", systemImage: "arrow.right").padding(.horizontal, 8).padding(.vertical, 3) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(enrollment.selected == nil || (try? EnrollmentWire.password(enrollment.code)) == nil)
                }
            }
            Text("번호는 2분·1회용이에요. Windows에서 공유를 시작하면 번호를 아는 Mac 한 대에 이번 화면·입력 연결을 허용해요.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(26).nativePanel()
    }
    private func findPC(manual: Bool = false) {
        guard !model.active else { return }
        secret = ""; model.invitation = nil; activeTarget = nil
        enrollment.find(manual: manual)
    }
    private func connectNumber() {
        guard !model.active else { return }
        guard Invitation.validViewerLabel(model.viewerLabel) else {
            enrollment.code = ""; model.status = "Choose a viewer label of 1–64 UTF-8 bytes without control characters."; showingOptions = true; return
        }
        secret = ""; model.invitation = nil
        enrollment.connect(name: model.viewerLabel) { result in
            guard !model.active else { return }
            let value = result.offer.invitation
            activeTarget = NativeTarget(address: value.address, port: value.port, pin: value.certificateSHA256)
            model.connectAuthenticated(result)
        }
    }

    private var invitationCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 15) {
                Image(systemName: "desktopcomputer").font(.system(size: 28, weight: .light))
                    .foregroundStyle(.blue).frame(width: 54, height: 54)
                    .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 7) {
                    Text("작업할 PC를 연결하세요").font(.system(size: 19, weight: .semibold))
                    Text("Windows의 Knot에서 연결 코드를 복사해 주세요.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }.padding(.top, 4)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("연결 코드").font(.system(size: 12, weight: .medium))
                SecureField("knot-native:v1:…", text: $secret)
                    .font(.system(size: 14, design: .monospaced)).textFieldStyle(.plain)
                    .padding(12).background(NativeStyle.canvas, in: RoundedRectangle(cornerRadius: 7))
                    .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(NativeStyle.border, lineWidth: 1) }
                    .accessibilityLabel("Windows에서 복사한 연결 코드")
                    .onSubmit { review() }
            }
            HStack(spacing: 16) {
                Label("생성 후 2분 · 1회 연결", systemImage: "clock")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button { review() } label: { Label("코드 확인", systemImage: "arrow.right").padding(.horizontal, 8).padding(.vertical, 3) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(secret.isEmpty)
            }
        }.padding(26).nativePanel()
    }

    private func targetCard(_ target: NativeTarget) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "desktopcomputer").font(.system(size: 28, weight: .light)).foregroundStyle(.blue)
                    .frame(width: 54, height: 54).background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text("연결할 PC를 확인하세요").font(.system(size: 18, weight: .semibold))
                    Text(verbatim: "\(target.address):\(target.port)").font(.system(size: 15, design: .monospaced)).textSelection(.enabled)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Label("인증서 지문 · SHA-256", systemImage: "key.horizontal").font(.system(size: 12, weight: .medium))
                Text(String(target.pin.prefix(32)) + "\n" + String(target.pin.suffix(32)))
                    .font(.system(size: 13, design: .monospaced)).lineSpacing(5).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    .background(NativeStyle.canvas, in: RoundedRectangle(cornerRadius: 7))
                Text("Windows의 공유 화면에 표시된 값과 같은지 확인하세요.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack {
                Button("다른 코드 입력") { model.invitation = nil }
                Spacer()
                Button {
                    enrollment.cancel(); secret = ""
                    if Invitation.validViewerLabel(model.viewerLabel) { activeTarget = target }
                    else { showingOptions = true }
                    model.connect()
                } label: { Label("이 PC에 연결", systemImage: "arrow.right").padding(.horizontal, 8).padding(.vertical, 3) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }.padding(26).nativePanel()
    }

    private var failurePanel: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 18)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 7) {
                Text("연결을 확인해 주세요").font(.system(size: 14, weight: .semibold))
                Text(NativeCopy.status(model.status)).font(.system(size: 13)).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).nativePanel()
    }

    private var helpPage: some View {
        Group {
            VStack(alignment: .leading, spacing: 9) {
                Text("연결은, 이렇게.").font(.system(size: 28, weight: .bold))
                Text("계정이나 웹 PIN 없이 두 컴퓨터를 연결해요.").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 26) {
                NativeStep(number: 1, title: "Windows에서 화면 공유 시작", detail: "Knot Native Preview의 ‘화면 공유 시작’을 누르면 8자리 연결 번호가 표시돼요.")
                NativeStep(number: 2, title: "Mac에서 PC 찾고 선택하기", detail: "주변 PC를 찾거나 LAN/Tailscale IPv4 주소로 찾아주세요. 표시 이름과 주소만으로 기기를 신뢰하지 않아요.")
                NativeStep(number: 3, title: "8자리 번호로 연결하기", detail: "Windows에 표시된 번호를 입력하면 연결 정보를 확인한 뒤 화면을 준비해요. Windows에서 다시 승인할 필요는 없어요.")
            }.padding(26).nativePanel()
            VStack(alignment: .leading, spacing: 14) {
                Label("이번 미리보기에서", systemImage: "info.circle").font(.system(size: 15, weight: .semibold))
                Text("로그인된 Windows 11의 기본 SDR 가로 화면과 하드웨어 H.264 인코더가 필요해요. Mac은 Apple Silicon · macOS 26 이상을 지원해요.")
                Text("파일·오디오·무모니터·잠금/UAC 화면·HDR·다중 모니터·자동 재연결/업데이트는 아직 지원하지 않아요.")
                Text("8자리 번호는 2분·1회용이며 실패 횟수가 제한돼요. 종료 후에는 Windows에서 공유를 다시 시작해주세요. 번호와 페어링은 저장하지 않아요. 긴 연결 코드는 호환 모드로 남아 있고, 그 경로는 지문 확인과 Windows의 별도 승인이 필요해요.")
                Text("기본 Mac 입력기로 한글·영문을 입력해요. 한/영 전환은 Caps Lock 등 이 Mac에 설정된 키를 그대로 사용하세요. 일반적인 Windows 복사·붙여넣기는 Control+C/V를 사용해요. 물리 키 입력에서 Command는 Windows 키에 해당해요.")
            }.font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(22).nativePanel()
            Label("실기기 품질과 정식 서명은 추가 검증이 필요한 실험판이에요.", systemImage: "flask")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var immersive: Bool { simulatedFullscreen ?? windowState.isFullscreen }
    private var session: some View {
        VStack(spacing: 0) {
            sessionToolbar
                .frame(height: immersive ? 0 : nil).clipped()
                .allowsHitTesting(!immersive).accessibilityHidden(immersive)
            Divider().frame(height: immersive ? 0 : nil).clipped()
            // This sibling position and identity stay stable for all active
            // phases and fullscreen changes. Chrome overlays never reparent it.
            Group {
                if let simulatedDesktop { simulatedDesktop }
                else { NativeDesktop(model: model) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if model.phase != .streaming {
                        VStack(spacing: 16) {
                            ProgressView().controlSize(.regular)
                            Text(phaseTitle).font(.system(size: 18, weight: .semibold))
                            Text(NativeCopy.status(model.status)).font(.system(size: 13)).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).frame(maxWidth: 380)
                        }.padding(28).frame(maxWidth: 460).nativePanel().padding(24).allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottom) {
                    if model.phase == .streaming, model.inputRecovery {
                        Label("입력이 일시 중지됐어요 · 화면을 클릭하면 다시 시작해요", systemImage: "cursorarrow.click")
                            .font(.system(size: 13)).padding(.horizontal, 16).padding(.vertical, 12)
                            .nativePanel().padding(18).allowsHitTesting(false)
                    }
                }
            Divider().frame(height: immersive ? 0 : nil).clipped()
            keyboardBar
                .frame(height: immersive ? 0 : nil).clipped()
                .allowsHitTesting(!immersive).accessibilityHidden(immersive)
        }
        .ignoresSafeArea(immersive ? .container : [], edges: .all)
        .overlay(alignment: .top) {
            if immersive {
                VStack(spacing: 0) {
                    if model.showFullscreenControls {
                        VStack(spacing: 0) { sessionToolbar; Divider(); keyboardBar }
                            .nativePanel().padding(.horizontal, 16).padding(.top, 12)
                    }
                    Button {
                        model.releaseInput(); model.showFullscreenControls.toggle()
                    } label: {
                        Label(model.showFullscreenControls ? "연결 제어 접기" : "연결 제어", systemImage: "slider.horizontal.3")
                            .font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 7)
                    }.buttonStyle(.plain).nativePanel().padding(.top, 5)
                        .help("연결 제어 보기/접기 · Control+Option+Command+K")
                }
            }
        }
    }
    private var sessionToolbar: some View {
        HStack(spacing: 12) {
            NativeBrandMark(size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text("Windows 데스크톱").font(.system(size: 14, weight: .semibold))
                Text(activeTarget?.address ?? "이번 연결").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.phase == .streaming {
                Text(verbatim: "\(Int(model.videoSize.width))×\(Int(model.videoSize.height))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            NativeStatusChip(title: phaseTitle, symbol: model.phase == .streaming ? "display" : "clock", tint: model.phase == .streaming ? .blue : .secondary)
            Button { model.releaseInput(); windowState.toggleFullscreen() } label: {
                Label(immersive ? "전체 화면 나가기" : "전체 화면", systemImage: "arrow.up.left.and.arrow.down.right")
            }.disabled(!immersive && model.phase != .streaming)
            Button("연결 종료") { model.disconnect() }.buttonStyle(.bordered)
        }.padding(.horizontal, 20).padding(.vertical, 14).background(NativeStyle.surface)
    }
    private var keyboardBar: some View {
        HStack(spacing: 18) {
            Menu {
                Picker("키보드 입력", selection: $model.textMode) {
                    Text("Mac 입력기 · 기본").tag(true)
                    Text("물리 키보드 · 호환 모드").tag(false)
                }
                Text("한/영은 이 Mac의 Caps Lock 등 전환키를 사용해요.")
            } label: {
                Label(model.textMode ? "Mac 입력기 · Caps Lock 한/영" : "물리 키보드", systemImage: "keyboard")
            }.menuStyle(.borderlessButton).fixedSize()
                .onChange(of: model.textMode) { _, _ in model.releaseInput() }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(NativeCopy.status(model.status)).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)
                Text("화면 클릭으로 입력 · Control + 방향키로 Mac 공간 이동")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.font(.system(size: 12)).padding(.horizontal, 20).padding(.vertical, 12).background(NativeStyle.surface)
    }
    private func review() {
        guard !secret.isEmpty else { return }
        let draft = secret; secret = ""; enrollment.cancel()
        model.review(draft)
    }
}
