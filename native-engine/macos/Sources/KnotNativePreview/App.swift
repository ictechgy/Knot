import SwiftUI
import AppKit
import Combine

#if !arch(arm64)
#error("Knot Native Preview requires Apple Silicon.")
#endif

@main
struct KnotNativePreviewApp: App {
    @StateObject private var model = SessionModel(makeAudioSession: { try NativeAudioSession(invitation: $0) },
                                                 makeConnectionActivity: { NativeConnectionActivity() },
                                                 reloadSavedDevicesForNumber: { try NativeDeviceKeychain.load() },
                                                 authorizeDeviceStorage: { try NativeDeviceKeychain.load(allowUserInteraction: true) })
    @StateObject private var windowState = NativeWindowState()
    @StateObject private var preferences = NativePreferences()
    @StateObject private var quick = NativeQuickActivation()
    @StateObject private var updates = NativeUpdateModel()
    @StateObject private var power = NativePowerMonitor()
    @StateObject private var videoIdle = NativeVideoIdleMonitor()
    @StateObject private var lifecycle = NativeApplicationLifecycle()
    init() { NativeUpdateHandoff.runIfRequested() }
    var body: some Scene {
        Window("Knot Native Preview", id: "main") {
            NativeMainContent(model: model, windowState: windowState, preferences: preferences, quick: quick, updates: updates, power: power, videoIdle: videoIdle, lifecycle: lifecycle)
        }
            .defaultSize(width: 1200, height: 760)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandMenu("연결") {
                    Button("연결 제어 보기/접기") {
                        windowState.toggleFullscreenControls(for: model)
                    }.keyboardShortcut("k", modifiers: [.control, .option, .command])
                        .disabled(!windowState.canToggleFullscreenControls(for: model))
                    Button("연결 종료") { model.disconnect() }
                        .keyboardShortcut("d", modifiers: [.control, .option, .command]).disabled(!model.active && !model.hasPendingReconnect)
                }
            }
        MenuBarExtra("Knot", systemImage: "display") {
            NativeMenuContent(model: model, windowState: windowState, quick: quick, updates: updates)
        }
    }
}

private struct NativeMainContent: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: SessionModel
    @ObservedObject var windowState: NativeWindowState
    @ObservedObject var preferences: NativePreferences
    @ObservedObject var quick: NativeQuickActivation
    @ObservedObject var updates: NativeUpdateModel
    @ObservedObject var power: NativePowerMonitor
    @ObservedObject var videoIdle: NativeVideoIdleMonitor
    @ObservedObject var lifecycle: NativeApplicationLifecycle
    var body: some View {
        PreviewWindow(model: model, windowState: windowState, updates: updates)
            .onAppear {
                lifecycle.bind(model: model, quick: quick, updates: updates)
                power.bind(model, notificationCenter: NSWorkspace.shared.notificationCenter)
                videoIdle.bind(model, notificationCenter: NotificationCenter.default, initiallyActive: NSApp.isActive)
                preferences.bind(model)
                model.refreshSavedDevices(); model.resumeAfterUpdateIfRequested()
                windowState.onFullscreenChanged = { preferences.preferFullscreen = $0 }
                quick.register { openWindow(id: "main"); windowState.activate() }
                updates.startAutomaticChecks()
            }
            .onChange(of: model.phase) { _, phase in
                if phase == .streaming { windowState.restoreFullscreen(preferences.preferFullscreen); preferences.restoreQuality(model) }
            }
    }
}

private struct NativeMenuContent: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: SessionModel
    @ObservedObject var windowState: NativeWindowState
    @ObservedObject var quick: NativeQuickActivation
    @ObservedObject var updates: NativeUpdateModel
    var body: some View {
        Group {
            Button("Windows 화면 열기 · ⌃⌥⌘B") { openWindow(id: "main"); windowState.activate() }
            if !quick.shortcutAvailable { Text("빠른 전환 단축키를 등록하지 못했어요") }
            Divider()
            Button("업데이트 확인") { updates.check() }.disabled(updates.checking || !updates.configured)
            Text(updates.status)
            if updates.available { Button("업데이트하고 다시 열기") { updates.install { model.prepareForUpdate() } } }
            Divider()
            Button("연결 종료") { model.disconnect() }.disabled(!model.active && !model.hasPendingReconnect)
            Button("Knot 종료") { model.disconnect(); updates.stop(); quick.stop(); NSApp.terminate(nil) }
        }
    }
}


/// App-scoped ownership survives closing the main window. Installation hands
/// its committed stage to the helper; stop only reclaims inactive parent work.
@MainActor
private final class NativeApplicationLifecycle: ObservableObject {
    private var termination: AnyCancellable?
    func bind(model: SessionModel, quick: NativeQuickActivation, updates: NativeUpdateModel) {
        guard termination == nil else { return }
        termination = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification).sink { [weak model, weak quick, weak updates] _ in
            MainActor.assumeIsolated { model?.disconnect(); updates?.stop(); quick?.stop() }
        }
    }
}
