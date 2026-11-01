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
        let effects = FixtureEnrollmentEffects()
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
            ("reviewed-dark", "reviewed", 1200, 760, true),
            ("fullscreen", "streaming", 1920, 1080, false),
            ("fullscreen-controls", "streaming", 1920, 1080, false),
            ("fullscreen-4k", "streaming", 3840, 2160, false),
            ("fullscreen-4k-controls", "streaming", 3840, 2160, false),
            ("nearby", "nearby", 1200, 760, false),
            ("number", "number", 1200, 760, false),
            ("number-working", "number-working", 1200, 760, false),
            ("number-error", "number-error", 1200, 760, false),
            ("manual-address", "manual-address", 1200, 760, false)
        ]
        var images: [[String: Any]] = []
        for (name, state, width, height, dark) in cases {
            let model = try makeModel(state)
            let enrollment = try makeEnrollment(state, effects: effects)
            let immersive = name.hasPrefix("fullscreen")
            let revealed = name.hasSuffix("controls")
            if name.contains("4k") { model.videoSize = CGSize(width: 3840, height: 2160) }
            model.showFullscreenControls = revealed
            // Allocate the real inert presenter below new synthetic pixels. No
            // channel, capture, real input event or shown window is involved.
            let simulated = AnyView(NativeDesktop(model: model).overlay {
                if model.phase == .streaming { SyntheticDesktop() }
                else { Color(white: 0.045) }
            })
            let content = root(model: model, enrollment: enrollment, simulated: simulated, help: state == "help", manual: state == "manual-address", fullscreen: immersive,
                width: width, height: height, dark: dark)
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
            if immersive { try requireFullCanvas(model: model, root: view, width: width, height: height) }
            var stablePresenter: Bool?
            if name == "streaming" {
                guard let presenter = model.surface else { throw FixtureError.presenter }
                let identity = ObjectIdentifier(presenter)
                for (full, controls) in [(true, false), (true, true), (false, false)] {
                    model.showFullscreenControls = controls
                    view.rootView = root(model: model, enrollment: enrollment, simulated: simulated, help: false, manual: false, fullscreen: full,
                        width: width, height: height, dark: dark)
                    view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.08))
                    view.layoutSubtreeIfNeeded()
                    guard let current = model.surface, ObjectIdentifier(current) == identity else { throw FixtureError.presenter }
                    if full { try requireFullCanvas(model: model, root: view, width: width, height: height) }
                }
                stablePresenter = model.surface.map { ObjectIdentifier($0) == identity } == true
            }

            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw FixtureError.bitmap }
            bitmap.size = rect.size
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw FixtureError.bitmap }
            let file = "mac-" + name + ".png"
            try png.write(to: output.appendingPathComponent(file), options: .atomic)
            images.append(["name": file, "width": width, "height": height, "state": state, "dark": dark,
                "immersiveFullscreen": immersive, "controlsRevealed": revealed,
                "desktopFrame": frameDictionary(model: model, root: view),
                "presenterTransitionChecks": name == "streaming" ? 3 : 0,
                "stablePresenterAcrossFullscreen": stablePresenter.map { $0 as Any } ?? NSNull()])
            window.close()
            print("Rendered " + file)
        }
        guard effects.count == 0 else { throw FixtureError.effects }
        let result: [String: Any] = [
            "schema": 1, "renderMethod": "offscreen NSHostingView cacheDisplay into owned bitmap; no shown window or screen capture",
            "controlActiveState": "key, explicit synthetic view environment",
            "syntheticWindowsShown": false, "existingUserUIRead": false,
            "productionEntryInvoked": false, "networkInvoked": false,
            "clipboardInvoked": false, "certificateCreationInvoked": false,
            "captureInvoked": false, "actualInputInvoked": false, "screenCaptureInvoked": false,
            "freshSyntheticOnly": true, "enrollmentAdaptersInvoked": effects.count, "images": images
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("render-result.json"), options: .atomic)
    }

    @MainActor private static func root(model: SessionModel, enrollment: EnrollmentModel, simulated: AnyView, help: Bool,
                                        manual: Bool, fullscreen: Bool, width: Int, height: Int, dark: Bool) -> some View {
        PreviewWindow(model: model, simulatedDesktop: simulated, initialHelp: help, simulatedFullscreen: fullscreen,
            enrollment: enrollment, initialManualAddress: manual)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.controlActiveState, .key)
            .frame(width: CGFloat(width), height: CGFloat(height))
    }

    @MainActor private static func desktopFrame(model: SessionModel, root: NSView) -> CGRect {
        guard let desktop = model.surface as? DesktopView else { return .zero }
        return desktop.convert(desktop.bounds, to: root)
    }
    @MainActor private static func frameDictionary(model: SessionModel, root: NSView) -> [String: Double] {
        let frame = desktopFrame(model: model, root: root)
        return ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
    }
    @MainActor private static func requireFullCanvas(model: SessionModel, root: NSView, width: Int, height: Int) throws {
        let frame = desktopFrame(model: model, root: root)
        guard abs(frame.minX) < 0.5, abs(frame.minY) < 0.5,
              abs(frame.width - Double(width)) < 0.5, abs(frame.height - Double(height)) < 0.5 else {
            throw FixtureError.geometry(frame, CGSize(width: width, height: height))
        }
    }

    @MainActor private static func makeEnrollment(_ state: String, effects: FixtureEnrollmentEffects) throws -> EnrollmentModel {
        let first = try EnrollmentCandidate(address: "192.168.50.24", port: 48632, slot: Data(repeating: 1, count: 16), name: "작업용 Windows")
        let second = try EnrollmentCandidate(address: "192.168.50.25", port: 48632, slot: Data(repeating: 2, count: 16), name: "개발용 PC")
        let values = state == "nearby" ? [first, second] : ["number", "number-working", "number-error"].contains(state) ? [first] : []
        let phase: EnrollmentModel.Phase = state == "number-working" ? .authenticating : state == "number-error" ? .failed : .idle
        let status = state == "number-working" ? "8자리 번호를 확인하고 연결 정보를 안전하게 받고 있어요…" :
            state == "number-error" ? "8자리 번호를 확인해주세요. 번호가 바뀌었다면 Windows에서 공유를 다시 시작하세요." :
            values.isEmpty ? nil : "Windows에 표시된 8자리 번호를 입력하세요. 기기 이름과 주소는 아직 인증되지 않았어요."
        let model = EnrollmentModel(makeDiscovery: { effects.mark(); return FixtureEmptyDiscovery() },
            makeClient: { _, _ in effects.mark(); throw EnrollmentFailure.cancelled },
            initialCandidates: values, initialPhase: phase, initialStatus: status)
        if state == "number" { model.code = "12345678" }
        if state == "manual-address" { model.manualAddress = "100.100.10.12" }
        return model
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

enum FixtureError: Error { case arguments, bitmap, presenter, effects, geometry(CGRect, CGSize) }

private final class FixtureEnrollmentEffects: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func mark() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
private final class FixtureEmptyDiscovery: EnrollmentDiscovering, @unchecked Sendable {
    func discover(address: String?) async throws -> [EnrollmentCandidate] { [] }
    func close() {}
}

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
