import Foundation
import Testing
@testable import KnotNativePreview

@Test @MainActor func connectionDiagnosticsRetainsFirstCauseAcrossBoundedRetryHistory() {
    let began = ContinuousClock.now
    var instant = began
    let diagnostics = NativeConnectionDiagnostics(now: { instant })
    #expect(diagnostics.report.isEmpty)
    diagnostics.record(.silenceDeadline)
    for index in 1...100 {
        instant = began + .seconds(index)
        diagnostics.record(.transport)
    }
    #expect(diagnostics.entries.count == NativeConnectionDiagnostics.capacity)
    #expect(diagnostics.firstIssue == .init(seconds: 0, issue: .silenceDeadline))
    #expect(diagnostics.entries.first?.seconds == 69)
    #expect(diagnostics.entries.last?.seconds == 100)
    #expect(diagnostics.report.contains("First issue: +0s  network.incoming-silence"))
    #expect(diagnostics.report.split(separator: "\n").count == NativeConnectionDiagnostics.capacity + 4)
}

@Test @MainActor func connectionDiagnosticsAcceptsOnlyFixedCodesAndClampsNegativeElapsedTime() {
    let began = ContinuousClock.now
    var instant = began
    let diagnostics = NativeConnectionDiagnostics(now: { instant })
    instant = began - .seconds(5)
    for issue in NativeConnectionIssue.allCases { diagnostics.record(issue) }
    #expect(diagnostics.entries.allSatisfy { $0.seconds == 0 })
    #expect(diagnostics.entries.map(\.issue) == NativeConnectionIssue.allCases)
    #expect(diagnostics.report.utf8.count < 2048)
}


private func recoverySnapshot(credential: NativeRecoveryCredential = .saved,
                              intent: NativeRecoveryIntent = .current,
                              sleeping: Bool = false, scheduled: Bool = false,
                              attempt: Int = 0, autoReconnect: Bool = true) -> NativeRecoverySnapshot {
    NativeRecoverySnapshot(autoReconnect: autoReconnect, credential: credential, isSystemSleeping: sleeping,
                           intent: intent, scheduled: scheduled, attempt: attempt)
}

@Test @MainActor func successfulRecoveryDecisionsNeverBecomeOrReplaceFirstIssue() {
    let began = ContinuousClock.now
    var instant = began
    let diagnostics = NativeConnectionDiagnostics(now: { instant })
    diagnostics.recordRecovery(.numberAdoptedEndpoint, snapshot: recoverySnapshot(credential: .authenticatedEndpoint))
    instant = began + .seconds(30)
    diagnostics.recordRecovery(.willSleep, snapshot: recoverySnapshot(credential: .authenticatedEndpoint, intent: .suspended, sleeping: true))
    #expect(diagnostics.entries.isEmpty && diagnostics.firstIssue == nil && diagnostics.report.isEmpty)
    instant = began + .seconds(3575)
    diagnostics.record(.silenceDeadline)
    diagnostics.recordRecovery(.transportFailure, snapshot: recoverySnapshot(credential: .authenticatedEndpoint, intent: .transient))
    diagnostics.recordRecovery(.retryScheduled, snapshot: recoverySnapshot(credential: .authenticatedEndpoint, intent: .transient, scheduled: true, attempt: 1))
    #expect(diagnostics.firstIssue == .init(seconds: 3575, issue: .silenceDeadline))
    #expect(diagnostics.entries.count == 1 && diagnostics.recoveryEntries.count == 4)
    #expect(diagnostics.report.hasPrefix("Knot connection diagnostics v2\nClock: elapsed seconds since app launch."))
    #expect(diagnostics.report.contains("First issue: +3575s  network.incoming-silence"))
    #expect(diagnostics.report.contains("Recovery state: autoReconnect=true credential=authenticated-endpoint sleeping=false intent=transient scheduled=true attempt=1"))
    #expect(diagnostics.report.contains("recovery.number-adopted-authenticated-endpoint"))
}

@Test @MainActor func recoveryHistoryHasIndependentBoundAndRetainsLatestDecisionSnapshot() {
    let began = ContinuousClock.now
    var instant = began
    let diagnostics = NativeConnectionDiagnostics(now: { instant })
    diagnostics.record(.transport)
    for index in 0...100 {
        instant = began + .seconds(index)
        diagnostics.recordRecovery(.retryScheduled, snapshot: recoverySnapshot(intent: .transient, scheduled: true, attempt: index))
    }
    #expect(diagnostics.recoveryEntries.count == NativeConnectionDiagnostics.capacity)
    #expect(diagnostics.recoveryEntries.first?.seconds == 69 && diagnostics.recoveryEntries.last?.seconds == 100)
    #expect(diagnostics.latestRecoverySnapshot == recoverySnapshot(intent: .transient, scheduled: true, attempt: 100))
    #expect(diagnostics.firstIssue == .init(seconds: 0, issue: .transport) && diagnostics.entries.count == 1)
    #expect(diagnostics.report.split(separator: "\n").count == NativeConnectionDiagnostics.capacity + 7)
}

@Test @MainActor func recoveryDiagnosticsAcceptOnlyFixedCategoriesAndClampNegativeElapsedAndAttempt() {
    let began = ContinuousClock.now
    var instant = began
    let diagnostics = NativeConnectionDiagnostics(now: { instant })
    instant = began - .seconds(100)
    for event in NativeRecoveryEvent.allCases {
        diagnostics.recordRecovery(event, snapshot: recoverySnapshot(credential: .storeUnavailable, intent: .none, attempt: -1, autoReconnect: false))
    }
    #expect(diagnostics.recoveryEntries.map(\.event) == NativeRecoveryEvent.allCases)
    #expect(diagnostics.recoveryEntries.allSatisfy { $0.seconds == 0 && $0.snapshot.attempt == 0 })
    #expect(diagnostics.firstIssue == nil)
    diagnostics.record(.silenceDeadline)
    let codes = diagnostics.recoveryEntries.map { $0.event.rawValue }
    #expect(codes.allSatisfy { $0.hasPrefix("recovery.") && $0.utf8.allSatisfy { (45...46).contains($0) || (97...122).contains($0) } })
    #expect(NativeRecoveryCredential.allCases.count == 5 && NativeRecoveryIntent.allCases.count == 4)
    #expect(diagnostics.report.utf8.count < 8192)
}
