import SwiftUI
import AppKit

#if !arch(arm64)
#error("Knot Native Preview requires Apple Silicon.")
#endif

@main
struct KnotNativePreviewApp: App {
    @StateObject private var model = SessionModel()
    @StateObject private var windowState = NativeWindowState()
    @StateObject private var preferences = NativePreferences()
    @StateObject private var quick = NativeQuickActivation()
    @StateObject private var updates = NativeUpdateModel()
    init() { NativeUpdateHandoff.runIfRequested() }
    var body: some Scene {
        Window("Knot Native Preview", id: "main") {
            PreviewWindow(model: model, windowState: windowState, updates: updates)
                .onAppear {
                    preferences.bind(model)
                    model.refreshSavedDevices(); model.resumeAfterUpdateIfRequested()
                    windowState.onFullscreenChanged = { preferences.preferFullscreen = $0 }
                    quick.register { windowState.activate() }
                    updates.startAutomaticChecks()
                }
                .onChange(of: model.phase) { _, phase in
                    if phase == .streaming { windowState.restoreFullscreen(preferences.preferFullscreen) }
                }
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
                        .keyboardShortcut("d", modifiers: [.control, .option, .command]).disabled(!model.active)
                }
            }
        MenuBarExtra("Knot", systemImage: "display") {
            Button("Windows 화면 열기 · ⌃⌥⌘B") { windowState.activate() }
            if !quick.shortcutAvailable { Text("빠른 전환 단축키를 등록하지 못했어요") }
            Divider()
            Button("업데이트 확인") { updates.check() }.disabled(updates.checking)
            Text(updates.status)
            if updates.available { Button("업데이트하고 다시 열기") { updates.install { model.prepareForUpdate() } } }
            Divider()
            Button("연결 종료") { model.disconnect() }.disabled(!model.active)
            Button("Knot 종료") { model.disconnect(); quick.stop(); NSApp.terminate(nil) }
        }
    }
}
