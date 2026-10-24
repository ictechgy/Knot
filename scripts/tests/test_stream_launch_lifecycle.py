#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Execute actual launch/stop/error boundaries with fresh offline Swift fixtures.

The initial start phase is extracted unchanged as one complete do/catch/reset/check
block. Its launch leaf is inert and can return with an expired shared deadline.
NetworkClient.dataRequest, the stop/ownership methods and backend error methods are
complete production methods. Transport, media, telemetry and teardown leaves are
inert; this does not exercise real network, codecs, preferences, UI or host processes.
"""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / "Vendor/Glimmer/GlimmerEngine"


def block(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[start:end]


def make_fixture():
    names = {
        "start": "Session/StreamSession+Start.swift",
        "lifecycle": "Session/StreamSession+Lifecycle.swift",
        "attempt": "Session/StreamSession+Attempt.swift",
        "deadline": "Session/SessionDeadline.swift",
        "stream_attempt": "Network/StreamAttempt.swift",
        "connect": "Session/StreamSession+Connect.swift",
        "backend": "Session/NativeBackend.swift",
        "host": "Session/StreamHostDisposition.swift",
        "network": "Network/Network.swift",
        "request": "Network/NetworkClient+Request.swift",
        "endpoints": "Network/NetworkClient+Endpoints.swift",
        "types": "Models/Types.swift",
        "failure": "Models/StreamFailure.swift",
        "connection": "Session/StreamConnection.swift",
        "policy": "Protocol/StreamSecurityPolicy.swift",
        "rtsp": "Network/RtspClient.swift",
        "session": "Session/StreamSession.swift",
        "watchdog": "Session/StreamSession+FrameWatchdog.swift",
    }
    sources = {key: (ENGINE / name).read_text() for key, name in names.items()}
    start = block(sources["start"], "package func start(")
    begin = start.index("        let launch: LaunchResponse\n")
    end = start.index("        if publicMedia != nil", begin)
    initial = start[begin:end]
    assert initial.count("launch = try await launchWithDeadline(") == 1
    assert initial.rstrip().endswith("try checkAttempt()")
    # Only the two deadline-clear leaves gain an inert continuation gate. The
    # wrapper then calls the unchanged actual setter; all actor-local ordering,
    # catch/throw and attempt checks remain the complete extracted source block.
    assert initial.count("await network.setRequestDeadline(nil)") == 2
    gated_initial = initial.replace("await network.setRequestDeadline(nil)",
                                    "await network.setRequestDeadlineAtGate(nil)")
    consent_property = re.search(r"(?m)^    package var takeoverAuthorized = false$", sources["session"])[0]
    # Bind the refresh leaf to its actual /serverinfo caller without replacing TLS/endpoint policy.
    endpoint = block(sources["endpoints"], "public func fetchServerInfo(")
    assert 'rawRequest(path: "serverinfo"' in endpoint
    raw = block(sources["request"], "func rawRequest(")
    assert "try await dataRequest(path: path" in raw
    methods = {
        "initialLaunchBlock": initial,
        "stop": block(sources["lifecycle"], "package func stop(cause:"),
        "launchOwnership": block(sources["lifecycle"], "package func launchAndRecordOwnership("),
        "consumeLaunch": block(sources["lifecycle"], "private func consumeLaunch("),
        "settleLaunch": block(sources["lifecycle"], "package func settlePendingLaunch("),
        "retainsLaunchOwnership": block(sources["lifecycle"], "package static func retainsLaunchOwnership("),
        "launchPCKey": block(sources["lifecycle"], "private var launchPCKey:"),
        "checkAttempt": block(sources["attempt"], "package func checkAttempt("),
        "connectBackend": block(sources["connect"], "package func connectBackend("),
        "connectLegError": block(sources["connect"], "package static func connectLegError("),
        "mapToStreamError": block(sources["backend"], "static func mapToStreamError("),
        "rtspCode": block(sources["backend"], "static func rtspCode("),
        "setRequestDeadline": block(sources["network"], "package func setRequestDeadline("),
        "dataRequest": block(sources["request"], "func dataRequest("),
        "requestError": block(sources["request"], "static func requestError("),
        "codecMask": block(sources["request"], "package static func backendCodecModeMask("),
    }
    constants = "\n".join(re.findall(
        r"^    package static let (?:deadPeer|protectedContent|frameConversion|noVideoTraffic|noVideoFrame)TerminationCode[^\n]*",
        sources["session"] + "\n" + sources["watchdog"], re.M))
    assert len(constants.splitlines()) == 5
    contract = "\n".join([
        block(sources["types"], "public enum StreamError:"),
        "enum StreamFailureCopy { static func needsSunshineMessage(_ pc: String) -> String { pc } }",
        "public enum StreamConnection {\n" + block(sources["connection"], "public enum Failure:") + "\n}",
        block(sources["attempt"], "package struct TakeoverRequired:"),
        block(sources["network"], "package struct LaunchResponse:"),
        sources["failure"], sources["policy"], sources["host"], sources["deadline"], sources["stream_attempt"],
        block(sources["attempt"], "package actor SharedTeardown"),
        block(sources["attempt"], "package actor HostLaunchMutations"),
        block(sources["rtsp"], "enum RtspError:"),
    ])
    fixture = r'''
import Foundation
__CONTRACT__
struct CheckFailure: Error { let message: String }
struct SyntheticMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    enum Privacy { case `public`, `private` }
    init(stringLiteral value: String) {}
    init(stringInterpolation: StringInterpolation) {}
    struct StringInterpolation: StringInterpolationProtocol {
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ value: String) {}
        mutating func appendInterpolation<T>(_ value: T) {}
        mutating func appendInterpolation<T>(_ value: T, privacy: Privacy) {}
    }
}
struct SyntheticLog: Sendable {
    func debug(_ text: SyntheticMessage) {}
    func error(_ text: SyntheticMessage) {}
}
struct OSSignposter {
    static let network = SyntheticSignposter()
}
struct SyntheticSignposter: Sendable {
    func beginInterval(_ name: String, id: Int, _ message: SyntheticMessage) -> Int { 0 }
}
package struct ServerInfo: Sendable {
    var address = "synthetic.invalid", appVersion: String? = "synthetic", serverName = "synthetic"
    var serverCertPEM: String? = "SYNTHETIC_PIN", uniqueId = "synthetic-pc"
    var serverCodecModeRaw = 0
    var httpsPort: UInt16 = 47984, httpPort: UInt16 = 47989
}
struct StreamRequest: Sendable {}
package struct BackendStreamConfig: Sendable {}
struct BackendServerInfo: Sendable {
    let address: String, appVersion: String, rtspSessionUrl: String
    let serverCodecModeRaw: Int32
}
struct VideoDecoder: Sendable {}
struct AudioDecoder: Sendable {}
package struct SessionMedia: Sendable { let video = VideoDecoder() }
struct PublicInput: Sendable {}
struct NativeConnectionEvents: Sendable {
    init(bridge: SyntheticBridge?, backend: NativeBackend, feedback: Int?) {}
}
struct SessionFeedback {
    static func input(_ input: PublicInput, attempt: UUID) -> Int { 0 }
}
final class SyntheticBridge: Sendable {
    func setEventSource(_ backend: NativeBackend, attempt: UUID) {}
}
struct ControlTransport {
    struct TLSCredential: Sendable { let clientCertPEM: String?, clientKeyPEM: String?, pinnedCertPEM: String? }
    struct Response: Sendable { let status: Int; let body: Data }
}
enum AssetError: Error { case missing }
actor TransportLedger {
    private(set) var targets: [String] = []
    private(set) var cancellations = 0
    func send(_ target: String, paired: Bool, credential: ControlTransport.TLSCredential, timeout: TimeInterval) throws -> ControlTransport.Response {
        guard paired, credential.pinnedCertPEM == "SYNTHETIC_PIN", timeout > 0 else {
            throw CheckFailure(message: "inert refresh lost pin, pairing or fresh budget")
        }
        targets.append(target)
        return .init(status: 200, body: Data("synthetic-refresh".utf8))
    }
    func recordCancel() { cancellations += 1 }
}
package actor NetworkClient {
    typealias Transport = @Sendable (String, UInt16, String, String, Bool, ControlTransport.TLSCredential, TimeInterval) async throws -> ControlTransport.Response
    var server = ServerInfo(), requestDeadline: Date?
    let log = SyntheticLog(), ledger: TransportLedger
    var clientUniqueID: String? = "SYNTHETIC_ID", clientCertPEM: String?, clientKeyPEM: String?
    static let controlTimeout: TimeInterval = 5
    static let wireUniqueID = "SYNTHETIC_ID"
    let transport: Transport
    var deadlineClearGate: AsyncGate?
    init(_ ledger: TransportLedger) {
        self.ledger = ledger
        transport = { _, _, target, _, paired, credential, timeout in
            try await ledger.send(target, paired: paired, credential: credential, timeout: timeout)
        }
    }
    func ensureIdentityLoaded() async throws {}
    static func notPaired(_ pc: String) -> StreamError { .pairingFailed(pc) }
    static func requestNonce() -> String { "SYNTHETIC_NONCE" }
    func cancel() async throws { await ledger.recordCancel() }
    func holdDeadlineClear(_ gate: AsyncGate) { deadlineClearGate = gate }
    func setRequestDeadlineAtGate(_ deadline: Date?) async {
        if let gate = deadlineClearGate { try? await gate.wait() }
        setRequestDeadline(deadline)
    }
    __SET_DEADLINE__
    __DATA_REQUEST__
    __REQUEST_ERROR__
    __CODEC_MASK__
}
// Sticky continuation barriers preserve liveness without blocking a cooperative executor.
actor AsyncGate {
    private var entered = false, released = false, cancelled = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    private var work: CheckedContinuation<Void, Error>?
    func wait() async throws {
        entered = true
        let waiters = enteredWaiters; enteredWaiters = []; for waiter in waiters { waiter.resume() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancelled { continuation.resume(throwing: CancellationError()) }
                else if released { continuation.resume() }
                else { work = continuation }
            }
        } onCancel: { Task { await self.cancel() } }
    }
    func waitEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
    func waitCancelled() async {
        if cancelled { return }
        await withCheckedContinuation { cancelWaiters.append($0) }
    }
    func release() {
        released = true; let pending = work; work = nil; pending?.resume()
    }
    private func cancel() {
        cancelled = true; let pending = work; work = nil; pending?.resume(throwing: CancellationError())
        let waiters = cancelWaiters; cancelWaiters = []; for waiter in waiters { waiter.resume() }
    }
    var sawCancellation: Bool { cancelled }
}
actor Signal {
    private var arrived = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func arrive() { arrived = true; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
    func wait() async { if arrived { return }; await withCheckedContinuation { waiters.append($0) } }
}
protocol StreamingBackend: Sendable {
    func attachVideoSink(_ video: VideoDecoder)
    func attachAudioSink(_ audio: AudioDecoder)
    func startConnectionAsync(server: BackendServerInfo, config: BackendStreamConfig) async throws
}
final class NativeBackend: StreamingBackend, @unchecked Sendable {
    let failure: Error?
    init(_ failure: Error? = nil) { self.failure = failure }
    func attachVideoSink(_ video: VideoDecoder) {}
    func attachAudioSink(_ audio: AudioDecoder) {}
    func attachConnectionEvents(_ events: NativeConnectionEvents) {}
    func startConnectionAsync(server: BackendServerInfo, config: BackendStreamConfig) async throws {
        if let failure { throw failure }
    }
    __MAP_ERROR__
    __RTSP_CODE__
}
package enum DisconnectReason: Sendable { case userStopped, connectFailed, other }
enum InitialOutcome: Sendable { case success, failure, cancelled, stopAfterSuccess, suspended }
public actor StreamSession {
    __CONSTANTS__
    static let stopCancelSeconds: TimeInterval = 2
    static let launchMutations = HostLaunchMutations()
    let lifecycleNetwork: NetworkClient, stopEntered = Signal()
    let hostDisposition: StreamHostDisposition
    let initialOutcome: InitialOutcome, initialGate: AsyncGate?
    var publicInput: PublicInput?, publicTerminal = false
    var isStreaming = true, stopInProgress = false, waitingForVideo = true
    var stopCause: DisconnectReason?
__TAKEOVER_PROPERTY__
    var teardown = SharedTeardown()
    var initialServerInfoTask: Task<ServerInfo, Error>?
    var launchTask: Task<LaunchResponse, Error>?, pendingLaunch: Task<LaunchResponse, Error>?
    var mediaPreparation: Task<SessionMedia, Error>?
    var ownsHostSession = false, hostSessionClientID: String?, hostSessionAppID = 0, hostLaunchEpoch = 0
    var reconnectServer: ServerInfo? = ServerInfo()
    var backend: any StreamingBackend
    let audioDecoder = AudioDecoder(), log = SyntheticLog()
    var bridge: SyntheticBridge?, attemptID = UUID()
    var connectFlowState: Int?, connectFlowSignpostID = 0, telemetryServerName = ""
    init(network: NetworkClient, disposition: StreamHostDisposition = .disconnectOnly,
         outcome: InitialOutcome = .success, gate: AsyncGate? = nil, failure: Error? = nil) {
        lifecycleNetwork = network; hostDisposition = disposition
        initialOutcome = outcome; initialGate = gate; backend = NativeBackend(failure)
    }
    var isTearingDown: Bool { !isStreaming || stopInProgress }
    func stopPreparedPublicMedia() async { stopInProgress = false }
    func performStop(cause: DisconnectReason, pendingPreparation: Task<SessionMedia, Error>?) async {
        await stopEntered.arrive()
        let network = lifecycleNetwork
        await settlePendingLaunch { try? await network.cancel() }
        stopInProgress = false
    }
    func anchorTelemetryConnectStart(hostAddress: String) {}
    func noteTelemetryDisconnect(_ cause: DisconnectReason) {}
    func installOuterLaunch(_ task: Task<LaunchResponse, Error>) { launchTask = task }
    func pendingWasCancelled() -> Bool { pendingLaunch?.isCancelled ?? false }
    func authorizeTakeover() { takeoverAuthorized = true }
    func launchWithDeadline(network: NetworkClient, appID: Int, config: StreamRequest, info: ServerInfo) async throws -> LaunchResponse {
        // Inert launch leaf deliberately returns with an expired shared budget; no clock sleep/network.
        await network.setRequestDeadline(Date.distantPast)
        switch initialOutcome {
        case .failure: throw StreamError.hostRefused(message: "synthetic refusal", code: 503)
        case .cancelled: throw CancellationError()
        case .stopAfterSuccess: isStreaming = false
        case .suspended: try await initialGate!.wait()
        case .success: break
        }
        return syntheticLaunch()
    }
    func initialLaunch(network: NetworkClient) async throws -> LaunchResponse {
        let appID = 1, config = StreamRequest(), serverInfo = ServerInfo()
__INITIAL_BLOCK__
        return launch
    }
    __CHECK_ATTEMPT__
    __STOP__
    __LAUNCH_OWNERSHIP__
    __CONSUME_LAUNCH__
    __SETTLE_LAUNCH__
    __RETAINS_OWNERSHIP__
    __LAUNCH_PC_KEY__
    __CONNECT_BACKEND__
    __CONNECT_LEG_ERROR__
}
func syntheticLaunch() -> LaunchResponse {
    LaunchResponse(sessionURL: "rtspenc://synthetic.invalid", gcmKey: Data(repeating: 1, count: 16), gcmKeyId: Data(repeating: 2, count: 16))
}
@main struct Checks {
    static func main() async throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) throws {
            guard condition else { throw CheckFailure(message: message) }; checks += 1
        }
        for outcome: InitialOutcome in [.success, .failure, .cancelled, .stopAfterSuccess] {
            let ledger = TransportLedger(), client = NetworkClient(ledger)
            // Use the SAME client and its own inert transport after the initial phase.
            let session = StreamSession(network: client, outcome: outcome)
            var caught: Error?
            do { _ = try await session.initialLaunch(network: client) } catch { caught = error }
            switch outcome {
            case .success: try expect(caught == nil, "initial success unexpectedly threw")
            case .failure:
                if case .hostRefused(_, 503) = caught as? StreamError { try expect(true, "typed refusal") }
                else { throw CheckFailure(message: "launch failure lost its original diagnosis") }
            default: try expect(caught is CancellationError, "cancel/stop did not remain cancellation")
            }
            try expect(await client.requestDeadline == nil, "initial phase retained a shared launch budget")
            let body = try await client.dataRequest(path: "serverinfo", query: [:], usePaired: true, timeout: 0.5)
            try expect(body == Data("synthetic-refresh".utf8), "same client refresh inherited a stale launch deadline")
            try expect(await client.ledger.targets.count == 1, "fresh refresh did not reach its inert transport exactly once")
        }
        for outcome: InitialOutcome in [.success, .failure] {
            let ledger = TransportLedger(), client = NetworkClient(ledger), gate = AsyncGate()
            await client.holdDeadlineClear(gate)
            let session = StreamSession(network: client, outcome: outcome)
            await session.authorizeTakeover()
            let starting = Task { try await session.initialLaunch(network: client) }
            await gate.waitEntered()
            if outcome == .success {
                try expect(await session.takeoverAuthorized == false,
                           "successful launch yielded with stale takeover consent")
                await session.stop(cause: .userStopped)
                try expect(await session.takeoverAuthorized == false,
                           "stop during deadline clear retained consumed takeover consent")
            } else {
                try expect(await session.takeoverAuthorized,
                           "failed launch consumed takeover consent before retry")
            }
            await gate.release()
            if case .failure(let error) = await starting.result {
                if outcome == .success {
                    try expect(error is CancellationError, "held-clear stop lost cancellation")
                } else if case .hostRefused(_, 503) = error as? StreamError {
                    try expect(true, "held-clear launch failure preserved diagnosis")
                } else { throw CheckFailure(message: "held-clear failure lost host refusal") }
            } else { throw CheckFailure(message: "held-clear launch unexpectedly completed") }
            try expect(await session.takeoverAuthorized == (outcome == .failure),
                       "attempt exit changed one-shot takeover consent")
        }
        let cancelLedger = TransportLedger(), cancelClient = NetworkClient(cancelLedger), cancelGate = AsyncGate()
        let cancelledStart = StreamSession(network: cancelClient, outcome: .suspended, gate: cancelGate)
        let starting = Task { try await cancelledStart.initialLaunch(network: cancelClient) }
        await cancelGate.waitEntered(); starting.cancel()
        if case .failure(let error) = await starting.result {
            try expect(error is CancellationError, "actual caller cancellation lost its diagnosis")
        } else { throw CheckFailure(message: "cancelled initial launch returned success") }
        try expect(await cancelClient.requestDeadline == nil, "cancelled caller retained its shared request budget")
        _ = try await cancelClient.dataRequest(path: "serverinfo", query: [:], usePaired: true, timeout: 0.5)
        try expect(await cancelLedger.targets.count == 1, "post-cancel refresh failed to reuse the exact client")

        for disposition: StreamHostDisposition in [.disconnectOnly, .cancelOwnedHostSession] {
            let ledger = TransportLedger(), client = NetworkClient(ledger), gate = AsyncGate()
            let session = StreamSession(network: client, disposition: disposition)
            let outer = Task { try await session.launchAndRecordOwnership(client: "synthetic-client", appID: 1) {
                try await gate.wait(); return syntheticLaunch()
            } }
            await session.installOuterLaunch(outer)
            await gate.waitEntered()
            let stopping = Task { await session.stop(cause: .userStopped) }
            await session.stopEntered.wait()
            if disposition.cancellation == nil {
                let observed = await SessionDeadline.runBounded(seconds: 0.5) { await gate.waitCancelled() }
                await gate.release(); await stopping.value
                let innerCancelled = await gate.sawCancellation
                try expect(observed && innerCancelled, "disconnect-only stop cancelled its outer waiter but left inner HTTP work running")
                try expect(await ledger.cancellations == 0, "disconnect-only stop acquired host cancellation")
            } else {
                try expect(!(await gate.sawCancellation), "owned-host cleanup prematurely cancelled its pending late reply")
                await gate.release(); await stopping.value
                try expect(await ledger.cancellations == 1, "owned-host cleanup lost its bounded late-success cancellation capability")
            }
            _ = await outer.result
            let stillStreaming = await session.isStreaming, stillStopping = await session.stopInProgress
            try expect(!stillStreaming && !stillStopping, "stop did not join its inert local teardown")
        }
        let policyFailures: [StreamSecurityPolicy.Failure] = [StreamSecurityPolicy.Failure.plaintextSignalling,
                                       StreamSecurityPolicy.Failure.missingEncryption(3)]
        for failure in policyFailures {
            let mapped = NativeBackend.mapToStreamError(failure)
            guard case .securityNegotiation(let preserved) = mapped, preserved == failure else {
                throw CheckFailure(message: "backend flattened the typed security negotiation failure")
            }
            try expect(StreamFailure.connection(mapped) == .security, "mandatory encryption failure was presented as a generic stream exit")
        }
        let typed: [(Error, StreamFailure.ConnectionReason)] = [
            (NativeBackend.mapToStreamError(StreamSecurityPolicy.Failure.plaintextSignalling), .security),
            (NativeBackend.mapToStreamError(RtspError.connectTimeout(48010)), .portsBlocked(proto: "TCP", port: 48010)),
            (NativeBackend.mapToStreamError(RtspError.responseTimeout(3)), .unreachable),
            (StreamError.hostTimedOut, .hostTimedOut), (StreamError.decoderFailed("synthetic"), .decoderFailed),
        ]
        for (failure, reason) in typed {
            let ledger = TransportLedger(), client = NetworkClient(ledger)
            let session = StreamSession(network: client, failure: failure)
            var caught: Error?
            do { try await session.connectBackend(serverInfo: ServerInfo(), launch: syntheticLaunch(),
                backendConfig: BackendStreamConfig(), setup: SessionMedia(), network: client, duringReconnect: true) }
            catch { caught = error }
            try expect(caught.map(StreamFailure.connection) == reason, "actual reconnect catch flattened a typed backend diagnosis")
            try expect(await ledger.cancellations == 0, "typed reconnect failure violated disconnect-only host disposition")
        }
        let untypedClient = NetworkClient(TransportLedger())
        let untyped = StreamSession(network: untypedClient, failure: CheckFailure(message: "synthetic untyped"))
        do {
            try await untyped.connectBackend(serverInfo: ServerInfo(), launch: syntheticLaunch(), backendConfig: BackendStreamConfig(),
                setup: SessionMedia(), network: untypedClient, duringReconnect: true)
            throw CheckFailure(message: "untyped backend failure returned success")
        } catch let failure as StreamError {
            if case .sessionFailed(-1) = failure { try expect(true, "untyped fallback") }
            else { throw CheckFailure(message: "untyped failure invented a typed diagnosis") }
        }
        try expect(StreamSession.connectLegError(StreamError.crypto("synthetic"), stoppedBy: .userStopped) is CancellationError,
                   "user-stopped initial connection became a security error")
        try expect(StreamFailure.connection(StreamSession.connectLegError(StreamError.crypto("synthetic"), stoppedBy: nil)) == .security,
                   "initial non-user failure lost typed security guidance")
        print("{\"status\":\"passed\",\"streamLaunchLifecycleChecks\":\(checks),\"scope\":\"actual launch block, request, stop/ownership, backend mapping and connect methods; inert network/media/teardown/telemetry\"}")
    }
}
'''
    replacements = {
        "__CONTRACT__": contract, "__CONSTANTS__": constants,
        "__INITIAL_BLOCK__": gated_initial, "__TAKEOVER_PROPERTY__": consent_property,
        "__SET_DEADLINE__": methods["setRequestDeadline"], "__DATA_REQUEST__": methods["dataRequest"],
        "__REQUEST_ERROR__": methods["requestError"], "__CODEC_MASK__": methods["codecMask"],
        "__CHECK_ATTEMPT__": methods["checkAttempt"], "__STOP__": methods["stop"],
        "__LAUNCH_OWNERSHIP__": methods["launchOwnership"], "__CONSUME_LAUNCH__": methods["consumeLaunch"],
        "__SETTLE_LAUNCH__": methods["settleLaunch"], "__RETAINS_OWNERSHIP__": methods["retainsLaunchOwnership"],
        "__LAUNCH_PC_KEY__": methods["launchPCKey"], "__CONNECT_BACKEND__": methods["connectBackend"],
        "__CONNECT_LEG_ERROR__": methods["connectLegError"], "__MAP_ERROR__": methods["mapToStreamError"],
        "__RTSP_CODE__": methods["rtspCode"],
    }
    for marker, value in replacements.items():
        fixture = fixture.replace(marker, value)
    assert not re.search(r"__[A-Z_]+__", fixture)
    binding = {
        "sourceSHA256": {str((ENGINE / names[key]).relative_to(ROOT)): hashlib.sha256(value.encode()).hexdigest()
                         for key, value in sources.items()},
        "extractedSHA256": {key: hashlib.sha256(value.encode()).hexdigest() for key, value in methods.items()},
        "fixtureSHA256": hashlib.sha256(fixture.encode()).hexdigest(),
        "deadlineClearLeafAdaptations": 2,
        "scope": "source-extracted synthetic regression; initial launch leaf and all transport/media/teardown leaves inert; not native/device acceptance",
    }
    return fixture, binding


def main():
    fixture, binding = make_fixture()
    with tempfile.TemporaryDirectory(prefix="knot-stream-launch-lifecycle-", dir="/tmp") as directory:
        temporary = Path(directory)
        source = temporary / "Checks.swift"
        source.write_text(fixture)
        executable = temporary / "checks"
        compile_argv = ["/usr/bin/swiftc", "-swift-version", "6", "-package-name", "Glimmer",
                        "-parse-as-library", "-O", "-module-cache-path", str(temporary / "module-cache"),
                        str(source), "-o", str(executable)]
        for argv, timeout in [(compile_argv, 90), ([str(executable)], 20)]:
            result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
            print(json.dumps({"argv": argv, "exitCode": result.returncode,
                              "stdout": result.stdout, "stderr": result.stderr}))
            result.check_returncode()
        print(json.dumps(binding))


if __name__ == "__main__":
    main()
