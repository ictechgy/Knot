#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Exercise exact decoder lifecycle/latch and shell state with inert codec dependencies."""
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
    depth = 1
    end = opening + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[start:end]


lifecycle = (ENGINE / "Video/VideoDecoder+Decode.swift").read_text()
output = (ENGINE / "Video/VideoDecoder+Session.swift").read_text()
presentation = (ROOT / "Sources/DeskBridgeApp/Streaming/DesktopRecoveryPresentation.swift").read_text()
types = (ENGINE / "Models/Types.swift").read_text()
failure = (ENGINE / "Models/StreamFailure.swift").read_text()
failure_copy = (ENGINE / "Models/StreamFailureCopy.swift").read_text()
connection = (ENGINE / "Session/StreamConnection.swift").read_text()
takeover = (ENGINE / "Session/StreamSession+Attempt.swift").read_text()
constants = "\n".join(re.findall(r"^    package static let (?:deadPeer|protectedContent|frameConversion|noVideoTraffic|noVideoFrame)TerminationCode[^\n]*",
    (ENGINE / "Session/StreamSession.swift").read_text() + "\n" +
    (ENGINE / "Session/StreamSession+FrameWatchdog.swift").read_text(), re.M))
assert len(constants.splitlines()) == 5
model_contract = "\n".join([
    (ENGINE / "Protocol/StreamSecurityPolicy.swift").read_text(),
    (ROOT / "Sources/DeskBridgeApp/DesktopSecurityGuidance.swift").read_text().replace("import GlimmerEngine\n", ""),
    block(types, "public enum StreamEvent:"), block(types, "public enum ConnectionQuality:"),
    block(types, "public enum StreamError:"), failure, failure_copy,
    "enum StreamSession {\n" + constants + "\n}",
    "public enum StreamConnection {\n" + block(connection, "public enum Failure:") + "\n}",
    block(takeover, "package struct TakeoverRequired:"),
    "public enum StreamInput { public enum Event: Sendable {} }",
])
methods = "\n".join(block(lifecycle, "nonisolated func " + name + "()")
                    for name in ("handleStart", "handleStop", "handleCleanup"))
gate = block(output, "if !decoder.didFireFirstDecodedFrame")
fixture = r'''
import Foundation
import Synchronization

// No VT session, native backend, display, socket, preferences or media exists.
struct SilentLog: Sendable { func info(_ value: String) {} }
let log = SilentLog()
func VTDecompressionSessionInvalidate(_ session: Int) {}
final class Stats: @unchecked Sendable { func resetForConnection() {} }
__ACTUAL_MODEL_CONTRACT__
final class VideoDecoder: @unchecked Sendable {
    var isStreaming = false
    var didFireFirstDecodedFrame = false
    let firstFrameLifecycleGeneration = Atomic<UInt64>(0)
    let decodeQueue = DispatchQueue(label: "synthetic.decoder.lifecycle")
    let statsCollector = Stats()
    var decompressionSession: Int? = 1
    var formatDescription: Int?, cachedHDRFormatDescription: Int?
    var spsData: Data?, ppsData: Data?, vpsData: Data?
    let inFlightDecodeLock = NSLock()
    var inFlightDecodes = 3
    var lastVtDecodeFailed = true
    var schedules = 0
    var onFirstDecodedFrame: (() -> Void)?
    @MainActor func configureLayerColorspace() {}
    func reapplySuppressionAtConnect() {}
    func clearDecodeGateForConnectionStop() {}
    func releaseOutputCallbackRefcon() {}
    static func noteFirstDecodedFrameTelemetry() {}
    func scheduleFirstDecodedFrame() { schedules += 1; onFirstDecodedFrame?() }
    func syntheticDecodedFrame() {
        guard isStreaming else { return }
        let decoder = self
        __ACTUAL_FIRST_FRAME_GATE__
    }
    __ACTUAL_LIFECYCLE_METHODS__
}
__ACTUAL_PRESENTATION__
@main struct Checks {
    @MainActor static func main() throws {
        var checks = 0
        func expect(_ value: Bool) throws {
            guard value else { throw NSError(domain: "synthetic first-frame lifecycle", code: checks) }
            checks += 1
        }
        let decoder = VideoDecoder()
        var state = DesktopRecoveryPresentation()
        decoder.onFirstDecodedFrame = { state.receive(.firstFrame) }
        for attempt in 1...3 {
            decoder.handleStart()
            try expect(decoder.isStreaming && !decoder.didFireFirstDecodedFrame)
            if attempt > 1 {
                state.receive(.reconnected)
                try expect(state.phase == .waiting)
            }
            decoder.syntheticDecodedFrame(); decoder.syntheticDecodedFrame()
            try expect(decoder.schedules == attempt)
            try expect(state.phase == .live && state.message == nil)
            decoder.handleStop(); decoder.handleCleanup()
            try expect(!decoder.isStreaming && decoder.inFlightDecodes == 0 && !decoder.lastVtDecodeFailed)
            try expect(decoder.firstFrameLifecycleGeneration.load(ordering: .acquiring) == UInt64(attempt))
            if attempt < 3 { state.receive(.reconnecting) }
        }
        print("{\"status\":\"passed\",\"videoFrameLifecycleChecks\":\(checks),\"firstFrameSchedules\":\(decoder.schedules),\"scope\":\"exact production lifecycle methods, first-frame latch and shell state; inert codec/platform; no VT/native/UI/network\"}")
    }
}
'''
fixture = fixture.replace("__ACTUAL_FIRST_FRAME_GATE__", gate).replace("__ACTUAL_LIFECYCLE_METHODS__", methods)
fixture = fixture.replace("__ACTUAL_MODEL_CONTRACT__", model_contract)
fixture = fixture.replace("__ACTUAL_PRESENTATION__", presentation.replace("import GlimmerEngine\n", ""))

# Exercise the receive-thread consumer and actor timeout, not a parallel model
# of their decisions. Codec/backlog/presentation dependencies are inert fakes;
# the gate, epoch commit, drop consumer, and watchdog methods are production bodies.
suppression = (ENGINE / "Video/VideoDecoder+Suppression.swift").read_text()
backlog = (ENGINE / "Video/VideoDecoder+Backlog.swift").read_text()
watchdog = (ENGINE / "Session/StreamSession+FrameWatchdog.swift").read_text()
recovery_methods = "\n".join([
    block(suppression, "enum DecodeGateDisposition:"),
    block(suppression, "nonisolated func decodeGateDisposition(isIDR: Bool)"),
    block(suppression, "nonisolated func commitReservedDecode(isIDR: Bool)"),
    block(suppression, "private nonisolated func decodeGateDisposition("),
    block(suppression, "nonisolated func gateAfterHiddenReferenceDrop()"),
    block(suppression, "nonisolated func armResyncAfterDecodeError(epoch: UInt)"),
    block(suppression, "private func liftDecodeGate()"),
    block(lifecycle, "struct PendingDecode"),
    block(lifecycle, "nonisolated func decodeAssembledFrame("),
    block(backlog, "nonisolated func reserveDecodeSlot(isIDR: Bool)").replace(
        "func reserveDecodeSlot(", "func productionReserveDecodeSlot(", 1),
    block(backlog, "nonisolated func releaseInFlightDecode("),
    block(output, "nonisolated func tearDownDecompressionSession()"),
])
watchdog_methods = "\n".join([
    block(watchdog, "package static func watchdogTerminationCode("),
    block(watchdog, "package static func watchdogDecodeIdle("),
    block(watchdog, "package static func watchdogFailedDecodeReconnect("),
    block(watchdog, "private func handleWatchdogTimeout("),
])
recovery_fixture = r'''
import Foundation
import os

// No VideoToolbox, display, preferences, live media, socket, or real backend.
struct QuietLog: Sendable { func notice(_ value: String) {} }
enum OSSignposter {
    static let decode = os.OSSignposter(logger: Logger(subsystem: "org.deskbridge.synthetic", category: "inert-decoder"))
}
enum Diag {
    static func notice(_ value: String, _ context: String) {}
    static func error(_ value: String, _ context: String) {}
}
func now() -> UInt64 { 1_000_000_000 }
final class Counter: @unchecked Sendable { var value = 0; func increment() { value += 1 } }
final class TelemetryCounters: @unchecked Sendable {
    static let shared = TelemetryCounters()
    let decodeGatedDropTotal = Counter(), backlogOverflowTotal = Counter()
    var gated = false
    func setDecodeGated(_ value: Bool) { gated = value }
}
enum StreamProtocol { static let DR_OK: Int32 = 0, DR_NEED_IDR: Int32 = -1 }
final class Pacer: @unchecked Sendable {
    var retained = 2
    var clears: [String] = []
    @discardableResult func clearQueue(reason: String) -> Int {
        let count = retained; retained = 0; clears.append(reason); return count
    }
}
final class DecodeStats: @unchecked Sendable {
    var discards = 0
    func recordDecoderDiscard() { discards += 1 }
    func dropPendingDecodeSubmits() {}
}
final class VideoDecoder: @unchecked Sendable {
    enum DecodeSlotDecision { case reserved, reservedForStallRecreate, dropAndFlush }
    let presentSuppressedLock = NSLock()
    var isStreaming = true, _presentSuppressed = false, _decodeGated = false, _awaitingResyncIdr = false
    var _idrEpoch: UInt = 0
    var _decodeGateLiftedAtNanos: UInt64?
    let framePacer: Pacer? = Pacer()
    let statsCollector = DecodeStats()
    let log = Logger(subsystem: "org.deskbridge.synthetic", category: "inert-decoder")
    let decodeQueue = DispatchQueue(label: "synthetic.reference-drop")
    var decision = DecodeSlotDecision.reserved
    var beforeReserve: (() -> Void)?
    let inFlightDecodeLock = NSLock()
    var inFlightDecodes = 0, consecutiveBacklogOverflow = 0
    var lastVtDecodeFailed = false, useProductionReservation = false
    let maxInFlightDecodes = 3, maxInFlightDecodeCeiling = 6
    static let decodeStallEscalateSeconds = 10.0, decodeStallWindowSeconds = 1.0
    var slots: Int { get { inFlightDecodes } set { inFlightDecodes = newValue } }
    var reservations = 0
    var decompressionSession: Int? = 1
    var sessionEvents: [String] = []
    func releaseOutputCallbackRefcon() { sessionEvents.append("retired") }
    var submitted: [PendingDecode] = []
    var decodedIdle = Double.infinity, gateLiftIdle = Double.infinity, receiveIdle = 0.1
    var presentSuppressed: Bool { _presentSuppressed }
    var decodeGated: Bool { _decodeGated }
    func secondsSinceLastDecodedFrame() -> Double { decodedIdle }
    func secondsSinceDecodeGateLifted() -> Double { gateLiftIdle }
    func secondsSinceLastReceivedFrame() -> Double { receiveIdle }
    func reserveDecodeSlot(isIDR: Bool) -> DecodeSlotDecision {
        reservations += 1
        let result = useProductionReservation ? productionReserveDecodeSlot(isIDR: isIDR) : decision
        if !useProductionReservation && result != .dropAndFlush { slots += 1 }
        beforeReserve?()
        return result
    }
    func runDecodeOnQueue(_ pending: PendingDecode) {
        sessionEvents.append(decompressionSession == nil ? "fresh-decode" : "old-decode")
        if decompressionSession == nil { decompressionSession = 2 }
        submitted.append(pending); releaseInFlightDecode()
    }
    func submit(idr: Bool = false) -> Int32 {
        decodeAssembledFrame(pictureData: Data([0]), newSps: nil, newPps: nil, newVps: nil,
            isIDR: idr, rtpTimestamp: 1, totalLength: 1)
    }
    @MainActor func resume() {
        presentSuppressedLock.lock(); _presentSuppressed = false; presentSuppressedLock.unlock()
        _ = liftDecodeGate()
    }
    __ACTUAL_REFERENCE_RECOVERY_METHODS__
}
enum DisconnectCause: String { case watchdogStall }
enum Update { case connectionTerminated(errorCode: Int32) }
final class Trace: @unchecked Sendable { var events: [String] = [] }
final class Bridge: @unchecked Sendable {
    let trace: Trace
    init(_ trace: Trace) { self.trace = trace }
    func emit(_ update: Update) {
        switch update { case .connectionTerminated(let code): trace.events.append("event:\(code)") }
    }
}
struct Health: Sendable { let sinceLastAckMs: UInt32 }
struct Backend: Sendable { func enetHealth() -> Health? { Health(sinceLastAckMs: 50) } }
actor StreamSession {
    static let noVideoTrafficTerminationCode: Int32 = -100, noVideoFrameTerminationCode: Int32 = -101
    static let deadPeerTerminationCode: Int32 = -1
    static let decodeOnlyStallThreshold = 3.0, decodeOnlyReconnectSeconds = 30.0, frameWatchdogTimeout = 10.0
    static let enetAliveHoldThresholdMs: UInt32 = 5_000
    nonisolated(unsafe) var frameWatchdogArmedAt = 100.0
    var uptimeSeconds = 140.0
    var isStreaming = true, stopInProgress = false, isReconnecting = false, didReconnectForDecodeStall = true
    var videoDecoder: VideoDecoder?
    let backend = Backend()
    let log = Logger(subsystem: "org.deskbridge.synthetic", category: "inert-watchdog")
    let trace = Trace()
    var bridge: Bridge?
    var holds = 0
    init(_ decoder: VideoDecoder) { videoDecoder = decoder; bridge = Bridge(trace) }
    func noteTelemetryDisconnect(_ cause: DisconnectCause) { trace.events.append("cause:\(cause.rawValue)") }
    func stop() async { trace.events.append("stop"); isStreaming = false }
    func holdForAliveLink(decodeIdle: Double, receiveIdle: Double, ackMs: UInt32) async { holds += 1 }
    func tick(_ decoder: VideoDecoder, arm: Double = 100) async {
        await handleWatchdogTimeout(decoder: decoder, armedAt: arm)
    }
    func configure(arm: Double = 100, uptime: Double = 140, reconnected: Bool = true, reconnecting: Bool = false) {
        frameWatchdogArmedAt = arm; uptimeSeconds = uptime
        didReconnectForDecodeStall = reconnected; isReconnecting = reconnecting
    }
    func result() -> ([String], Int) { (trace.events, holds) }
    __ACTUAL_WATCHDOG_METHODS__
}
@main struct Checks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: Bool, _ context: String) throws {
            guard value else { throw NSError(domain: context, code: checks) }; checks += 1
        }
        let brief = VideoDecoder(); brief._presentSuppressed = true
        try expect(brief.submit() == StreamProtocol.DR_OK, "brief hide should keep decoding")
        brief.decodeQueue.sync {}
        try expect(!brief._decodeGated && brief.framePacer?.retained == 2 && brief.submitted.count == 1,
                   "ordinary brief hide must retain its newest frame")

        let hidden = VideoDecoder(); hidden._presentSuppressed = true; hidden.decision = .dropAndFlush
        try expect(hidden.submit() == StreamProtocol.DR_OK, "hidden overflow must not request wire IDR")
        try expect(hidden._decodeGated && hidden._awaitingResyncIdr && hidden._idrEpoch == 0,
                   "hidden reference drop must latch gate and resync without committing an epoch")
        try expect(hidden.framePacer?.retained == 0 && hidden.framePacer?.clears == ["hidden_reference_drop"],
                   "broken-reference retained frame must not repaint")
        let reservations = hidden.reservations, gatedDrops = TelemetryCounters.shared.decodeGatedDropTotal.value
        try expect(hidden.submit() == StreamProtocol.DR_OK && hidden.reservations == reservations,
                   "following hidden P frame must be dropped before reserving")
        try expect(TelemetryCounters.shared.decodeGatedDropTotal.value == gatedDrops + 1,
                   "one gated frame must be counted once")
        hidden.resume(); hidden.decision = .reserved
        try expect(hidden.submit() == StreamProtocol.DR_NEED_IDR && hidden.reservations == reservations,
                   "first post-drop P frame must transfer wait-for-IDR without reservation")
        try expect(hidden.submit(idr: true) == StreamProtocol.DR_OK, "resync IDR should feed")
        hidden.decodeQueue.sync {}
        try expect(hidden._idrEpoch == 1 && hidden.submitted.last?.epoch == 1 && hidden.slots == 0,
                   "accepted IDR must commit its epoch into PendingDecode and balance slots")

        for suppressed in [false, true] {
            let droppedIdr = VideoDecoder(); droppedIdr._presentSuppressed = suppressed; droppedIdr.decision = .dropAndFlush
            try expect(droppedIdr.submit(idr: true) == (suppressed ? StreamProtocol.DR_OK : StreamProtocol.DR_NEED_IDR),
                       "dropped IDR must respect visibility recovery owner")
            try expect(droppedIdr._idrEpoch == 0, "dropped IDR must not make prior VT failures stale")
            if !suppressed {
                try expect(droppedIdr.armResyncAfterDecodeError(epoch: 0), "current epoch failure must remain current after IDR drop")
            }
        }
        let observed = VideoDecoder(); observed._awaitingResyncIdr = true
        try expect(observed.decodeGateDisposition(isIDR: true) == .feed(epoch: 0) &&
                   observed._idrEpoch == 0 && observed._awaitingResyncIdr,
                   "IDR observation must not commit before reservation")
        try expect(observed.submit(idr: true) == StreamProtocol.DR_OK, "reserved IDR should clear obligation")
        observed.decodeQueue.sync {}
        try expect(observed._idrEpoch == 1 && !observed._awaitingResyncIdr && !observed.armResyncAfterDecodeError(epoch: 0),
                   "only accepted IDR makes old failure stale")

        for stop in [false, true] {
            let raced = VideoDecoder(); raced._presentSuppressed = true; raced.decision = .dropAndFlush
            raced.beforeReserve = { if stop { raced.isStreaming = false } else { raced._presentSuppressed = false } }
            try expect(raced.submit() == StreamProtocol.DR_NEED_IDR && !raced._decodeGated && !raced._awaitingResyncIdr,
                       "racing resume or stop must prevent a stale hidden gate")
        }
        let gatedDuringReserve = VideoDecoder()
        gatedDuringReserve.beforeReserve = { gatedDuringReserve._decodeGated = true; gatedDuringReserve._awaitingResyncIdr = true }
        let beforeGateDrops = TelemetryCounters.shared.decodeGatedDropTotal.value
        try expect(gatedDuringReserve.submit(idr: true) == StreamProtocol.DR_OK && gatedDuringReserve.slots == 0 &&
                   gatedDuringReserve._idrEpoch == 0 && gatedDuringReserve._awaitingResyncIdr,
                   "gate racing slot reservation must release slot without committing IDR")
        try expect(TelemetryCounters.shared.decodeGatedDropTotal.value == beforeGateDrops + 1,
                   "commit-time gate refusal must count only this one drop")
        let gatedStall = VideoDecoder()
        gatedStall.useProductionReservation = true
        gatedStall.inFlightDecodes = gatedStall.maxInFlightDecodes
        gatedStall.lastVtDecodeFailed = true
        gatedStall.beforeReserve = { gatedStall._decodeGated = true; gatedStall._awaitingResyncIdr = true }
        // Hold the serial queue so resume and its IDR arrive before teardown runs.
        let releaseQueue = DispatchSemaphore(value: 0)
        gatedStall.decodeQueue.async { releaseQueue.wait() }
        try expect(gatedStall.submit(idr: true) == StreamProtocol.DR_OK && gatedStall.slots == 0 &&
                   !gatedStall.lastVtDecodeFailed && gatedStall._idrEpoch == 0 && gatedStall.submitted.isEmpty,
                   "stall reservation refused by gate must balance its abandoned backlog without hidden IDR")
        gatedStall.beforeReserve = nil
        gatedStall.resume(); gatedStall.gateLiftIdle = 0
        try expect(gatedStall.submit(idr: true) == StreamProtocol.DR_OK,
                   "resumed IDR must reserve normally after gate-lift resets darkness")
        releaseQueue.signal(); gatedStall.decodeQueue.sync {}
        try expect(gatedStall.sessionEvents == ["retired", "fresh-decode"] &&
                   gatedStall.submitted.count == 1 && gatedStall.submitted[0].isIDR &&
                   !gatedStall.submitted[0].forceSessionRecreate && gatedStall.slots == 0 && gatedStall._idrEpoch == 1,
                   "refused stall IDR must retire wedged session before fresh resumed decode, with balanced reservations")
        let failedDuringReserve = VideoDecoder()
        failedDuringReserve.beforeReserve = { _ = failedDuringReserve.armResyncAfterDecodeError(epoch: 0) }
        try expect(failedDuringReserve.submit() == StreamProtocol.DR_NEED_IDR && failedDuringReserve.slots == 0,
                   "VT failure racing slot reservation must release slot and transfer resync")

        func giveUp(reconnected: Bool = true, hidden: Bool = false, gated: Bool = false,
                    decoded: Double = .infinity, lift: Double = .infinity, arm: Double = 40, received: Double = 0.1) -> Bool {
            StreamSession.watchdogFailedDecodeReconnect(didReconnect: reconnected, presentSuppressed: hidden, decodeGated: gated,
                sinceDecoded: decoded, sinceGateLift: lift, sinceArm: arm, receiveIdle: received)
        }
        try expect(giveUp(), "post-reconnect zero output must be bounded")
        try expect(giveUp(decoded: 120) && giveUp(lift: 30, arm: 100), "old output and elapsed visible allowance must count")
        for refusal in [giveUp(reconnected: false), giveUp(hidden: true), giveUp(gated: true), giveUp(decoded: 20),
                        giveUp(decoded: 40), giveUp(lift: 29.999, arm: 100), giveUp(arm: 29.999), giveUp(received: 3)] {
            try expect(!refusal, "healthy/paused/hidden/gated/current-output state must not give up")
        }

        for decoded in [Double.infinity, 120] {
            let dec = VideoDecoder(); dec.decodedIdle = decoded; dec.gateLiftIdle = 35
            let session = StreamSession(dec); await session.tick(dec)
            let (events, holds) = await session.result()
            try expect(events == ["cause:watchdogStall", "event:-101", "stop"] && holds == 0,
                       "actual timeout consumer must emit no-video-frame with watchdog cause before stop")
        }
        for state in 0..<8 {
            let dec = VideoDecoder(); dec.gateLiftIdle = 35
            let session = StreamSession(dec)
            switch state {
            case 0: dec._presentSuppressed = true
            case 1: dec._decodeGated = true
            case 2: dec.receiveIdle = 5
            case 3: dec.decodedIdle = 20 // An output on this arm; later idle is permitted.
            case 4: dec.gateLiftIdle = 5 // A long hidden span gets a fresh visible allowance.
            case 5: await session.configure(reconnected: false)
            case 6: dec.gateLiftIdle = 25; await session.configure(uptime: 129) // Below new visible recovery budget.
            default: await session.configure(reconnecting: true)
            }
            await session.tick(dec)
            try expect((await session.result()).0.isEmpty, "timeout must preserve supported waiting state \(state)")
        }
        let stale = VideoDecoder(); stale.gateLiftIdle = 35
        let rearmed = StreamSession(stale); await rearmed.configure(arm: 200, uptime: 240)
        await rearmed.tick(stale, arm: 100)
        try expect((await rearmed.result()).0.isEmpty, "old queued arm must not terminate a new attempt")
        let replacement = StreamSession(VideoDecoder()); await replacement.tick(stale)
        try expect((await replacement.result()).0.isEmpty, "old decoder identity must not terminate a replacement")
        let recovered = VideoDecoder(); recovered.gateLiftIdle = 35; recovered.decodedIdle = 0.1
        let recoveredSession = StreamSession(recovered); await recoveredSession.tick(recovered)
        try expect((await recoveredSession.result()).0.isEmpty, "queued timeout must re-read actual decode progress")
        for (received, code) in [(0.1, "-101"), (Double.infinity, "-100")] {
            let fresh = VideoDecoder(); fresh.receiveIdle = received
            let initial = StreamSession(fresh); await initial.configure(uptime: 111, reconnected: false)
            await initial.tick(fresh)
            try expect((await initial.result()).0 == ["cause:watchdogStall", "event:" + code, "stop"],
                       "ordinary first-frame timeout must retain its existing failure category")
        }
        print("{\"status\":\"passed\",\"mediaRecoveryChecks\":\(checks),\"scope\":\"exact production gate/epoch/drop consumer and timeout methods; inert codec/platform; no VT/native/UI/network\"}")
    }
}
'''
recovery_fixture = recovery_fixture.replace("__ACTUAL_REFERENCE_RECOVERY_METHODS__", recovery_methods)
recovery_fixture = recovery_fixture.replace("import os\n", "import os\nfunc VTDecompressionSessionInvalidate(_ session: Int) {}\n", 1)
recovery_fixture = recovery_fixture.replace("__ACTUAL_WATCHDOG_METHODS__", watchdog_methods)
with tempfile.TemporaryDirectory(prefix="deskbridge-decoder-lifecycle-", dir="/tmp") as directory:
    temporary = Path(directory)
    source = temporary / "Checks.swift"
    source.write_text(fixture)
    executable = temporary / "checks"
    subprocess.run(["/usr/bin/swiftc", "-swift-version", "6", "-package-name", "Glimmer", "-parse-as-library", "-O",
                    "-module-cache-path", str(temporary / "module-cache"), str(source), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
    print(json.dumps({"fixtureSHA256": hashlib.sha256(fixture.encode()).hexdigest(),
                      "scope": "source-extracted regression, not device or video acceptance"}))
    recovery_source = temporary / "RecoveryChecks.swift"
    recovery_source.write_text(recovery_fixture)
    recovery_executable = temporary / "recovery-checks"
    subprocess.run(["/usr/bin/swiftc", "-swift-version", "6", "-package-name", "Glimmer", "-parse-as-library", "-O",
                    "-module-cache-path", str(temporary / "module-cache"), str(recovery_source), "-o", str(recovery_executable)], check=True)
    subprocess.run([str(recovery_executable)], check=True)
    print(json.dumps({"recoveryFixtureSHA256": hashlib.sha256(recovery_fixture.encode()).hexdigest(),
                      "scope": "source-extracted recovery regression, not device or video acceptance"}))
