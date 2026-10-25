// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation

@MainActor final class KnotInstaller: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let status = NSTextField(wrappingLabelWithString: "Knot을 직접 종료할 필요 없이 설치하고 다시 엽니다. 기존 연결 설정은 유지됩니다.")
    private let install = NSButton(title: "설치 및 다시 시작", target: nil, action: nil)
    private var working = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 530, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Knot 설치 및 업데이트"; window.delegate = self; window.center()
        let heading = NSTextField(labelWithString: "Knot을 자동으로 교체하고 다시 시작합니다")
        heading.font = .boldSystemFont(ofSize: 20)
        status.preferredMaxLayoutWidth = 470
        let note = NSTextField(wrappingLabelWithString: "화면 연결은 잠시 끊깁니다. preview.22 이하 앱은 파일 전송·설정 작업을 먼저 마쳐 주세요. 이후 버전은 진행 중인 작업을 기다립니다.")
        note.preferredMaxLayoutWidth = 470; note.textColor = .secondaryLabelColor
        install.target = self; install.action = #selector(begin); install.bezelStyle = .rounded
        let stack = NSStackView(views: [heading, status, note, install]); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = 18; stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28)])
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !working }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { working ? .terminateCancel : .terminateNow }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func destination(running: [NSRunningApplication]) throws -> URL {
        let fm = FileManager.default
        let runningPaths = Set(running.compactMap { $0.bundleURL?.standardizedFileURL })
        guard runningPaths.count <= 1 else { throw KnotInstallFailure.changedApplication }
        if let only = runningPaths.first { return only }
        let user = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let known = [system, user].flatMap { [$0.appendingPathComponent("Knot.app"), $0.appendingPathComponent("DeskBridge.app")] }
            .filter { fm.fileExists(atPath: $0.path) }
        guard known.count <= 1 else { throw KnotInstallFailure.changedApplication }
        if let only = known.first { return only }
        if fm.isWritableFile(atPath: system.path) { return system.appendingPathComponent("Knot.app") }
        if !fm.fileExists(atPath: user.path) { try fm.createDirectory(at: user, withIntermediateDirectories: false) }
        return user.appendingPathComponent("Knot.app")
    }

    @objc private func begin() {
        guard !working else { return }
        working = true; install.isEnabled = false
        Task { @MainActor in
            var transaction: KnotInstallTransaction?
            var didQuit = false
            do {
                status.stringValue = "설치할 앱과 설치 위치를 확인하는 중…"; await Task.yield()
                // Gatekeeper may translocate this helper on first open. All
                // required content travels inside its signed bundle.
                let source = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Knot.app")
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: "org.deskbridge.app")
                let destination = try destination(running: running)
                transaction = try KnotInstallTransaction(source: source, destination: destination)
                status.stringValue = "Knot의 파일 전송·설정 작업과 정상 종료를 기다리는 중…"; await Task.yield()
                for app in running {
                    guard app.bundleURL?.standardizedFileURL == destination,
                          app.terminate() else { throw KnotInstallFailure.changedApplication }
                }
                let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(140))
                while running.contains(where: { !$0.isTerminated }) {
                    guard clock.now < deadline else { throw KnotInstallFailure.cannotReplace }
                    try await Task.sleep(for: .milliseconds(100))
                }
                didQuit = !running.isEmpty
                // A second copy may have started while the original app was draining.
                guard NSRunningApplication.runningApplications(withBundleIdentifier: "org.deskbridge.app").isEmpty else { throw KnotInstallFailure.changedApplication }
                status.stringValue = "앱 교체 후 다시 여는 중…"; await Task.yield()
                try transaction!.commit()
                try await open(destination)
                try? transaction!.discardStaged()
                status.stringValue = "설치 완료 · Knot을 다시 열었습니다. 기존 PC 연결 설정을 사용할 수 있습니다."
                working = false; install.title = "완료"; install.target = NSApp; install.action = #selector(NSApplication.terminate(_:)); install.isEnabled = true
            } catch {
                let recovery: KnotInstallRecovery.Result?
                if let transaction {
                    recovery = await KnotInstallRecovery.restore(transaction, wasRunning: didQuit, reopen: open)
                } else { recovery = nil }
                if recovery?.needsRecovery == true {
                    status.stringValue = "자동 복구를 완료하지 못했습니다. " + (recovery?.detail ?? "")
                } else {
                    status.stringValue = ((error as? LocalizedError)?.errorDescription ?? "업데이트를 완료하지 못했습니다.") + " " + (recovery?.detail ?? "")
                }
                working = false; install.isEnabled = true
            }
        }
    }

    private func open(_ url: URL) async throws {
        let config = NSWorkspace.OpenConfiguration(); config.activates = true
        try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}

@main struct KnotInstallerMain {
    @MainActor static func main() {
        let delegate = KnotInstaller(); let app = NSApplication.shared
        app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
