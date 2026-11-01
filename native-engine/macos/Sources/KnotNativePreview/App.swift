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

struct PreviewWindow: View {
    @ObservedObject var model: SessionModel
    @State private var secret = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Knot Native Preview").font(.title2.bold())
                Spacer()
                if model.active { Button("Disconnect") { model.disconnect() } }
                Button("Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }.disabled(model.phase != .streaming)
            }
            Text("Experimental · Windows 11 Home SDR → Apple Silicon Mac · session-only trust").font(.caption).foregroundStyle(.secondary)
            if !model.active {
                TextField("Viewer label shown to host (unverified)", text: $model.viewerLabel).textFieldStyle(.roundedBorder)
                SecureField("Paste a secret knot-native:v1 invitation", text: $secret).textFieldStyle(.roundedBorder)
                    .onSubmit { review() }
                HStack {
                    Button("Review invitation") { review() }.disabled(secret.isEmpty)
                    if let invitation = model.invitation {
                        Text("\(invitation.address):\(invitation.port)").monospaced()
                        Spacer()
                        Button("Connect to reviewed host") { secret = ""; model.connect() }.buttonStyle(.borderedProminent)
                    }
                }
                if let invitation = model.invitation {
                    Text("SHA-256  \(invitation.certificateSHA256)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text("Compare this pin with the host. The invitation is one-use and expires after 120 seconds; host approval is still required.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(model.status).font(.callout).textSelection(.enabled)
            NativeDesktop(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay { if model.phase != .streaming { Text(model.phase == .decoding ? "Waiting for decoded image" : "Desktop appears after host approval and decoding").foregroundStyle(.white.opacity(0.7)) } }
            HStack {
                Toggle("Committed text / local IME", isOn: $model.textMode).toggleStyle(.checkbox)
                    .help("IME candidates use a local pointer anchor. The remote caret position is unavailable.")
                    .onChange(of: model.textMode) { _,_ in model.releaseInput() }
                Text("Click desktop to focus. Control-arrow switches Mac Spaces. Command maps to Windows key in physical mode.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).frame(minWidth: 880, minHeight: 620)
    }
    private func review() { model.review(secret); secret = "" }
}
