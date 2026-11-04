import SwiftUI
import AppKit

#if !arch(arm64)
#error("Knot Native Preview requires Apple Silicon.")
#endif

@main
struct KnotNativePreviewApp: App {
    @StateObject private var model = SessionModel()
    @StateObject private var windowState = NativeWindowState()
    var body: some Scene {
        Window("Knot Native Preview", id: "main") { PreviewWindow(model: model, windowState: windowState) }
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
    }
}
