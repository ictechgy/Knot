#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Actual shell notice/power methods with inert media, view and activity tokens.

Runs no AppKit window, real power activity, network, codec or user preferences.
The production eight-second notice timer runs unchanged.
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
    depth = 1
    end = opening + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[start:end]


paths = {
    "start": ENGINE / "Session/StreamSession+Start.swift",
    "public": ENGINE / "Session/StreamSession+Public.swift",
    "controller": ROOT / "Sources/DeskBridgeApp/Streaming/DesktopStreamController.swift",
    "presentation": ROOT / "Sources/DeskBridgeApp/Streaming/DesktopRecoveryPresentation.swift",
    "checks": ROOT / "Sources/DeskBridgeAppChecks/DesktopRecoveryChecks.swift",
    "activity": ROOT / "Sources/DeskBridgeCore/DesktopStreamActivity.swift",
}
sources = {key: value.read_text() for key, value in paths.items()}
# Bind to the real startup and event/teardown consumers, not an unused helper.
assert "beginPowerAssertion()\n        refreshPowerAssertion()" in sources["start"]
assert sources["start"].index("beginPowerAssertion()") < sources["start"].index("let network =")
assert "self.refreshAudioNoticeTimer(epoch: epoch)" in sources["controller"]
assert "audioNoticeTask?.cancel(); audioNoticeTask = nil; timedAudioNotice = nil" in block(
    sources["controller"], "private func stopCurrentSession(")
assert "var recovery = DesktopRecoveryPresentation()" not in block(
    sources["controller"], "func open(")
timer = block(sources["controller"], "private func refreshAudioNoticeTimer(")
assert "Task.sleep(for: .seconds(8))" in timer

types = (ENGINE / "Models/Types.swift").read_text()
connection = (ENGINE / "Session/StreamConnection.swift").read_text()
takeover = (ENGINE / "Session/StreamSession+Attempt.swift").read_text()
constants = "\n".join(re.findall(
    r"^    package static let (?:deadPeer|protectedContent|frameConversion|noVideoTraffic|noVideoFrame)TerminationCode[^\n]*",
    (ENGINE / "Session/StreamSession.swift").read_text() + "\n" +
    (ENGINE / "Session/StreamSession+FrameWatchdog.swift").read_text(), re.M))
assert len(constants.splitlines()) == 5
contract = "\n".join([
    (ENGINE / "Protocol/StreamSecurityPolicy.swift").read_text(),
    (ROOT / "Sources/DeskBridgeApp/DesktopSecurityGuidance.swift").read_text().replace("import GlimmerEngine\n", ""),
    block(types, "public enum StreamEvent:"), block(types, "public enum ConnectionQuality:"),
    block(types, "public enum StreamError:"), (ENGINE / "Models/StreamFailure.swift").read_text(),
    (ENGINE / "Models/StreamFailureCopy.swift").read_text(),
    "public enum StreamConnection {\n" + block(connection, "public enum Failure:") + "\n}",
    block(takeover, "package struct TakeoverRequired:"),
    "public enum StreamInput { public enum Event: Sendable {} }",
])
power = "\n".join(block(sources["start"], "package func " + name) for name in [
    "beginPowerAssertion()", "endPowerAssertion()", "refreshPowerAssertion()", "adoptVideoDecoder("])
power += "\n" + block(sources["public"], "public func refreshPresentationActivity()")
presentation_checks = block(sources["checks"], "func runDesktopRecoveryChecks()")
presentation_checks = presentation_checks.replace("count += try runDesktopVisibilityChecks()", "")

fixture = r'''
import Foundation
__CONTRACT__
__ACTIVITY__
__PRESENTATION__
struct ModelCheckFailure: Error { let message: String }
__PRESENTATION_CHECKS__
final class Ledger: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [Bool] = []
    private var held: Set<ObjectIdentifier> = []
    func acquire(_ suppressed: Bool) -> NSObjectProtocol {
        let token = NSObject()
        lock.withLock { states.append(suppressed); held.insert(ObjectIdentifier(token)) }
        return token
    }
    func release(_ token: NSObjectProtocol) { _ = lock.withLock { held.remove(ObjectIdentifier(token)) } }
    var snapshot: (states: [Bool], held: Int) { lock.withLock { (states, held.count) } }
}
public final class VideoDecoder: Sendable {
    let presentSuppressed: Bool
    init(_ suppressed: Bool) { presentSuppressed = suppressed }
}
@MainActor final class PreparedMedia {
    let video: VideoDecoder
    init(_ decoder: VideoDecoder) { video = decoder }
}
struct Services: Sendable {
    let beginActivity: @Sendable () -> Void
    let endActivity: @Sendable () -> Void
    let refreshActivity: @Sendable (Bool) -> Void
}
public actor StreamSession {
    __CONSTANTS__
    var isStreaming = false, stopInProgress = false, activityHeld = false, publicTerminal = false
    var videoDecoder: VideoDecoder?
    let publicMedia: PreparedMedia?
    let services: Services
    init(_ media: PreparedMedia?, ledger: Ledger) {
        publicMedia = media
        let activity = DesktopStreamActivity(acquire: { ledger.acquire($0) }, release: { ledger.release($0) })
        services = Services(beginActivity: { activity.begin() }, endActivity: { activity.end() },
                            refreshActivity: { activity.refresh(displaySuppressed: $0) })
    }
    func syntheticStartupPrelude() {
        isStreaming = true
        __STARTUP_POWER_SEQUENCE__
    }
    func syntheticStop() {
        isStreaming = false; stopInProgress = true; publicTerminal = true
        endPowerAssertion()
    }
    __POWER__
}
@MainActor final class View {
    var messages: [String?] = []
    func showRecovery(_ message: String?) { messages.append(message) }
}
// Exact production timer; the view and outer window/network owner are inert.
@MainActor final class DesktopStreamController {
    var recovery = DesktopRecoveryPresentation()
    var audioNoticeTask: Task<Void, Never>?
    var timedAudioNotice: UUID?
    var generation = UUID()
    var view: View? = View()
    func receive(_ event: StreamEvent) {
        recovery.receive(event); view?.showRecovery(recovery.message)
        refreshAudioNoticeTimer(epoch: generation)
    }
    func syntheticStop() {
        generation = UUID()
        audioNoticeTask?.cancel(); audioNoticeTask = nil; timedAudioNotice = nil
        recovery.receive(.stopped); view?.showRecovery(nil)
    }
    __TIMER__
}
@main struct Checks {
    @MainActor static func main() async throws {
        var checks = try runDesktopRecoveryChecks()
        func expect(_ condition: Bool, _ message: String) throws {
            guard condition else { throw ModelCheckFailure(message: message) }; checks += 1
        }
        let hiddenLedger = Ledger()
        let hidden = StreamSession(PreparedMedia(VideoDecoder(true)), ledger: hiddenLedger)
        await hidden.syntheticStartupPrelude()
        try expect(hiddenLedger.snapshot.states == [false, true] && hiddenLedger.snapshot.held == 1,
                   "prepared hidden decoder retained the display assertion before adoption")
        await hidden.refreshPresentationActivity()
        try expect(hiddenLedger.snapshot.states == [false, true], "duplicate pre-adoption refresh stacked power")
        await hidden.adoptVideoDecoder(VideoDecoder(false))
        try expect(hiddenLedger.snapshot.states == [false, true, false], "adopted decoder did not supersede prepared suppression")
        await hidden.syntheticStop()
        await hidden.refreshPresentationActivity(); await hidden.refreshPowerAssertion()
        await hidden.adoptVideoDecoder(VideoDecoder(false))
        try expect(hiddenLedger.snapshot.held == 0 && hiddenLedger.snapshot.states == [false, true, false],
                   "late refresh/adoption after stop reacquired activity")
        let absentLedger = Ledger(), visibleLedger = Ledger()
        let absent = StreamSession(nil, ledger: absentLedger)
        let visible = StreamSession(PreparedMedia(VideoDecoder(false)), ledger: visibleLedger)
        await absent.syntheticStartupPrelude(); await visible.syntheticStartupPrelude()
        try expect(absentLedger.snapshot.states == [false] && visibleLedger.snapshot.states == [false],
                   "absent/visible decoder changed normal startup activity")
        await absent.syntheticStop(); await visible.syntheticStop()
        try expect(absentLedger.snapshot.held == 0 && visibleLedger.snapshot.held == 0, "startup activities leaked")

        let live = DesktopStreamController(), stalled = DesktopStreamController()
        let stopped = DesktopStreamController(), replaced = DesktopStreamController()
        for controller in [live, stalled, stopped, replaced] {
            controller.receive(.firstFrame); controller.receive(.audioFailed("synthetic receive/output failure"))
            try expect(controller.audioNoticeTask != nil, "visible audio failure did not start bounded notice")
        }
        let liveTask = live.audioNoticeTask!, stalledTask = stalled.audioNoticeTask!
        let stoppedTask = stopped.audioNoticeTask!, replacedTask = replaced.audioNoticeTask!
        stalled.receive(.waitingForVideo(true))
        stopped.syntheticStop()
        // A replacement session must not be touched even if an old task was not cancelled.
        replaced.generation = UUID(); replaced.recovery = DesktopRecoveryPresentation()
        replaced.recovery.receive(.firstFrame); replaced.recovery.receive(.audioFailed("replacement"))
        let replacementID = replaced.recovery.audioNoticeID
        let reconnect = DesktopStreamController()
        reconnect.receive(.firstFrame); reconnect.receive(.audioFailed("old attempt"))
        let cancelledTask = reconnect.audioNoticeTask!
        reconnect.receive(.reconnecting)
        try expect(reconnect.audioNoticeTask == nil && reconnect.timedAudioNotice == nil,
                   "reconnect did not cancel prior notice task")
        reconnect.receive(.firstFrame); reconnect.receive(.audioFailed("new attempt"))
        let newID = reconnect.recovery.audioNoticeID
        await cancelledTask.value
        try expect(newID != nil && reconnect.recovery.audioNoticeID == newID && reconnect.recovery.message != nil,
                   "cancelled prior-attempt task dismissed new audio notice")
        reconnect.syntheticStop()
        await liveTask.value; await stalledTask.value; await stoppedTask.value; await replacedTask.value
        try expect(live.recovery.message == nil && live.recovery.status.contains("오디오를 사용할 수 없습니다"),
                   "unchanged production timer did not expire visible audio notice")
        for _ in 0..<5 {
            live.receive(.waitingForVideo(true)); live.receive(.waitingForVideo(false))
            try expect(live.audioNoticeTask == nil && live.recovery.message == nil,
                       "post-expiry stall scheduled a new notice")
        }
        try expect(stalled.recovery.phase == .waiting && stalled.recovery.message?.contains("영상을 기다리는") == true,
                   "audio timer hid active video wait")
        try expect(stopped.view?.messages.last! == nil && stopped.recovery.phase == .ended,
                   "cancelled stop task restored a stale card")
        try expect(replaced.recovery.audioNoticeID == replacementID && replaced.recovery.message != nil,
                   "old session generation expired a replacement notice")
        print("{\"status\":\"passed\",\"audioNoticePowerChecks\":\(checks),\"timerSeconds\":8,\"scope\":\"actual presentation checks, timer and session activity methods; inert media/view/activity; no UI/power/network/preferences\"}")
    }
}
'''
for marker, value in {
    "__CONTRACT__": contract,
    "__CONSTANTS__": constants,
    "__ACTIVITY__": sources["activity"],
    "__PRESENTATION__": sources["presentation"].replace("import GlimmerEngine\n", ""),
    "__PRESENTATION_CHECKS__": presentation_checks,
    "__POWER__": power,
    "__TIMER__": timer,
    "__STARTUP_POWER_SEQUENCE__": "beginPowerAssertion()\n        refreshPowerAssertion()",
}.items():
    fixture = fixture.replace(marker, value)
with tempfile.TemporaryDirectory(prefix="knot-audio-notice-power-", dir="/tmp") as directory:
    temporary = Path(directory)
    source = temporary / "Checks.swift"
    source.write_text(fixture)
    executable = temporary / "checks"
    compile_argv = ["/usr/bin/swiftc", "-swift-version", "6", "-package-name", "Glimmer",
                    "-parse-as-library", "-O", "-module-cache-path", str(temporary / "module-cache"),
                    str(source), "-o", str(executable)]
    for argv in [compile_argv, [str(executable)]]:
        result = subprocess.run(argv, capture_output=True, text=True)
        print(json.dumps({"argv": argv, "exitCode": result.returncode,
                          "stdout": result.stdout, "stderr": result.stderr}))
        result.check_returncode()
    print(json.dumps({"fixtureSHA256": hashlib.sha256(fixture.encode()).hexdigest(),
                      "sourceSHA256": {str(paths[key].relative_to(ROOT)): hashlib.sha256(value.encode()).hexdigest()
                                       for key, value in sources.items()},
                      "scope": "source-extracted synthetic regression; not native window, power or audio acceptance"}))
