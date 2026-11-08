import SwiftUI
import KnotNativeCore

enum NativeVideoResolution: Int, CaseIterable, Identifiable, Hashable {
    case fullHD, quadHD, ultraHD
    var id: Int { rawValue }
    var width: Int { switch self { case .fullHD: 1920; case .quadHD: 2560; case .ultraHD: 3840 } }
    var height: Int { switch self { case .fullHD: 1080; case .quadHD: 1440; case .ultraHD: 2160 } }
    var title: String { switch self { case .fullHD: "최대 1080p"; case .quadHD: "최대 1440p"; case .ultraHD: "최대 4K" } }
    static func fitting(_ profile: VideoProfile) -> Self {
        allCases.first { profile.width <= $0.width && profile.height <= $0.height } ?? .ultraHD
    }
}

struct NativeIdleVideoSettings: View {
    @Binding var minutes: Int
    @Binding var backgroundOnly: Bool
    var onInteraction: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("사용하지 않을 때 영상 절전", selection: Binding(get: { minutes }, set: { onInteraction(); minutes = $0 })) {
                Text("사용 안 함").tag(0)
                ForEach([1, 5, 10, 15, 30, 60], id: \.self) { value in
                    Text("\(value)분 후").tag(value)
                }
            }.pickerStyle(.menu)
            Toggle("다른 앱이나 Space를 사용할 때만", isOn: Binding(get: { backgroundOnly }, set: { onInteraction(); backgroundOnly = $0 }))
                .disabled(minutes == 0)
            Text(backgroundOnly ? "이 앱으로 돌아오면 영상을 다시 준비해요. 파일·소리·연결은 유지돼요." :
                    "원격 입력이 없으면 영상과 입력을 쉬어요. 영상을 보고만 있어도 멈출 수 있어요.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 12))
    }
}

struct NativeVideoControlsButton: View {
    @ObservedObject var video: VideoControlModel
    let quality: QualityModel?
    @Binding var idleMinutes: Int
    @Binding var idleBackgroundOnly: Bool
    let beforeAction: () -> Void
    @State private var showing = false
    var body: some View {
        Button {
            beforeAction(); showing.toggle()
        } label: { Label("화질", systemImage: "slider.horizontal.3") }
            .help("연결 중 해상도·FPS·선명도와 영상 절전을 바꿔요.")
            .accessibilityLabel("화질과 영상 절전 설정")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                NativeVideoSettingsPanel(video: video, quality: quality, idleMinutes: $idleMinutes,
                    idleBackgroundOnly: $idleBackgroundOnly, beforeAction: beforeAction)
            }
    }
}

struct NativeVideoConnectionChip: View {
    @ObservedObject var video: VideoControlModel
    var body: some View {
        NativeStatusChip(title: video.isApplying ? "영상 준비 중" : video.isPaused ? "영상 절전 중" : "연결됨",
            symbol: video.isApplying ? "clock" : video.isPaused ? "pause.circle" : "display",
            tint: video.isPaused ? .secondary : .blue)
    }
}

/// Draft selectors never send traffic. One explicit Apply performs the bounded
/// video transaction; host-confirmed values remain visible while it runs.
struct NativeVideoSettingsPanel: View {
    @ObservedObject var video: VideoControlModel
    let quality: QualityModel?
    @Binding var idleMinutes: Int
    @Binding var idleBackgroundOnly: Bool
    let beforeAction: () -> Void
    @State private var resolution: NativeVideoResolution = .ultraHD
    @State private var fps = 30
    @State private var megabits = 40

    private var draftDiffers: Bool {
        video.requested.width != resolution.width || video.requested.height != resolution.height ||
            video.requested.fps != fps || video.requested.bitrate != megabits * 1_000_000
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Label("화질 설정", systemImage: "display").font(.system(size: 18, weight: .semibold))
                    Text("연결을 유지하면서 전송 영상만 바꿔요.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("호스트가 확인한 설정").font(.caption).foregroundStyle(.secondary)
                    Text("\(video.actual.width)×\(video.actual.height) · 최대 \(video.actual.fps)fps · 목표 \(video.actual.bitrate / 1_000_000)Mbps")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                    Text(video.status).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("video-control-status")
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).nativePanel()
                VStack(alignment: .leading, spacing: 12) {
                    Picker("전송 해상도", selection: Binding(get: { resolution }, set: { beforeAction(); resolution = $0 })) {
                        ForEach(NativeVideoResolution.allCases) { value in Text(value.title).tag(value) }
                    }.pickerStyle(.menu)
                    HStack(spacing: 18) {
                        Picker("최대 FPS", selection: Binding(get: { fps }, set: { beforeAction(); fps = $0 })) {
                            Text("30fps").tag(30); Text("60fps").tag(60)
                        }.pickerStyle(.menu)
                        Picker("목표 전송률", selection: Binding(get: { megabits }, set: { beforeAction(); megabits = $0 })) {
                            ForEach([1, 2, 5, 10, 15, 20, 25, 30, 35, 40], id: \.self) { value in Text("\(value)Mbps").tag(value) }
                        }.pickerStyle(.menu)
                    }
                    Text("원본 화면보다 크게 확대하지 않아요. 높게 설정할수록 GPU와 네트워크 사용량이 늘 수 있어요.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if video.isApplying { ProgressView().controlSize(.small) }
                        Spacer()
                        Button(video.isApplying ? "적용 중…" : "화질 적용") {
                            beforeAction()
                            video.requestProfile(width: resolution.width, height: resolution.height,
                                fps: fps, bitrate: megabits * 1_000_000)
                        }.buttonStyle(.borderedProminent)
                            .disabled(video.isApplying || video.isPaused || !draftDiffers)
                            .accessibilityHint("새 설정을 적용하는 동안 마지막 화면을 유지해요.")
                    }
                }.disabled(video.isApplying || video.isPaused)
                if video.isPaused {
                    Text("화면을 재개한 뒤 화질을 적용할 수 있어요.").font(.caption).foregroundStyle(.secondary)
                }
                if let quality { NativeVideoPolicyPicker(quality: quality, disabled: video.isApplying || video.isPaused, beforeAction: beforeAction) }
                Divider()
                HStack {
                    Label("영상과 원격 입력", systemImage: video.isPaused ? "pause.circle" : "play.circle")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button(video.isPaused ? "화면 재개" : "일시 정지") {
                        beforeAction()
                        if video.isPaused { video.resume() } else { video.pause() }
                    }.disabled(video.isApplying)
                }
                Divider()
                NativeIdleVideoSettings(minutes: $idleMinutes, backgroundOnly: $idleBackgroundOnly, onInteraction: beforeAction)
            }.padding(20)
        }.frame(width: 420).frame(maxHeight: 570)
            .onAppear { restoreDraft() }
    }
    private func restoreDraft() {
        let profile = video.requested
        resolution = .fitting(profile); fps = profile.fps >= 60 ? 60 : 30
        let target = Double(profile.bitrate) / 1_000_000
        megabits = [1, 2, 5, 10, 15, 20, 25, 30, 35, 40].min { abs(Double($0) - target) < abs(Double($1) - target) } ?? 20
    }
}

private struct NativeVideoPolicyPicker: View {
    @ObservedObject var quality: QualityModel
    let disabled: Bool
    let beforeAction: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker("부하 조절 방식", selection: Binding(get: { quality.preference.rawValue }, set: { value in
                if let preference = QualityModel.Preference(rawValue: value) { beforeAction(); quality.choose(preference) }
            })) {
                ForEach(QualityModel.Preference.allCases) { value in Text(value.title).tag(value.rawValue) }
            }.pickerStyle(.menu).disabled(disabled)
            Text(quality.preference == .sharp ? "글자 선명도 우선은 최대 30fps로 조절해요." :
                    quality.preference == .responsive ? "반응 우선은 목표 전송률을 최대 20Mbps로 조절해요." :
                    "자동은 요청한 범위 안에서 처리 부하에 맞춰 조절해요.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct NativeVideoStateOverlay: View {
    @ObservedObject var video: VideoControlModel
    let beforeAction: () -> Void
    var body: some View {
        if video.isApplying || video.isPaused {
            ZStack {
                Color.black.opacity(video.isPaused ? 0.38 : 0.12)
                VStack(spacing: 12) {
                    if video.isApplying { ProgressView().controlSize(.regular) }
                    else { Image(systemName: "moon.zzz").font(.system(size: 26)) }
                    Text(video.isApplying ? "영상을 준비하고 있어요" : "영상 절전 중")
                        .font(.system(size: 18, weight: .semibold))
                    Text(video.status).font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Text("연결·파일·소리는 유지돼요.").font(.caption).foregroundStyle(.secondary)
                    if video.isPaused && !video.isApplying {
                        Button("화면 재개") { beforeAction(); video.resume() }.buttonStyle(.borderedProminent)
                    }
                }.padding(24).frame(maxWidth: 390).nativePanel().padding(20)
            }.contentShape(Rectangle())
        }
    }
}
