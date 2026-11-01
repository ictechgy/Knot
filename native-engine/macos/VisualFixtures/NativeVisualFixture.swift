import AppKit
import SwiftUI
import Foundation
import KnotNativeCore

/// Separate entry point. It never enters App.main, creates a channel, or shows a window.
@main
struct NativeVisualFixture {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw FixtureError.arguments }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let cases: [(String, String, Int, Int, Bool)] = [
            ("idle", "idle", 1200, 760, false),
            ("reviewed", "reviewed", 1200, 760, false),
            ("connecting", "connecting", 1200, 760, false),
            ("approval", "approval", 1200, 760, false),
            ("decoding", "decoding", 1200, 760, false),
            ("streaming", "streaming", 1200, 760, false),
            ("input-paused", "input-paused", 1200, 760, false),
            ("display-behind", "display-behind", 1200, 760, false),
            ("invalid-name", "invalid-name", 1200, 760, false),
            ("failed", "failed", 1200, 760, false),
            ("help", "help", 1200, 760, false),
            ("compact", "idle", 880, 620, false),
            ("reviewed-compact", "reviewed", 880, 620, false),
            ("streaming-compact", "streaming", 880, 620, false),
            ("dark", "idle", 1200, 760, true),
            ("reviewed-dark", "reviewed", 1200, 760, true)
        ]
        var images: [[String: Any]] = []
        for (name, state, width, height, dark) in cases {
            let model = try makeModel(state)
            let simulated = AnyView(model.phase == .streaming ? AnyView(SyntheticDesktop()) : AnyView(Color(white: 0.045)))
            let content = PreviewWindow(model: model, simulatedDesktop: simulated, initialHelp: state == "help")
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.controlActiveState, .key)
                .frame(width: CGFloat(width), height: CGFloat(height))
            let view = NSHostingView(rootView: content)
            let rect = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = view
            view.frame = rect
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw FixtureError.bitmap }
            bitmap.size = rect.size
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw FixtureError.bitmap }
            let file = "mac-" + name + ".png"
            try png.write(to: output.appendingPathComponent(file), options: .atomic)
            images.append(["name": file, "width": width, "height": height, "state": state, "dark": dark])
            window.close()
            print("Rendered " + file)
        }
        let result: [String: Any] = [
            "schema": 1, "renderMethod": "offscreen NSHostingView cacheDisplay into owned bitmap; no shown window or screen capture",
            "controlActiveState": "key, explicit synthetic view environment",
            "syntheticWindowsShown": false, "existingUserUIRead": false,
            "productionEntryInvoked": false, "networkInvoked": false,
            "clipboardInvoked": false, "certificateCreationInvoked": false,
            "captureInvoked": false, "actualInputInvoked": false, "screenCaptureInvoked": false,
            "freshSyntheticOnly": true, "images": images
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("render-result.json"), options: .atomic)
    }

    @MainActor private static func makeModel(_ state: String) throws -> SessionModel {
        let model = SessionModel(makeChannel: { _ in throw NativeFailure.state })
        model.viewerLabel = "나의 Mac"
        switch state {
        case "reviewed", "invalid-name":
            let body: [String: Any] = ["v": 1, "address": "192.168.50.24", "port": 48631,
                "certificateSHA256": String(repeating: "0123456789abcdef", count: 4),
                "token": Invitation.encodeBase64URL(Data(repeating: 0, count: 32))]
            let code = "knot-native:v1:" + Invitation.encodeBase64URL(try JSONSerialization.data(withJSONObject: body))
            model.invitation = try Invitation(code)
            model.status = "Review the private address and exact certificate pin below. Trust lasts for this connection only."
            if state == "invalid-name" {
                model.viewerLabel = ""
                model.status = "Choose a viewer label of 1–64 UTF-8 bytes without control characters."
            }
        case "connecting":
            model.phase = .connecting; model.status = "Verifying the host certificate…"
        case "approval":
            model.phase = .approval; model.status = "Certificate verified. Waiting for host approval and native encoder startup…"
        case "decoding":
            model.phase = .decoding; model.status = "Host approved and encoder ready. Waiting for the first decoded image…"
        case "streaming":
            model.phase = .streaming; model.status = "Receiving the host desktop. Temporary trust; no saved pairing."
        case "input-paused":
            model.phase = .streaming; model.inputRecovery = true
            model.status = "Input paused. Click the desktop to resume."
        case "display-behind":
            model.phase = .streaming
            model.status = "Display is behind; still receiving decoded images. Temporary trust; no saved pairing."
        case "failed":
            model.phase = .failed
            model.status = "Connection ended or validation failed. Ask the host for a new invitation."
        default: break
        }
        return model
    }
}

enum FixtureError: Error { case arguments, bitmap }

/// Newly authored synthetic pixels, not a captured desktop or user document.
struct SyntheticDesktop: View {
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack {
                    Label("합성 테스트 화면 · 실제 원격 화면 아님", systemImage: "flask")
                    Spacer()
                    Text("Windows 미리보기")
                }.font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 20).frame(height: 38).background(Color(white: 0.1))
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("EXPLORER").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
                        Label("knot-workspace", systemImage: "folder").font(.system(size: 12, weight: .medium))
                        Label("README.md", systemImage: "doc.text").font(.system(size: 12))
                        Label("index.ts", systemImage: "chevron.left.forwardslash.chevron.right").font(.system(size: 12)).foregroundStyle(Color(red: 0.45, green: 0.75, blue: 0.95))
                        Label("assets", systemImage: "folder").font(.system(size: 12))
                        Spacer()
                    }.foregroundStyle(.white.opacity(0.7)).padding(24)
                        .frame(width: max(160, geometry.size.width * 0.2), alignment: .leading)
                        .background(Color(red: 0.105, green: 0.12, blue: 0.14))
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("index.ts").font(.system(size: 12)).padding(.horizontal, 24)
                            Spacer()
                            Image(systemName: "ellipsis").padding(.trailing, 20)
                        }.foregroundStyle(.white.opacity(0.8)).frame(height: 42).background(Color(white: 0.14))
                        VStack(alignment: .leading, spacing: 15) {
                            codeLine("1", "// Your computers, tied together.", tint: Color(red: 0.45, green: 0.65, blue: 0.5))
                            codeLine("2", "")
                            codeLine("3", "export function continueWorking() {")
                            codeLine("4", "  const workspace = 'Windows';")
                            codeLine("5", "  const view = 'Mac';")
                            codeLine("6", "")
                            codeLine("7", "  return { workspace, view };")
                            codeLine("8", "}")
                        }.padding(.vertical, 24)
                        Spacer()
                        HStack { Text("UTF-8"); Spacer(); Text("TypeScript · 합성 데이터") }
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 20).frame(height: 28).background(Color(red: 0.1, green: 0.3, blue: 0.49))
                    }.background(Color(red: 0.12, green: 0.14, blue: 0.16))
                }
            }
        }
    }
    private func codeLine(_ number: String, _ source: String, tint: Color = Color(red: 0.7, green: 0.79, blue: 0.9)) -> some View {
        HStack(spacing: 24) {
            Text(number).foregroundStyle(.white.opacity(0.28)).frame(width: 30, alignment: .trailing)
            Text(source).foregroundStyle(tint)
            Spacer()
        }.font(.system(size: 14, design: .monospaced))
    }
}
