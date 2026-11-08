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
    #expect(diagnostics.report.split(separator: "\n").count == NativeConnectionDiagnostics.capacity + 3)
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
