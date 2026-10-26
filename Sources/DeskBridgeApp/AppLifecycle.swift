// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import Foundation

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate, ObservableObject {
    private let termination = DesktopTermination()
    private let drain = DesktopTerminationDrain()
    @Published private(set) var preparingToTerminate = false
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
            guard self?.terminating == false, self?.preparingToTerminate == false,
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
        requestTermination { sender.reply(toApplicationShouldTerminate: $0) }
    }
    /// Shared native Quit entry, with an inert reply seam for model checks.
    func requestTermination(timeout: Duration = .seconds(110), poll: Duration = .milliseconds(50),
                            reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        if termination.finished { return .terminateNow }
        guard !preparingToTerminate else { return .terminateLater }
        preparingToTerminate = true
        Self.setTerminationAdmissionPaused(true)
        drain.begin(timeout: timeout, poll: poll, protectedWork: {
            Self.desktop?.busy == true || Self.linuxDesktop?.busy == true ||
            Self.files?.busy == true || Self.files?.enrollmentActive == true ||
            Self.macHost?.downloading == true || Self.macHost?.busy == true
        }, ready: { [weak self] in
            guard let self else { Self.setTerminationAdmissionPaused(false); reply(false); return }
            KnotUpdates.shared.prepareForRelaunch()
            self.finishTermination(reply: reply)
        }, refused: { [weak self] in
            Self.setTerminationAdmissionPaused(false)
            self?.preparingToTerminate = false
            reply(false)
        })
        return .terminateLater
    }
    private static func setTerminationAdmissionPaused(_ paused: Bool) {
        desktop?.setTerminationAdmissionPaused(paused)
        linuxDesktop?.setTerminationAdmissionPaused(paused)
        files?.setTerminationAdmissionPaused(paused)
        macHost?.setTerminationAdmissionPaused(paused)
    }
    private func finishTermination(reply: @escaping @MainActor (Bool) -> Void) {
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
        }, reply: { reply(true) })
    }
}
