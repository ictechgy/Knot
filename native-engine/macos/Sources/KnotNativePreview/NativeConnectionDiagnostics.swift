import Foundation
import Combine
import SwiftUI

/// Only fixed codes enter this in-memory record: no endpoint, credential,
/// clipboard, remote content, raw error description, or filesystem logging.
enum NativeConnectionIssue: String, CaseIterable, Sendable {
    case silenceDeadline = "network.incoming-silence"
    case transport = "network.read-or-handshake"
    case writeTransport = "network.write"
    case decoder = "media.decoder"
    case presentation = "media.presentation"
    case approvalDeadline = "startup.approval-deadline"
    case firstImageDeadline = "startup.first-image-deadline"
    case certificatePin = "security.certificate-pin"
    case certificatePolicy = "security.certificate-policy"
    case trust = "security.device-authorization"
    case protocolFailure = "protocol.validation"
    case hostTimeout = "host.timeout"
    case hostFailure = "host.failure"
}

/// Categories describe authorization decisions, never the stored credential.
enum NativeRecoveryCredential: String, CaseIterable, Sendable {
    case none, saved, ambiguous
    case authenticatedEndpoint = "authenticated-endpoint"
    case storeUnavailable = "store-unavailable"
}

enum NativeRecoveryIntent: String, CaseIterable, Sendable {
    case none, current, transient, suspended
}

enum NativeRecoveryEvent: String, CaseIterable, Sendable {
    case savedDevicesLoaded = "recovery.saved-devices-loaded"
    case savedDevicesLoadFailed = "recovery.saved-devices-load-failed"
    case numberAdoptedSaved = "recovery.number-adopted-saved"
    case numberAdoptedEndpoint = "recovery.number-adopted-authenticated-endpoint"
    case numberTemporary = "recovery.number-temporary"
    case numberAmbiguous = "recovery.number-ambiguous"
    case numberStoreUnavailable = "recovery.number-store-unavailable"
    case registrationStarted = "recovery.registration-started"
    case registrationFailed = "recovery.registration-failed"
    case registrationSaved = "recovery.registration-saved"
    case recoveryDisabled = "recovery.disabled"
    case recoveryEnabled = "recovery.enabled"
    case transportFailure = "recovery.transport-failure"
    case retryScheduled = "recovery.retry-scheduled"
    case retryStarted = "recovery.retry-started"
    case retryCancelled = "recovery.retry-cancelled"
    case willSleep = "recovery.will-sleep"
    case didWake = "recovery.did-wake"
    case wakeScheduled = "recovery.wake-scheduled"
    case wakeStarted = "recovery.wake-started"
    case wakeCancelled = "recovery.wake-cancelled"
    case connectionClosed = "recovery.connection-closed"
}

struct NativeRecoverySnapshot: Equatable, Sendable {
    let autoReconnect: Bool
    let credential: NativeRecoveryCredential
    let isSystemSleeping: Bool
    let intent: NativeRecoveryIntent
    let scheduled: Bool
    let attempt: Int

    init(autoReconnect: Bool, credential: NativeRecoveryCredential, isSystemSleeping: Bool,
         intent: NativeRecoveryIntent, scheduled: Bool, attempt: Int) {
        self.autoReconnect = autoReconnect; self.credential = credential
        self.isSystemSleeping = isSystemSleeping; self.intent = intent
        self.scheduled = scheduled; self.attempt = max(0, attempt)
    }
    var line: String {
        "autoReconnect=\(autoReconnect) credential=\(credential.rawValue) sleeping=\(isSystemSleeping) intent=\(intent.rawValue) scheduled=\(scheduled) attempt=\(attempt)"
    }
}

@MainActor
final class NativeConnectionDiagnostics: ObservableObject {
    struct Entry: Equatable {
        let seconds: Int
        let issue: NativeConnectionIssue
        var line: String { "+\(seconds)s  \(issue.rawValue)" }
    }
    struct RecoveryEntry: Equatable {
        let seconds: Int
        let event: NativeRecoveryEvent
        let snapshot: NativeRecoverySnapshot
        var line: String { "+\(seconds)s  \(event.rawValue) \(snapshot.line)" }
    }
    static let capacity = 32
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var recoveryEntries: [RecoveryEntry] = []
    @Published private(set) var latestRecoverySnapshot: NativeRecoverySnapshot?
    private(set) var firstIssue: Entry?
    private let now: () -> ContinuousClock.Instant
    private let began: ContinuousClock.Instant

    init(now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.now = now; began = now()
    }
    func record(_ issue: NativeConnectionIssue) {
        let entry = Entry(seconds: elapsedSeconds, issue: issue)
        if firstIssue == nil { firstIssue = entry }
        if entries.count == Self.capacity { entries.removeFirst() }
        entries.append(entry)
    }
    func recordRecovery(_ event: NativeRecoveryEvent, snapshot: NativeRecoverySnapshot) {
        latestRecoverySnapshot = snapshot
        let entry = RecoveryEntry(seconds: elapsedSeconds, event: event, snapshot: snapshot)
        if recoveryEntries.count == Self.capacity { recoveryEntries.removeFirst() }
        recoveryEntries.append(entry)
    }
    private var elapsedSeconds: Int {
        Int(clamping: max(.zero, now() - began).components.seconds)
    }
    var report: String {
        guard let firstIssue else { return "" }
        var lines = ["Knot connection diagnostics v2", "Clock: elapsed seconds since app launch.",
                     "First issue: " + firstIssue.line, "Recent issues:"] + entries.map(\.line)
        if let latestRecoverySnapshot {
            lines.append("Recovery state: " + latestRecoverySnapshot.line)
            lines.append("Recent recovery decisions:")
            lines += recoveryEntries.map(\.line)
        }
        return lines.joined(separator: "\n")
    }
}

struct NativeConnectionDiagnosticsView: View {
    @ObservedObject var diagnostics: NativeConnectionDiagnostics
    var body: some View {
        if !diagnostics.entries.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    Text("이번 앱 실행 중 확인한 오류와 자동 복구 판단이에요. 시간은 앱 실행 시점 기준이며 재시도 후에도 남아요. 아래 내용을 선택해 복사할 수 있어요.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(diagnostics.report).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 10)
            } label: { Label("최근 연결 진단", systemImage: "stethoscope").font(.system(size: 13)) }
                .padding(16).nativePanel()
        }
    }
}
