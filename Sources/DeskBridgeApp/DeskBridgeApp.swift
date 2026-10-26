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
                .safeAreaInset(edge: .bottom) {
                    if lifecycle.preparingToTerminate {
                        Text("진행 중인 작업을 마치면 Knot을 종료합니다. 파일 전송이나 연결 설정을 취소할 수 있습니다.")
                            .font(.callout).padding(10)
                    }
                }
        }.defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("업데이트 확인…") { KnotUpdates.shared.checkForUpdates() }
                    .disabled(lifecycle.preparingToTerminate)
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
