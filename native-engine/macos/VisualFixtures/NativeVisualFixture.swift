import AppKit
import SwiftUI
import Foundation
import Darwin
import KnotNativeCore

/// Separate entry point. It never enters App.main, creates a channel, or shows a window.
@main
struct NativeVisualFixture {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw FixtureError.arguments }
        let probe = CommandLine.arguments[1] == "--probe-media-adapter-rejection"
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let effects = FixtureEnrollmentEffects()
        if probe {
            let model = try makeModel("reviewed", effects: effects)
            model.connect() // Rejecting inert factory only; never creates a socket.
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            guard effects.mediaCount == 1 else { throw FixtureError.effects }
            do { try requireInert(model: model, state: "reviewed", effects: effects) }
            catch FixtureError.effects {
                let result: [String: Any] = ["schema": 1, "status": "rejected", "probe": "media-adapter",
                    "adapterInvocations": effects.mediaCount, "freshSyntheticOnly": true,
                    "networkInvoked": false, "productionEntryInvoked": false]
                let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                Darwin.exit(3)
            }
            throw FixtureError.effects
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
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
            ("fullscreen-text-rejected", "streaming", 1920, 1080, false),
            ("nearby", "nearby", 1200, 760, false),
            ("number", "number", 1200, 760, false),
            ("number-working", "number-working", 1200, 760, false),
            ("number-error", "number-error", 1200, 760, false),
            ("manual-address", "manual-address", 1200, 760, false),
            ("searching", "searching", 1200, 760, false),
            ("empty", "empty", 1200, 760, false),
            ("nearby-compact", "nearby", 880, 620, false),
            ("number-compact", "number", 880, 620, false),
            ("number-dark", "number", 1200, 760, true),
            ("saved-devices", "saved-devices", 1200, 760, false),
            ("saved-devices-compact", "saved-devices", 880, 620, false),
            ("number-remembered", "number-remembered", 1200, 760, false),
            ("work-tools", "work-tools", 880, 620, false),
            ("certificate-policy", "certificate-policy", 1200, 760, false),
            ("certificate-pin-mismatch", "certificate-pin-mismatch", 880, 620, false),
            ("help-compact", "help", 880, 620, false),
            ("files", "files", 1200, 760, false),
            ("files-compact", "files", 880, 620, false),
            ("files-fullscreen", "files", 1200, 760, false),
            ("files-working", "files-working", 1200, 760, false),
            ("files-error", "files-error", 1200, 760, false),
            ("files-empty", "files-empty", 1200, 760, false),
            ("files-complete", "files-complete", 1200, 760, false),
            ("files-retry", "files-retry", 1200, 760, false)
        ]
        var images: [[String: Any]] = []
        var fileAdapterAttempts = 0
        for (name, state, width, height, dark) in cases {
            let model = try makeModel(state, effects: effects)
            let enrollment = try makeEnrollment(state, effects: effects)
            let files = try makeFiles(state)
            let convenience = state == "work-tools" ? FixtureConvenienceModels(effects: effects) : nil
            let immersive = name.hasPrefix("fullscreen") || name == "files-fullscreen"
            let revealed = name.hasSuffix("controls")
            if name.contains("4k") { model.videoSize = CGSize(width: 3840, height: 2160) }
            model.showFullscreenControls = revealed
            if name == "fullscreen-text-rejected" {
                guard !model.sendCommittedText(String(repeating: "a", count: 513)), model.inputRecovery else { throw FixtureError.phase }
            }
            // Allocate the real inert presenter below new synthetic pixels. No
            // channel, capture, real input event or shown window is involved.
            let simulated = AnyView(NativeDesktop(model: model).overlay {
                if model.phase == .streaming { SyntheticDesktop() }
                else { Color(white: 0.045) }
            })
            let content = root(model: model, enrollment: enrollment, simulated: simulated, help: state == "help", manual: state == "manual-address", fullscreen: immersive,
                width: width, height: height, dark: dark, files: files, convenience: convenience)
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

            try requireInert(model: model, state: state, effects: effects)
            if let files {
                fileAdapterAttempts += files.fixtureOperationAttempts
                guard files.fixtureOperationAttempts == 0 else { throw FixtureError.effects }
            }
            let numberFields = secureFieldCount(view)
            let filePanels = filePanelViews(view)
            guard filePanels.count == (files == nil ? 0 : 1) else { throw FixtureError.filePanel }
            var filePanelFrame: [String: Double]?
            if let panel = filePanels.first {
                let frame = panel.convert(panel.bounds, to: view)
                guard view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), frame.width >= 360, frame.height >= 360 else { throw FixtureError.filePanel }
                filePanelFrame = ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
                guard model.fileUIInputSuspended, model.inputRecovery else { throw FixtureError.filePanel }
            }
            let codeStage = !model.active && model.invitation == nil && enrollment.selected != nil && state != "help"
            guard numberFields == (codeStage ? 1 : 0) else { throw FixtureError.numberStage }
            guard enrollment.selected == nil || state.hasPrefix("number") else { throw FixtureError.numberStage }
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
                "expectedPhase": String(describing: expectedPhase(state)), "observedPhase": String(describing: model.phase),
                "desktopFrame": frameDictionary(model: model, root: view),
                "connectionStep": enrollment.selected != nil ? 3 : enrollment.candidates.isEmpty ? 1 : 2,
                "candidateCount": enrollment.candidates.count, "explicitSelection": enrollment.selected != nil,
                "codeStageVisible": codeStage, "renderedNumberFields": numberFields,
                "rememberThisPC": model.rememberThisPC,
                "savedDeviceCount": model.savedDevices.count,
                "convenienceActionsVisible": convenience != nil,
                "convenienceActionsPresentation": convenience == nil ? "native-menu" : "inline-production-action-views",
                "searchCompleted": enrollment.hasSearched,
                "filePanelVisible": !filePanels.isEmpty,
                "renderedFilePanels": filePanels.count,
                "fileFolderEntryCount": files?.entries.filter(\.isFolder).count ?? 0,
                "renderedFolderEntries": folderDragViews(view).count,
                "filePanelFrame": filePanelFrame.map { $0 as Any } ?? NSNull(),
                "fileInputSuspended": model.fileUIInputSuspended,
                "fileEntryCount": files?.entries.count ?? 0,
                "fileCompletedItems": files?.completedItems ?? 0,
                "fileRetryVisible": files?.canRetryUploads ?? false,
                "fileRevealVisible": files?.lastReceivedURL != nil,
                "fileAdaptersInvoked": files?.fixtureOperationAttempts ?? 0,
                "presenterTransitionChecks": name == "streaming" ? 3 : 0,
                "stablePresenterAcrossFullscreen": stablePresenter.map { $0 as Any } ?? NSNull()])
            window.close()
            print("Rendered " + file)
        }
        guard effects.count == 0, effects.mediaCount == 0, effects.convenienceCount == 0 else { throw FixtureError.effects }
        let result: [String: Any] = [
            "schema": 1, "renderMethod": "offscreen NSHostingView cacheDisplay into owned bitmap; no shown window or screen capture",
            "controlActiveState": "key, explicit synthetic view environment",
            "syntheticWindowsShown": false, "existingUserUIRead": false,
            "productionEntryInvoked": false, "networkInvoked": effects.count + effects.mediaCount > 0,
            "clipboardInvoked": false, "certificateCreationInvoked": false,
            "captureInvoked": false, "actualInputInvoked": false, "screenCaptureInvoked": false,
            "freshSyntheticOnly": true, "enrollmentAdaptersInvoked": effects.count,
            "mediaAdaptersInvoked": effects.mediaCount, "fileAdaptersInvoked": fileAdapterAttempts,
            "convenienceAdaptersInvoked": effects.convenienceCount,
            "modelPhaseChecks": images.count, "images": images
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("render-result.json"), options: .atomic)
    }

    @MainActor private static func root(model: SessionModel, enrollment: EnrollmentModel, simulated: AnyView, help: Bool,
                                        manual: Bool, fullscreen: Bool, width: Int, height: Int, dark: Bool, files: FileTransferModel? = nil,
                                        convenience: FixtureConvenienceModels? = nil) -> some View {
        Group {
            if let convenience { FixtureConvenienceSurface(model: model, clipboard: convenience.clipboard, quality: convenience.quality) }
            else {
                PreviewWindow(model: model, simulatedDesktop: simulated, initialHelp: help, simulatedFullscreen: fullscreen,
                    enrollment: enrollment, initialManualAddress: manual, simulatedFiles: files, initialFiles: files != nil)
            }
        }
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.controlActiveState, .key)
            .frame(width: CGFloat(width), height: CGFloat(height))
    }

    /// Inspect only the fresh offscreen view hierarchy; never another app/window.
    @MainActor private static func secureFieldCount(_ root: NSView) -> Int {
        let own = root is NSSecureTextField ? 1 : 0
        return own + root.subviews.reduce(0) { $0 + secureFieldCount($1) }
    }
    @MainActor private static func filePanelViews(_ root: NSView) -> [NativeFilePanelHost] {
        (root as? NativeFilePanelHost).map { [$0] } ?? root.subviews.flatMap { filePanelViews($0) }
    }
    @MainActor private static func folderDragViews(_ root: NSView) -> [NativeRemoteFileDragView] {
        let own = (root as? NativeRemoteFileDragView).flatMap { $0.entry?.isFolder == true ? $0 : nil }
        return own.map { [$0] } ?? root.subviews.flatMap { folderDragViews($0) }
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
        let values = state == "nearby" ? [first, second] : state.hasPrefix("number") ? [first] : []
        let phase: EnrollmentModel.Phase = state == "number-working" ? .authenticating : state == "number-error" ? .failed : state == "searching" ? .discovering : .idle
        let status = state == "number-working" ? "8자리 번호를 확인하고 연결 정보를 안전하게 받고 있어요…" :
            state == "number-error" ? EnrollmentModel.authenticationGuidance :
            state == "searching" ? "공유 중인 PC를 찾고 있어요…" :
            state == "empty" ? "공유 중인 PC를 찾지 못했어요. Windows에서 공유를 시작했는지 확인하거나 주소로 찾아주세요." :
            values.isEmpty ? nil : state == "nearby" ? "목록에서 연결할 Windows PC를 선택해주세요. 다음 화면에서 8자리 번호를 입력해요." :
                "Windows에 표시된 8자리 번호를 입력하세요. 기기 이름과 주소는 아직 인증되지 않았어요."
        let model = EnrollmentModel(makeDiscovery: { effects.mark(); return FixtureEmptyDiscovery() },
            makeClient: { _, _ in effects.mark(); throw EnrollmentFailure.cancelled },
            initialCandidates: values, initialPhase: phase, initialStatus: status,
            initialSelection: state.hasPrefix("number") ? first.id : nil, initialSearchCompleted: state == "empty")
        if state == "number" || state == "number-remembered" { model.code = "12345678" }
        if state == "manual-address" { model.manualAddress = "100.100.10.12" }
        return model
    }

    @MainActor private static func requireInert(model: SessionModel, state: String, effects: FixtureEnrollmentEffects) throws {
        guard effects.count == 0, effects.mediaCount == 0, effects.convenienceCount == 0 else { throw FixtureError.effects }
        guard model.phase == expectedPhase(state) else { throw FixtureError.phase }
    }
    @MainActor private static func expectedPhase(_ state: String) -> SessionModel.Phase {
        if state.hasPrefix("files") { return .streaming }
        return switch state {
        case "connecting": .connecting
        case "approval": .approval
        case "decoding": .decoding
        case "streaming", "input-paused", "display-behind": .streaming
        case "failed", "certificate-policy", "certificate-pin-mismatch": .failed
        default: .idle
        }
    }
    @MainActor private static func makeFiles(_ state: String) throws -> FileTransferModel? {
        guard state.hasPrefix("files") else { return nil }
        let entries = state == "files-empty" ? [] : [
            try NativeFileEntry(id: String(repeating: "1", count: 32), name: "회의 자료.pdf", size: 2_400_000),
            try NativeFileEntry(id: String(repeating: "2", count: 32), name: "프로젝트 폴더", size: 0, kind: .folder),
            try NativeFileEntry(id: String(repeating: "3", count: 32), name: "README.md", size: 4096)
        ]
        return FileTransferModel(rootName: "Knot Files", entries: entries, isBusy: state == "files-working",
            status: state == "files-error" ? "같은 이름의 파일이 있어요. 다른 이름이나 저장 위치를 선택해주세요." :
                state == "files-complete" ? "회의 자료.pdf 받기를 완료했어요. Finder에서 저장 위치를 확인하세요." :
                state == "files-retry" ? "1개는 전송을 완료했어요. 연결이 끊겼어요. 미완료 항목을 다시 시도하세요." :
                state == "files-working" ? "Windows 공유 폴더로 보내는 중이에요. 원본은 유지돼요." :
                state == "files-empty" ? "공유 폴더가 비어 있어요. Windows 파일을 넣고 새로고침하세요." :
                "파일을 선택해 받거나 왼쪽 아이콘을 Finder로 끌어주세요.",
            progress: state == "files-working" ? 0.42 : nil,
            currentName: state == "files-working" ? "project-source.zip" : nil,
            completedItems: state == "files-complete" ? 2 : state == "files-retry" ? 1 : 0,
            unfinishedUploads: state == "files-retry" ? [URL(fileURLWithPath: "/synthetic-fixture/project-source.zip")] : [],
            lastReceivedURL: state == "files-complete" ? URL(fileURLWithPath: "/synthetic-fixture/회의 자료.pdf") : nil)
    }
    @MainActor private static func makeModel(_ state: String, effects: FixtureEnrollmentEffects) throws -> SessionModel {
        let saved = state == "saved-devices" ? try makeSavedDevices() : []
        let model = SessionModel(makeChannel: { _ in effects.markMedia(); throw NativeFailure.state },
            makeTrustedClient: { _, _ in effects.mark(); throw NativeFailure.state }, initialSavedDevices: saved)
        model.viewerLabel = "나의 Mac"
        model.rememberThisPC = state == "number-remembered"
        if state.hasPrefix("files") { model.phase = .streaming; model.status = "Receiving the host desktop. Temporary trust; no saved pairing."; return model }
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
        case "certificate-policy":
            model.phase = .failed; model.status = NativeCopy.certificatePolicyGuidance
        case "certificate-pin-mismatch":
            model.phase = .failed; model.status = NativeCopy.certificatePinMismatchGuidance
        case "connecting":
            model.phase = .connecting; model.status = "Checking the secure connection…"
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

    /// Fixed authored records decoded in memory; no Keychain read or credential creation.
    private static func makeSavedDevices() throws -> [SavedNativeDevice] {
        let records: [[String: Any]] = [(UInt8(1), "작업용 Windows", "192.168.50.24"),
                                      (UInt8(2), "개발용 PC", "192.168.50.25")].map { seed, name, address in
            ["id": Invitation.encodeBase64URL(Data(repeating: seed, count: 32)), "name": name, "address": address,
             "certificateSHA256": String(repeating: "0123456789abcdef", count: 4),
             "secret": Data(repeating: seed, count: 32).base64EncodedString()]
        }
        return try JSONDecoder().decode([SavedNativeDevice].self, from: JSONSerialization.data(withJSONObject: records))
            .map { try $0.validated() }
    }
}

enum FixtureError: Error {
    case arguments, bitmap, presenter, effects, phase, numberStage, filePanel, geometry(CGRect, CGSize)
}

private final class FixtureEnrollmentEffects: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var media = 0
    private var convenience = 0
    func mark() { lock.lock(); value += 1; lock.unlock() }
    func markMedia() { lock.lock(); media += 1; lock.unlock() }
    func markConvenience() { lock.lock(); convenience += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    var mediaCount: Int { lock.lock(); defer { lock.unlock() }; return media }
    var convenienceCount: Int { lock.lock(); defer { lock.unlock() }; return convenience }
}

@MainActor private struct FixtureConvenienceModels {
    let clipboard: ClipboardModel
    let quality: QualityModel
    init(effects: FixtureEnrollmentEffects) {
        clipboard = ClipboardModel(send: { _ in effects.markConvenience(); return false },
            readText: { effects.markConvenience(); return nil }, writeText: { _ in effects.markConvenience(); return false })
        quality = QualityModel(send: { _ in effects.markConvenience(); return false })
    }
}

/// Native Menu popups require shown windows. Render their actual production
/// action views inline in a fresh owned offscreen view instead.
private struct FixtureConvenienceSurface: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var clipboard: ClipboardModel
    @ObservedObject var quality: QualityModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("작업 도구", systemImage: "slider.horizontal.3").font(.system(size: 24, weight: .semibold))
            VStack(alignment: .leading, spacing: 14) {
                NativeWorkToolsActions(macShortcuts: $model.macShortcuts, clipboard: clipboard, quality: quality)
            }.padding(24).nativePanel()
            Spacer()
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity).background(NativeStyle.canvas)
    }
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
