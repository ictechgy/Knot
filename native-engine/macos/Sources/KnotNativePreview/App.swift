import SwiftUI
import AppKit

#if !arch(arm64)
#error("Knot Native Preview requires Apple Silicon.")
#endif

@main
struct KnotNativePreviewApp: App {
    @StateObject private var model = SessionModel()
    var body: some Scene {
        Window("Knot Native Preview", id: "main") { PreviewWindow(model: model) }
            .defaultSize(width: 1200, height: 760)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
