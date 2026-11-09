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
    var updates: NativeUpdateModel?
    // Only the separately compiled synthetic renderer supplies these values.
    var simulatedDesktop: AnyView? = nil
    var simulatedFullscreen: Bool? = nil
    var simulatedFiles: FileTransferModel? = nil
    var simulatedAudio: NativeAudioSession? = nil
    var simulatedVideo: VideoControlModel? = nil
    @StateObject private var windowState: NativeWindowState
    @StateObject private var enrollment: EnrollmentModel
    @State private var secret = ""
    @State private var showingHelp = false
    @State private var showingOptions = false
    @State private var showingLegacy = false
    @State private var showingAlternatives = false
    @State private var showingFiles = false
    @StateObject private var filePromises = NativeFilePromiseOwner()
    @FocusState private var codeFocused: Bool
    @State private var activeTarget: NativeTarget?
    @State private var deviceToForget: SavedNativeDevice?
    @State private var showingStorageWarning = false
    @State private var storageWarningDismissed = false

    init(model: SessionModel, simulatedDesktop: AnyView? = nil, initialHelp: Bool = false, simulatedFullscreen: Bool? = nil, enrollment: EnrollmentModel? = nil, initialManualAddress: Bool = false, windowState: NativeWindowState? = nil, simulatedFiles: FileTransferModel? = nil, initialFiles: Bool = false, updates: NativeUpdateModel? = nil, simulatedAudio: NativeAudioSession? = nil, simulatedVideo: VideoControlModel? = nil) {
        self.model = model
        self.updates = updates
        _windowState = StateObject(wrappedValue: windowState ?? NativeWindowState())
        _enrollment = StateObject(wrappedValue: enrollment ?? EnrollmentModel())
        _showingAlternatives = State(initialValue: initialManualAddress)
        self.simulatedDesktop = simulatedDesktop
        self.simulatedFullscreen = simulatedFullscreen
        self.simulatedFiles = simulatedFiles
        self.simulatedAudio = simulatedAudio
        self.simulatedVideo = simulatedVideo
        _showingFiles = State(initialValue: initialFiles)
        _showingHelp = State(initialValue: initialHelp)
        _showingOptions = State(initialValue: model.status == "Choose a viewer label of 1–64 UTF-8 bytes without control characters.")
    }

    private var phaseTitle: String {
        if model.hasPendingReconnect { return "재연결 준비 중" }
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
                        .disabled(model.isAuthorizingSavedDeviceStorage)
                }
            }
        }.frame(minWidth: 880, minHeight: 620)
            .background(NativeStyle.canvas)
            .background(NativeWindowProbe(state: windowState))
            .tint(.blue)
            .onChange(of: windowState.isFullscreen) { _, _ in
                model.showFullscreenControls = false; model.releaseInput()
            }
            .onAppear { windowState.bindSession(model, enrollment: enrollment); if showingFiles { model.setFileUIInputSuspended(true) } }
            .onDisappear { enrollment.cancel(); secret = "" }
            .onChange(of: enrollment.selectedID) { _, selected in
                codeFocused = selected != nil
            }
            .onChange(of: model.savedDeviceStorageMessage) { _, _ in storageWarningDismissed = false }
            .onChange(of: model.isSystemSleeping) { _, sleeping in
                if sleeping, enrollment.busy { enrollment.interrupt(.sleep) }
            }
            .onChange(of: model.active) { _, active in
                enrollment.cancel()
                if !active { activeTarget = nil; setFilesVisible(false) }
            }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                NativeBrandMark(size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Knot").font(.system(size: 24, weight: .semibold))
                    Text("Native Preview").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(model.diagnostics.buildIdentity.version ?? "빌드 정보 없음")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityLabel("실행 중인 앱 버전: \(model.diagnostics.buildIdentity.diagnosticValue)")
                }
            }.padding(.horizontal, 22).padding(.top, 30).padding(.bottom, 36)
            sidebarButton("원격 데스크톱", symbol: "display", selected: !showingHelp) { showingHelp = false }
            sidebarButton("연결 안내", symbol: "questionmark.circle", selected: showingHelp) { showingHelp = true }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Label("내 기기는 한 번 등록", systemImage: "lock.shield").font(.system(size: 12, weight: .medium))
                Text("등록은 직접 선택해요.\n저장한 기기는 언제든 해제해요.")
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
                    Text("이 Mac에서 Windows의 화면과 키보드를 사용해요.")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                NativeStatusChip(title: phaseTitle,
                    symbol: model.phase == .failed || enrollment.phase == .failed ? "exclamationmark.circle" : enrollment.busy ? "clock" : "circle",
                    tint: model.phase == .failed || enrollment.phase == .failed ? .orange : .secondary)
            }
            savedDeviceStorageWarning
            if model.hasPendingReconnect {
                VStack(alignment: .leading, spacing: 14) {
                    Label("등록된 PC에 다시 연결해요", systemImage: "arrow.clockwise").font(.headline)
                    Text(model.status).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("재연결 취소") { enrollment.cancel(); model.disconnect() }
                        .buttonStyle(.bordered)
                        .accessibilityHint("자동 재연결을 멈추고 다른 PC를 선택할 수 있어요.")
                }.padding(20).nativePanel()
            } else {
                if model.phase == .failed || model.status == "Choose a viewer label of 1–64 UTF-8 bytes without control characters." { failurePanel }
                if !model.savedDevices.isEmpty { savedDevicesCard }
                if let target = reviewedTarget { targetCard(target) }
                else {
                    connectionProgress
                    if let candidate = enrollment.selected { numberCard(candidate) }
                    else {
                        discoveryCard
                        alternateMethods
                    }
                }
            }
            DisclosureGroup(isExpanded: $showingOptions) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Windows에 표시할 Mac 이름", text: $model.viewerLabel).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Windows에 표시할 Mac 이름")
                    Text("이 이름은 연결 요청의 참고 정보예요. 확인된 기기 신원을 뜻하지 않아요.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Toggle("등록 기기의 일시적인 끊김 자동 복구", isOn: $model.autoReconnect)
                    Text(model.diagnostics.buildIdentity.displayText)
                        .font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    Divider()
                    NativeIdleVideoSettings(minutes: $model.idleVideoMinutes, backgroundOnly: $model.idleVideoBackgroundOnly,
                        onInteraction: { model.acceptedLocalInteraction() })
                    Text("빠른 화면 전환 · Control+Option+Command+B").font(.system(size: 12)).foregroundStyle(.secondary)
                    if let updates { NativeUpdatesView(updates: updates, beforeExit: { model.prepareForUpdate() }) }
                }.padding(.top, 12)
            } label: { Label("연결 설정 · 내 Mac 이름", systemImage: "laptopcomputer").font(.system(size: 13)) }
                .disabled(enrollment.busy).padding(16).nativePanel()
            NativeConnectionDiagnosticsView(diagnostics: model.diagnostics)
            Text("미리보기 · Windows 11 SDR 기본 화면 → Apple Silicon Mac")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var savedDeviceStorageWarning: some View {
        if let message = model.savedDeviceStorageMessage {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("자동 재연결 등록을 확인해 주세요").font(.system(size: 13, weight: .semibold))
                    Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Button(model.isAuthorizingSavedDeviceStorage ? "접근 확인 중…" : "키체인 접근 허용") {
                    model.releaseInput()
                    model.authorizeSavedDeviceStorage()
                }.buttonStyle(.bordered).disabled(model.isAuthorizingSavedDeviceStorage)
                    .accessibilityHint("macOS가 접근 확인을 요청할 수 있어요. 허용 여부는 직접 선택해요.")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16).nativePanel()
        }
    }

    @ViewBuilder private var sessionStorageWarningControl: some View {
        if model.savedDeviceStorageMessage != nil, !storageWarningDismissed {
            HStack(spacing: 8) {
                Button { model.releaseInput(); showingStorageWarning = true } label: {
                    Label(model.isAuthorizingSavedDeviceStorage ? "키체인 접근 확인 중…" : "자동 재연결 등록 확인",
                          systemImage: "exclamationmark.triangle")
                }.buttonStyle(.plain)
                    .popover(isPresented: $showingStorageWarning) {
                        savedDeviceStorageWarning.frame(width: 430).padding(12)
                    }
                Button { storageWarningDismissed = true; showingStorageWarning = false } label: {
                    Image(systemName: "xmark")
                }.buttonStyle(.plain).accessibilityLabel("이번 화면에서 등록 안내 접기")
            }.font(.system(size: 12)).padding(10).nativePanel()
        }
    }

    private var savedDevicesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("내 PC", systemImage: "desktopcomputer").font(.headline)
            ForEach(model.savedDevices) { device in
                HStack {
                    VStack(alignment: .leading) { Text(device.name); Text(device.address).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("연결") {
                        guard !model.active, !model.isSystemSleeping else { return }
                        enrollment.cancel(); model.connectSaved(device.id)
                    }.buttonStyle(.borderedProminent)
                    Button("등록 해제", role: .destructive) { deviceToForget = device }
                }
            }
        }.padding(20).nativePanel()
            .confirmationDialog("PC 등록을 해제할까요?", isPresented: Binding(get: { deviceToForget != nil }, set: { if !$0 { deviceToForget = nil } }), presenting: deviceToForget) { device in
                Button("등록 해제", role: .destructive) { model.forgetSaved(device.id); deviceToForget = nil }
                Button("취소", role: .cancel) { deviceToForget = nil }
            } message: { device in
                Text("\(device.name)의 저장된 연결을 해제해요. 다시 등록하려면 Windows의 새 8자리 번호가 필요해요.")
            }
    }

    private var connectionStep: Int {
        enrollment.selected != nil ? 3 : enrollment.candidates.isEmpty ? 1 : 2
    }
    private var connectionProgress: some View {
        HStack(spacing: 12) {
            progressStep(1, "주변 PC 찾기")
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary).accessibilityHidden(true)
            progressStep(2, "PC 선택")
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary).accessibilityHidden(true)
            progressStep(3, "번호 입력")
        }.accessibilityElement(children: .contain).accessibilityLabel("연결 순서 · 현재 \(connectionStep)단계")
    }
    private func progressStep(_ number: Int, _ title: String) -> some View {
        let current = number == connectionStep
        let complete = number < connectionStep
        return HStack(spacing: 7) {
            Image(systemName: complete ? "checkmark.circle.fill" : "\(number).circle\(current ? ".fill" : "")")
                .font(.system(size: 16)).accessibilityHidden(true)
            Text(title).font(.system(size: 12, weight: current ? .semibold : .regular))
        }.foregroundStyle(current || complete ? Color.blue : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(number)단계 \(title) · \(complete ? "완료" : current ? "현재 단계" : "다음 단계")")
    }

    private var discoveryTitle: String {
        if enrollment.phase == .discovering { return "주변 Windows PC를 찾고 있어요" }
        if !enrollment.candidates.isEmpty { return "연결할 Windows PC를 선택하세요" }
        if enrollment.phase == .failed { return "연결 준비를 확인해주세요" }
        return enrollment.hasSearched ? "공유 중인 PC가 보이지 않아요" : "먼저 Windows에서 공유를 시작하세요"
    }
    private var discoveryCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "desktopcomputer").font(.system(size: 28, weight: .light))
                    .foregroundStyle(.blue).frame(width: 50, height: 50)
                    .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 7) {
                    Text(discoveryTitle).font(.system(size: 19, weight: .semibold))
                    Text(enrollment.candidates.isEmpty ? "Windows PC와 이 Mac에 Knot Native Preview가 필요해요." : "Windows에 표시된 PC 이름·주소와 비교하고 선택해주세요.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            if !enrollment.candidates.isEmpty {
                VStack(spacing: 8) {
                    ForEach(enrollment.candidates) { candidate in
                        Button {
                            guard !model.active, !model.isSystemSleeping else { return }
                            model.prepareForNewTarget()
                            secret = ""; model.invitation = nil; activeTarget = nil
                            enrollment.select(candidate.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "desktopcomputer").font(.system(size: 20)).foregroundStyle(.blue).frame(width: 30)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(verbatim: candidate.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                    Text(verbatim: candidate.address).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Label("선택", systemImage: "chevron.right").font(.system(size: 12, weight: .medium)).foregroundStyle(.blue)
                            }.padding(14).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(enrollment.busy)
                            .background(NativeStyle.canvas, in: RoundedRectangle(cornerRadius: 8))
                            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(NativeStyle.border, lineWidth: 1) }
                            .accessibilityLabel("\(candidate.name), \(candidate.address), 이 PC 선택")
                            .accessibilityHint("인증 전 PC 정보예요. 선택 후 Windows의 8자리 번호를 입력해요.")
                    }
                }
                Text("PC 이름과 주소는 아직 인증되지 않은 정보예요. 다음 단계에서 해당 Windows의 번호로 연결을 확인해요.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if enrollment.phase != .discovering {
                VStack(alignment: .leading, spacing: 18) {
                    NativeStep(number: 1, title: "Windows에서 Knot 열기", detail: "‘화면 공유 시작’을 누르세요. Windows에 8자리 번호가 나타나요.")
                    NativeStep(number: 2, title: "이 Mac에서 PC 찾고 선택하기", detail: "아래 버튼으로 같은 Wi-Fi의 PC를 찾으세요. 번호는 PC를 고른 다음 입력해요.")
                }
            }
            if enrollment.phase == .failed || enrollment.hasSearched || enrollment.busy {
                HStack(alignment: .top, spacing: 10) {
                    if enrollment.busy { ProgressView().controlSize(.small) }
                    else if enrollment.phase == .failed { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                    Text(enrollment.status).font(.system(size: 12))
                        .foregroundStyle(enrollment.phase == .failed ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine)
            }
            HStack(spacing: 12) {
                if enrollment.busy {
                    Button("찾기 취소") { enrollment.cancel() }.buttonStyle(.bordered)
                } else {
                    Button { findPC() } label: {
                        Label(enrollment.hasSearched || enrollment.phase == .failed ? "다시 찾기" : "주변 PC 찾기", systemImage: "magnifyingglass")
                            .padding(.horizontal, 6).padding(.vertical, 3)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                }
                Spacer()
                Button("처음 연결하는 방법") { showingHelp = true }.buttonStyle(.link)
            }
        }.padding(26).nativePanel()
    }

    private func numberCard(_ candidate: EnrollmentCandidate) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("선택한 Windows PC", systemImage: "desktopcomputer").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Text(verbatim: candidate.name).font(.system(size: 19, weight: .semibold)).lineLimit(1)
                    Text(verbatim: candidate.address).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                }
                Spacer(minLength: 12)
                Button("다른 PC 선택") { codeFocused = false; enrollment.changePC() }.buttonStyle(.bordered)
            }
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Text("이 Windows에 표시된 8자리 번호").font(.system(size: 17, weight: .semibold))
                Text("선택한 PC의 Knot 공유 화면을 보세요. 번호를 입력하면 화면 연결을 확인해요.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                SecureField("숫자 8자리", text: $enrollment.code)
                    .font(.system(size: 24, design: .monospaced)).textFieldStyle(.plain)
                    .padding(14).background(NativeStyle.canvas, in: RoundedRectangle(cornerRadius: 7))
                    .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(codeFocused ? Color.blue : NativeStyle.border, lineWidth: 1) }
                    .accessibilityLabel("선택한 Windows에 표시된 8자리 연결 번호")
                    .focused($codeFocused).disabled(enrollment.busy).onSubmit { connectNumber() }
            }
            Toggle("내 PC로 등록 · 다음에는 번호 없이 연결", isOn: $model.rememberThisPC).disabled(enrollment.busy)
            HStack(alignment: .center, spacing: 12) {
                if enrollment.busy { ProgressView().controlSize(.small) }
                Text(enrollment.phase == .failed || enrollment.busy ? enrollment.status : "번호는 2분 동안 한 번만 사용할 수 있어요.")
                    .font(.system(size: 12)).foregroundStyle(enrollment.phase == .failed ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                if enrollment.busy {
                    Button("취소") { codeFocused = false; enrollment.changePC() }.buttonStyle(.bordered)
                } else {
                    Button { connectNumber() } label: {
                        Label("이 PC에 연결", systemImage: "arrow.right").padding(.horizontal, 6).padding(.vertical, 3)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled((try? EnrollmentWire.password(enrollment.code)) == nil)
                }
            }
            Text("이름·주소는 인증 전 정보예요. 번호를 아는 Mac 한 대에 Windows에 표시한 공유 범위가 허용돼요. 번호가 만료됐다면 Windows에서 공유를 다시 시작하세요.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(26).nativePanel()
    }

    private var alternateMethods: some View {
        DisclosureGroup(isExpanded: $showingAlternatives) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("LAN / Tailscale 주소로 PC 찾기", systemImage: "network").font(.system(size: 13, weight: .medium))
                    Text("주변 검색은 같은 네트워크에서 동작해요. Windows 공유 화면의 LAN/Tailscale IPv4 주소로도 찾을 수 있어요. 찾은 PC를 선택한 뒤 번호를 입력하세요.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack {
                        TextField("192.168.x.x 또는 100.x.x.x", text: $enrollment.manualAddress)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("Windows의 LAN 또는 Tailscale IPv4 주소")
                            .onSubmit { findPC(manual: true) }
                        Button("주소로 찾기") { findPC(manual: true) }.disabled(enrollment.busy)
                    }
                }
                Divider()
                DisclosureGroup(isExpanded: $showingLegacy) { invitationCard.padding(.top, 12) }
                    label: { Label("긴 연결 코드 · 호환 모드", systemImage: "link").font(.system(size: 13)) }
            }.padding(.top, 14)
        } label: { Label("다른 연결 방법", systemImage: "ellipsis.circle").font(.system(size: 13)) }
            .disabled(enrollment.busy).padding(16).nativePanel()
    }
    private func findPC(manual: Bool = false) {
        guard !model.active, !model.isSystemSleeping else { return }
        model.prepareForNewTarget()
        secret = ""; model.invitation = nil; activeTarget = nil
        codeFocused = false
        enrollment.find(manual: manual)
    }
    private func connectNumber() {
        guard !model.active, !model.isSystemSleeping else { return }
        guard Invitation.validViewerLabel(model.viewerLabel) else {
            enrollment.code = ""; model.status = "Choose a viewer label of 1–64 UTF-8 bytes without control characters."; showingOptions = true; return
        }
        codeFocused = false
        secret = ""; model.invitation = nil
        enrollment.connect(name: model.viewerLabel) { result in
            guard !model.active, !model.isSystemSleeping else {
                enrollment.interrupt(model.isSystemSleeping ? .sleep : .anotherConnection, authenticated: true); return
            }
            let value = result.offer.invitation
            model.savedDeviceLabel = enrollment.selected?.name ?? "Windows PC"
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
                    guard !model.active, !model.isSystemSleeping else { return }
                    guard Invitation.validViewerLabel(model.viewerLabel) else {
                        model.status = "Choose a viewer label of 1–64 UTF-8 bytes without control characters."
                        showingOptions = true
                        return
                    }
                    enrollment.cancel(); secret = ""
                    activeTarget = target
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
                Text(NativeCopy.status(model.status, reconnectMethod: model.reconnectMethod)).font(.system(size: 13)).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).nativePanel()
    }

    private var helpPage: some View {
        Group {
            VStack(alignment: .leading, spacing: 9) {
                Text("처음 연결하기").font(.system(size: 28, weight: .bold))
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
                Text("연결 중 ‘파일’에서 파일·폴더를 주고받으세요. Finder 항목을 원격 화면에 놓으면 Windows 공유 폴더로 복사돼요. Windows 탐색기 항목은 버튼을 누른 채 화면 밖 Finder로 끌어오세요. Mac 쪽 아이콘이 나타난 뒤 놓으면 돼요. 목록의 ‘받기’도 사용할 수 있어요. 원본과 기존 파일은 유지하며 앱 패키지·링크·클립보드 동기화는 지원하지 않아요.")
                Text("Windows에서 공유 시작 전에 ‘Windows 재생 소리 포함’을 켜면 이 Mac에서 소리를 들을 수 있어요. 마이크는 공유하지 않아요. 연결 제어의 스피커 버튼으로 음소거할 수 있어요.")
                Text("무모니터·잠금/UAC 화면·HDR·다중 모니터는 아직 지원하지 않아요. 자동 업데이트는 서명된 공개 배포 피드 구성 후 사용할 수 있어요.")
                Text("8자리 번호는 2분·1회용이며 실패 횟수가 제한돼요. 내 PC로 등록하면 키체인에 기기 자격 증명을 저장하고 다음에는 새 인증으로 접속해요. 등록하지 않은 기기는 새 번호가 필요해요. 긴 코드는 지문 확인과 Windows의 별도 승인이 필요한 호환 모드예요.")
                Text("기본 Mac 입력기로 한글·영문을 입력해요. 한/영 전환은 Caps Lock 등 이 Mac에 설정된 키를 그대로 사용하세요. 일반적인 Windows 복사·붙여넣기는 Control+C/V를 사용해요. 물리 키 입력에서 Command는 Windows 키에 해당해요.")
            }.font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(22).nativePanel()
            Button("연결 화면으로 돌아가기") { showingHelp = false }.buttonStyle(.borderedProminent).controlSize(.large)
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
                else { NativeDesktop(model: model, onFilesDropped: { setFilesVisible(true) }, inputSuspended: showingFiles) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if let video = simulatedVideo ?? model.videoControl, model.phase == .streaming {
                        NativeVideoStateOverlay(video: video, beforeAction: { model.releaseInput(); model.acceptedLocalInteraction() })
                    }
                }
                .overlay {
                    if model.phase != .streaming {
                        VStack(spacing: 16) {
                            ProgressView().controlSize(.regular)
                            Text(phaseTitle).font(.system(size: 18, weight: .semibold))
                            Text(NativeCopy.status(model.status, reconnectMethod: model.reconnectMethod)).font(.system(size: 13)).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).frame(maxWidth: 380)
                        }.padding(28).frame(maxWidth: 460).nativePanel().padding(24).allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    sessionStorageWarningControl.padding(.horizontal, 12)
                        .padding(.top, immersive && model.showFullscreenControls ? 164 : 12)
                }
                .overlay(alignment: .bottom) {
                    VStack(spacing: 10) {
                        if model.phase == .streaming, model.inputRecovery {
                            Label(NativeCopy.status(model.status), systemImage: "cursorarrow.click")
                                .font(.system(size: 13)).multilineTextAlignment(.center)
                                .frame(maxWidth: 620).padding(.horizontal, 16).padding(.vertical, 12)
                                .nativePanel().allowsHitTesting(false)
                        }
                    }.padding(18)
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
                        windowState.toggleFullscreenControls(for: model)
                    } label: {
                        Label(model.showFullscreenControls ? "연결 제어 접기" : "연결 제어", systemImage: "slider.horizontal.3")
                            .font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 7)
                    }.buttonStyle(.plain).nativePanel().padding(.top, 5)
                        .help("연결 제어 보기/접기 · Control+Option+Command+K")
                }
            }
        }
        .overlay {
            if showingFiles {
                ZStack {
                    Color.black.opacity(0.18).onTapGesture { setFilesVisible(false) }
                    if let files = simulatedFiles ?? model.files {
                        NativeFilePanel(files: files, owner: filePromises, beforeAction: { model.releaseInput(); model.acceptedLocalInteraction() }, close: { setFilesVisible(false) })
                            .frame(maxWidth: 520, maxHeight: 540).padding(24)
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            Label("파일 공유를 사용할 수 없어요", systemImage: "folder.badge.questionmark").font(.headline)
                            Text("Windows에서 파일·폴더 송수신과 공유 폴더를 확인한 뒤 다시 공유해주세요. 폴더를 준비하지 못했거나 파일 공유가 꺼져 있을 수 있어요. 두 앱 모두 최신 버전으로 업데이트해주세요.")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                            Button("닫기") { setFilesVisible(false) }
                        }.padding(24).frame(maxWidth: 440).nativePanel().padding(24)
                    }
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
            if model.phase == .streaming, let video = simulatedVideo ?? model.videoControl {
                NativeVideoConnectionChip(video: video)
            } else {
                NativeStatusChip(title: phaseTitle, symbol: model.phase == .streaming ? "display" : "clock", tint: model.phase == .streaming ? .blue : .secondary)
            }
            if let video = simulatedVideo ?? model.videoControl {
                NativeVideoControlsButton(video: video, quality: model.quality, idleMinutes: $model.idleVideoMinutes,
                    idleBackgroundOnly: $model.idleVideoBackgroundOnly, beforeAction: { model.releaseInput(); model.acceptedLocalInteraction() })
                    .disabled(model.phase != .streaming)
            } else if let quality = model.quality {
                Menu { NativeQualityActions(quality: quality) } label: { Label("화질", systemImage: "slider.horizontal.3") }
                    .help("이 연결에서는 해상도 변경과 영상 절전을 사용할 수 없어요. 두 앱의 버전과 Windows 미디어 지원을 확인하세요.")
            }
            Button {
                setFilesVisible(true)
                if let files = model.files, !files.isBusy { files.refresh() }
            } label: { Label("파일", systemImage: "folder") }.disabled(model.phase != .streaming)
            Button { model.releaseInput(); model.acceptedLocalInteraction(); windowState.toggleFullscreen() } label: {
                Label(immersive ? "전체 화면 나가기" : "전체 화면", systemImage: "arrow.up.left.and.arrow.down.right")
            }.labelStyle(.iconOnly).help(immersive ? "전체 화면 나가기" : "전체 화면")
                .disabled(!immersive && model.phase != .streaming)
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
                .onChange(of: model.textMode) { _, _ in model.releaseInput(); model.acceptedLocalInteraction() }
            Menu {
                NativeWorkToolsActions(macShortcuts: $model.macShortcuts, clipboard: model.clipboard, quality: model.quality, clipboardAction: { model.performClipboardGesture(paste: $0) }, qualityDisabled: model.videoControl?.blocksInput == true)
            } label: { Label("작업 도구", systemImage: "slider.horizontal.3") }.menuStyle(.borderlessButton).fixedSize()
                .onChange(of: model.macShortcuts) { _, _ in model.releaseInput(); model.acceptedLocalInteraction() }
            if let audio = simulatedAudio ?? model.audio {
                NativeAudioControls(audio: audio, beforeAction: { model.releaseInput(); model.acceptedLocalInteraction() })
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(NativeCopy.status(model.status, reconnectMethod: model.reconnectMethod)).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)
                Text("화면 클릭으로 입력 · Control + 방향키로 Mac 공간 이동")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.font(.system(size: 12)).padding(.horizontal, 20).padding(.vertical, 12).background(NativeStyle.surface)
    }
    private func setFilesVisible(_ value: Bool) {
        model.setFileUIInputSuspended(value)
        showingFiles = value
    }
    private func review() {
        guard !model.active, !model.isSystemSleeping else { return }
        guard !secret.isEmpty else { return }
        let draft = secret; secret = ""; enrollment.cancel()
        model.review(draft)
    }
}

private struct NativeAudioControls: View {
    @ObservedObject var audio: NativeAudioSession
    let beforeAction: () -> Void
    private var title: String {
        switch audio.state {
        case .idle: "소리 준비 중"
        case .connecting: "소리 연결 중"
        case .playing: audio.muted ? "소리 켜기" : "음소거"
        case .unavailable: "소리 다시 연결"
        case .stopped: "소리 꺼짐"
        }
    }
    private var symbol: String {
        switch audio.state {
        case .idle, .connecting: "clock"
        case .unavailable: "arrow.clockwise"
        case .playing: audio.muted ? "speaker.slash" : "speaker.wave.2"
        case .stopped: "speaker.slash"
        }
    }
    private var guidance: String {
        audio.state == .unavailable ? "눌러서 Windows 소리만 다시 연결해요. Windows에서 ‘Windows 재생 소리 포함 · 마이크 제외’를 켜고 직접 공유를 시작했는지 확인해주세요. 두 앱을 최신 버전으로 업데이트하고 Windows 방화벽에서 Knot의 개인 네트워크 연결도 허용해주세요." : audio.status
    }
    var body: some View {
        Button {
            beforeAction()
            if audio.state == .unavailable { audio.retry() }
            else { audio.toggleMuted() }
        } label: { Label(title, systemImage: symbol) }
            .buttonStyle(.borderless).disabled(audio.state != .playing && audio.state != .unavailable)
            .help(guidance)
            .accessibilityLabel(title).accessibilityHint(guidance)
            .fixedSize()
    }
}
