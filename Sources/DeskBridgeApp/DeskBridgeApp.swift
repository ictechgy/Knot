// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 DeskBridge contributors
import AppKit
import Combine
import SwiftUI

@main
struct DeskBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @StateObject private var desktop: DesktopModel
    @StateObject private var files: FilesModel
    @StateObject private var linux: LinuxDesktopWorkspace
    @StateObject private var macHost: MacHostModel
    init() {
        let model = DesktopModel()
        let transfers = FilesModel(desktop: model)
        _desktop = StateObject(wrappedValue: model)
        _files = StateObject(wrappedValue: transfers)
        let linuxWorkspace = LinuxDesktopWorkspace()
        model.peerDesktop = linuxWorkspace.desktop; linuxWorkspace.desktop.peerDesktop = model
        _linux = StateObject(wrappedValue: linuxWorkspace)
        AppLifecycle.linuxDesktop = linuxWorkspace.desktop
        let host = MacHostModel()
        _macHost = StateObject(wrappedValue: host)
        AppLifecycle.desktop = model; AppLifecycle.files = transfers; AppLifecycle.macHost = host
    }
    var body: some Scene {
        Window("Knot", id: "main") {
            MainView(linux: linux).environmentObject(desktop).environmentObject(files).environmentObject(macHost)
                .frame(minWidth: 880, minHeight: 620)
        }.defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("업데이트 확인…") { KnotUpdates.shared.checkForUpdates() }
                Button("오픈소스 라이선스") {
                    openCredits("LICENSE", extension: "txt")
                }
                Button("QR 코드 라이선스") {
                    openCredits("QR_CODEGEN_LICENSE", extension: "txt")
                }
                Button("GlimmerEngine / Moonlight 기여자") { openCredits("GLIMMER_CREDITS", extension: "md") }
            }
        }
    }
    private func openCredits(_ name: String, extension suffix: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: suffix), NSWorkspace.shared.open(url) else {
            let alert = NSAlert()
            alert.messageText = "라이선스 문서를 열지 못했습니다."
            alert.informativeText = "앱 패키지의 Contents/Resources 폴더에서 라이선스와 기여자 문서를 확인할 수 있습니다."
            alert.runModal()
            return
        }
    }
}
@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    private let termination = DesktopTermination()
    private var terminating = false
    private var updateObservers: Set<AnyCancellable> = []
    static weak var desktop: DesktopModel?
    static weak var files: FilesModel?
    static weak var linuxDesktop: DesktopModel?
    static weak var macHost: MacHostModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        configureUpdates()
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        // Consume every receipt before starting work, including invalid receipts.
        let windows = (try? Self.desktop?.consumeUpdateReconnect(build: build)) == true
        let linux = (try? Self.linuxDesktop?.consumeUpdateReconnect(build: build)) == true
        if windows { Self.desktop?.connect() }
        else if linux { Self.linuxDesktop?.connect() }
        else if Self.desktop?.settings.host == nil { Self.desktop?.startNearbySearch() }
    }
    private func configureUpdates() {
        let updates = KnotUpdates.shared
        updates.isIdle = { [weak self] in
            guard self?.terminating == false,
                  let desktop = Self.desktop, let linux = Self.linuxDesktop,
                  let files = Self.files, let host = Self.macHost else { return false }
            return !desktop.busy && !desktop.stream.isEngaged && !linux.busy && !linux.stream.isEngaged
                && !files.busy && !files.connected && !files.enrollmentActive
                && host.phase == .stopped && !host.downloading
        }
        updates.prepareForRelaunch = {
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            // Store no passwords, session keys or PIN. Failed receipt persistence
            // only suppresses automatic PC verification after the update.
            try? Self.desktop?.prepareUpdateReconnect(build: build)
            try? Self.linuxDesktop?.prepareUpdateReconnect(build: build)
        }
        func observe(_ publisher: ObservableObjectPublisher?) {
            publisher?.sink { _ in
                Task { @MainActor in updates.stateDidChange() }
            }.store(in: &updateObservers)
        }
        observe(Self.desktop?.objectWillChange); observe(Self.linuxDesktop?.objectWillChange)
        observe(Self.files?.objectWillChange); observe(Self.macHost?.objectWillChange)
        updates.objectWillChange.sink { _ in
            Task { @MainActor in
                Self.desktop?.objectWillChange.send(); Self.linuxDesktop?.objectWillChange.send()
                Self.files?.objectWillChange.send(); Self.macHost?.objectWillChange.send()
            }
        }.store(in: &updateObservers)
        updates.start()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if termination.finished { return .terminateNow }
        terminating = true
        termination.begin(revoke: {
            Self.desktop?.beginShutdown()
            Self.linuxDesktop?.beginShutdown()
            Self.files?.beginShutdown()
            Self.macHost?.beginShutdown()
        }, cleanup: {
            await DesktopTermination.cleanupOwners([
                { await Self.linuxDesktop?.stream.disconnect() },
                { await Self.desktop?.stream.disconnect() },
                { await Self.files?.shutdown() },
                { await Self.macHost?.shutdown() }
            ])
        }, reply: { sender.reply(toApplicationShouldTerminate: true) })
        return .terminateLater
    }
}
