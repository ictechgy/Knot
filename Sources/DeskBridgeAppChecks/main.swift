// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import DeskBridgeCore
import Foundation

/// Compiled with the app's actual models, excluding App.main. All state is synthetic and temporary.
@main
struct AppModelChecks {
    @MainActor static func main() async throws {
        // Actual Mac host producer -> PNG pixels -> Windows decoder/parser.
        // The caller owns the fresh output path; no user image or preferences.
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--synthetic-mac-qr" {
            let invitation = try ConnectionInvitation(name: "Knot Mac", addresses: ["192.168.50.20"])
            guard let png = MacHostQR.png(invitation), let bitmap = NSBitmapImageRep(data: png),
                  bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
                  bitmap.pixelsWide <= 2048, bitmap.pixelsHigh <= 2048 else {
                throw ModelCheckFailure(message: "Synthetic Mac QR PNG generation failed")
            }
            var luminance = Data(capacity: bitmap.pixelsWide * bitmap.pixelsHigh)
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                        throw ModelCheckFailure(message: "Synthetic Mac QR pixel conversion failed")
                    }
                    luminance.append(UInt8(max(0, min(255, (color.redComponent * 255).rounded()))))
                }
            }
            let fixture: [String: Any] = ["link": invitation.url.absoluteString,
                "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh,
                "luminance": luminance.base64EncodedString()]
            try JSONSerialization.data(withJSONObject: fixture).write(
                to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .withoutOverwriting)
            print("{\"status\":\"passed\",\"scope\":\"fresh actual Swift host invitation and PNG pixels; no UI/network\"}")
            return
        }
        // Used only by test_windows_launcher.py with its newly generated C# BMP.
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--synthetic-qr-bmp" {
            let invitation = try ConnectionQRReader.decode(data: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
            guard invitation.name == "Synthetic PC", invitation.addresses == ["192.168.1.20", "100.80.10.20"] else {
                throw ModelCheckFailure(message: "Windows QR encoding / Mac decoding contract differs")
            }
            print("{\"status\":\"passed\",\"windowsToMacQRInterop\":1,\"scope\":\"new synthetic C# bitmap decoded by actual Mac QR reader; no UI/network/camera\"}")
            return
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("deskbridge-model-fixtures-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if CommandLine.arguments.dropFirst().first == "--synthetic-termination-admission" {
            let admission = try await runTerminationAdmissionChecks(temporary: temporary)
            let enrollment = try runSetupExchangeGateChecks(temporary: temporary)
            let guidance = try await runDesktopFailureGuidanceChecks(temporary: temporary)
            print("{\"status\":\"passed\",\"terminationAdmissionChecks\":\(admission),\"setupExchangeGateChecks\":\(enrollment),\"desktopGuidanceChecks\":\(guidance),\"scope\":\"actual Quit/model entry paths; fresh temp stores and inert injected operations; no UI/network\"}")
            return
        }
        var count = 0
        func expect(_ condition: Bool, _ message: String) throws {
            guard condition else { throw ModelCheckFailure(message: message) }; count += 1
        }
        let prefix: [UInt8] = [0,0,0,11,115,115,104,45,101,100,50,53,53,49,57,0,0,0,32]
        let clientKey = "ssh-ed25519 " + Data(prefix + Array(repeating: UInt8(1), count: 32)).base64EncodedString()
        let serverKey = "ssh-ed25519 " + Data(prefix + Array(repeating: UInt8(2), count: 32)).base64EncodedString()
        let reply: [String: Any] = ["kind": "deskbridge.windows-connection", "version": 1,
            "requestID": UUID().uuidString, "clientPublicKey": clientKey, "address": "100.80.10.30",
            "port": 22, "username": "deskbridge-transfer", "serverPublicKey": serverKey]
        let preview = try SetupExchange.preview(JSONSerialization.data(withJSONObject: reply), clientPublicKey: clientKey)
        for failStorage in [false, true] {
            let directory = temporary.appendingPathComponent(failStorage ? "failure" : "success")
            let store = SettingsStore(directory: directory)
            var original = SavedSettings(); original.address = "192.168.1.20"
            original.sshUsername = "old-user"; original.sshHostPublicKey = clientKey
            original.sshIdentityPath = directory.appendingPathComponent("not-created-key").path
            original.host = SavedHost(address: original.address, uniqueID: "synthetic-host", name: "Synthetic",
                certificatePEM: "SYNTHETIC NOT A CERTIFICATE", httpPort: 47989, httpsPort: 47984)
            try store.save(original)
            let suite = "org.deskbridge.synthetic." + UUID().uuidString
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            let desktop = DesktopModel(storageDirectory: directory, identitySuite: suite)
            let files = FilesModel(desktop: desktop)
            desktop.paired = true; desktop.fingerprint = "synthetic-paired-fingerprint"
            let originalSSHFingerprint = files.keyFingerprint
            desktop.pair()
            for _ in 0..<1000 {
                if !desktop.busy { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            try expect(!desktop.busy && desktop.errorMessage?.contains("인증서를 먼저 삭제") == true,
                       "pairing with an existing saved host is refused before network work")
            try expect(desktop.settings.host?.certificatePEM == original.host?.certificatePEM &&
                       (try store.load()).host?.certificatePEM == original.host?.certificatePEM,
                       "refused re-pairing preserves the saved certificate")
            if failStorage {
                try FileManager.default.removeItem(at: directory)
                try Data("synthetic storage blocker".utf8).write(to: directory)
                var failed = false
                do { try files.applyWindowsConnection(preview) } catch { failed = true }
                try expect(failed, "storage failure surfaced")
                try expect(desktop.address == original.address && desktop.settings.address == original.address,
                           "failed import leaves target and saved settings unchanged")
                try expect(desktop.paired && desktop.fingerprint == "synthetic-paired-fingerprint",
                           "failed import preserves current pairing state")
                try expect(files.username == original.sshUsername && files.pinnedHostKey == original.sshHostPublicKey &&
                           files.keyFingerprint == originalSSHFingerprint, "failed import leaves visible SSH identity unchanged")
            } else {
                try files.applyWindowsConnection(preview)
                try expect(desktop.address == preview.reply.address && !desktop.paired, "successful import updates target and invalidates pairing")
                try expect(files.username == preview.reply.username && files.pinnedHostKey == serverKey &&
                           files.keyFingerprint == preview.fingerprint, "successful import publishes SSH settings")
                let persisted = try store.load()
                try expect(persisted.address == preview.reply.address && persisted.sshHostPublicKey == serverKey,
                           "successful import persists the complete settings transaction")
                files.pinnedHostKey = clientKey
                try expect(files.keyFingerprint == originalSSHFingerprint && files.keyFingerprint != preview.fingerprint,
                           "edited host key retained a stale displayed fingerprint")
                files.pinnedHostKey = "ssh-ed25519 AAAA"
                try expect(files.keyFingerprint.isEmpty, "invalid edited host key retained a fingerprint")
                files.pinnedHostKey = serverKey
                files.connected = true
                var refused = false
                do { try files.applyWindowsConnection(preview) } catch { refused = true }
                try expect(refused, "active connection prevents import")
            }
            // Exercise actual FilesModel error recovery without creating a transport or showing UI.
            files.connected = true; files.selection = "/files/synthetic"
            files.perform { throw SFTPError.remoteStatus(3, "synthetic denied") }
            try await settle(files)
            try expect(files.connected && files.selection != nil, "ordinary remote permission error retains connection")
            files.perform { throw SFTPError.timedOut }
            try await settle(files)
            try expect(!files.connected && files.selection == nil && files.entries.isEmpty,
                       "terminal transport error clears connection and stale file UI")
            try expect(files.errorMessage != nil && !files.busy, "terminal transport error permits reconnect")
            files.connected = true
            files.perform { throw CancellationError() }
            try await settle(files)
            try expect(!files.connected && files.errorMessage == nil && files.status.contains("취소"),
                       "user cancellation resets connection without a raw error banner")
            for failure: any Error in [SFTPError.remoteStatus(3, "synthetic denied"), CancellationError()] {
                files.connected = true
                files.perform {
                    files.recordCommittedTransfer("보내기 완료: /files/synthetic-committed")
                    throw failure
                }
                try await settle(files)
                try expect(files.status.hasPrefix("보내기 완료:") && files.errorMessage == nil,
                           "a post-commit refresh failure/cancel falsely reported transfer failure")
            }
            await files.shutdown()
        }
        let discovery = try await runConnectionDiscoveryChecks(temporary: temporary)
        let keySelection = try runFileIdentitySelectionChecks(temporary: temporary)
        let desktopGuidance = try await runDesktopFailureGuidanceChecks(temporary: temporary)
        let updateReconnect = try runUpdateReconnectChecks(temporary: temporary)
        let setupExchangeGate = try runSetupExchangeGateChecks(temporary: temporary)
        let enrollmentAdmission = try await runDesktopEnrollmentAdmissionChecks(temporary: temporary)
        let screenVerification = try await runScreenVerificationChecks(temporary: temporary)
        let desktopReopen = try await runDesktopReopenChecks(temporary: temporary)
        let desktopQuality = try await runDesktopQualityChecks(temporary: temporary)
        let desktopRecovery = try runDesktopRecoveryChecks()
        let termination = try await runDesktopTerminationChecks()
        let terminationAdmission = try await runTerminationAdmissionChecks(temporary: temporary)
        let linuxContext = try await runLinuxContextChecks(temporary: temporary)
        let macHost = try await runMacHostChecks(temporary: temporary)
        print("{\"status\":\"passed\",\"appModelChecks\":\(count),\"updateReconnectChecks\":\(updateReconnect),\"desktopEnrollmentAdmissionChecks\":\(enrollmentAdmission),\"desktopQualityChecks\":\(desktopQuality),\"discoveryAndQRChecks\":\(discovery),\"keySelectionChecks\":\(keySelection),\"desktopErrorGuidanceChecks\":\(desktopGuidance),\"setupExchangeGateChecks\":\(setupExchangeGate),\"screenVerificationChecks\":\(screenVerification),\"desktopReopenChecks\":\(desktopReopen),\"desktopRecoveryChecks\":\(desktopRecovery),\"terminationChecks\":\(termination),\"terminationAdmissionChecks\":\(terminationAdmission),\"macHostChecks\":\(macHost),\"linuxContextChecks\":\(linuxContext),\"scope\":\"synthetic temp storage and isolated identity suite; no App.main, UI, camera or network\"}")
    }
    @MainActor private static func settle(_ files: FilesModel) async throws {
        for _ in 0..<1000 {
            if !files.busy { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw ModelCheckFailure(message: "model operation failed to settle")
    }
}
struct ModelCheckFailure: Error { let message: String }
