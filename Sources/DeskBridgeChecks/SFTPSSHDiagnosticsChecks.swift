import Foundation
import DeskBridgeCore
import Darwin

private struct SSHDiagnosticsCheckFailure: Error { let message: String }
private func diagnosticsCheck(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw SSHDiagnosticsCheckFailure(message: message) }
}

/// Only newly synthesized bytes and anonymous pipes are used. This never runs
/// OpenSSH, reads an existing log/key/preferences file, or makes a connection.
func runSFTPSSHDiagnosticsChecks() async throws -> Int {
    var checks = 0
    let signatures: [(String, SFTPSSHFailure)] = [
        ("WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!", .hostKeyVerificationFailed),
        ("Host key verification failed.", .hostKeyVerificationFailed),
        ("synthetic-user@synthetic.invalid: Permission denied (publickey).", .authenticationRejected),
        ("ssh: connect to host synthetic.invalid port 22: Connection refused", .connectionRefused),
        ("ssh: connect to host synthetic.invalid port 22: No route to host", .networkUnavailable),
        ("ssh: connect to host synthetic.invalid port 22: Network is unreachable", .networkUnavailable),
        ("ssh: connect to host synthetic.invalid port 22: Operation timed out", .networkUnavailable),
        ("ssh: connect to host synthetic.invalid port 22: Connection timed out", .networkUnavailable),
    ]
    for (message, expected) in signatures {
        let data = Data(message.utf8)
        // Every split, including splits inside ASCII tokens, must be equivalent.
        for split in 0...data.count {
            var classifier = SFTPSSHFailureClassifier()
            classifier.consume(Data(data.prefix(split))); classifier.consume(Data(data.dropFirst(split)))
            try diagnosticsCheck(classifier.failure == expected, "SSH diagnostic changed across a chunk boundary")
        }
        checks += 1
    }
    do {
        var classifier = SFTPSSHFailureClassifier()
        let all = "Connection refused\nPermission denied (publickey).\nHost key verification failed.\nNetwork is unreachable"
        for byte in all.utf8 { classifier.consume(Data([byte])) }
        try diagnosticsCheck(classifier.failure == .hostKeyVerificationFailed, "host-key failure lost priority to other diagnostics"); checks += 1
        try diagnosticsCheck(classifier.inspectedByteCount == all.utf8.count && classifier.retainedByteCount <= 64,
                             "SSH classifier retained an unbounded raw diagnostic"); checks += 1
    }
    do {
        var classifier = SFTPSSHFailureClassifier()
        classifier.consume(Data(repeating: 0xff, count: SFTPSSHFailureClassifier.maximumInspectedBytes))
        classifier.consume(Data("Host key verification failed.\nPermission denied (publickey).".utf8))
        try diagnosticsCheck(classifier.failure == nil && classifier.inspectedByteCount == 4096 && classifier.retainedByteCount == 0,
                             "SSH parsing exceeded its byte budget or retained raw bytes"); checks += 1
        try diagnosticsCheck(classifier.replacingStartupDisconnect(.disconnected) == .disconnected,
                             "unknown or exit-255-style EOF guessed an authentication reason"); checks += 1
    }
    do {
        let token = Data("Host key verification failed.".utf8)
        var classifier = SFTPSSHFailureClassifier()
        classifier.consume(Data(repeating: 120, count: 4096 - token.count)); classifier.consume(token)
        try diagnosticsCheck(classifier.failure == .hostKeyVerificationFailed && classifier.retainedByteCount == 0,
                             "diagnostic ending exactly at byte budget was missed"); checks += 1
        for original in [SFTPError.cancelled, .timedOut, .protocolViolation("synthetic"), .localIO("synthetic")] {
            try diagnosticsCheck(classifier.replacingStartupDisconnect(original) == original,
                                 "SSH guidance masked cancellation, deadline or protocol failure"); checks += 1
        }
    }
    do {
        var classifier = SFTPSSHFailureClassifier()
        classifier.consume(Data("synthetic-private-user@synthetic-secret-host: Permission denied (publickey). /synthetic-secret-path".utf8))
        let reported = classifier.replacingStartupDisconnect(.disconnected)
        try diagnosticsCheck(reported == .sshConnectionFailure(.authenticationRejected), "authentication guidance was not typed"); checks += 1
        try diagnosticsCheck(!reported.localizedDescription.contains("synthetic-") && !reported.localizedDescription.contains("publickey"),
                             "raw SSH identity or diagnostic leaked into guidance"); checks += 1
        for failure: SFTPSSHFailure in [.hostKeyVerificationFailed, .authenticationRejected, .connectionRefused, .networkUnavailable] {
            try diagnosticsCheck(SFTPError.requiresReconnect(after: SFTPError.sshConnectionFailure(failure)),
                                 "SSH startup failure left a reusable session"); checks += 1
        }
    }
    do {
        let pipe = Pipe()
        let drainer = try SFTPSSHStderrDrain(input: pipe.fileHandleForReading)
        defer { drainer.close(); try? pipe.fileHandleForWriting.close() }
        let writerFD = pipe.fileHandleForWriting.fileDescriptor
        guard fcntl(writerFD, F_SETFL, fcntl(writerFD, F_GETFL) | O_NONBLOCK) == 0,
              fcntl(writerFD, F_SETNOSIGPIPE, 1) == 0 else {
            throw SSHDiagnosticsCheckFailure(message: "cannot configure synthetic diagnostic writer")
        }
        // Far beyond the parser budget and pipe capacity. The later host-key
        // phrase is outside the budget and must not change the earlier result.
        let bytes = Data("Permission denied (publickey).\n".utf8) + Data(repeating: 120, count: 1_048_576) + Data("Host key verification failed.".utf8)
        let writer = Task.detached {
            defer { try? pipe.fileHandleForWriting.close() }
            let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    guard DispatchTime.now().uptimeNanoseconds < deadline else {
                        throw SSHDiagnosticsCheckFailure(message: "diagnostic pipe stopped draining after its parsing budget")
                    }
                    var ready = pollfd(fd: writerFD, events: Int16(POLLOUT), revents: 0)
                    let result = Darwin.poll(&ready, 1, 50)
                    if result < 0 && errno == EINTR { continue }
                    guard result >= 0 else { throw SSHDiagnosticsCheckFailure(message: "synthetic diagnostic poll failed") }
                    if result == 0 { continue }
                    let count = Darwin.write(writerFD, buffer.baseAddress!.advanced(by: offset), min(8192, buffer.count - offset))
                    if count > 0 { offset += count }
                    else if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                    else { throw SSHDiagnosticsCheckFailure(message: "synthetic diagnostic pipe unexpectedly closed") }
                }
            }
        }
        try await writer.value
        try diagnosticsCheck(drainer.waitForEOF(timeout: 1), "stderr reader did not finish at synthetic EOF"); checks += 1
        try diagnosticsCheck(drainer.failure == .authenticationRejected && drainer.inspectedByteCount == 4096,
                             "drainer exceeded parser budget or lost fixed guidance"); checks += 1
    }
    do {
        let pipe = Pipe()
        let drainer = try SFTPSSHStderrDrain(input: pipe.fileHandleForReading)
        defer { drainer.close(); try? pipe.fileHandleForWriting.close() }
        let writer = Task.detached {
            try await Task.sleep(for: .milliseconds(250))
            try pipe.fileHandleForWriting.write(contentsOf: Data("Host key verification failed.".utf8))
            try pipe.fileHandleForWriting.close()
        }
        try diagnosticsCheck(drainer.waitForEOF(timeout: 1), "startup grace missed delayed SSH diagnostics"); checks += 1
        try await writer.value
        try diagnosticsCheck(drainer.failure == .hostKeyVerificationFailed, "delayed host-key rejection lost its fixed guidance"); checks += 1
    }
    do {
        let pipe = Pipe()
        let readFD = pipe.fileHandleForReading.fileDescriptor
        let drainer = try SFTPSSHStderrDrain(input: pipe.fileHandleForReading)
        defer { try? pipe.fileHandleForWriting.close() }
        let started = DispatchTime.now().uptimeNanoseconds
        drainer.close(); drainer.close()
        try diagnosticsCheck(DispatchTime.now().uptimeNanoseconds - started < 1_000_000_000,
                             "stderr cancellation did not wake its reader"); checks += 1
        try diagnosticsCheck(fcntl(readFD, F_GETFD) == -1 && errno == EBADF && drainer.waitForEOF(timeout: 0),
                             "stderr cleanup leaked its descriptor or reader"); checks += 1
        try diagnosticsCheck(drainer.failure == nil, "cancelled diagnostic reader invented an SSH failure"); checks += 1
    }
    return checks
}
