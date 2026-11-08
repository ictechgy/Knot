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

@MainActor
final class NativeConnectionDiagnostics: ObservableObject {
    struct Entry: Equatable {
        let seconds: Int
        let issue: NativeConnectionIssue
        var line: String { "+\(seconds)s  \(issue.rawValue)" }
    }
    static let capacity = 32
    @Published private(set) var entries: [Entry] = []
    private(set) var firstIssue: Entry?
    private let now: () -> ContinuousClock.Instant
    private let began: ContinuousClock.Instant

    init(now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.now = now; began = now()
    }
    func record(_ issue: NativeConnectionIssue) {
        let elapsed = max(.zero, now() - began)
        let entry = Entry(seconds: Int(clamping: elapsed.components.seconds), issue: issue)
        if firstIssue == nil { firstIssue = entry }
        if entries.count == Self.capacity { entries.removeFirst() }
        entries.append(entry)
    }
    var report: String {
        guard let firstIssue else { return "" }
        return (["Knot connection diagnostics v1", "First issue: " + firstIssue.line, "Recent issues:"] + entries.map(\.line)).joined(separator: "\n")
    }
}

struct NativeConnectionDiagnosticsView: View {
    @ObservedObject var diagnostics: NativeConnectionDiagnostics
    var body: some View {
        if !diagnostics.entries.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    Text("이번 앱 실행 중 확인한 오류예요. 재시도 후에도 남아요. 아래 내용을 선택해 복사할 수 있어요.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(diagnostics.report).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 10)
            } label: { Label("최근 연결 진단", systemImage: "stethoscope").font(.system(size: 13)) }
                .padding(16).nativePanel()
        }
    }
}
