// SPDX-License-Identifier: GPL-3.0-only
import DeskBridgeCore
import Foundation
import GlimmerEngine

/// Real model entry points, inert operations and fresh private settings only.
@MainActor
func runDesktopEnrollmentAdmissionChecks(temporary: URL) async throws -> Int {
    var count = 0, calls = 0
    func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ModelCheckFailure(message: message) }; count += 1
    }
    func settle(_ model: DesktopModel) async throws {
        for _ in 0..<1000 {
            if !model.busy { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw ModelCheckFailure(message: "synthetic admission operation failed to settle")
    }
    let app = HostApp(id: 42, name: "Desktop", hdrCapable: false, hidden: false)
    var models: [DesktopModel] = [], suites: [String] = []
    defer { for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) } }
    for platform: HostPlatform in [.windows, .linux] {
        let directory = temporary.appendingPathComponent("enrollment-admission-" + platform.rawValue)
        let suite = "org.deskbridge.synthetic." + UUID().uuidString; suites.append(suite)
        var info = ServerInfo(address: "192.168.1.30", uniqueId: "synthetic-host", serverName: "Synthetic")
        info.serverCertPEM = "SYNTHETIC NOT A CERTIFICATE"; info.pairStatus = .paired
        var settings = SavedSettings(); settings.address = info.address
        settings.host = SavedHost(address: info.address, uniqueID: info.uniqueId, name: info.serverName,
            certificatePEM: info.serverCertPEM!, httpPort: 47989, httpsPort: 47984)
        try SettingsStore(directory: directory).save(settings)
        let result = info
        let operations = DesktopOperations(fetchServerInfo: { _, _ in calls += 1; return result },
            appList: { _ in calls += 1; return [app] }, openStream: { _, _, _, _, _ in calls += 1 })
        let model = DesktopModel(storageDirectory: directory, identitySuite: suite, platform: platform, operations: operations)
        model.connect(); try await settle(model)
        try expect(model.paired && model.apps.count == 1, "inert setup did not bind the actual paired model")
        models.append(model)
    }
    let windows = models[0], linux = models[1]
    windows.peerDesktop = linux; linux.peerDesktop = windows
    let files = FilesModel(desktop: windows)
    for canceledModal in [false, true] {
        files.enrollmentConfirmation = canceledModal ? nil : UUID()
        files.enrollmentModalActive = canceledModal; files.busy = !canceledModal
        let before = calls
        for model in models {
            try expect(model.enrollmentEngaged && !model.canChoosePC && !model.canVerifyCurrentPC && !model.canForgetHost,
                       "own/peer enrollment did not gate PC changes and certificate reset")
            model.start(app)
            try expect(!model.busy && model.errorMessage != nil, "screen launch admitted active enrollment")
            model.pair()
            try expect(!model.busy && model.errorMessage != nil, "PIN pairing admitted active enrollment")
            model.connect()
            try expect(!model.busy && model.errorMessage != nil, "PC verification admitted active enrollment")
            model.perform { calls += 1000 }
            try expect(!model.busy, "direct desktop work bypassed shared enrollment admission")
            model.disconnect(); try await settle(model)
            try expect(model.status.contains("연결을 끊었습니다"), "enrollment blocked owned disconnect cleanup")
        }
        try expect(calls == before, "refused enrollment-time action reached a network/stream operation")
    }
    files.enrollmentConfirmation = nil; files.enrollmentModalActive = false; files.busy = true
    for model in models {
        let before = calls
        model.start(app); try await settle(model)
        try expect(!model.enrollmentEngaged && calls == before + 2,
                   "enrollment isolation incorrectly removed ordinary screen/file concurrency")
    }
    files.busy = false
    return count
}
