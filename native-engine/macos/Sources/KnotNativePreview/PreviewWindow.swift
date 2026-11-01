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
    @State private var secret = ""
    @State private var showingHelp = false
    @State private var showingOptions = false
    @State private var activeTarget: NativeTarget?

    init(model: SessionModel, simulatedDesktop: AnyView? = nil, initialHelp: Bool = false) {
        self.model = model
        self.simulatedDesktop = simulatedDesktop
        _showingHelp = State(initialValue: initialHelp)
        _showingOptions = State(initialValue: model.status == "Choose a viewer label of 1–64 UTF-8 bytes without control characters.")
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
            .tint(.blue)
            .onChange(of: model.active) { _, active in if !active { activeTarget = nil } }
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
                NativeStatusChip(title: NativeCopy.phase(model.phase), symbol: model.phase == .failed ? "exclamationmark.circle" : "circle", tint: model.phase == .failed ? .orange : .secondary)
            }
            if model.phase == .failed || model.status == "Choose a viewer label of 1–64 UTF-8 bytes without control characters." { failurePanel }
            if let target = reviewedTarget { targetCard(target) }
            else { invitationCard }
            DisclosureGroup(isExpanded: $showingOptions) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Windows에 표시할 Mac 이름", text: $model.viewerLabel).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Windows에 표시할 Mac 이름")
                    Text("이 이름은 연결 요청의 참고 정보예요. 확인된 기기 신원을 뜻하지 않아요.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(.top, 12)
            } label: { Label("내 Mac 이름", systemImage: "laptopcomputer").font(.system(size: 13)) }
                .padding(16).nativePanel()
            HStack(alignment: .top, spacing: 18) {
                NativeStep(number: 1, title: "코드 복사", detail: "Windows에서 화면 공유 시작")
                NativeStep(number: 2, title: "PC 확인", detail: "주소와 인증서 지문 대조")
                NativeStep(number: 3, title: "연결 허용", detail: "Windows에서 요청 승인")
            }.padding(.top, 2)
            Text("미리보기 · Windows 11 SDR 기본 화면 → Apple Silicon Mac")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
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
                    secret = ""
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
                NativeStep(number: 1, title: "Windows에서 연결 코드 만들기", detail: "Knot Native Preview의 ‘화면 공유 시작’을 누르고 연결 코드를 복사하세요.")
                NativeStep(number: 2, title: "Mac에서 PC 확인하기", detail: "코드를 입력한 뒤 주소와 인증서 지문을 Windows 화면과 대조하세요.")
                NativeStep(number: 3, title: "Windows에서 연결 허용하기", detail: "요청 주소와 표시 이름을 확인하고 허용하면 화면을 준비해요.")
            }.padding(26).nativePanel()
            VStack(alignment: .leading, spacing: 14) {
                Label("이번 미리보기에서", systemImage: "info.circle").font(.system(size: 15, weight: .semibold))
                Text("로그인된 Windows 11의 기본 SDR 가로 화면과 하드웨어 H.264 인코더가 필요해요. Mac은 Apple Silicon · macOS 26 이상을 지원해요.")
                Text("파일·오디오·무모니터·잠금/UAC 화면·HDR·다중 모니터·자동 재연결/업데이트는 아직 지원하지 않아요.")
                Text("연결 코드는 2분 동안 한 번만 사용할 수 있어요. 종료 후에는 새 코드가 필요해요. 연결 코드와 페어링은 저장하지 않아요.")
                Text("한글은 ‘한글 · Mac 입력기’를 켜서 입력하세요. 일반적인 Windows 복사·붙여넣기는 Control+C/V를 사용해요. 물리 키 입력에서 Command는 Windows 키에 해당해요.")
            }.font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(22).nativePanel()
            Label("실기기 품질과 정식 서명은 추가 검증이 필요한 실험판이에요.", systemImage: "flask")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var session: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                NativeBrandMark(size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Windows 데스크톱").font(.system(size: 14, weight: .semibold))
                    Text(activeTarget?.address ?? "이번 연결").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                NativeStatusChip(title: NativeCopy.phase(model.phase), symbol: model.phase == .streaming ? "display" : "clock", tint: model.phase == .streaming ? .blue : .secondary)
                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Label("전체 화면", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .disabled(model.phase != .streaming)
                Button("연결 종료") { model.disconnect() }.buttonStyle(.bordered)
            }.padding(.horizontal, 20).padding(.vertical, 14).background(NativeStyle.surface)
            Divider()
            // This position and identity stay stable for every active phase.
            // The first decoded image needs its presenter before .streaming.
            Group {
                if let simulatedDesktop { simulatedDesktop }
                else { NativeDesktop(model: model) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if model.phase != .streaming {
                        VStack(spacing: 16) {
                            ProgressView().controlSize(.regular)
                            Text(NativeCopy.phase(model.phase)).font(.system(size: 18, weight: .semibold))
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
            Divider()
            HStack(spacing: 18) {
                Toggle("한글 · Mac 입력기", isOn: $model.textMode).toggleStyle(.checkbox)
                    .help("한글 등은 이 Mac에서 조합한 뒤 전송해요. 후보 창은 로컬 포인터 가까이에 표시돼요.")
                    .onChange(of: model.textMode) { _,_ in model.releaseInput() }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(NativeCopy.status(model.status)).font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(2).textSelection(.enabled)
                    Text("화면 클릭으로 입력 · Control + 방향키로 Mac 공간 이동")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.font(.system(size: 12)).padding(.horizontal, 20).padding(.vertical, 12).background(NativeStyle.surface)
        }
    }
    private func review() {
        guard !secret.isEmpty else { return }
        let draft = secret; secret = ""
        model.review(draft)
    }
}
