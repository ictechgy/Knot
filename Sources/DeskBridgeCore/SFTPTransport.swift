import Foundation
import CryptoKit
import Darwin

public struct SFTPConnectionConfiguration: Sendable {
    public let host: String
    public let port: UInt16
    public let username: String
    public let identityFile: URL
    public let pinnedHostPublicKey: String
    public let hostKeyFingerprint: String
    let hostKeyAlias: String

    public init(host: String, port: UInt16 = 22, username: String, identityFile: URL, pinnedHostPublicKey: String) throws {
        let pinnedHostPublicKey = pinnedHostPublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedHost = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        guard !host.isEmpty, host.utf8.count <= 253, host.unicodeScalars.allSatisfy({ allowedHost.contains($0) }),
              !host.hasPrefix("-"), !host.contains(".."), port != 0 else {
            throw SFTPError.invalidConfiguration("invalid hostname or port")
        }
        if host.contains(":") {
            var address = in6_addr()
            guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
                throw SFTPError.invalidConfiguration("invalid IPv6 address")
            }
        }
        let allowedUser = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !username.isEmpty, username.utf8.count <= 64, !username.hasPrefix("-"),
              username.unicodeScalars.allSatisfy({ allowedUser.contains($0) }) else {
            throw SFTPError.invalidConfiguration("use a dedicated local Windows username")
        }
        guard identityFile.isFileURL, identityFile.path.hasPrefix("/"),
              !identityFile.path.contains("%"),
              !identityFile.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SFTPError.invalidConfiguration("invalid identity file path")
        }
        guard pinnedHostPublicKey.utf8.count <= 4096,
              !pinnedHostPublicKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SFTPError.invalidConfiguration("paste one Ed25519 host public key line")
        }
        let fields = pinnedHostPublicKey.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2, fields[0] == "ssh-ed25519", let blob = Data(base64Encoded: String(fields[1])) else {
            throw SFTPError.invalidConfiguration("an ssh-ed25519 server host public key is required")
        }
        var key = SFTPBinaryReader(blob)
        guard (try? key.string()) == "ssh-ed25519", (try? key.bytes(maximum: 32).count) == 32, key.remaining == 0 else {
            throw SFTPError.invalidConfiguration("invalid Ed25519 host public key")
        }
        let digest = Data(SHA256.hash(data: blob))
        self.host = host; self.port = port; self.username = username; self.identityFile = identityFile
        self.pinnedHostPublicKey = "ssh-ed25519 \(blob.base64EncodedString())"
        self.hostKeyFingerprint = "SHA256:" + digest.base64EncodedString().replacingOccurrences(of: "=", with: "")
        self.hostKeyAlias = "deskbridge-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Each element is one Process argument, never shell input.
    public func sshArguments(knownHostsFile: URL) -> [String] {
        let knownHosts = knownHostsFile.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "%", with: "%%")
        let options = [
            "BatchMode=yes", "IdentitiesOnly=yes", "AddKeysToAgent=no", "StrictHostKeyChecking=yes",
            "UserKnownHostsFile=\"\(knownHosts)\"", "GlobalKnownHostsFile=/dev/null",
            "HostKeyAlias=\(hostKeyAlias)", "HostKeyAlgorithms=ssh-ed25519", "UpdateHostKeys=no",
            "CheckHostIP=no", "ForwardAgent=no", "ClearAllForwardings=yes", "PermitLocalCommand=no",
            "PasswordAuthentication=no", "KbdInteractiveAuthentication=no", "PreferredAuthentications=publickey",
            "ConnectTimeout=10", "ConnectionAttempts=1", "ServerAliveInterval=15", "ServerAliveCountMax=2",
            "ControlMaster=no", "ControlPath=none", "ProxyCommand=none", "ProxyJump=none", "RequestTTY=no"
        ]
        return ["-F", "/dev/null", "-T"] + options.flatMap { ["-o", $0] } +
            ["-i", identityFile.path, "-p", String(port), "-l", username, "-s", "--", host, "sftp"]
    }
}

/// Payloads exclude the four-byte length prefix. Implementations must bound packets.
public protocol SFTPTransport: AnyObject, Sendable {
    func send(_ payload: Data) throws
    func receive() throws -> Data
    func cancel()
    func close()
}

final class SFTPSSHTransport: SFTPTransport, @unchecked Sendable {
    private let process: Process
    private let framer: SFTPPipeFramer
    private let diagnostics: SFTPSSHStderrDrain
    private let trustDirectory: URL
    private let stateLock = NSLock()
    private var closed = false
    private var receivedPacket = false

    init(configuration: SFTPConnectionConfiguration) throws {
        let fileManager = FileManager.default
        trustDirectory = fileManager.temporaryDirectory.appendingPathComponent("DeskBridgeSSH-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: trustDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let knownHosts = trustDirectory.appendingPathComponent("known_hosts")
        var pendingFramer: SFTPPipeFramer?
        var pendingDiagnostics: SFTPSSHStderrDrain?
        var pendingChildHandles: [FileHandle] = []
        do {
            let descriptor = Darwin.open(knownHosts.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw SFTPError.localIO("cannot create private host key pin") }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? file.close() }
            try file.write(contentsOf: Data("\(configuration.hostKeyAlias) \(configuration.pinnedHostPublicKey)\n".utf8))
            process = Process()
            let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
            pendingChildHandles = [stdinPipe.fileHandleForReading, stdoutPipe.fileHandleForWriting, stderrPipe.fileHandleForWriting]
            framer = try SFTPPipeFramer(input: stdinPipe.fileHandleForWriting, output: stdoutPipe.fileHandleForReading)
            pendingFramer = framer
            diagnostics = try SFTPSSHStderrDrain(input: stderrPipe.fileHandleForReading)
            pendingDiagnostics = diagnostics
            for handle in pendingChildHandles {
                let flags = fcntl(handle.fileDescriptor, F_GETFD)
                guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
                    throw SFTPError.localIO("cannot isolate SSH pipe descriptors")
                }
            }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = configuration.sshArguments(knownHostsFile: knownHosts)
            process.standardInput = stdinPipe; process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            var environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C", "SSH_ASKPASS_REQUIRE": "never"]
            if let agent = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"],
               !agent.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                environment["SSH_AUTH_SOCK"] = agent
            }
            process.environment = environment
            try process.run()
            for handle in pendingChildHandles { try? handle.close() }
        } catch {
            pendingFramer?.close()
            pendingDiagnostics?.close()
            for handle in pendingChildHandles { try? handle.close() }
            try? fileManager.removeItem(at: trustDirectory)
            throw error
        }
    }
    func send(_ payload: Data) throws {
        do { try framer.send(payload) }
        catch SFTPError.disconnected { throw startupDisconnect() }
    }
    func receive() throws -> Data {
        do {
            let payload = try framer.receive()
            stateLock.withLock { receivedPacket = true }
            return payload
        } catch SFTPError.disconnected { throw startupDisconnect() }
    }
    private func startupDisconnect() -> SFTPError {
        let state = stateLock.withLock { (closed, receivedPacket) }
        if state.0 { return .cancelled }
        guard !state.1 else { return .disconnected }
        diagnostics.waitForEOF(timeout: 1)
        if stateLock.withLock({ closed }) { return .cancelled }
        if let failure = diagnostics.failure { return .sshConnectionFailure(failure) }
        // Exit 255 alone is ambiguous. Unknown stderr and EOF retain a fixed,
        // explicit disconnected error rather than guessing an auth reason.
        return .disconnected
    }
    func cancel() {
        framer.cancel()
        stateLock.lock(); let shouldStop = !closed; closed = true; stateLock.unlock()
        if shouldStop, process.isRunning { process.terminate() }
    }
    func close() {
        cancel()
        framer.close()
        diagnostics.close()
        try? FileManager.default.removeItem(at: trustDirectory)
    }
    deinit { close() }
}
