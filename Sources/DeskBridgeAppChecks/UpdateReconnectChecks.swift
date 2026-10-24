// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import DeskBridgeCore

@MainActor
func runUpdateReconnectChecks(temporary: URL) throws -> Int {
    var count = 0
    func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ModelCheckFailure(message: message) }; count += 1
    }
    let directory = temporary.appendingPathComponent("update-reconnect")
    let store = UpdateReconnectStore(directory: directory)
    let now = Date(timeIntervalSince1970: 1000), digest = String(repeating: "a", count: 64)
    let intent = UpdateReconnectIntent(endpoint: "192.168.1.21", hostUniqueID: "synthetic-host",
        certificateSHA256: digest, now: now)!
    func consume(build: String = "201", endpoint: String = "192.168.1.21", id: String = "synthetic-host",
                 certificate: String? = nil, when: Date? = nil) throws -> UpdateReconnectIntent? {
        try store.consume(currentBuild: build, endpoint: endpoint, hostUniqueID: id,
            certificateSHA256: certificate ?? digest, now: when ?? now)
    }
    try expect(try consume() == nil, "absent update receipt invented connection intent")
    try store.save(intent, previousBuild: "200")
    try expect(try consume() == intent, "a newer build lost the certificate-bound intent")
    try expect(try consume() == nil, "consumed update intent replayed")
    for build in ["200", "199", "", "0201", "201\n", "99999999999999999"] {
        try store.save(intent, previousBuild: "200")
        try expect(try consume(build: build) == nil, "same, older or malformed build admitted automatic verification")
        try expect(try consume() == nil, "failed build admission did not consume the receipt")
    }
    for (endpoint, id, certificate, when) in [
        ("192.168.1.22", "synthetic-host", digest, now),
        (intent.endpoint, "other-host", digest, now),
        (intent.endpoint, "synthetic-host", String(repeating: "b", count: 64), now),
        (intent.endpoint, "synthetic-host", digest, now.addingTimeInterval(600)),
        (intent.endpoint, "synthetic-host", digest, now.addingTimeInterval(-1))
    ] {
        try store.save(intent, previousBuild: "200")
        try expect(try consume(endpoint: endpoint, id: id, certificate: certificate, when: when) == nil,
                   "changed identity or expired intent admitted automatic verification")
        try expect(try consume() == nil, "failed identity admission left a replayable receipt")
    }
    let receipt = directory.appendingPathComponent("update-reconnect.json")
    try Data("MALFORMED SYNTHETIC RECEIPT".utf8).write(to: receipt)
    try expect(try consume() == nil, "malformed update receipt was admitted")
    try expect(try Data(contentsOf: receipt).isEmpty, "malformed receipt was not consumed before decoding")
    try store.save(intent, previousBuild: "200"); try store.clear()
    try expect(try consume() == nil, "cancelled receipt was retained")
    try FileManager.default.removeItem(at: receipt)
    let target = temporary.appendingPathComponent("synthetic-receipt-link-target")
    let sentinel = Data("PRESERVE SYNTHETIC TARGET".utf8); try sentinel.write(to: target)
    try FileManager.default.createSymbolicLink(at: receipt, withDestinationURL: target)
    do { _ = try consume(); throw ModelCheckFailure(message: "symlink update receipt accepted") }
    catch is CorePrivateStorageFailure { count += 1 }
    try expect(try Data(contentsOf: target) == sentinel, "reconnect receipt touched a symlink target")

    let modelDirectory = temporary.appendingPathComponent("update-reconnect-model")
    let settingsStore = SettingsStore(directory: modelDirectory)
    var settings = SavedSettings(); settings.address = intent.endpoint
    settings.host = SavedHost(address: intent.endpoint, uniqueID: "synthetic-host", name: "Synthetic",
        certificatePEM: "-----BEGIN CERTIFICATE-----\nU1lOVEhFVElD\n-----END CERTIFICATE-----", httpPort: 47989, httpsPort: 47984)
    settings.sshHostPublicKey = "PRESERVE SYNTHETIC SSH PIN"
    try settingsStore.save(settings)
    let before = try Data(contentsOf: modelDirectory.appendingPathComponent("settings.json"))
    let suite = "org.deskbridge.synthetic." + UUID().uuidString
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let model = DesktopModel(storageDirectory: modelDirectory, identitySuite: suite)
    model.paired = true
    try model.prepareUpdateReconnect(build: "200", now: now)
    try expect(try model.consumeUpdateReconnect(build: "201", now: now), "actual model failed to normalize the colon-separated certificate fingerprint")
    try expect(try !model.consumeUpdateReconnect(build: "201", now: now), "actual model replayed update verification")
    try expect(try Data(contentsOf: modelDirectory.appendingPathComponent("settings.json")) == before,
               "update reconnect changed screen/file trust settings")
    return count
}
