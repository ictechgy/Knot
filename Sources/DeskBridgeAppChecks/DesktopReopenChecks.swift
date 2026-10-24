// SPDX-License-Identifier: GPL-3.0-only
import DeskBridgeCore
import Foundation
import GlimmerEngine

@MainActor private final class SyntheticDesktopHost {
    var info: ServerInfo
    var requiredIDs: [String?] = []
    var opened: [ServerInfo] = []
    var configurations: [StreamConfiguration] = []
    var failure: (any Error)?
    var suspendRefresh = false
    var continuation: CheckedContinuation<Void, Never>?
    let app = HostApp(id: 42, name: "Desktop", hdrCapable: false, hidden: false)

    init() {
        info = ServerInfo(address: "192.168.1.20", uniqueId: "synthetic-host", serverName: "Synthetic")
        info.serverCertPEM = "SYNTHETIC NOT A CERTIFICATE"; info.pairStatus = .paired
    }
    var operations: DesktopOperations {
        DesktopOperations(fetchServerInfo: { [self] _, requiredID in
            requiredIDs.append(requiredID)
            if suspendRefresh { await withCheckedContinuation { continuation = $0 } }
            if let failure { throw failure }
            return info
        }, appList: { [self] _ in [app] }, openStream: { [self] _, _, snapshot, _, configuration in
            opened.append(snapshot)
            configurations.append(configuration)
        })
    }
}

/// Checks the actual model -> engine configuration boundary without opening a stream.
@MainActor
func runDesktopQualityChecks(temporary: URL) async throws -> Int {
    var count = 0
    func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ModelCheckFailure(message: message) }; count += 1
    }
    func settle(_ model: DesktopModel) async throws {
        for _ in 0..<1000 {
            if !model.busy { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw ModelCheckFailure(message: "synthetic quality operation did not settle")
    }
    let host = SyntheticDesktopHost()
    let directory = temporary.appendingPathComponent("desktop-quality")
    var settings = SavedSettings(); settings.address = host.info.address
    settings.host = SavedHost(address: host.info.address, uniqueID: host.info.uniqueId, name: host.info.serverName,
        certificatePEM: host.info.serverCertPEM!, httpPort: 47989, httpsPort: 47984)
    let store = SettingsStore(directory: directory)
    try store.save(settings)
    let suite = "org.deskbridge.synthetic." + UUID().uuidString
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let model = DesktopModel(storageDirectory: directory, identitySuite: suite, operations: host.operations)
    try expect(model.resolution == 1080 && model.frameRate == 60 && model.bitrateKbps == 0,
        "existing default quality changed")
    model.connect(); try await settle(model)
    // Literal expectations independently pin horizontal sizes and automatic bitrates.
    for (height, width, automatic) in [(1080, 1920, 20000), (1440, 2560, 30000), (2160, 3840, 60000)] {
        for fps in [30, 60] {
            for bitrate in [0, 10000, 20000, 30000, 40000, 60000, 80000, 100000] {
                model.resolution = height; model.frameRate = fps; model.bitrateKbps = bitrate
                let before = host.configurations.count
                model.start(host.app); try await settle(model)
                guard let config = host.configurations.last else { throw ModelCheckFailure(message: "quality did not reach openStream") }
                try expect(host.configurations.count == before + 1 && config.width == width && config.height == height &&
                    config.fps == fps && config.bitrateKbps == (bitrate == 0 ? automatic : bitrate),
                    "actual model passed incorrect quality to the engine")
            }
        }
    }
    for (height, fps, bitrate) in [(4320,60,0),(2160,120,0),(2160,60,-1),(2160,60,100001),(Int.max,Int.max,Int.max)] {
        model.resolution = height; model.frameRate = fps; model.bitrateKbps = bitrate
        let before = host.configurations.count, fetches = host.requiredIDs.count
        model.start(host.app); try await settle(model)
        try expect(host.configurations.count == before && host.requiredIDs.count == fetches && model.errorMessage != nil,
            "invalid quality reached network refresh or stream open")
    }
    model.resolution = 2160; model.frameRate = 60; model.bitrateKbps = 80000
    host.suspendRefresh = true
    model.start(host.app)
    for _ in 0..<1000 {
        if host.continuation != nil { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    guard let continuation = host.continuation else { throw ModelCheckFailure(message: "quality refresh never suspended") }
    model.resolution = 1080; model.frameRate = 30; model.bitrateKbps = 10000
    continuation.resume(); host.continuation = nil
    try await settle(model)
    let config = host.configurations.last!
    try expect(config.width == 3840 && config.height == 2160 && config.fps == 60 && config.bitrateKbps == 80000,
        "in-flight refresh changed the selected quality snapshot")
    let persisted = try store.load()
    try expect(persisted.address == settings.address && persisted.host?.certificatePEM == settings.host?.certificatePEM &&
        persisted.host?.uniqueID == settings.host?.uniqueID, "quality changed persistent connection trust")
    return count
}

@MainActor
func runDesktopReopenChecks(temporary: URL) async throws -> Int {
    var count = 0
    func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ModelCheckFailure(message: message) }; count += 1
    }
    func settle(_ model: DesktopModel) async throws {
        for _ in 0..<1000 {
            if !model.busy { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw ModelCheckFailure(message: "synthetic desktop operation did not settle")
    }
    for scenario in ["reopen", "failed-refresh", "cancel", "target-change", "wrong-id", "wrong-pin", "unpaired"] {
        let host = SyntheticDesktopHost()
        let directory = temporary.appendingPathComponent("desktop-reopen-" + scenario)
        var settings = SavedSettings(); settings.address = host.info.address
        settings.host = SavedHost(address: host.info.address, uniqueID: host.info.uniqueId, name: host.info.serverName,
            certificatePEM: host.info.serverCertPEM!, httpPort: 47989, httpsPort: 47984)
        let store = SettingsStore(directory: directory); try store.save(settings)
        let suite = "org.deskbridge.synthetic." + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        // NetworkClient construction is lazy. All operations are inert replacements;
        // these actual model paths never call a transport, identity read or NSWindow.
        let model = DesktopModel(storageDirectory: directory, identitySuite: suite, operations: host.operations)
        model.connect(); try await settle(model)
        try expect(model.paired && model.apps.count == 1, "synthetic connect did not bind the actual model")
        if scenario == "reopen" {
            model.start(host.app); try await settle(model)
            model.disconnect(); try await settle(model)
            host.info.currentGameID = host.app.id
            model.start(host.app); try await settle(model)
            model.disconnect(); try await settle(model)
            host.info.currentGameID = 0 // The Windows user exited Desktop in between opens.
            model.start(host.app); try await settle(model)
            try expect(host.opened.map(\.currentGameID) == [0, 42, 0], "reopen passed stale launch/resume occupancy")
            try expect(host.requiredIDs.count == 4 && host.requiredIDs.allSatisfy { $0 == "synthetic-host" },
                       "connect/start refresh omitted the saved host identity")
        } else {
            if scenario == "failed-refresh" { host.failure = StreamError.hostUnreachable("synthetic unreachable") }
            if scenario == "wrong-id" { host.info.uniqueId = "different-host" }
            if scenario == "wrong-pin" { host.info.serverCertPEM = "DIFFERENT SYNTHETIC CERTIFICATE" }
            if scenario == "unpaired" { host.info.pairStatus = .unpaired }
            let suspended = scenario == "cancel" || scenario == "target-change"
            host.suspendRefresh = suspended
            model.start(host.app)
            if suspended {
                for _ in 0..<1000 {
                    if host.continuation != nil { break }
                    try await Task.sleep(for: .milliseconds(1))
                }
                guard let continuation = host.continuation else { throw ModelCheckFailure(message: "refresh never suspended") }
                if scenario == "cancel" { model.cancelOperation() }
                else { model.address = "192.168.1.21" }
                continuation.resume(); host.continuation = nil
            }
            try await settle(model)
            try expect(host.opened.isEmpty, "failed/cancelled/changed-target refresh opened a stream")
            try expect(suspended || model.errorMessage != nil, "rejected refresh did not surface fixed guidance")
            if scenario == "target-change" { try expect(!model.paired, "changed target retained a live binding") }
        }
        let persisted = try store.load()
        try expect(persisted.host?.certificatePEM == settings.host?.certificatePEM &&
                   persisted.host?.uniqueID == settings.host?.uniqueID && persisted.address == settings.address,
                   "start refresh changed persistent trust or address")
    }
    return count
}
