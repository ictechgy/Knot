#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Exercise production receive/drain/CBC methods with inert, newly created fixtures.

No sockets, codec, preferences, devices or existing media are opened. Queue/FEC
bookkeeping is real; the unexercised RS decoder and display are inert stand-ins.
"""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
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


audio_receive = (ENGINE / "Network/RtpAudioReceiver+Receive.swift").read_text()
audio_decrypt = (ENGINE / "Network/RtpAudioReceiver+Decrypt.swift").read_text()
video = (ENGINE / "Network/VideoRtpReceiver.swift").read_text()
pipeline = (ENGINE / "Session/NativeBackend+Pipeline.swift").read_text()
backend = (ENGINE / "Session/NativeBackend.swift").read_text()
bridge = (ENGINE / "Session/StreamBridgeContext.swift").read_text()

# Bind the extracted methods to their real production consumers as well as
# executing them. These checks prevent an unused fixed helper from passing.
assert audio_receive.index("!acceptsAudioPayload") < audio_receive.index("queue.addPacket")
assert "self?.publishReceiveFailure(receiveFailure, callback: onReceiveFailed)" in audio_receive
assert "if receiveFailed { self?.publishReceiveFailure(callback: onReceiveFailed) }" in video
assert "if receiveFailed { onReceiveFailed?() }" not in video
assert "events.audioFailed(\"audio receive failed (errno " in pipeline
assert video.index("try Self.configureReceiveTimeout(sock)") < video.index("fd = sock")

fixture = r'''
import Foundation
import Darwin
import Synchronization
import CommonCrypto

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func use<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body(&value)
    }
}
enum EnetError: Error { case socketFailure(String) }
let timeoutFailure = Locked(false)
let closedSockets = Locked<[Int32]>([])
let timeoutSockets = Locked<[Int32]>([])
func setsockopt(_ socket: Int32, _ level: Int32, _ option: Int32, _ bytes: UnsafeRawPointer?, _ length: socklen_t) -> Int32 {
    precondition(level == SOL_SOCKET && option == SO_RCVTIMEO && length == MemoryLayout<timeval>.size)
    precondition(bytes!.load(as: timeval.self).tv_usec == 100_000)
    timeoutSockets.use { $0.append(socket) }
    if timeoutFailure.use({ $0 }) { errno = EIO; return -1 }
    return 0
}
func close(_ socket: Int32) -> Int32 { closedSockets.use { $0.append(socket) }; return 0 }
final class Flag: @unchecked Sendable {
    let state = Locked(false)
    var isSet: Bool { state.use { $0 } }
    func set() { state.use { $0 = true } }
}
let sleeps = Locked<[useconds_t]>([])
let sleepHook = Locked<(@Sendable (useconds_t) -> Void)?>(nil)
@discardableResult func usleep(_ delay: useconds_t) -> Int32 {
    sleeps.use { $0.append(delay) }; sleepHook.use { $0 }?(delay); return 0
}
final class Script: @unchecked Sendable {
    let errors: Locked<[Int32]>
    let calls = Locked(0)
    let entered = DispatchSemaphore(value: 0)
    let release: DispatchSemaphore?
    init(_ errors: [Int32], parked: Bool = false) {
        self.errors = Locked(errors)
        release = parked ? DispatchSemaphore(value: 0) : nil
    }
    func next() -> Int32 {
        calls.use { $0 += 1 }
        entered.signal(); release?.wait()
        return errors.use { $0.isEmpty ? EIO : $0.removeFirst() }
    }
}
let script = Locked(Script([EIO]))
let receiveModes = Locked<[String]>([])
final class DatagramBatch {
    let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: 1500)
    let activeScript: Script
    init(capacity: Int, stride: Int, receiveBatch: TransportPlatform.ReceiveBatch? = nil) { activeScript = script.use { $0 } }
    deinit { storage.deallocate() }
    private func result() -> Int { errno = activeScript.next(); return errno == 0 ? 1 : -1 }
    func receiveOne(from: Int32) -> Int { receiveModes.use { $0.append("one") }; return result() }
    func receive(from: Int32) -> Int { receiveModes.use { $0.append("batch") }; return result() }
    func datagram(_ index: Int) -> (bytes: UnsafeMutablePointer<UInt8>, length: Int) { (storage, 1) }
    func isExpectedPeer(at: Int, expected: Int, expectedLength: Int) -> Bool { true }
}
struct ReceiveTiming {
    enum Kind { case audio, video }
    init(telemetry: Kind) {}
    mutating func note(_ batch: DatagramBatch, index: Int, count: Int, socket: Int32, stream: String) {}
}
enum UdpPinger { static func noteForeignPeer(_ noted: inout Bool, stream: String, category: String) {} }
final class Worker: @unchecked Sendable {
    let idle = Locked(0)
    func enqueue(_ bytes: [UInt8], count: Int, arrival: UInt64) { idle.use { $0 += 1 } }
    func enqueue(_ bytes: UnsafeRawBufferPointer, count: Int, arrival: UInt64) {}
}
final class Counter: @unchecked Sendable { func increment() {} }
final class TelemetryCounters: Sendable {
    static let shared = TelemetryCounters()
    let audioFecMismatchTotal = Counter()
}
enum AudioDiagnostics {
    static func warn(_ message: String, _ category: String) {}
    static func notice(_ message: String, _ category: String) {}
}
struct AudioFecDecoder { func recover(_ block: RtpAudioQueue.FecBlock) -> Bool { false } }
struct TransportRoute: Sendable { static let shared = TransportRoute(); let streamLink = "wired" }
final class RtpAudioReceiver: @unchecked Sendable {
    static let maxPacketSize = 1400
    static let cat = "synthetic.audio"
    let fd: Int32 = -1
    let destAddr = 0, destAddrLen = 0
    let recvQueue = DispatchQueue(label: "synthetic.audio.receive")
    let interrupted = Flag()
    let decodeWorker = Worker()
    var onReceiveFailed: (@Sendable (Int32) -> Void)?
    var audioEncryption = true
    let aesKey = [UInt8](repeating: 0x42, count: 16)
    let avRiKeyId: UInt32 = 0x01020304
    var decryptScratch = [UInt8](repeating: 0, count: 1416)
    let queue = RtpAudioQueue(audioPacketDuration: 5)
    func noteAudioArrivalGap(now: UInt64) {}
    __AUDIO_METHODS__
}
enum StreamProtocol { static let FRAME_TYPE_IDR = 1; static let DR_NEED_IDR: Int32 = -1 }
struct DecodeUnit: Sendable {
    let frameType = 0, rtpTimestamp = 0, frameNumber = 0
    let receiveTimeUs: UInt64 = 0, enqueueTimeUs: UInt64 = 0
    let fullLength = 0, frameHostProcessingLatency = 0
}
final class Sink: @unchecked Sendable {
    let submissions = Locked(0)
    func submitDecodeUnit(_ unit: DecodeUnit) -> Int32 { submissions.use { $0 += 1 }; return 0 }
}
struct Episode { var isOpen = false }
struct Depacketizer { func requestDecoderRefresh() {} }
final class FrameTimingTracker: Sendable {
    static let shared: FrameTimingTracker? = nil
    func recordAssembled(rtpTimestamp: Int, frameIndex: Int, receiveNanos: UInt64,
        assembleNanos: UInt64, frameBytes: Int, isIDR: Bool, hostEncodeTenthsMs: Int) {}
}
enum Diag {
    static func info(_ message: String, _ category: String) {}
    static func warn(_ message: String, _ category: String) {}
    static func notice(_ message: String, _ category: String) {}
    static func error(_ message: String, _ category: String) {}
}
enum TransportPlatform { typealias ReceiveBatch = @Sendable () -> Void }
struct VideoDecryptor: Sendable { init?(key: [UInt8]) {} }
struct SyntheticVideoQueue {
    let flushes = Locked(0)
    func flushDeferredIfWindowElapsed(nowUs: UInt64) { flushes.use { $0 += 1 } }
}
final class VideoRtpReceiver: @unchecked Sendable {
    static let cat = "synthetic.video"
    let interrupted = Atomic<Bool>(false)
    let recvQueue = DispatchQueue(label: "synthetic.video.receive")
    let fd: Int32 = -1, packetSize = 1400
    let encrypted = false, aesKey = [UInt8]()
    let receiveBatch: TransportPlatform.ReceiveBatch? = nil
    let destAddr = 0, destAddrLen = 0
    var onReceiveFailed: (@Sendable () -> Void)?
    var loggedReceivePressure = false
    let rtpQueue = SyntheticVideoQueue()
    let received = Locked(0)
    let sink: Sink?
    var lossEpisode = Episode()
    let depacketizer = Depacketizer()
    init(sink: Sink) { self.sink = sink }
    func noteKeyFrame(_ unit: DecodeUnit, tracker: FrameTimingTracker) {}
    func closeLossEpisode(at unit: DecodeUnit, isIDR: Bool) {}
    func isExpectedPostGateResync(isIDR: Bool) -> Bool { false }
    func receive(_ bytes: UnsafeMutablePointer<UInt8>, count: Int, decryptor: VideoDecryptor?) { received.use { $0 += 1 } }
    __VIDEO_METHODS__
}
final class LeafResource: @unchecked Sendable {
    var onTerminated: (@Sendable (Int32) -> Void)?
    var onHdrMode: (@Sendable (Bool) -> Void)?
    func stop() {}
    func interrupt() {}
    func close() {}
}
typealias EnetControlChannel = LeafResource
protocol ConnectionEvents: Sendable {
    func connectionTerminated(code: Int32)
    func setHdrMode(_ enabled: Bool)
}
final class RecordedEvents: ConnectionEvents, @unchecked Sendable {
    let codes = Locked<[Int32]>([])
    let notified = DispatchSemaphore(value: 0)
    func connectionTerminated(code: Int32) { codes.use { $0.append(code) }; notified.signal() }
    func setHdrMode(_ enabled: Bool) {}
}
final class LifecycleSink: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let cleanups = Locked(0)
    var onCleanup: (@Sendable () -> Void)?
    func stop() {}
    func cleanup() {
        cleanups.use { $0 += 1 }; onCleanup?(); entered.signal(); release.wait()
    }
}
final class NativeBackend: @unchecked Sendable {
    static let logCategory = "synthetic.backend"
    let stateLock = NSLock()
    let teardownLock = NSRecursiveLock()
    var interrupted = false, inputReady = true
    var enetChannel: LeafResource?, rtspClient: LeafResource?, audioReceiver: LeafResource?
    var audioSink: LeafResource?, inputBatcher: LeafResource?
    var videoReceiver: VideoRtpReceiver?
    var videoSink: LifecycleSink?
    func withState<T>(_ body: () -> T) -> T { stateLock.lock(); defer { stateLock.unlock() }; return body() }
    func checkInterrupted() -> Bool { withState { interrupted } }
    func wireVideoFailure(receiver: VideoRtpReceiver, events: any ConnectionEvents) {
        __VIDEO_FAILURE_CLOSURE__
    }
    __BACKEND_METHODS__
}
enum StreamEvent: Equatable, Sendable { case reconnecting, audioFailed(String), firstFrame }
final class SessionEventSource: @unchecked Sendable {
    let events = Locked<[StreamEvent]>([])
    let didBegin = Locked<[UUID]>([])
    var onYield: (@Sendable (StreamEvent) -> Void)?
    func beginAttempt(_ id: UUID) { didBegin.use { $0.append(id) } }
    func yield(_ event: StreamEvent, attempt: UUID) { events.use { $0.append(event) }; onYield?(event) }
}
final class StreamBridgeContext: @unchecked Sendable {
    private var attemptID = UUID()
    private let sourceLock = NSLock()
    private var eventSource: ObjectIdentifier?
    private var terminationSource: ObjectIdentifier?
    private var terminationAttempt: UUID?
    private var terminationEventsRetired = true
    private var admittedTerminationCode: Int32?
    private var audioEventsQuiesced = false
    let publicEvents: SessionEventSource?
    var eventContinuation: AsyncStream<StreamEvent>.Continuation?
    init(events: SessionEventSource? = nil) { publicEvents = events }
    __BRIDGE_METHODS__
}
func encrypt(_ bytes: [UInt8], receiver: RtpAudioReceiver, sequence: UInt16, padding: Bool) -> [UInt8] {
    var iv = ((receiver.avRiKeyId &+ UInt32(sequence)).bigEndian, UInt32(0), UInt32(0), UInt32(0))
    var output = [UInt8](repeating: 0, count: bytes.count + 16)
    var moved = 0
    let status = bytes.withUnsafeBytes { input in
        receiver.aesKey.withUnsafeBytes { key in
            withUnsafeBytes(of: &iv) { ivBytes in
                output.withUnsafeMutableBytes { destination in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                        padding ? CCOptions(kCCOptionPKCS7Padding) : 0, key.baseAddress,
                        key.count, ivBytes.baseAddress, input.baseAddress, input.count,
                        destination.baseAddress, destination.count, &moved)
                }
            }
        }
    }
    precondition(status == kCCSuccess)
    return Array(output[..<moved])
}
func packet(_ payload: [UInt8], sequence: UInt16) -> [UInt8] {
    [0x80, 97, UInt8(sequence >> 8), UInt8(truncatingIfNeeded: sequence),
     0, 0, 0, UInt8(truncatingIfNeeded: sequence * 5), 0, 0, 0, 1] + payload
}
@main struct Checks {
    static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw NSError(domain: label, code: checks) }; checks += 1
        }
        func wait(_ signal: DispatchSemaphore, _ label: String) throws {
            try expect(signal.wait(timeout: .now() + 3) == .success, label)
        }
        try VideoRtpReceiver.configureReceiveTimeout(701)
        try expect(timeoutSockets.use { $0 } == [701] && closedSockets.use { $0.isEmpty }, "successful timeout retains local socket")
        timeoutFailure.use { $0 = true }
        var failedTimeout = false
        do { try VideoRtpReceiver.configureReceiveTimeout(702) }
        catch EnetError.socketFailure { failedTimeout = true }
        try expect(failedTimeout && closedSockets.use { $0 } == [702], "failed timeout must close unpublished socket and refuse startup")

        // Real CBC and real queue bookkeeping: bad in-order padding cannot
        // consume the sequence, so its valid retransmission still plays.
        let audio = RtpAudioReceiver()
        let seedCipher = encrypt([0x11, 0x22, 0x33], receiver: audio, sequence: 0, padding: true)
        let seed = packet(seedCipher, sequence: 0)
        try expect(audio.acceptsAudioPayload(seed, count: seed.count), "valid baseline payload")
        _ = audio.queue.addPacket(seed, rtp: RtpAudioQueue.RtpHeader(header: 0x80,
            packetType: 97, sequenceNumber: 0, timestamp: 0, ssrc: 1))
        try expect(audio.queue.nextRtpSequenceNumber == 4, "start on first whole block")
        for sequence in UInt16(4)...UInt16(6) {
            let bad = packet(encrypt([UInt8](repeating: 0, count: 16), receiver: audio,
                                     sequence: sequence, padding: false), sequence: sequence)
            let before = audio.queue.nextRtpSequenceNumber
            try expect(!audio.acceptsAudioPayload(bad, count: bad.count), "bad padding at every cursor")
            try expect(audio.queue.nextRtpSequenceNumber == before, "invalid payload leaves cursor")
            let cipher = encrypt([0x11, 0x22, 0x33], receiver: audio, sequence: sequence, padding: true)
            let valid = packet(cipher, sequence: sequence)
            try expect(audio.acceptsAudioPayload(valid, count: valid.count), "valid ciphertext admitted")
            let header = RtpAudioQueue.RtpHeader(header: 0x80, packetType: 97,
                sequenceNumber: sequence, timestamp: UInt32(sequence) * 5, ssrc: 1)
            try expect(audio.queue.addPacket(valid, rtp: header) == .handleNow, "valid packet follows rejected packet")
            try expect(audio.queue.nextRtpSequenceNumber == sequence + 1, "valid queue advances once")
            try expect(Array(audio.queue.blocks[0].dataShards[Int(sequence % 4)].prefix(cipher.count)) == cipher,
                       "FEC retains original ciphertext")
        }
        let runt = packet([1, 2, 3], sequence: 3)
        try expect(!audio.acceptsAudioPayload(runt, count: runt.count), "misaligned encrypted packet rejected")
        audio.audioEncryption = false
        try expect(audio.acceptsAudioPayload(runt, count: runt.count), "legacy plaintext format unchanged")

        // Run the exact production receive loop against scripted syscall
        // results; no real descriptor/socket exists.
        let runtimeAudio = RtpAudioReceiver()
        let terminal = DispatchSemaphore(value: 0)
        let failureCodes = Locked<[Int32]>([])
        runtimeAudio.onReceiveFailed = { error in
            failureCodes.use { $0.append(error) }; terminal.signal()
        }
        sleeps.use { $0.removeAll() }
        script.use { $0 = Script([ENOBUFS, ENOMEM, ENOBUFS, ENOMEM, ENOBUFS, ENOMEM, EAGAIN, ENOBUFS, EIO]) }
        runtimeAudio.startReceiveLoop()
        try wait(terminal, "runtime audio failure delivered")
        runtimeAudio.recvQueue.sync {}
        try expect(failureCodes.use { $0 } == [EIO], "one nonfatal terminal event")
        try expect(sleeps.use { $0 } == [1_000, 2_000, 4_000, 8_000, 16_000, 16_000, 1_000], "capped resettable backoff")
        try expect(runtimeAudio.decodeWorker.idle.use { $0 } == 1, "idle timeout remains startup evidence")

        let cancelledAudio = RtpAudioReceiver()
        let cancelledScript = Script([EBADF], parked: true)
        script.use { $0 = cancelledScript }
        let cancelledFailures = Locked(0)
        cancelledAudio.onReceiveFailed = { _ in cancelledFailures.use { $0 += 1 } }
        cancelledAudio.startReceiveLoop()
        try wait(cancelledScript.entered, "cancelled receive entered")
        cancelledAudio.interrupted.set()
        cancelledScript.release?.signal()
        cancelledAudio.recvQueue.sync {}
        try expect(cancelledFailures.use { $0 } == 0, "stop excludes terminal event")

        // Execute the full video loop with scripted buffer pressure, an idle
        // poll and a successful datagram. No descriptor is used by the stub.
        let pressuredVideo = VideoRtpReceiver(sink: Sink())
        let videoFailure = DispatchSemaphore(value: 0)
        pressuredVideo.onReceiveFailed = { videoFailure.signal() }
        sleeps.use { $0.removeAll() }
        script.use { $0 = Script([ENOBUFS, ENOMEM, ENOBUFS, ENOMEM, ENOBUFS, ENOMEM,
                                  EAGAIN, ENOBUFS, 0, ENOBUFS, EIO]) }
        pressuredVideo.startReceiveLoop()
        try wait(videoFailure, "video terminal error delivered off receive queue")
        pressuredVideo.recvQueue.sync {}
        try expect(sleeps.use { $0 } == [1_000, 2_000, 4_000, 8_000, 16_000, 16_000, 1_000, 1_000],
                   "video pressure is capped and resets after idle and successful batch")
        try expect(pressuredVideo.received.use { $0 } == 1, "successful datagram reaches production loop consumer")
        try expect(pressuredVideo.rtpQueue.flushes.use { $0 } == 1, "idle poll still flushes reorder hold")

        let interruptedVideo = VideoRtpReceiver(sink: Sink())
        let interruptScript = Script([ENOBUFS, EIO])
        let interruptFailures = Locked(0)
        interruptedVideo.onReceiveFailed = { interruptFailures.use { $0 += 1 } }
        script.use { $0 = interruptScript }
        sleeps.use { $0.removeAll() }
        sleepHook.use { $0 = { _ in interruptedVideo.interrupted.store(true, ordering: .relaxed) } }
        interruptedVideo.startReceiveLoop()
        interruptedVideo.recvQueue.sync {}
        sleepHook.use { $0 = nil }
        try expect(interruptScript.calls.use { $0 } == 1, "interrupt after pressure sleep excludes another syscall")
        try expect(sleeps.use { $0 } == [1_000] && interruptFailures.use { $0 } == 0,
                   "pressure cancellation is quiet and bounded")

        let fallbackVideo = VideoRtpReceiver(sink: Sink())
        let fallbackFailure = DispatchSemaphore(value: 0)
        fallbackVideo.onReceiveFailed = { fallbackFailure.signal() }
        script.use { $0 = Script([ENOSYS, ENOBUFS, EIO]) }
        receiveModes.use { $0.removeAll() }
        fallbackVideo.startReceiveLoop()
        try wait(fallbackFailure, "batch syscall fallback remains operational")
        fallbackVideo.recvQueue.sync {}
        try expect(receiveModes.use { $0 } == ["batch", "one", "one"], "unsupported batch syscall switches subsequent receives to recvmsg")

        // A callback may have passed NativeConnectionEvents.isCurrent before
        // recovery starts. The real bridge must fence it at actual delivery.
        let bridgeEvents = SessionEventSource()
        let bridge = StreamBridgeContext(events: bridgeEvents)
        let oldBackend = NativeBackend(), oldAttempt = UUID()
        bridge.setEventSource(oldBackend, attempt: oldAttempt)
        try expect(bridge.acceptsEvent(from: oldBackend, attempt: oldAttempt), "old callback passes precheck")
        bridge.emit(.reconnecting)
        bridge.emit(.audioFailed("old failure during backoff"), source: oldBackend, attempt: oldAttempt)
        try expect(bridgeEvents.events.use { $0 } == [.reconnecting], "backoff fences old audio event after precheck")
        let newAttempt = UUID(), newBackend = NativeBackend()
        bridge.beginAttempt(newAttempt)
        bridge.emit(.audioFailed("old generation"), source: oldBackend, attempt: oldAttempt)
        bridge.setEventSource(newBackend, attempt: newAttempt)
        bridge.emit(.audioFailed("new receiver before first picture"), source: newBackend, attempt: newAttempt)
        bridge.emit(.firstFrame, source: newBackend, attempt: newAttempt)
        try expect(bridgeEvents.events.use { $0 } == [.reconnecting, .audioFailed("new receiver before first picture"), .firstFrame],
                   "new receiver failure survives first frame while old generation stays rejected")

        // Park the actual reconnect yield while sourceLock is held. A competing
        // audio delivery cannot pass between quiescing and publishing that edge.
        let raceEvents = SessionEventSource()
        let orderedBridge = StreamBridgeContext(events: raceEvents)
        orderedBridge.setEventSource(oldBackend, attempt: oldAttempt)
        let reconnectEntered = DispatchSemaphore(value: 0), reconnectRelease = DispatchSemaphore(value: 0)
        let reconnectDone = DispatchSemaphore(value: 0), racedAudioDone = DispatchSemaphore(value: 0)
        raceEvents.onYield = { event in
            if event == .reconnecting { reconnectEntered.signal(); reconnectRelease.wait() }
        }
        DispatchQueue.global().async { orderedBridge.emit(.reconnecting); reconnectDone.signal() }
        try wait(reconnectEntered, "reconnect delivery entered under bridge source lock")
        DispatchQueue.global().async {
            orderedBridge.emit(.audioFailed("raced old event"), source: oldBackend, attempt: oldAttempt)
            racedAudioDone.signal()
        }
        try expect(racedAudioDone.wait(timeout: .now() + 0.02) == .timedOut, "audio emission waits for reconnect boundary")
        reconnectRelease.signal()
        try wait(reconnectDone, "reconnect event released")
        try wait(racedAudioDone, "racing audio delivery completed")
        try expect(raceEvents.events.use { $0 } == [.reconnecting], "raced audio is rejected after ordered reconnect yield")
        // Both attempt entry points reset the same latch; beginAttempt also
        // serves the legacy continuation path before a backend is installed.
        let resetEvents = SessionEventSource(), resetBridge = StreamBridgeContext(events: resetEvents)
        resetBridge.emit(.reconnecting)
        resetBridge.beginAttempt(newAttempt)
        resetBridge.emit(.audioFailed("fresh attempt"), attempt: newAttempt)
        try expect(resetEvents.events.use { $0 } == [.reconnecting, .audioFailed("fresh attempt")], "beginAttempt independently resets audio fence")
        resetBridge.emit(.reconnecting)
        resetBridge.setEventSource(newBackend, attempt: newAttempt)
        resetBridge.emit(.audioFailed("fresh source"), source: newBackend, attempt: newAttempt)
        try expect(resetEvents.events.use { $0.last } == .audioFailed("fresh source"), "setEventSource independently resets audio fence")

        // Park an old receive before submit. Stop cannot finish until it
        // drains; releasing it after cancellation cannot reach the shared sink.
        let sink = Sink()
        let oldVideo = VideoRtpReceiver(sink: sink)
        let parked = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        oldVideo.recvQueue.async { parked.signal(); release.wait(); oldVideo.depacketizerDidAssembleFrame(DecodeUnit()) }
        try wait(parked, "old video parked")
        DispatchQueue.global().async { oldVideo.stop(); stopped.signal() }
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while !oldVideo.interrupted.load(ordering: .relaxed), DispatchTime.now().uptimeNanoseconds < deadline { sched_yield() }
        try expect(oldVideo.interrupted.load(ordering: .relaxed), "video cancellation published")
        try expect(stopped.wait(timeout: .now() + 0.02) == .timedOut, "stop waits for old receive")
        release.signal()
        try wait(stopped, "old receiver drained")
        let replacement = VideoRtpReceiver(sink: sink)
        replacement.recvQueue.sync { replacement.depacketizerDidAssembleFrame(DecodeUnit()) }
        oldVideo.recvQueue.sync { oldVideo.depacketizerDidAssembleFrame(DecodeUnit()) }
        try expect(sink.submissions.use { $0 } == 1, "only replacement submits after reopen")

        // Real failure publication moves callbacks off recvQueue. Its consumer
        // can synchronously stop/join while the exiting receive is still parked.
        let failedVideo = VideoRtpReceiver(sink: Sink())
        let published = DispatchSemaphore(value: 0), exitReceive = DispatchSemaphore(value: 0)
        let fatalFinished = DispatchSemaphore(value: 0), callbackStarted = DispatchSemaphore(value: 0)
        failedVideo.recvQueue.async {
            failedVideo.publishReceiveFailure {
                callbackStarted.signal(); failedVideo.stop(); fatalFinished.signal()
            }
            published.signal(); exitReceive.wait()
        }
        try wait(published, "fatal published")
        try wait(callbackStarted, "fatal callback starts off receive queue")
        try expect(fatalFinished.wait(timeout: .now() + 0.02) == .timedOut, "fatal consumer joins exiting receive")
        exitReceive.signal()
        try wait(fatalFinished, "fatal callback drains without deadlock")

        // Concurrent stop cannot return after references are taken but before
        // cleanup completes. A same-thread leaf notification may reenter stop.
        let backend = NativeBackend(), lifecycleSink = LifecycleSink()
        backend.videoSink = lifecycleSink
        lifecycleSink.onCleanup = { [weak backend] in backend?.stopConnection() }
        let firstStop = DispatchSemaphore(value: 0), secondStop = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { backend.stopConnection(); firstStop.signal() }
        try wait(lifecycleSink.entered, "backend entered cleanup after reentrant stop")
        DispatchQueue.global().async { backend.stopConnection(); secondStop.signal() }
        try expect(secondStop.wait(timeout: .now() + 0.02) == .timedOut, "concurrent stop waits for cleanup")
        lifecycleSink.release.signal()
        try wait(firstStop, "first backend stop completed")
        try wait(secondStop, "second backend stop completed")
        try expect(lifecycleSink.cleanups.use { $0 } == 1, "backend cleans sink exactly once")

        // Run each production termination closure. Notification is queued
        // before teardown can block, while stop still drains the shared sink.
        for hostTermination in [false, true] {
            let terminatingBackend = NativeBackend(), parkedSink = LifecycleSink()
            let receiver = VideoRtpReceiver(sink: Sink()), events = RecordedEvents()
            terminatingBackend.videoSink = parkedSink
            terminatingBackend.videoReceiver = receiver
            let callbackDone = DispatchSemaphore(value: 0)
            if hostTermination {
                let control = EnetControlChannel()
                terminatingBackend.wireVideoControl(enet: control, events: events)
                DispatchQueue.global().async { control.onTerminated?(42); callbackDone.signal() }
            } else {
                terminatingBackend.wireVideoFailure(receiver: receiver, events: events)
                DispatchQueue.global().async { receiver.onReceiveFailed?(); callbackDone.signal() }
            }
            try wait(events.notified, "termination notification precedes parked cleanup")
            try wait(parkedSink.entered, "termination teardown entered cleanup")
            try expect(callbackDone.wait(timeout: .now() + 0.02) == .timedOut, "termination callback still waits for decoder cleanup")
            try expect(events.codes.use { $0 } == [hostTermination ? 42 : -1], "termination code preserved")
            parkedSink.release.signal()
            try wait(callbackDone, "termination teardown completes after cleanup release")
            try expect(parkedSink.cleanups.use { $0 } == 1, "termination cleanup remains singular")
        }
        print("{\"status\":\"passed\",\"mediaLifecycleChecks\":\(checks),\"scope\":\"exact production receive/drain/CBC methods and audio queue; scripted syscalls, inert display/FEC recovery, no network or device\"}")
    }
}
'''

audio_methods = [block(audio_receive, "func " + name) for name in (
    "startReceiveLoop()", "shouldContinueReceiving(after", "publishReceiveFailure(")]
audio_methods += [block(audio_decrypt, "func " + name) for name in ("acceptsAudioPayload(", "decryptCbc(")]
video_methods = [block(video, signature).replace("private func", "func", 1) for signature in (
    "func stop()", "private func publishReceiveFailure(", "func depacketizerDidAssembleFrame(",
    "private func startReceiveLoop()", "private func shouldContinueReceiving(")]
video_methods.append(block(video, "private static func configureReceiveTimeout(").replace("private static func", "static func", 1))
fixture = fixture.replace("__AUDIO_METHODS__", "\n".join(audio_methods))
fixture = fixture.replace("__VIDEO_METHODS__", "\n".join(video_methods))
fixture = fixture.replace("__BACKEND_METHODS__", "\n".join(
    block(backend, signature).replace("package func", "func", 1)
    for signature in ("package func stopConnection()", "package func interruptConnection()")))
fixture = fixture.replace("__VIDEO_FAILURE_CLOSURE__", block(pipeline, "receiver.onReceiveFailed ="))
fixture = fixture.replace("__BRIDGE_METHODS__", "\n".join(
    block(bridge, signature).replace("package func", "func", 1)
    for signature in ("package func beginAttempt(", "package func setEventSource(",
                      "package func acceptsEvent(", "package func admitTermination(", "package func terminationIntent(", "package func emit(")))
fixture = fixture.replace("    func wireVideoFailure", block(pipeline, "func wireVideoControl(") + "\n    func wireVideoFailure", 1)
queue_sources = [ENGINE / "Network" / name for name in ("RtpAudioQueue.swift", "RtpAudioQueue+Fec.swift")]
with tempfile.TemporaryDirectory(prefix="knot-media-lifecycle-", dir="/tmp") as directory:
    temporary = Path(directory)
    source = temporary / "Checks.swift"
    source.write_text(fixture)
    executable = temporary / "checks"
    compile_argv = ["/usr/bin/swiftc", "-swift-version", "6", "-parse-as-library", "-O",
                    "-module-cache-path", str(temporary / "module-cache"), str(source),
                    *map(str, queue_sources), "-o", str(executable)]
    print(json.dumps({"compileArgv": compile_argv, "checksArgv": [str(executable)]}), flush=True)
    subprocess.run(compile_argv, check=True)
    subprocess.run([str(executable)], check=True, timeout=30)
    source_paths = [ENGINE / "Network/RtpAudioReceiver+Receive.swift",
                    ENGINE / "Network/RtpAudioReceiver+Decrypt.swift",
                    ENGINE / "Network/VideoRtpReceiver.swift", ENGINE / "Session/NativeBackend.swift",
                    ENGINE / "Session/NativeBackend+Pipeline.swift", ENGINE / "Session/StreamBridgeContext.swift", *queue_sources]
    print(json.dumps({"fixtureSHA256": hashlib.sha256(fixture.encode()).hexdigest(),
                      "productionSourceSHA256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                                 for path in source_paths},
                      "scope": "offline source-extracted synthetic regression, not device acceptance"}))


# Separate source-extracted audio startup fixture keeps all 74 receive/drain
# checks above unchanged. Only syscalls, ping scheduling, codec work and logging
# are inert; openSocket, timeout setup and both backend audio consumers are real.
audio_socket = (ENGINE / "Network/RtpAudioReceiver+Socket.swift").read_text()
assert audio_socket.index("try Self.configureReceiveTimeout(sock)") < audio_socket.index("fd = sock")
assert "config: config, host: host, events: events" in block(pipeline, "rtsp.onAudioPortNegotiated =")
socket_fixture = r'''
import Foundation
import Darwin

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func use<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
struct Ledger {
    var nextSocket: Int32 = 703
    var timeoutFails = false
    var binds = [Int32](), closes = [Int32](), timeouts = [Int32](), timestamps = [Int32]()
    var family = AF_INET
    var onTimeout: (@Sendable () -> Void)?
}
let ledger = Locked(Ledger())
func socket(_ family: Int32, _ kind: Int32, _ proto: Int32) -> Int32 {
    precondition(kind == SOCK_DGRAM && proto == 0)
    return ledger.use { value in defer { value.nextSocket += 1 }; return value.nextSocket }
}
@discardableResult func setsockopt(_ socket: Int32, _ level: Int32, _ option: Int32, _ bytes: UnsafeRawPointer?, _ length: socklen_t) -> Int32 {
    precondition(level == SOL_SOCKET)
    guard option == SO_RCVTIMEO else {
        precondition(option == SO_RCVBUF || option == SO_NET_SERVICE_TYPE); return 0
    }
    precondition(length == MemoryLayout<timeval>.size && bytes!.load(as: timeval.self).tv_sec == 0
                 && bytes!.load(as: timeval.self).tv_usec == 100_000)
    let state = ledger.use { value -> (Bool, (@Sendable () -> Void)?) in
        value.timeouts.append(socket); return (value.timeoutFails, value.onTimeout)
    }
    state.1?()
    if state.0 { errno = EIO; return -1 }
    return 0
}
@discardableResult func close(_ socket: Int32) -> Int32 { ledger.use { $0.closes.append(socket) }; return 0 }
func bind(_ socket: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> Int32 {
    ledger.use { $0.binds.append(socket) }; return 0
}
enum SocketTimestamp { static func enable(on socket: Int32) -> Bool { ledger.use { $0.timestamps.append(socket) }; return true } }
enum NWEndpoint { typealias Host = String }
enum EnetError: Error { case socketFailure(String) }
enum UdpPinger {
    static func makeSockaddr(for host: String, port: UInt16) -> (sockaddr_storage, socklen_t, Int32)? {
        (sockaddr_storage(), socklen_t(MemoryLayout<sockaddr_storage>.size), ledger.use { $0.family })
    }
}
enum Privacy { case `private`, `public` }
struct Message: ExpressibleByStringInterpolation {
    init(stringLiteral: String) {}
    init(stringInterpolation: StringInterpolation) {}
    static func + (_ lhs: Message, _ rhs: Message) -> Message { Message(stringLiteral: "") }
    struct StringInterpolation: StringInterpolationProtocol {
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ value: String) {}
        mutating func appendInterpolation<T>(_ value: T, privacy: Privacy = .public) {}
    }
}
enum Diag {
    static func info(_ message: Message, _ category: String) {}
    static func warn(_ message: Message, _ category: String) {}
    static func notice(_ message: Message, _ category: String) {}
    static func error(_ message: Message, _ category: String) {}
}
struct OpusConfig {}
struct RtspHandshakeResult {}
struct BackendServerInfo {}
struct BackendStreamConfig {
    let audioConfiguration: Int32 = 0
    let remoteInputAesKey = [UInt8](), remoteInputAesIv = [UInt8]()
}
struct TransportPlatform { let configureAudioThread: @Sendable () -> Void = {} }
final class Sink: @unchecked Sendable {}
final class Counter: @unchecked Sendable {
    let count = Locked(0)
    func increment() { count.use { $0 += 1 } }
}
final class TelemetryCounters: Sendable {
    static let shared = TelemetryCounters()
    let audioReceiveFailedTotal = Counter()
}
final class RtpAudioReceiver: @unchecked Sendable {
    static let cat = "inert.audio", maxPacketSize = 1400
    let host: String, audioPort: UInt16
    var destAddr = sockaddr_storage(), destAddrLen: socklen_t = 0
    var fd: Int32 = -1
    var onReceiveFailed: (@Sendable (Int32) -> Void)?
    var receiveStarts = 0
    init(host: String = "inert", audioPort: UInt16 = 1, pingPayload: [UInt8] = [], audioPacketDuration: Int = 5,
         opusConfig: OpusConfig = OpusConfig(), audioConfig: Int32 = 0, audioEncryption: Bool = false,
         aesKey: [UInt8] = [], aesIvId: [UInt8] = [], sink: Sink? = nil, platform: TransportPlatform = TransportPlatform(),
         configureThread: @escaping @Sendable () -> Void = {}) { self.host = host; self.audioPort = audioPort }
    func startPing() throws { try openSocket() } // Ping scheduling deliberately inert.
    func startReceive() throws { receiveStarts += 1 } // Codec and receive loop covered separately.
    __SOCKET_METHODS__
}
protocol ConnectionEvents: Sendable { func audioFailed(_ detail: String) }
final class Events: ConnectionEvents, @unchecked Sendable {
    let failures = Locked<[String]>([])
    func audioFailed(_ detail: String) { failures.use { $0.append(detail) } }
}
final class NativeBackend: @unchecked Sendable {
    static let logCategory = "inert.backend"
    let stateLock = NSLock(), platform = TransportPlatform()
    var interrupted = false
    var audioReceiver: RtpAudioReceiver?, audioSink: Sink?
    func withState<T>(_ body: () -> T) -> T { stateLock.lock(); defer { stateLock.unlock() }; return body() }
    func adoptWhileConnecting(_ body: () -> Void) -> Bool { withState { guard !interrupted else { return false }; body(); return true } }
    __PIPELINE_METHODS__
}
@main struct Checks {
    static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ name: String) throws {
            guard value() else { throw NSError(domain: name, code: checks) }; checks += 1
        }
        ledger.use { $0.timeoutFails = true }
        let failed = RtpAudioReceiver()
        var refused = false
        do { try failed.openSocket() } catch EnetError.socketFailure { refused = true }
        try expect(refused && failed.fd == -1, "timeout failure refuses fd publication")
        try expect(ledger.use { $0.closes } == [703], "only unpublished audio socket closes")
        try expect(ledger.use { $0.binds.isEmpty && $0.timestamps.isEmpty && $0.timeouts == [703] }, "timeout failure precedes bind and timestamp enable")

        ledger.use { $0.timeoutFails = false }
        let valid = RtpAudioReceiver()
        try valid.openSocket()
        try expect(valid.fd == 704 && ledger.use { $0.binds } == [704], "successful audio timeout allows normal fd publication")
        try expect(ledger.use { $0.closes } == [703], "successful audio socket remains receiver owned")
        ledger.use { $0.family = AF_INET6 }
        let valid6 = RtpAudioReceiver()
        try valid6.openSocket()
        try expect(valid6.fd == 705 && ledger.use { $0.binds.last } == 705, "IPv6 bind also follows mandatory timeout")

        func start(_ backend: NativeBackend, _ events: Events) {
            backend.startAudioPing(audioPort: 1, pingPayload: [], audioEncryption: false,
                                   opusConfig: OpusConfig(), config: BackendStreamConfig(), host: "inert", events: events)
            backend.startAudioReceive(handshake: RtspHandshakeResult(), config: BackendStreamConfig(),
                                      server: BackendServerInfo(), host: "inert", events: events)
        }
        ledger.use { $0.timeoutFails = true }
        let backend = NativeBackend(), events = Events()
        backend.audioSink = Sink()
        start(backend, events)
        try expect(backend.audioReceiver == nil, "failed early ping receiver is released")
        try expect(events.failures.use { $0 } == ["audio transport initialization failed"], "one fixed nonfatal audio failure reaches event sink")
        try expect(TelemetryCounters.shared.audioReceiveFailedTotal.count.use { $0 } == 1, "failed early transport increments audio failure counter once")

        let disabled = NativeBackend(), disabledEvents = Events()
        start(disabled, disabledEvents)
        try expect(disabled.audioReceiver == nil && disabledEvents.failures.use { $0.isEmpty }, "deliberate no-sink configuration remains silent")

        ledger.use { $0.timeoutFails = false }
        let live = NativeBackend(), liveEvents = Events()
        live.audioSink = Sink()
        start(live, liveEvents)
        try expect(live.audioReceiver?.receiveStarts == 1 && liveEvents.failures.use { $0.isEmpty }, "successful ping reuses its receiver without a failure event")

        let stopped = NativeBackend(), stoppedEvents = Events()
        stopped.audioSink = Sink()
        ledger.use { $0.timeoutFails = true; $0.onTimeout = { stopped.withState { stopped.interrupted = true } } }
        start(stopped, stoppedEvents)
        ledger.use { $0.onTimeout = nil }
        try expect(stopped.audioReceiver == nil && stoppedEvents.failures.use { $0.isEmpty }, "concurrent stop suppresses stale startup failure event")
        try expect(TelemetryCounters.shared.audioReceiveFailedTotal.count.use { $0 } == 1, "no-sink success and cancellation do not count failures")
        let replaced = NativeBackend(), replacedEvents = Events(), replacement = RtpAudioReceiver()
        replaced.audioSink = Sink()
        ledger.use { $0.onTimeout = { replaced.withState { replaced.audioReceiver = replacement } } }
        start(replaced, replacedEvents)
        ledger.use { $0.onTimeout = nil }
        try expect(replaced.audioReceiver === replacement && replacedEvents.failures.use { $0.isEmpty }, "obsolete startup failure cannot clear a replacement receiver or emit its error")
        print("{\"status\":\"passed\",\"audioSocketStartupChecks\":\(checks),\"scope\":\"exact production audio socket and backend startup methods; inert syscalls/ping/codec/logging, no network or device\"}")
    }
}
'''
socket_fixture = socket_fixture.replace("__SOCKET_METHODS__", "\n".join(
    block(audio_socket, signature).replace("private static func", "static func", 1)
    for signature in ("func openSocket()", "private static func configureReceiveTimeout(")))
socket_fixture = socket_fixture.replace("__PIPELINE_METHODS__", "\n".join(
    block(pipeline, signature) for signature in ("func startAudioPing(", "func startAudioReceive(")))
with tempfile.TemporaryDirectory(prefix="knot-audio-socket-", dir="/tmp") as directory:
    temporary = Path(directory)
    source = temporary / "Checks.swift"
    source.write_text(socket_fixture)
    executable = temporary / "checks"
    argv = ["/usr/bin/swiftc", "-swift-version", "6", "-parse-as-library", "-O",
            "-module-cache-path", str(temporary / "module-cache"), str(source), "-o", str(executable)]
    print(json.dumps({"compileArgv": argv, "checksArgv": [str(executable)]}), flush=True)
    subprocess.run(argv, check=True)
    subprocess.run([str(executable)], check=True, timeout=30)
    print(json.dumps({"audioSocketFixtureSHA256": hashlib.sha256(socket_fixture.encode()).hexdigest(),
                      "productionSourceSHA256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                                 for path in (ENGINE / "Network/RtpAudioReceiver+Socket.swift",
                                                              ENGINE / "Session/NativeBackend+Pipeline.swift")}}))


# A fatal current replacement used to vanish while isReconnecting was true.
# Exercise the actual actor consumer, complete bounded episode, success suffix,
# ordered callback adapter and native cleanup with controlled inert await seams.
reconnect = (ENGINE / "Session/StreamSession+Reconnect.swift").read_text()
session_source = (ENGINE / "Session/StreamSession.swift").read_text()
events_source = (ENGINE / "Session/NativeConnectionEvents.swift").read_text()
terminate = block(reconnect, "package func handleHostTerminate(")
terminate_prefix = terminate[:terminate.index("        // The uplink is dead")]
selection_start = reconnect.index("        let fresh = makeBackend()")
selection_end = reconnect.index("        await MainActor.run {", selection_start)
selection = reconnect[selection_start:selection_end]
tail_start = reconnect.index("        await net.setRequestDeadline(nil)", selection_end)
tail_end = reconnect.index("    /// Actor-owned attempt state", tail_start)
attempt_tail = reconnect[tail_start:tail_end].rstrip()
# The closing brace belongs to reconnectInPlace; the fixture supplies its header.
assert attempt_tail.endswith("}")
attempt_tail = attempt_tail[:-1]
# Full production consumer wiring is checked in addition to executing slices.
assert "package var reconnectAttemptID: UUID?" in session_source
assert "package var reconnectAttemptFailure: Int32?" in session_source
assert "observeReconnectTermination(retiringSource: true)" in block(reconnect, "private func teardownConnectionForReconnect(")
assert selection.index("attemptID = UUID()") < selection.index("reconnectAttemptID = freshAttempt")
assert "try checkReconnectAttempt(freshAttempt, deadline: deadline)" in block(reconnect, "private func reconnectInPlace(")
assert "enqueueSessionEvent { await session.handleHostTerminate(code: code, from: backend) }" in events_source
success = block(reconnect, "if resumed {")
assert success.index("await MainActor.run") < success.index("guard reconnectAttemptIsHealthy(resumedAttempt)")
commit = success[success.index("guard reconnectAttemptIsHealthy(resumedAttempt)"):success.index("bridge?.emit(.reconnected)")]
assert "await " not in commit
assert "reconnectAttemptID = nil" in commit
teardown = block(reconnect, "private func teardownConnectionForReconnect()")
teardown = teardown[:teardown.index("        if let state = connectFlowState")] + "    }"
reconnect_fixture = r'''
import Foundation
import os

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func use<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
func wait(_ semaphore: DispatchSemaphore) { precondition(semaphore.wait(timeout: .now() + 5) == .success, "controlled schedule timed out") }
final class Resource: @unchecked Sendable {
    let cleanups = Locked(0)
    func stop() {}; func interrupt() {}; func close() {}; func requestIdrFrame() {}
    func setNegotiatedBitrateKbps(_ value: Int) {}
    func cleanup() { cleanups.use { $0 += 1 } }
}
final class Receiver: @unchecked Sendable {
    var onReceiveFailed: (@Sendable () -> Void)?
    func stop() {}
}
let stopHook = Locked<(@Sendable () -> Void)?>(nil)
let rearmHook = Locked<(@Sendable () -> Void)?>(nil)
final class NativeBackend: @unchecked Sendable {
    static let logCategory = "inert"
    let stateLock = NSLock(), teardownLock = NSRecursiveLock()
    var interrupted = false, inputReady = true
    var videoReceiver: Receiver?, videoSink: Resource?, audioSink: Resource?
    var enetChannel: Resource? = Resource(), rtspClient: Resource? = Resource()
    var audioReceiver: Resource?, inputBatcher: Resource?
    func withState<T>(_ body: () -> T) -> T { stateLock.lock(); defer { stateLock.unlock() }; return body() }
    func wire(receiver: Receiver, events: NativeConnectionEvents) { __VIDEO_FAILURE_CLOSURE__ }
    __BACKEND_METHODS__
    func requestIdrFrame() { withState { enetChannel }?.requestIdrFrame() }
}
typealias StreamingBackend = NativeBackend
enum StreamError: Error { case sessionFailed(Int32), hostTimedOut, hostUnreachable(String) }
struct TakeoverRequired: Error { let appID: Int }
enum StreamEvent { case connectionTerminated(errorCode: Int32, error: StreamError? = nil), reconnecting, reconnected }
enum DisconnectReason { case hostClosedClean, hostError }
enum Privacy { case `private`, `public` }
struct Message: ExpressibleByStringInterpolation {
    init(stringLiteral: String) {}; init(stringInterpolation: StringInterpolation) {}
    static func + (_ lhs: Message, _ rhs: Message) -> Message { Message(stringLiteral: "") }
    struct StringInterpolation: StringInterpolationProtocol {
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ value: String) {}
        mutating func appendInterpolation<T>(_ value: T, privacy: Privacy = .public) {}
    }
}
enum Diag {
    static func info(_ message: Message, _ category: String) { stopHook.use { $0 }?() }
    static func error(_ message: Message, _ category: String) {}
    static func notice(_ message: Message, _ category: String) {}
}
final class Counter: @unchecked Sendable {
    let value = Locked(0)
    func increment() { value.use { $0 += 1 } }
}
final class P2: @unchecked Sendable { func setDisconnectReason(_ reason: DisconnectReason) {} }
final class TelemetryCounters: Sendable {
    static let shared = TelemetryCounters()
    let p2 = P2(), reconnectTotal = Counter()
}
final class EpochSink: Sendable { func beginAttempt(_ id: UUID) {} }
final class Bridge: @unchecked Sendable {
    weak var session: StreamSession?
    let values = Locked<[String]>([])
    private var attemptID = UUID()
    private let sourceLock = NSLock()
    private var eventSource: ObjectIdentifier?
    private var terminationSource: ObjectIdentifier?
    private var terminationAttempt: UUID?
    private var terminationEventsRetired = true
    private var admittedTerminationCode: Int32?
    private var audioEventsQuiesced = false
    let publicEvents: EpochSink? = nil
    __BRIDGE_INTENT_METHODS__
    func emit(_ event: StreamEvent) {
        values.use { value in
            switch event {
            case .reconnected: value.append("reconnected")
            case .reconnecting: value.append("reconnecting")
            case .connectionTerminated: value.append("terminated")
            }
        }
    }
}
final class NativeConnectionEvents: @unchecked Sendable {
    static let logCategory = "inert"
    weak var bridge: Bridge?, backend: NativeBackend?
    private let sessionEvents = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    private let attempt: UUID
    private var isCurrent: Bool { bridge?.acceptsEvent(from: backend, attempt: attempt) ?? false }
    init(bridge: Bridge, backend: NativeBackend) {
        self.bridge = bridge; self.backend = backend; self.attempt = bridge.currentAttempt
    }
    private func emit(_ event: StreamEvent) { bridge?.emit(event) }
    __EVENT_METHODS__
    func drain() async { let tail = sessionEvents.withLock { $0 }; await tail?.value }
}
@MainActor final class Presentation {
    var values = [String?]()
    func showRecovery(_ value: String?) { values.append(value) }
}
final class Input: Sendable {
    func prepareForReplacement(attempt: UUID) {}; func rebind(to: NativeBackend, attempt: UUID) {}
    @MainActor func quiesce() {}; @MainActor func setReady(_ ready: Bool) {}
}
struct SyntheticClock: Sendable {
    let schedule: Schedule
    func sleep(_ duration: Duration) async throws { try Task.checkCancellation(); await schedule.sleep() }
}
actor NetworkClient {
    let schedule: Schedule
    let backend: NativeBackend
    let events: NativeConnectionEvents
    let probing: Bool
    var shutdowns = 0
    let clientUniqueID: String? = "synthetic"
    init(schedule: Schedule, backend: NativeBackend, events: NativeConnectionEvents, probing: Bool = false) {
        self.schedule = schedule; self.backend = backend; self.events = events; self.probing = probing
    }
    func setRequestDeadline(_ deadline: Date?) async {
        if !probing { await schedule.deadlineCleared(backend: backend, events: events) }
    }
    func fetchServerInfo() async throws -> ServerInfo {
        guard let id = await schedule.probeResult() else { throw StreamError.hostUnreachable("inert probe silence") }
        return ServerInfo(currentGameID: id)
    }
    func launch(appID: Int, config: StreamRequest) async throws -> LaunchResponse { await schedule.recordRequest("launch"); return LaunchResponse() }
    func resume(config: StreamRequest) async throws -> LaunchResponse { await schedule.recordRequest("resume"); return LaunchResponse() }
    func shutdown() { shutdowns += 1 }
}
struct ServerInfo: Sendable { let currentGameID: Int }
struct StreamRequest: Sendable {}
struct LaunchResponse: Sendable {}
struct DisconnectOnly: Sendable { var cancellation: Int? { nil } }
enum StreamAttempt {
    static func run<Value: Sendable>(until deadline: Date, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await operation() // Deadline transport is inert; production supplies its bounded probe deadline.
    }
}
struct BackendStreamConfig { let bitrate: Int32 = 20_000 }
actor Schedule {
    enum Mode: Sendable { case healthy, deadlineFatal, rearmFatal, notifyBeforeStop, stale, wake, cancel, taskCancel, allFatal }
    let mode: Mode
    weak var session: StreamSession?
    var backends = [NativeBackend](), resources = [Resource](), events = [NativeConnectionEvents]()
    var sleepCalls = 0, setupCount = 0, interruptedBeforeRelease: Bool?
    let callbackDone = DispatchSemaphore(value: 0), releaseStop = DispatchSemaphore(value: 0)
    var retainedReceiver: Receiver?
    init(_ mode: Mode) { self.mode = mode }
    var requests = [String](), probeCalls = 0
    func recordRequest(_ request: String) { requests.append(request) }
    func requestSnapshot() -> [String] { requests }
    func probeResult() async -> Int? { probeCalls += 1; return 42 }
    func setSession(_ session: StreamSession) { self.session = session }
    func sleep() {
        sleepCalls += 1
        if mode == .notifyBeforeStop && sleepCalls == 2 {
            stopHook.use { $0 = nil }; releaseStop.signal(); wait(callbackDone)
        }
    }
    func register(_ backend: NativeBackend, _ resource: Resource, _ event: NativeConnectionEvents) {
        // Production teardown must finish before another setup touches the sink.
        precondition(resources.allSatisfy { $0.cleanups.use { $0 } == 1 }, "replacement overlapped previous cleanup")
        backends.append(backend); resources.append(resource); events.append(event); setupCount += 1
    }
    func deadlineCleared(backend: NativeBackend, events: NativeConnectionEvents) async {
        let index = setupCount
        if mode == .allFatal || (mode == .deadlineFatal && index == 1) {
            backend.videoReceiver?.onReceiveFailed?(); await events.drain()
        } else if mode == .cancel && index == 1 {
            await session?.cancelCurrent()
        } else if mode == .taskCancel && index == 1 {
            withUnsafeCurrentTask { $0?.cancel() }
        } else if mode == .stale && index == 1 {
            // Even an already-queued adapter that passed its bridge gate is fenced.
            await session?.handleHostTerminate(code: -1, from: NativeBackend())
        } else if mode == .wake && index == 1 {
            await session?.handleHostTerminate(code: -1)
        } else if (mode == .rearmFatal || mode == .notifyBeforeStop) && index == 1 {
            let beforeStop = mode == .notifyBeforeStop
            let stopped = DispatchSemaphore(value: 0), receiver = backend.videoReceiver!
            let callbackDone = self.callbackDone, releaseStop = self.releaseStop
            let drained = DispatchSemaphore(value: 0)
            retainedReceiver = receiver
            rearmHook.use { hook in hook = {
                rearmHook.use { $0 = nil }
                if beforeStop { stopHook.use { hook in hook = { stopped.signal(); wait(releaseStop) } } }
                DispatchQueue.global().async { receiver.onReceiveFailed?(); callbackDone.signal() }
                if beforeStop { wait(stopped) } else { wait(callbackDone) }
                Task { await events.drain(); drained.signal() }
                wait(drained)
                if beforeStop { precondition(!backend.withState { backend.interrupted }, "failure must be retained before stop latch") }
            } }
        }
    }
    func stats() -> (Int, [Int], Int) { (setupCount, resources.map { $0.cleanups.use { $0 } }, sleepCalls) }
}
actor StreamSession {
    static let deadPeerTerminationCode: Int32 = -1, reconnectAttemptCap = 3
    static let reconnectWindowSeconds: TimeInterval = 30, hostEndProbeSeconds: TimeInterval = 1.5
    static let recoverableTerminationCodes: Set<Int32> = [Int32(bitPattern: 0x80030023), Int32(bitPattern: 0x80030013)]
    let reconnectServer: Int? = 1, reconnectAppID: Int? = 42
    var ownsHostSession = true, hostSessionClientID: String? = "synthetic"
    let schedule: Schedule, clock: SyntheticClock, bridge: Bridge?
    var backend = NativeBackend(), attemptID = UUID()
    var reconnectAttemptID: UUID?, reconnectAttemptFailure: Int32?
    var reconnectAttemptFailureHandled = false, reachedLiveState = true
    var lastReconnectTerminationCode: Int32?
    var isStreaming = true, stopInProgress = false, isReconnecting = false, reconnectAttempts = 0
    var lastReconnectError: StreamError?, normalTerminations = 0, publicInput: Input? = Input(), input: Input? = Input()
    var network: NetworkClient?
    var presentation: Presentation?
    nonisolated(unsafe) var frameWatchdogArmedAt: Double = 0
    nonisolated var uptimeSeconds: Double { rearmHook.use { $0 }?(); return 1 }
    init(schedule: Schedule, bridge: Bridge, presentation: Presentation) {
        self.schedule = schedule; self.clock = SyntheticClock(schedule: schedule); self.bridge = bridge; self.presentation = presentation
        bridge.setEventSource(backend, attempt: attemptID)
    }
    func refreshReconnectAsk() async {}
    func setWaitingForVideo(_ waiting: Bool) {}; func resetStallLatches() {}
    func makeBackend() -> NativeBackend { NativeBackend() }
    func makeNetwork(_ server: Int) -> NetworkClient {
        NetworkClient(schedule: schedule, backend: backend,
                      events: NativeConnectionEvents(bridge: bridge!, backend: backend), probing: true)
    }
    func checkAttempt(deadline: Date? = nil) throws {
        guard !Task.isCancelled, isStreaming, !stopInProgress else { throw CancellationError() }
    }
    __TERMINATE_PREFIX__
        normalTerminations += 1 // Ordinary-live handling is outside this regression's slice.
    }
    __ATTEMPT_METHODS__
    __EPISODE__
    __TEARDOWN__
    func reconnectInPlace(deadline: Date) async throws(TakeoverRequired) -> Bool {
        await refreshReconnectAsk()
        observeReconnectTermination()
        if await endReconnectAfterCurrentFailure(until: deadline) { return false }
        await teardownConnectionForReconnect()
        if await endReconnectAfterCurrentFailure(until: deadline) { return false }
        guard !Task.isCancelled, isStreaming, !stopInProgress else { return false }
        __SELECTION__
        let dec = Resource(), backendConfig = BackendStreamConfig()
        let receiver = Receiver(), events = NativeConnectionEvents(bridge: bridge!, backend: fresh)
        bridge?.setEventSource(fresh, attempt: freshAttempt)
        fresh.videoReceiver = receiver; fresh.videoSink = dec; fresh.wire(receiver: receiver, events: events)
        await schedule.register(fresh, dec, events)
        let net = NetworkClient(schedule: schedule, backend: fresh, events: events)
        network = net
        __ATTEMPT_TAIL__
    }
    func cancelCurrent() { isStreaming = false; stopInProgress = true; backend.stopConnection() }
    func stop(cause: DisconnectReason) async { cancelCurrent() }
    __END_CLOSED__
    func run() async { await runReconnectEpisode(code: -1, cause: "synthetic") }
    func state() -> (Bool, Int, Int32?) { (isReconnecting, normalTerminations, reconnectAttemptFailure) }
    func finalCleanup() { backend.stopConnection() }
}
__BUDGET__
@main struct Checks {
    static func main() async throws {
        var checks = 0
        func expect(_ value: Bool, _ name: String) { precondition(value, name); checks += 1 }
        for mode: Schedule.Mode in [.healthy, .deadlineFatal, .rearmFatal, .notifyBeforeStop, .stale, .wake, .cancel, .taskCancel, .allFatal] {
            let schedule = Schedule(mode), bridge = Bridge(), presentation = await MainActor.run { Presentation() }
            let session = StreamSession(schedule: schedule, bridge: bridge, presentation: presentation)
            bridge.session = session; await schedule.setSession(session)
            let before = TelemetryCounters.shared.reconnectTotal.value.use { $0 }
            await Task { await session.run() }.value
            let stats = await schedule.stats(), state = await session.state()
            let values = bridge.values.use { $0 }
            let banners = await MainActor.run { presentation.values }
            let succeeds = mode != .cancel && mode != .taskCancel && mode != .allFatal
            expect(values.filter { $0 == "reconnected" }.count == (succeeds ? 1 : 0), "only a healthy attempt emits one reconnected")
            expect(TelemetryCounters.shared.reconnectTotal.value.use { $0 } - before == (succeeds ? 1 : 0), "telemetry agrees with accepted attempts")
            expect(!state.0, "episode finishes its ownership")
            let retried = mode == .deadlineFatal || mode == .rearmFatal || mode == .notifyBeforeStop
            expect(stats.0 == (retried ? 2 : (mode == .allFatal ? 3 : 1)), "failure consumes remaining attempts instead of false success")
            expect(stats.1.dropLast().allSatisfy { $0 == 1 }, "old failed sinks clean exactly once before replacement")
            expect(banners.count == 2 && banners.first! == "Reconnecting…" && banners.last! == nil, "failed attempts do not hide/recreate recovery banner")
            if mode == .allFatal { expect(values == Array(repeating: "reconnecting", count: 4) + ["terminated"], "each failed attempt reasserts recovery without a false success") }
            if mode == .cancel || mode == .taskCancel { expect(stats.1 == [1], "cancel cleanup remains singular") }
            if succeeds {
                let live = await session.backend, liveAttempt = await session.attemptID
                _ = bridge.admitTermination(code: -1, from: live, attempt: liveAttempt)
                await session.handleHostTerminate(code: -1, from: live)
                expect(await session.state().1 == 1, "post-commit current failure follows ordinary live handling")
            }
            await session.finalCleanup()
            expect(await schedule.stats().1.allSatisfy { $0 == 1 }, "every synthetic sink cleaned exactly once")
            stopHook.use { $0 = nil }; rearmHook.use { $0 = nil }
        }
        print("{\"status\":\"passed\",\"reconnectFatalRaceChecks\":\(checks),\"scope\":\"production actor termination/success/bounded episode, event adapter, callback and native cleanup slices; inert network/deadline/watchdog schedules, no device\"}")
    }
}
'''
reconnect_fixture = reconnect_fixture.replace("__BRIDGE_INTENT_METHODS__", "\n".join(
    block(bridge, signature).replace("package ", "") for signature in (
        "package var currentAttempt:", "package func beginAttempt(", "package func setEventSource(",
        "package func acceptsEvent(", "package func admitTermination(", "package func terminationIntent(")))
reconnect_fixture = reconnect_fixture.replace("__VIDEO_FAILURE_CLOSURE__", block(pipeline, "receiver.onReceiveFailed ="))
reconnect_fixture = reconnect_fixture.replace("__BACKEND_METHODS__", "\n".join(
    block(backend, signature).replace("package func", "func", 1)
    for signature in ("package func stopConnection()", "package func interruptConnection()")))
reconnect_fixture = reconnect_fixture.replace("__EVENT_METHODS__", "\n".join(
    block(events_source, signature).replace("package func", "func", 1)
    for signature in ("private func enqueueSessionEvent(", "package func connectionTerminated(")))
reconnect_fixture = reconnect_fixture.replace("__TERMINATE_PREFIX__", terminate_prefix.replace("package func", "func", 1))
reconnect_fixture = reconnect_fixture.replace("__ATTEMPT_METHODS__", "\n".join(
    block(reconnect, signature).replace("package ", "") for signature in ("private func reconnectAttemptIsHealthy(",
                                                "private func checkReconnectAttempt(", "private func tearDownSlippedInReconnect(",
                                                "private func endReconnectAfterCurrentFailure(", "private func probeRunningAppID(",
                                                "private func retainReconnectTermination(", "private func observeReconnectTermination(",
                                                "package static func pcEndedSession(")))
reconnect_fixture = reconnect_fixture.replace("__END_CLOSED__", block(reconnect, "private func endStreamClosedByPC("))
reconnect_fixture = reconnect_fixture.replace("__EPISODE__", block(reconnect, "private func runReconnectEpisode("))
reconnect_fixture = reconnect_fixture.replace("__TEARDOWN__", teardown)
reconnect_fixture = reconnect_fixture.replace("__SELECTION__", selection)
reconnect_fixture = reconnect_fixture.replace("__ATTEMPT_TAIL__", attempt_tail)
reconnect_fixture = reconnect_fixture.replace("__BUDGET__", block(reconnect, "package struct ReconnectBudget").replace("package ", ""))
with tempfile.TemporaryDirectory(prefix="knot-reconnect-fatal-", dir="/tmp") as directory:
    temporary = Path(directory)
    source = temporary / "Checks.swift"
    source.write_text(reconnect_fixture)
    executable = temporary / "checks"
    argv = ["/usr/bin/swiftc", "-swift-version", "6", "-parse-as-library", "-O",
            "-module-cache-path", str(temporary / "module-cache"), str(source), "-o", str(executable)]
    print(json.dumps({"compileArgv": argv, "checksArgv": [str(executable)]}), flush=True)
    subprocess.run(argv, check=True, timeout=90)
    subprocess.run([str(executable)], check=True, timeout=30)
    print(json.dumps({"reconnectFatalFixtureSHA256": hashlib.sha256(reconnect_fixture.encode()).hexdigest(),
                      "productionSourceSHA256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                                 for path in (ENGINE / "Session/StreamSession.swift", ENGINE / "Session/StreamSession+Reconnect.swift",
                                                              ENGINE / "Session/NativeConnectionEvents.swift", ENGINE / "Session/NativeBackend.swift",
                                                              ENGINE / "Session/NativeBackend+Pipeline.swift")}}))



# Public recovery must become honest again if a replacement dies after its first
# decoded frame. Execute current production callback wiring, bridge fencing,
# ordered public event source, termination prefix and complete shell reducer.
# Only backend/video/presentation resources are inert; no sockets or media open.
import re

recovery_paths = {
    "reconnect": ENGINE / "Session/StreamSession+Reconnect.swift",
    "start": ENGINE / "Session/StreamSession+Start.swift",
    "bridge": ENGINE / "Session/StreamBridgeContext.swift",
    "events": ENGINE / "Session/SessionEventSource.swift",
    "public": ENGINE / "Session/StreamSession+Public.swift",
    "presentation": ROOT / "Sources/DeskBridgeApp/Streaming/DesktopRecoveryPresentation.swift",
}
recovery_sources = {key: path.read_text() for key, path in recovery_paths.items()}
recovery_terminate = block(recovery_sources["reconnect"], "package func handleHostTerminate(")
recovery_prefix = recovery_terminate[:recovery_terminate.index("        // The uplink is dead")] + "    }"
recovery_types = (ENGINE / "Models/Types.swift").read_text()
recovery_constants = "\n".join(re.findall(
    r"^    package static let (?:deadPeer|protectedContent|frameConversion|noVideoTraffic|noVideoFrame)TerminationCode[^\n]*",
    (ENGINE / "Session/StreamSession.swift").read_text() + "\n" +
    (ENGINE / "Session/StreamSession+FrameWatchdog.swift").read_text(), re.M))
assert len(recovery_constants.splitlines()) == 5
recovery_contract = "\n".join([
    (ENGINE / "Protocol/StreamSecurityPolicy.swift").read_text(),
    (ROOT / "Sources/DeskBridgeApp/DesktopSecurityGuidance.swift").read_text().replace("import GlimmerEngine\n", ""),
    block(recovery_types, "public enum StreamEvent:"),
    block(recovery_types, "public enum ConnectionQuality:"),
    block(recovery_types, "public enum StreamError:"),
    (ENGINE / "Models/StreamFailure.swift").read_text(),
    (ENGINE / "Models/StreamFailureCopy.swift").read_text(),
    "public enum StreamConnection {\n" + block((ENGINE / "Session/StreamConnection.swift").read_text(), "public enum Failure:") + "\n}",
    block((ENGINE / "Session/StreamSession+Attempt.swift").read_text(), "package struct TakeoverRequired:"),
    "public enum StreamInput { public enum Event: Sendable {} }",
])
recovery_fixture = r'''
import Foundation
__CONTRACT__
__PRESENTATION__
__EVENT_SOURCE__
final class NativeBackend: @unchecked Sendable {}
final class RecoveryInput: Sendable {
    func prepareForReplacement(attempt: UUID) {}
    @MainActor func setReady(_ ready: Bool) {}
}
final class StreamBridgeContext: @unchecked Sendable {
    private let sourceLock = NSLock()
    private var attemptID = UUID()
    private var eventSource: ObjectIdentifier?
    private var terminationSource: ObjectIdentifier?
    private var terminationAttempt: UUID?
    private var terminationEventsRetired = true
    private var admittedTerminationCode: Int32?
    private var audioEventsQuiesced = false
    let publicEvents: SessionEventSource?
    var eventContinuation: AsyncStream<StreamEvent>.Continuation?
    init(_ events: SessionEventSource) { publicEvents = events }
    __BRIDGE_METHODS__
}
@MainActor final class Video {
    var onHDRActiveChanged: ((Bool) -> Void)?
    var onFirstDecodedFrame: (() -> Void)?
}
@MainActor final class SessionPresentation { var firstFrame: () -> Void = {} }
struct SessionMedia { let video: Video; let presentation: SessionPresentation }
public final class StreamSession: @unchecked Sendable {
    __UPDATE__
    __CONSTANTS__
    let backend = NativeBackend()
    var bridge: StreamBridgeContext?
    var isStreaming = true, stopInProgress = false, isReconnecting = true
    var reconnectAttempts = 1
    var attemptID: UUID, reconnectAttemptID: UUID?, reconnectAttemptFailure: Int32?
    var reconnectAttemptFailureHandled = false
    var lastReconnectTerminationCode: Int32?
    var lastReconnectError: StreamError?
    let publicInput: RecoveryInput? = nil, input: RecoveryInput? = nil
    init(bridge: StreamBridgeContext, attempt: UUID) {
        self.bridge = bridge; attemptID = attempt; reconnectAttemptID = attempt
    }
    @MainActor __TERMINATION_PREFIX__
    @MainActor __RETAIN_TERMINATION__
    @MainActor __WIRE__
}
@main struct PublicRecoveryChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) throws {
            guard condition() else { throw NSError(domain: name, code: checks) }; checks += 1
        }
        func label(_ event: StreamEvent) -> String {
            switch event {
            case .firstFrame: "frame"
            case .reconnecting: "reconnecting"
            default: "unexpected"
            }
        }
        func collect(_ source: SessionEventSource) async -> [StreamSession.Update] {
            source.finish()
            var values: [StreamSession.Update] = []
            for await update in source.stream { values.append(update) }
            return values
        }
        let source = SessionEventSource(); _ = source.stream
        let bridge = StreamBridgeContext(source), attempt = UUID()
        let session = StreamSession(bridge: bridge, attempt: attempt)
        bridge.setEventSource(session.backend, attempt: attempt)
        let video = Video(), presentation = SessionPresentation()
        var deliveredFrames = 0
        presentation.firstFrame = { deliveredFrames += 1 }
        let media = SessionMedia(video: video, presentation: presentation)
        session.wireMediaCallbacks(setup: media, bridge: bridge, attempt: attempt)
        let failedFrame = video.onFirstDecodedFrame!
        bridge.emit(.reconnecting); failedFrame()
        _ = bridge.admitTermination(code: -1, from: session.backend, attempt: attempt)
        await session.handleHostTerminate(code: -1, from: session.backend)
        let retiredEpoch = bridge.currentAttempt
        try expect(retiredEpoch != attempt, "first current failure retires callback epoch")
        try expect(session.attemptID == attempt && session.reconnectAttemptID == attempt,
                   "callback fence preserves session and sticky-latch attempt IDs")
        try expect(session.reconnectAttemptFailure == -1, "current failure stays latched")
        try expect(!bridge.acceptsEvent(from: session.backend, attempt: attempt), "failed native callback attempt rejected")
        failedFrame()
        bridge.emit(.firstFrame, source: session.backend, attempt: attempt)
        try expect(deliveredFrames == 1, "late failed decoder frame never reaches presentation callback")
        _ = bridge.admitTermination(code: -1, from: session.backend, attempt: attempt)
        await session.handleHostTerminate(code: -1, from: session.backend)
        try expect(bridge.currentAttempt == retiredEpoch && session.reconnectAttemptFailure == -1,
                   "duplicate failure neither resets epoch nor replaces first failure")
        let next = UUID()
        session.attemptID = next; session.reconnectAttemptID = next; session.reconnectAttemptFailure = nil
        bridge.setEventSource(session.backend, attempt: next)
        session.wireMediaCallbacks(setup: media, bridge: bridge, attempt: next)
        video.onFirstDecodedFrame?()
        try expect(deliveredFrames == 2 && bridge.acceptsEvent(from: session.backend, attempt: next),
                   "next fresh attempt decoder and native callbacks accepted")
        let updates = await collect(source)
        try expect(updates.map { label($0.event) } == ["reconnecting", "frame", "reconnecting", "frame"],
                   "one failure reassertion and no late/duplicate public frame")
        try expect(updates[1].attemptID == attempt && updates[2].attemptID == retiredEpoch && updates[3].attemptID == next,
                   "ordered public updates retain actual epochs")
        var recovery = DesktopRecoveryPresentation()
        recovery.receive(updates[0].event); recovery.receive(updates[1].event)
        try expect(recovery.phase == .live && recovery.message == nil, "actual reducer is live after original frame")
        recovery.receive(updates[2].event)
        try expect(recovery.phase == .reconnecting && recovery.message != nil, "actual reducer restores recovery card after current failure")
        recovery.receive(updates[3].event)
        try expect(recovery.phase == .live && recovery.message == nil, "only next fresh frame clears recovery card")
        for mode in ["stale", "wake", "stopping", "stopped", "old-drain"] {
            let events = SessionEventSource(); _ = events.stream
            let bridge = StreamBridgeContext(events), id = UUID()
            let session = StreamSession(bridge: bridge, attempt: id)
            bridge.setEventSource(session.backend, attempt: id)
            let video = Video(), media = SessionMedia(video: video, presentation: SessionPresentation())
            session.wireMediaCallbacks(setup: media, bridge: bridge, attempt: id)
            bridge.emit(.reconnecting); video.onFirstDecodedFrame?()
            if mode == "stopping" { session.stopInProgress = true }
            if mode == "stopped" { session.isStreaming = false }
            if mode == "old-drain" { session.reconnectAttemptID = nil }
            let producer: NativeBackend? = mode == "wake" ? nil : (mode == "stale" ? NativeBackend() : session.backend)
            if let producer { _ = bridge.admitTermination(code: -1, from: producer, attempt: id) }
            await session.handleHostTerminate(code: -1, from: producer)
            try expect(bridge.currentAttempt == id && session.reconnectAttemptFailure == nil,
                       "\(mode) does not retire epoch or latch failure")
            let values = await collect(events)
            try expect(values.map { label($0.event) } == ["reconnecting", "frame"],
                       "\(mode) does not add a recovery reset")
        }
        print("{\"status\":\"passed\",\"publicRecoveryChecks\":\(checks),\"scope\":\"current production termination prefix, decoder callback wiring, bridge methods, public FIFO and complete shell reducer; inert backend/video only\"}")
    }
}
'''
recovery_fixture = recovery_fixture.replace("__CONTRACT__", recovery_contract)
recovery_fixture = recovery_fixture.replace("__PRESENTATION__", recovery_sources["presentation"])
recovery_fixture = recovery_fixture.replace("__EVENT_SOURCE__", recovery_sources["events"])
recovery_fixture = recovery_fixture.replace("__UPDATE__", block(recovery_sources["public"], "public struct Update:"))
recovery_fixture = recovery_fixture.replace("__CONSTANTS__", recovery_constants)
recovery_fixture = recovery_fixture.replace("__TERMINATION_PREFIX__", recovery_prefix)
recovery_fixture = recovery_fixture.replace("__RETAIN_TERMINATION__", block(reconnect, "private func retainReconnectTermination("))
recovery_fixture = recovery_fixture.replace("__WIRE__", block(recovery_sources["start"], "package func wireMediaCallbacks("))
recovery_fixture = recovery_fixture.replace("__BRIDGE_METHODS__", "\n".join(
    block(recovery_sources["bridge"], signature) for signature in (
        "package var currentAttempt:", "package func beginAttempt(", "package func setEventSource(",
        "package func acceptsEvent(", "package func admitTermination(", "package func terminationIntent(", "package func emit(")))
recovery_fixture = recovery_fixture.replace("package ", "").replace("import GlimmerEngine\n", "")
with tempfile.TemporaryDirectory(prefix="knot-public-recovery-", dir="/tmp") as directory:
    temporary = Path(directory)
    source = temporary / "Checks.swift"
    source.write_text(recovery_fixture)
    executable = temporary / "checks"
    argv = ["/usr/bin/swiftc", "-swift-version", "6", "-parse-as-library", "-O",
            "-module-cache-path", str(temporary / "module-cache"), str(source), "-o", str(executable)]
    print(json.dumps({"compileArgv": argv, "checksArgv": [str(executable)]}), flush=True)
    subprocess.run(argv, check=True, timeout=90)
    subprocess.run([str(executable)], check=True, timeout=30)
    print(json.dumps({"publicRecoveryFixtureSHA256": hashlib.sha256(recovery_fixture.encode()).hexdigest(),
                      "productionSourceSHA256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                                 for path in recovery_paths.values()}}))


# Keep host intent while recovering: actual pinned Sunshine 0x80030023 can mean
# its app was Force Stopped. Execute the same bounded episode/probe/PC-ended
# decision plus actual next-serverinfo gate and /resume-versus-/launch selector.
# Controller revocation below runs the real input-owner methods against inert
# actuator/battery/release recorders; no hardware or real transport is touched.
lifecycle_source = (ENGINE / "Session/StreamSession+Lifecycle.swift").read_text()
inbound_source = (ENGINE / "Network/EnetControlChannel+Inbound.swift").read_text()
input_attempts = (ENGINE / "Input/StreamInput+Attempts.swift").read_text()
input_source = (ENGINE / "Input/StreamInput.swift").read_text()
first_failure = block(reconnect, "private func retainReconnectTermination(")
assert first_failure.index("publicInput?.prepareForReplacement(attempt: attemptID)") < first_failure.index("bridge?.beginAttempt(UUID())")
assert first_failure.index("DispatchQueue.main.async") < first_failure.index("bridge?.beginAttempt(UUID())")
assert "lastReconnectError = .sessionFailed(code)" in first_failure
assert "if reconnectAttemptFailure == nil," in block(reconnect, "private func reconnectInPlace(")
assert "endReconnectAfterCurrentFailure(until: budget.deadline())" in block(reconnect, "private func runReconnectEpisode(")
policy_fixture = reconnect_fixture[:reconnect_fixture.index("@main struct Checks")]
policy_fixture = policy_fixture.replace("final class NativeBackend: @unchecked Sendable {", """
final class Terminator {
    var onTerminated: ((Int32) -> Void)?
    __PARSE_TERMINATION__
}
final class NativeBackend: @unchecked Sendable {
    func hostTermination(_ code: Int32, events: NativeConnectionEvents) {
        let enet = Terminator()
        __HOST_TERMINATION__
        enet.onTerminated?(code)
    }
""", 1)
policy_fixture = policy_fixture.replace("__PARSE_TERMINATION__", block(inbound_source, "func parseTerminationCode("))
policy_fixture = policy_fixture.replace("__HOST_TERMINATION__", block(pipeline, "enet.onTerminated ="))
input_start = policy_fixture.index("final class Input: Sendable {")
input_end = policy_fixture.index("struct SyntheticClock:", input_start)
input_fixture = r'''
let inputTrace = Locked<[String]>([])
final class Actuator: @unchecked Sendable {
    let stops = Locked(0)
    func stopAll(reason: String) { stops.use { $0 += 1 }; inputTrace.use { $0.append(reason) } }
    func streamActivated(appActive: Bool) {}; func streamActivated(backend: NativeBackend) {}
    func setOwnership(_ focused: Bool) {}
}
final class Battery: @unchecked Sendable { let pauses = Locked(0); func pause() { pauses.use { $0 += 1 } } }
struct Snapshot { var ready = false, focused = false; var acceptEventsAfter: Double = 0 }
final class Releases { func releaseAll(connectionLost: Bool) {} }
final class InputCore: @unchecked Sendable {
    let lock = NSLock(), releases = Releases()
    var snapshot = Snapshot(), backend: NativeBackend?
    var pendingArrivals = [Int](), current = [Int](), buttons = [Int](), analogs = [Int]()
    func withLock<T>(_ operation: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return operation() }
}
struct Rearm { mutating func suppressHeld() {} }
struct Registration { var announced = true, rearm = Rearm(); let identity = 1 }
final class Input: @unchecked Sendable {
    enum Event { case controllersActive(Bool) }
    let core = InputCore(), haptics = Actuator(), motion = Actuator(), battery = Battery()
    var terminal = false, activeAttempt: UUID?, rearmOnActivation = false, focused = true
    var registrations = [0: Registration()]
    var legacyReady = true
    func releaseOwnership() {}
    func emit(_ event: Event) { if case .controllersActive(let value) = event { inputTrace.use { $0.append(value ? "active" : "inactive") } } }
    func announce(_ identity: Int) {}; func scheduleReconciliation() {}
    func rebind(to backend: NativeBackend, attempt: UUID) { core.withLock { self.activeAttempt = attempt; core.backend = backend } }
    @MainActor func quiesce() {}; @MainActor func setReady(_ ready: Bool) { legacyReady = ready }
    __PREPARE_INPUT__
    __ACTIVATE_INPUT__
    func state() -> (Bool, Int, Int, Int) {
        core.withLock { (activeAttempt == nil && core.backend == nil && !core.snapshot.ready,
                         haptics.stops.use { $0 }, motion.stops.use { $0 }, battery.pauses.use { $0 }) }
    }
}
'''
input_fixture = input_fixture.replace("__PREPARE_INPUT__", block(input_attempts, "package func prepareForReplacement(").replace("package ", ""))
input_fixture = input_fixture.replace("__ACTIVATE_INPUT__", block(input_source, "func activate(_ value: Bool, attempt:"))
policy_fixture = policy_fixture[:input_start] + input_fixture + policy_fixture[input_end:]
policy_fixture = policy_fixture.replace("values.use { value in\n            switch event", "values.use { value in\n            switch event", 1)
policy_fixture = policy_fixture.replace("            attemptID = id\n", "            inputTrace.use { $0.append(\"epoch\") }\n            attemptID = id\n", 1)
policy_fixture = policy_fixture.replace("    let values = Locked<[String]>([])", "    let values = Locked<[String]>([])\n    let terminations = Locked<[(Int32, Int32?)]>([])", 1)
policy_fixture = policy_fixture.replace("            case .connectionTerminated: value.append(\"terminated\")", """            case .connectionTerminated(let code, let error):
                var errorCode: Int32?
                if case .sessionFailed(let actual)? = error { errorCode = actual }
                terminations.use { $0.append((code, errorCode)) }; value.append("terminated")""", 1)
policy_fixture = policy_fixture.replace("case healthy, deadlineFatal, rearmFatal, notifyBeforeStop, stale, wake, cancel, taskCancel, allFatal", "case healthy, deadlineFatal, rearmFatal, notifyBeforeStop, stale, wake, cancel, taskCancel, allFatal, hostForceStop, hostTakeover, hostRestartSilent, hostSameApp, hostDuringBackoff, hostFatalCode, duplicateCatch, probeCancel")
policy_fixture = policy_fixture.replace("    func probeResult() async -> Int? { probeCalls += 1; return 42 }", """    func probeResult() async -> Int? {
        probeCalls += 1
        if mode == .probeCancel { await session?.cancelCurrent(); return 0 }
        if mode == .hostRestartSilent { return nil }
        if mode == .hostForceStop || mode == .hostDuringBackoff { return 0 }
        if mode == .hostTakeover { return 7 }
        return 42
    }
    func policyStats() -> (Int, [String], Int) { (probeCalls, requests, setupCount) }
    func currentGameIDForAttempt() -> Int {
        if setupCount == 1 { return 42 }
        if mode == .hostForceStop || mode == .hostDuringBackoff || mode == .hostRestartSilent { return 0 }
        if mode == .hostTakeover { return 7 }
        return 42
    }
    func sendHostFailure(backend: NativeBackend, events: NativeConnectionEvents, duplicate: Bool = false) async {
        // The protected-content value is a supported fatal receive contract;
        // this does not claim pinned Sunshine emits it in the Force Stop path.
        let payload: [UInt8] = mode == .hostFatalCode || mode == .duplicateCatch
            ? [0x80, 0x0e, 0x93, 0x02] : [0x80, 0x03, 0x00, 0x23]
        let code = Terminator().parseTerminationCode(payload)
        backend.hostTermination(code, events: events)
        if duplicate { events.connectionTerminated(code: Int32(bitPattern: 0x80030023)) }
        await events.drain()
        await session?.assertImmediateInputRevocation()
    }
    func beforeConnectCatch(backend: NativeBackend, events: NativeConnectionEvents) async -> Bool {
        if mode == .duplicateCatch && setupCount == 1 {
            await sendHostFailure(backend: backend, events: events, duplicate: true); return true
        }
        return false
    }""", 1)
policy_fixture = policy_fixture.replace("    func sleep() {\n        sleepCalls += 1", """    func sleep() async {
        sleepCalls += 1
        if mode == .hostDuringBackoff && sleepCalls == 2 {
            await sendHostFailure(backend: backends[0], events: events[0])
        }""", 1)
policy_fixture = policy_fixture.replace("        let index = setupCount\n        if mode == .allFatal", """        let index = setupCount
        if index == 1 && [.hostForceStop, .hostTakeover, .hostRestartSilent, .hostSameApp, .hostFatalCode, .probeCancel].contains(mode) {
            await sendHostFailure(backend: backend, events: events); return
        }
        if mode == .hostDuringBackoff && index == 1 { return }
        if mode == .allFatal""", 1)
# This mode first fails the connect without a terminate, then delivers the host
# close during backoff. The post-backoff policy checkpoint must catch it.
policy_fixture = policy_fixture.replace("        network = net\n", """        network = net
        let pcAnswered = true
        do {
            try await observedLaunch(net: net, currentGameID: await schedule.currentGameIDForAttempt(), deadline: deadline)
            if await schedule.beforeConnectCatch(backend: fresh, events: events) {
                throw StreamError.hostUnreachable("generic inert connect failure after specific host code")
            }
            if await schedule.mode == .hostDuringBackoff && schedule.stats().0 == 1 {
                throw StreamError.hostUnreachable("inert connect failure before late host close")
            }
        } __CONNECT_CATCH__
""", 1)
# No actor isolation is crossed without an explicit await in the condition.
policy_fixture = policy_fixture.replace("if await schedule.mode == .hostDuringBackoff && schedule.stats().0 == 1", "if await schedule.shouldFailBeforeBackoff()")
policy_fixture = policy_fixture.replace("    func beforeConnectCatch(", "    func shouldFailBeforeBackoff() -> Bool { mode == .hostDuringBackoff && setupCount == 1 }\n    func beforeConnectCatch(", 1)
assert "try await observedLaunch(net: net, currentGameID:" in policy_fixture
actual_attempt = block(reconnect, "private func reconnectInPlace(")
catch_start = actual_attempt.index("        } catch {\n            Diag.notice(\"reconnect attempt failed:")
catch_end = actual_attempt.index("\n\n        // H5:", catch_start)
policy_fixture = policy_fixture.replace("__CONNECT_CATCH__", actual_attempt[catch_start + len("        } "):catch_end])
gate_start = reconnect.index("            if serverInfo.currentGameID != appID { ownsHostSession = false }")
gate_end = reconnect.index("            let launch = try await launchWithDeadline(", gate_start)
policy_methods = block(lifecycle_source, "private func launchWithoutCancellation(")
policy_methods += "\n" + block(reconnect, "package static func reconnectAttemptError(").replace("package ", "")
policy_methods += '''
    let hostDisposition = DisconnectOnly()
    func launchAndRecordOwnership(client: String?, appID: Int,
        operation: @escaping @Sendable () async throws -> LaunchResponse) async throws -> LaunchResponse {
        try await operation() // Ownership bookkeeping only; real request choice below.
    }
    func observedLaunch(net: NetworkClient, currentGameID: Int, deadline: Date) async throws {
        let serverInfo = ServerInfo(currentGameID: currentGameID), appID = 42
''' + reconnect[gate_start:gate_end] + '''
        _ = try await launchWithoutCancellation(network: net, appID: appID, config: StreamRequest(), info: serverInfo, deadline: deadline)
    }
    func assertImmediateInputRevocation() async {
        let state = publicInput!.state()
        precondition(state.0 && state.1 == 1 && state.2 == 1 && state.3 == 1, "real owner revokes input and actuators immediately")
        publicInput?.activate(false, attempt: attemptID) // Late feedback cannot deactivate twice.
        precondition(publicInput!.state().1 == 1, "stale deactivation is idempotent after owner revocation")
        let trace = inputTrace.use { $0 }
        precondition(trace.contains("inactive"), "owner publishes controllers inactive")
        precondition(trace.suffix(2) == ["inactive", "epoch"], "input revocation precedes callback epoch retirement")
        let inp = input
        await MainActor.run { precondition(inp?.legacyReady == false, "FIFO ready-false precedes next retry backoff") }
    }
'''
policy_fixture = policy_fixture.replace("    func run() async {", policy_methods + "\n    func run() async {", 1)
policy_fixture = policy_fixture.replace("        await schedule.register(fresh, dec, events)", "        publicInput?.activate(true, attempt: attemptID)\n        await schedule.register(fresh, dec, events)", 1)
policy_fixture += r'''
@main struct TerminationPolicyChecks {
    static func main() async {
        var checks = 0
        func expect(_ value: Bool, _ name: String) { precondition(value, name); checks += 1 }
        for mode: Schedule.Mode in [.hostForceStop, .hostTakeover, .hostRestartSilent, .hostSameApp, .hostDuringBackoff, .hostFatalCode, .duplicateCatch, .probeCancel, .deadlineFatal] {
            inputTrace.use { $0 = [] }
            let schedule = Schedule(mode), bridge = Bridge(), presentation = await MainActor.run { Presentation() }
            let session = StreamSession(schedule: schedule, bridge: bridge, presentation: presentation)
            bridge.session = session; await schedule.setSession(session)
            await Task { await session.run() }.value
            let stats = await schedule.policyStats(), state = await session.state()
            let values = bridge.values.use { $0 }, terminal = bridge.terminations.use { $0 }
            let resumes = mode == .hostRestartSilent || mode == .hostSameApp || mode == .deadlineFatal
            expect(stats.2 == (resumes ? 2 : 1), "host stop/takeover/fatal/cancel does not select another backend")
            expect(stats.1.first == "resume", "first connection follows actual resume selector")
            expect(stats.1.filter { $0 == "launch" }.count == (mode == .hostRestartSilent ? 1 : 0), "Force Stop never relaunches; silent restart may launch again")
            expect(values.filter { $0 == "reconnected" }.count == (resumes ? 1 : 0), "only policy-approved recovery commits success")
            expect(!state.0, "policy ends episode ownership")
            expect(stats.0 == ((mode == .deadlineFatal || mode == .hostFatalCode || mode == .duplicateCatch) ? 0 : 1), "dead-peer and fatal do not probe; recoverable host close probes once")
            if mode == .hostForceStop || mode == .hostTakeover || mode == .hostDuringBackoff {
                expect(terminal.count == 1 && terminal[0].0 == 0 && terminal[0].1 == nil, "PC-ended outcome is a clean close with no cancel/launch")
                expect(await session.ownsHostSession == false && session.hostSessionClientID == nil, "actual PC-ended method relinquishes host cancellation ownership")
            }
            if mode == .hostFatalCode || mode == .duplicateCatch {
                let fatal = Int32(bitPattern: 0x800E9302)
                expect(terminal.count == 1 && terminal[0].0 == fatal && terminal[0].1 == fatal, "first specific fatal survives duplicate and generic connect catch")
            }
            await session.finalCleanup()
            expect(await schedule.stats().1.allSatisfy { $0 == 1 }, "policy cleanup drains each sink once")
        }
        print("{\"status\":\"passed\",\"reconnectTerminationPolicyChecks\":\(checks),\"scope\":\"actual host parser/producer/ordered adapter/episode/probe/PC-ended decision/next serverinfo gate/request selector/connect catch and input owner methods; inert transport and actuator recorders only\"}")
    }
}
'''
# Read both actor-owned values through one isolated accessor.
policy_fixture = policy_fixture.replace("    func finalCleanup()", "    func ownershipReleased() -> Bool { !ownsHostSession && hostSessionClientID == nil }\n    func finalCleanup()", 1)
policy_fixture = policy_fixture.replace("await session.ownsHostSession == false && session.hostSessionClientID == nil", "await session.ownershipReleased()")
with tempfile.TemporaryDirectory(prefix="knot-reconnect-policy-", dir="/tmp") as directory:
    temporary = Path(directory)
    source = temporary / "Checks.swift"
    source.write_text(policy_fixture)
    executable = temporary / "checks"
    argv = ["/usr/bin/swiftc", "-swift-version", "6", "-parse-as-library", "-O",
            "-module-cache-path", str(temporary / "module-cache"), str(source), "-o", str(executable)]
    print(json.dumps({"compileArgv": argv, "checksArgv": [str(executable)]}), flush=True)
    subprocess.run(argv, check=True, timeout=90)
    subprocess.run([str(executable)], check=True, timeout=30)
    print(json.dumps({"reconnectPolicyFixtureSHA256": hashlib.sha256(policy_fixture.encode()).hexdigest(),
                      "productionSourceSHA256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                                 for path in (ENGINE / "Session/StreamSession.swift", ENGINE / "Session/StreamSession+Reconnect.swift",
                                                              ENGINE / "Session/StreamSession+Lifecycle.swift", ENGINE / "Session/NativeConnectionEvents.swift",
                                                              ENGINE / "Session/NativeBackend+Pipeline.swift", ENGINE / "Network/EnetControlChannel+Inbound.swift",
                                                              ENGINE / "Input/StreamInput.swift", ENGINE / "Input/StreamInput+Attempts.swift")}}))

# Admission is transport-scoped, independent of decoder epochs and delayed actor
# delivery. Reuse the actual episode/bridge/adapter, and both real native failure
# closures plus the actual ENet once latch. All scheduling/resources remain inert.
control_loop = (ENGINE / "Network/EnetControlChannel+ControlLoop.swift").read_text()
intent_fixture = policy_fixture[:policy_fixture.index("@main struct TerminationPolicyChecks")]
intent_fixture = intent_fixture.replace("final class Terminator {", '''typealias DiagMessage = Message
final class Terminator {
    static let logCategory = "inert-host-control"
    let lock = NSLock()
    var disconnected = false
    var notifiedTerminationCode: Int32?
    func withState<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
''' + block(control_loop, "func declarePeerDead("), 1)
intent_fixture = intent_fixture.replace("        enet.onTerminated?(code)", '''        let callback = enet.onTerminated
        enet.onTerminated = { value in hostDeliveries.use { $0 += 1 }; callback?(value) }
        enet.declarePeerDead(code: code, reason: "inert authenticated host termination")
        enet.declarePeerDead(code: code, reason: "duplicate same ENet producer")''', 1)
intent_fixture = intent_fixture.replace("final class NativeBackend: @unchecked Sendable {", "let hostDeliveries = Locked(0)\nfinal class NativeBackend: @unchecked Sendable {", 1)
intent_fixture = intent_fixture.replace("case healthy,", "case originalBackoff, originalRefresh, queuedRetirement, retiredOriginal, localThenPC, pcThenLocal, healthy,", 1)
intent_fixture = intent_fixture.replace("    func refreshReconnectAsk() async {}", "    func refreshReconnectAsk() async { await schedule.refresh() }", 1)
intent_fixture = intent_fixture.replace("    func run() async {", '''    func originalTransport() -> (NativeBackend, NativeConnectionEvents, UUID) {
        (backend, NativeConnectionEvents(bridge: bridge!, backend: backend), attemptID)
    }
    func staleDecisionCheck() async -> (Bool, Bool) {
        isReconnecting = true; reconnectAttemptID = attemptID
        _ = bridge?.admitTermination(code: Int32(bitPattern: 0x80030023), from: backend, attempt: attemptID)
        let expired = await endReconnectAfterCurrentFailure(until: .distantPast)
        let pending = !reconnectAttemptFailureHandled
        let closed = await endReconnectAfterCurrentFailure(until: Date().addingTimeInterval(2))
        return (!expired && pending, closed)
    }
    func holdConsumer(entered: DispatchSemaphore, release: DispatchSemaphore) { entered.signal(); wait(release) }
    func run() async {''', 1)
intent_fixture = intent_fixture.replace("    func setSession(_ session: StreamSession) { self.session = session }", '''    var original: (NativeBackend, NativeConnectionEvents, UUID)?
    func setSession(_ session: StreamSession) async {
        self.session = session; original = await session.originalTransport()
    }
    func fireOriginal(retireBeforeDelivery: Bool = false, retireBeforeAdmission: Bool = false) async {
        let (backend, events, attempt) = original!
        let bridge = events.bridge!
        if retireBeforeAdmission { _ = bridge.terminationIntent(from: backend, attempt: attempt, retiring: true) }
        if retireBeforeDelivery {
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), session = self.session!
            Task.detached { await session.holdConsumer(entered: entered, release: release) }; wait(entered)
            backend.hostTermination(Int32(bitPattern: 0x80030023), events: events)
            precondition(bridge.terminationIntent(from: backend, attempt: attempt, retiring: true) == Int32(bitPattern: 0x80030023), "admitted intent survives atomic retirement")
            release.signal()
        } else {
            backend.hostTermination(Int32(bitPattern: 0x80030023), events: events)
        }
        await events.drain()
    }
    func refresh() async {
        await Task.yield() // Actual route provider suspends on MainActor.
        if mode == .originalRefresh { await fireOriginal() }
        if mode == .retiredOriginal { await fireOriginal(retireBeforeAdmission: true) }
    }''', 1)
intent_fixture = intent_fixture.replace("        sleepCalls += 1\n", '''        sleepCalls += 1
        if sleepCalls == 1 && mode == .originalBackoff { await fireOriginal() }
        if sleepCalls == 1 && mode == .queuedRetirement { await fireOriginal(retireBeforeDelivery: true) }
''', 1)
intent_fixture = intent_fixture.replace("        probeCalls += 1\n", '''        probeCalls += 1
        if [.originalBackoff, .originalRefresh, .queuedRetirement, .localThenPC, .pcThenLocal].contains(mode) { return 0 }
''', 1)
intent_fixture = intent_fixture.replace("        let index = setupCount\n", '''        let index = setupCount
        if index == 1 && (mode == .localThenPC || mode == .pcThenLocal) {
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), session = self.session!
            Task.detached { await session.holdConsumer(entered: entered, release: release) }; wait(entered)
            let receiver = backend.videoReceiver!
            if mode == .localThenPC {
                stopHook.use { hook in hook = {
                    stopHook.use { $0 = nil }
                    backend.hostTermination(Int32(bitPattern: 0x80030023), events: events)
                } }
                receiver.onReceiveFailed?()
            } else {
                stopHook.use { hook in hook = { stopHook.use { $0 = nil }; receiver.onReceiveFailed?() } }
                backend.hostTermination(Int32(bitPattern: 0x80030023), events: events)
            }
            release.signal(); await events.drain()
            let retained = await session.state().2
            precondition(retained == Int32(bitPattern: 0x80030023), "authenticated PC reason outranks local video failure in either order")
            return
        }
''', 1)
# Bind the inert prelude to the complete production retirement/check order.
actual_rebuild = block(reconnect, "private func reconnectInPlace(")
assert actual_rebuild.index("await refreshReconnectAsk()") < actual_rebuild.index("observeReconnectTermination()")
assert actual_rebuild.index("observeReconnectTermination()") < actual_rebuild.index("await teardownConnectionForReconnect()")
actual_teardown = block(reconnect, "private func teardownConnectionForReconnect(")
assert actual_teardown.index("await MainActor.run") < actual_teardown.index("observeReconnectTermination(retiringSource: true)") < actual_teardown.index("backend.stopConnection()")
assert "await " not in actual_teardown[actual_teardown.index("observeReconnectTermination(retiringSource: true)"):actual_teardown.index("backend.stopConnection()")]
assert actual_rebuild.index("await teardownConnectionForReconnect()") < actual_rebuild.index("endReconnectAfterCurrentFailure(until: deadline)", actual_rebuild.index("await teardownConnectionForReconnect()")) < actual_rebuild.index("let fresh = makeBackend()")
intent_fixture += r'''
@main struct TransportIntentChecks {
    static func main() async {
        var checks = 0
        func expect(_ value: Bool, _ name: String) { precondition(value, name); checks += 1 }
        for mode: Schedule.Mode in [.originalBackoff, .originalRefresh, .queuedRetirement, .retiredOriginal, .localThenPC, .pcThenLocal] {
            inputTrace.use { $0 = [] }; hostDeliveries.use { $0 = 0 }
            let schedule = Schedule(mode), bridge = Bridge(), presentation = await MainActor.run { Presentation() }
            let session = StreamSession(schedule: schedule, bridge: bridge, presentation: presentation)
            bridge.session = session; await schedule.setSession(session)
            await session.run()
            let stats = await schedule.policyStats(), values = bridge.values.use { $0 }
            let original = mode == .originalBackoff || mode == .originalRefresh || mode == .queuedRetirement
            let retired = mode == .retiredOriginal
            expect(stats.2 == (original ? 0 : 1), "original PC close is resolved before replacement selection")
            expect(stats.0 == (retired ? 0 : 1), "only admitted PC intent triggers one bounded probe")
            expect(stats.1 == (original ? [] : ["resume"]), "a Force Stop cannot issue a new launch")
            expect(values.contains("reconnected") == retired, "explicitly retired old producer cannot poison healthy replacement")
            expect(hostDeliveries.use { $0 } == 1, "ENet once latch permits one real host callback")
            expect(await session.ownershipReleased() == !retired, "PC stop relinquishes host cancellation ownership")
            await session.finalCleanup()
            expect(await schedule.stats().1.allSatisfy { $0 == 1 }, "real backend drain cleans every inert sink once")
        }
        let staleSchedule = Schedule(.originalBackoff), staleBridge = Bridge()
        let stalePresentation = await MainActor.run { Presentation() }
        let staleSession = StreamSession(schedule: staleSchedule, bridge: staleBridge, presentation: stalePresentation)
        staleBridge.session = staleSession; await staleSchedule.setSession(staleSession)
        let staleResult = await staleSession.staleDecisionCheck()
        expect(staleResult.0, "stale deadline does not consume unprobed PC intent")
        expect(staleResult.1, "fresh deadline from original budget resolves retained PC intent")
        expect(await staleSchedule.policyStats().0 == 1, "only valid refreshed deadline starts a probe")
        // A late callback from a fully retired source cannot alter either its
        // retained snapshot or a new transport's admission state.
        let bridge = Bridge(), old = NativeBackend(), fresh = NativeBackend(), oldID = UUID(), freshID = UUID()
        bridge.setEventSource(old, attempt: oldID)
        expect(bridge.admitTermination(code: -1, from: old, attempt: oldID), "current local reason admitted")
        bridge.beginAttempt(UUID())
        expect(bridge.admitTermination(code: Int32(bitPattern: 0x80030023), from: old, attempt: oldID), "PC intent survives decoder epoch fence")
        let code = bridge.terminationIntent(from: old, attempt: oldID, retiring: true)
        expect(code == Int32(bitPattern: 0x80030023), "retirement freezes authenticated reason")
        expect(!bridge.admitTermination(code: 0, from: old, attempt: oldID), "retired source rejected")
        expect(bridge.terminationIntent(from: old, attempt: oldID) == code, "retirement preserves admitted snapshot through drain")
        bridge.setEventSource(fresh, attempt: freshID)
        expect(!bridge.admitTermination(code: 0, from: old, attempt: oldID), "old source cannot affect new attempt")
        expect(bridge.terminationIntent(from: fresh, attempt: freshID) == nil, "fresh attempt starts without old host evidence")
        expect(bridge.admitTermination(code: Int32(bitPattern: 0x80030023), from: fresh, attempt: freshID), "fresh PC reason accepted")
        expect(bridge.admitTermination(code: Int32(bitPattern: 0x80030013), from: fresh, attempt: freshID), "duplicate PC reason admitted without replacement")
        expect(bridge.terminationIntent(from: fresh, attempt: freshID) == Int32(bitPattern: 0x80030023), "first explicit PC reason remains diagnostic owner")
        print("{\"status\":\"passed\",\"currentTransportIntentChecks\":\(checks),\"scope\":\"actual bridge admission/retirement, ordered native adapter, native video/control producers and ENet once latch, bounded episode/route refresh/drain/probe/request selector; inert resources only\"}")
    }
}
'''
intent_fixture = intent_fixture.replace("package ", "")
with tempfile.TemporaryDirectory(prefix="knot-current-intent-", dir="/tmp") as directory:
    temporary = Path(directory)
    source = temporary / "Checks.swift"; source.write_text(intent_fixture)
    executable = temporary / "checks"
    argv = ["/usr/bin/swiftc", "-swift-version", "6", "-parse-as-library", "-O", "-module-cache-path", str(temporary / "module-cache"), str(source), "-o", str(executable)]
    print(json.dumps({"compileArgv": argv, "checksArgv": [str(executable)]}), flush=True)
    subprocess.run(argv, check=True, timeout=90)
    subprocess.run([str(executable)], check=True, timeout=30)
    print(json.dumps({"currentTransportIntentFixtureSHA256": hashlib.sha256(intent_fixture.encode()).hexdigest(),
                      "productionSourceSHA256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                                 for path in (ENGINE / "Session/StreamSession.swift", ENGINE / "Session/StreamSession+Reconnect.swift", ENGINE / "Session/StreamBridgeContext.swift", ENGINE / "Session/NativeConnectionEvents.swift", ENGINE / "Session/NativeBackend+Pipeline.swift", ENGINE / "Network/EnetControlChannel+ControlLoop.swift")}}))

# A later attempt's real deadline/certificate failure supersedes earlier local
# link loss. The same-attempt explicit reason and unclassified cancellation stay
# intact. Execute actual resets/catch classifier/producers and public reducer.
deadline_source = (ENGINE / "Network/StreamAttempt.swift").read_text()
endpoint_source = (ENGINE / "Network/NetworkClient+Endpoints.swift").read_text()
diagnostic_fixture = recovery_fixture[:recovery_fixture.index("@main struct PublicRecoveryChecks")]
reset_start = reconnect.index("        attemptID = UUID()", reconnect.index("private func reconnectInPlace("))
reset_end = reconnect.index("        publicInput?.rebind", reset_start)
catch_body_start = reconnect.index("            observeReconnectTermination()", reconnect.index('Diag.notice("reconnect attempt failed:'))
catch_body_end = reconnect.index("            fresh.interruptConnection()", catch_body_start)
giveup_start = reconnect.index("        bridge?.emit(.connectionTerminated(errorCode: lastReconnectTerminationCode ?? code,")
giveup_end = reconnect.index("\n        await stop", giveup_start)
diagnostic_methods = "\n" + block(reconnect, "package static func reconnectAttemptError(").replace("package ", "")
diagnostic_methods += "\n    @MainActor " + block(reconnect, "private func observeReconnectTermination(")
diagnostic_methods += "\n    @MainActor func selectNextAttempt() {\n" + reconnect[reset_start:reset_end] + "        bridge?.setEventSource(backend, attempt: attemptID)\n    }\n"
diagnostic_methods += "    @MainActor func recordConnectCatch(_ error: Error, pcAnswered: Bool) {\n" + reconnect[catch_body_start:catch_body_end] + "    }\n"
diagnostic_methods += "    @MainActor func giveUp(code: Int32) {\n" + reconnect[giveup_start:giveup_end] + "\n    }\n"
diagnostic_fixture = diagnostic_fixture.replace("    @MainActor func handleHostTerminate(", diagnostic_methods + "    @MainActor func handleHostTerminate(", 1)
diagnostic_fixture += "\nenum DeadlineProducer {\n" + block(deadline_source, "package static func checkDeadline(").replace("package ", "") + "\n}\n"
diagnostic_fixture += "\nenum PairedFailureProducer {\n" + block(endpoint_source, "static func classifyPairedPathFailure(") + "\n" + block(endpoint_source, "static func isCertChange(") + "\n}\n"
diagnostic_fixture += r'''
@main struct DiagnosticScopeChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: Bool, _ name: String) { precondition(value, name); checks += 1 }
        for kind in ["timeout", "certificate", "cancellation"] {
            let events = SessionEventSource(); _ = events.stream
            let bridge = StreamBridgeContext(events), initial = UUID()
            let session = StreamSession(bridge: bridge, attempt: initial)
            bridge.setEventSource(session.backend, attempt: initial)
            _ = bridge.admitTermination(code: -1, from: session.backend, attempt: initial)
            await session.handleHostTerminate(code: -1, from: session.backend)
            session.recordConnectCatch(StreamError.hostUnreachable("same-attempt consequence"), pcAnswered: true)
            if case .sessionFailed(-1)? = session.lastReconnectError { expect(true, "same-attempt root retained") }
            else { preconditionFailure("same-attempt root lost") }
            session.selectNextAttempt()
            expect(session.reconnectAttemptFailure == nil && session.lastReconnectTerminationCode == -1, "next attempt clears only attempt latch")
            let laterError: Error
            if kind == "timeout" {
                do { try DeadlineProducer.checkDeadline(.distantPast); preconditionFailure("deadline producer drift") }
                catch { laterError = error }
            } else if kind == "certificate" {
                laterError = PairedFailureProducer.classifyPairedPathFailure("cert mismatch", hostName: "Synthetic PC")
            } else { laterError = CancellationError() }
            session.recordConnectCatch(laterError, pcAnswered: false)
            if kind == "cancellation" {
                expect(session.lastReconnectTerminationCode == -1, "nil classification preserves prior explicit evidence")
                if case .sessionFailed(-1)? = session.lastReconnectError { expect(true, "unclassified cancellation preserves diagnostic") }
                else { preconditionFailure("cancellation erased diagnostic") }
            } else {
                expect(session.lastReconnectTerminationCode == nil, "new classified attempt clears stale code")
                if kind == "timeout" {
                    if case .hostUnreachable? = session.lastReconnectError { expect(true, "later real deadline names unreachable host") }
                    else { preconditionFailure("later timeout masked") }
                } else {
                    if case .hostCertChanged? = session.lastReconnectError { expect(true, "later real certificate classifier names changed pin") }
                    else { preconditionFailure("later certificate masked") }
                }
            }
            session.giveUp(code: -1); events.finish()
            var received: StreamEvent?
            for await update in events.stream { received = update.event }
            var actual = DesktopRecoveryPresentation(), expected = DesktopRecoveryPresentation()
            actual.receive(received!)
            expected.receive(.connectionTerminated(errorCode: -1, error: session.lastReconnectError))
            expect(actual.status == expected.status && actual.message == expected.message, "public reducer receives current diagnostic")
        }
        print("{\"status\":\"passed\",\"reconnectDiagnosticScopeChecks\":\(checks),\"scope\":\"actual attempt resets/catch predicate/error classifier/deadline and paired-certificate producers/give-up FIFO and public reducer; inert transport only\"}")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="knot-reconnect-diagnostic-", dir="/tmp") as directory:
    temporary = Path(directory)
    source = temporary / "Checks.swift"; source.write_text(diagnostic_fixture)
    executable = temporary / "checks"
    argv = ["/usr/bin/swiftc", "-swift-version", "6", "-parse-as-library", "-O", "-module-cache-path", str(temporary / "module-cache"), str(source), "-o", str(executable)]
    print(json.dumps({"compileArgv": argv, "checksArgv": [str(executable)]}), flush=True)
    subprocess.run(argv, check=True, timeout=90)
    subprocess.run([str(executable)], check=True, timeout=30)
    print(json.dumps({"reconnectDiagnosticScopeFixtureSHA256": hashlib.sha256(diagnostic_fixture.encode()).hexdigest(),
                      "productionSourceSHA256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                                 for path in (ENGINE / "Session/StreamSession+Reconnect.swift", ENGINE / "Session/StreamBridgeContext.swift", ENGINE / "Network/StreamAttempt.swift", ENGINE / "Network/NetworkClient+Endpoints.swift", ROOT / "Sources/DeskBridgeApp/Streaming/DesktopRecoveryPresentation.swift")}}))

# Exercise the complete LIVE consumer (not its reconnect-only prefix), including
# its initial seed and real decoder callback. A clean PC close must not flash a
# reconnect card; failed decoder callbacks are fenced before the first await.
live_fixture = intent_fixture[:intent_fixture.index("@main struct TransportIntentChecks")]
live_handler = block(reconnect, "package func handleHostTerminate(").replace("package ", "")
live_fixture = live_fixture.replace(block(live_fixture, "func handleHostTerminate("), live_handler, 1)
live_fixture = live_fixture.replace("    func run() async {", "\n" + block(reconnect, "package static func reconnectCause(").replace("package ", "") + "\n" + block(reconnect, "package func runSelfInitiatedReconnect(").replace("package ", "") + "\n    func run() async {", 1)
live_fixture = live_fixture.replace("case originalBackoff,", "case livePCIdle, liveSameApp, livePCRestart, liveLocal, quiescePCStop, originalBackoff,", 1)
live_fixture = live_fixture.replace("final class Resource:", "let decodedFrames = Locked(0)\nlet quiesceHook = Locked<(@Sendable () -> Void)?>(nil)\nfinal class Resource:", 1)
live_fixture = live_fixture.replace("    let cleanups = Locked(0)", "    var onHDRActiveChanged: ((Bool) -> Void)?\n    var onFirstDecodedFrame: (() -> Void)?\n    let cleanups = Locked(0)", 1)
live_fixture = live_fixture.replace("case connectionTerminated(errorCode:", "case hdrActive(Bool), firstFrame, connectionTerminated(errorCode:", 1)
live_fixture = live_fixture.replace("    func emit(_ event: StreamEvent) {\n        values.use", "    func emit(_ event: StreamEvent, attempt: UUID? = nil) {\n        if let attempt, attempt != currentAttempt { return }\n        values.use", 1)
live_fixture = live_fixture.replace("            case .reconnected:", "            case .hdrActive: value.append(\"hdr\")\n            case .firstFrame: value.append(\"frame\")\n            case .reconnected:", 1)
live_fixture = live_fixture.replace("    var values = [String?]()", "    var firstFrame: () -> Void = {}\n    var values = [String?]()", 1)
live_fixture = live_fixture.replace("    @MainActor func quiesce() {}", "    @MainActor func quiesce() { quiesceHook.use { $0 }?() }", 1)
live_fixture = live_fixture.replace("actor StreamSession {", "struct SessionMedia { let video: Resource; let presentation: Presentation }\nactor StreamSession {", 1)
live_fixture = live_fixture.replace("    func originalTransport()", r'''
    var originalDecoder: Resource?
    @MainActor __LIVE_WIRE__
    func prepareLive() async {
        let decoder = Resource(), win = presentation!
        originalDecoder = decoder
        await MainActor.run {
            win.firstFrame = { decodedFrames.use { $0 += 1 } }
            self.wireMediaCallbacks(setup: SessionMedia(video: decoder, presentation: win), bridge: self.bridge!, attempt: self.attemptID)
        }
        publicInput?.rebind(to: backend, attempt: attemptID)
        publicInput?.activate(true, attempt: attemptID)
    }
    func delayedFailedFrame() async {
        let decoder = originalDecoder
        await MainActor.run { decoder?.onFirstDecodedFrame?() }
        precondition(decodedFrames.use { $0 } == 0, "failed original decoder callback cannot restore live state")
    }
    func runLive() async {
        await prepareLive()
        let events = NativeConnectionEvents(bridge: bridge!, backend: backend)
        if await schedule.mode == .liveLocal {
            let receiver = Receiver(); backend.videoReceiver = receiver; backend.videoSink = originalDecoder
            backend.wire(receiver: receiver, events: events); receiver.onReceiveFailed?()
        } else {
            backend.hostTermination(Int32(bitPattern: 0x80030023), events: events)
        }
        await events.drain()
    }
    func runSelfDuringQuiesce() async {
        await prepareLive()
        await runSelfInitiatedReconnect(cause: "inert route change")
    }
    func liveInputStops() -> Int { publicInput!.state().1 }
    func originalTransport()''', 1)
live_fixture = live_fixture.replace("__LIVE_WIRE__", block(recovery_sources["start"], "package func wireMediaCallbacks(").replace("package ", "").replace("StreamBridgeContext", "Bridge"))
# Capture actor-owned setup before entering the MainActor closure.
live_fixture = live_fixture.replace("        let decoder = Resource(), win = presentation!", "        let decoder = Resource(), win = presentation!, bridge = self.bridge!, attempt = attemptID", 1)
live_fixture = live_fixture.replace("bridge: self.bridge!, attempt: self.attemptID", "bridge: bridge, attempt: attempt", 1)
live_fixture = live_fixture.replace("        probeCalls += 1\n", "        probeCalls += 1\n        await session?.delayedFailedFrame()\n        if mode == .livePCIdle || mode == .quiescePCStop { return 0 }\n        if mode == .livePCRestart { return nil }\n", 1)
live_fixture = live_fixture.replace("        if setupCount == 1 { return 42 }", "        if mode == .livePCRestart { return 0 }\n        if setupCount == 1 { return 42 }", 1)
live_fixture = live_fixture.replace("        sleepCalls += 1\n", "        sleepCalls += 1\n        if mode == .liveLocal { await session?.delayedFailedFrame() }\n", 1)
live_fixture = live_fixture.replace("        await Task.yield() // Actual route provider suspends on MainActor.", r'''
        await Task.yield() // Actual route provider suspends on MainActor.
        if mode == .quiescePCStop {
            let (backend, events, attempt) = original!, bridge = original!.1.bridge!
            quiesceHook.use { hook in hook = {
                quiesceHook.use { $0 = nil }
                precondition(!bridge.acceptsEvent(from: backend, attempt: attempt), "self-reconnect fences original decoder before its first await")
                backend.hostTermination(Int32(bitPattern: 0x80030023), events: events)
                precondition(bridge.terminationIntent(from: backend, attempt: attempt) == Int32(bitPattern: 0x80030023), "PC intent during actual input quiesce is admitted before retirement")
            } }
        }''', 1)
live_fixture += r'''
@main struct LiveEntryChecks {
    static func main() async {
        var checks = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        for mode: Schedule.Mode in [.livePCIdle, .liveSameApp, .livePCRestart, .liveLocal, .quiescePCStop] {
            inputTrace.use { $0 = [] }; decodedFrames.use { $0 = 0 }; quiesceHook.use { $0 = nil }
            let schedule = Schedule(mode), bridge = Bridge(), presentation = await MainActor.run { Presentation() }
            let session = StreamSession(schedule: schedule, bridge: bridge, presentation: presentation)
            bridge.session = session; await schedule.setSession(session)
            if mode == .quiescePCStop { await session.runSelfDuringQuiesce() }
            else { await session.runLive() }
            let stats = await schedule.policyStats(), events = bridge.values.use { $0 }, banners = await MainActor.run { presentation.values }
            let closes = mode == .livePCIdle || mode == .quiescePCStop
            expect(stats.2 == (closes ? 0 : 1), "LIVE PC-ended decision or quiesce intent precedes replacement selection")
            expect(stats.1 == (closes ? [] : [mode == .livePCRestart ? "launch" : "resume"]), "complete LIVE handler preserves restart/local policy and never launches idle PC after explicit stop")
            expect(stats.0 == (mode == .liveLocal ? 0 : 1), "only authenticated PC closure probes once inside original budget")
            expect(events.filter { $0 == "reconnected" }.count == (closes ? 0 : 1), "only successful LIVE recovery commits")
            expect(await session.liveInputStops() == 1, "initial trigger revokes real input ownership exactly once")
            expect(decodedFrames.use { $0 } == 0, "actual delayed decoder callback remains fenced at suspended initial/probe/backoff seams")
            if mode == .livePCIdle {
                expect(events == ["terminated"] && banners.isEmpty, "clean PC-ended LIVE path never flashes reconnect event/card")
                expect(inputTrace.use { $0.filter { $0 == "epoch" }.count } == 1, "initial failed decoder epoch fences exactly once")
            }
            if mode == .quiescePCStop {
                expect(await session.ownershipReleased(), "quiesce-time host stop relinquishes cancellation ownership")
            }
            await session.finalCleanup()
            expect(await schedule.stats().1.allSatisfy { $0 == 1 }, "full LIVE closure cleans every replacement sink once")
        }
        print("{\"status\":\"passed\",\"completeLiveTerminationChecks\":\(checks),\"scope\":\"complete production LIVE termination consumer/episode, actual original decoder callback and input owner, actual quiesce await/retirement/drain, bounded probe/request choice; inert resources only\"}")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="knot-live-termination-", dir="/tmp") as directory:
    temporary = Path(directory)
    source = temporary / "Checks.swift"; source.write_text(live_fixture)
    executable = temporary / "checks"
    argv = ["/usr/bin/swiftc", "-swift-version", "6", "-parse-as-library", "-O", "-module-cache-path", str(temporary / "module-cache"), str(source), "-o", str(executable)]
    print(json.dumps({"compileArgv": argv, "checksArgv": [str(executable)]}), flush=True)
    subprocess.run(argv, check=True, timeout=90)
    subprocess.run([str(executable)], check=True, timeout=30)
    print(json.dumps({"completeLiveTerminationFixtureSHA256": hashlib.sha256(live_fixture.encode()).hexdigest(),
                      "productionSourceSHA256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in (ENGINE / "Session/StreamSession+Reconnect.swift", ENGINE / "Session/StreamSession+Start.swift", ENGINE / "Session/StreamBridgeContext.swift")}}))

# Compile complete ENet producers as part of the mandatory media lifecycle gate.
subprocess.run([sys.executable, str(ROOT / "scripts/tests/test_enet_termination.py")], check=True, timeout=150)

# Defensive direct episode cancellation and actual stop/waiting shell behavior.
# Real Wake producer ownership is exercised separately with two controlled
# handoff barriers below; it must discard canceled or superseded verdicts.
wake_source = (ENGINE / "Session/StreamSession+Wake.swift").read_text()
watchdog_source = (ENGINE / "Session/StreamSession+FrameWatchdog.swift").read_text()
handoff_fixture = live_fixture[:live_fixture.index("@main struct LiveEntryChecks")]
handoff_fixture = handoff_fixture.replace("case livePCIdle,", "case defensiveCanceledEpisode, stopInitialProbe, waitingPCIdle, waitingSameApp, selfEntryPC, livePCIdle,", 1)
handoff_fixture = handoff_fixture.replace("enum DisconnectReason { case hostClosedClean, hostError }", "enum DisconnectReason { case hostClosedClean, hostError, systemSleep }", 1)
handoff_fixture = handoff_fixture.replace("    let p2 = P2(), reconnectTotal = Counter()", "    let p2 = P2(), reconnectTotal = Counter(), wakeTotal = Counter()", 1)
# Rename the actual public contract in this combined fixture so the independent
# inert transport enum remains small, while presentation executes its real code.
shell_contract = recovery_contract.replace(block(recovery_contract, "package struct TakeoverRequired:"), "")
shell_contract = shell_contract.replace("StreamEvent", "ShellStreamEvent").replace("StreamError", "ShellStreamError").replace("package ", "")
shell_presentation = recovery_sources["presentation"].replace("import GlimmerEngine\n", "").replace("StreamEvent", "ShellStreamEvent").replace("StreamError", "ShellStreamError")
handoff_fixture = handoff_fixture.replace("import os\n", "import os\n" + shell_contract + "\n" + shell_presentation, 1)
other_constants = "\n".join(line.replace("package ", "") for line in recovery_constants.splitlines() if "deadPeerTerminationCode" not in line)
handoff_fixture = handoff_fixture.replace("actor StreamSession {", "actor StreamSession {\n" + other_constants, 1)
handoff_fixture = handoff_fixture.replace("case hdrActive(Bool), firstFrame,", "case stopped, waitingForVideo(Bool), hdrActive(Bool), firstFrame,", 1)
handoff_fixture = handoff_fixture.replace("    let values = Locked<[String]>([])", "    let values = Locked<[String]>([])\n    let shell = Locked(DesktopRecoveryPresentation())\n    let shellPhases = Locked<[String]>([])", 1)
handoff_fixture = handoff_fixture.replace("        if let attempt, attempt != currentAttempt { return }\n        values.use", r'''
        if let attempt, attempt != currentAttempt { return }
        let publicEvent: ShellStreamEvent
        switch event {
        case .stopped: publicEvent = .stopped
        case .waitingForVideo(let value): publicEvent = .waitingForVideo(value)
        case .hdrActive(let value): publicEvent = .hdrActive(value)
        case .firstFrame: publicEvent = .firstFrame
        case .reconnecting: publicEvent = .reconnecting
        case .reconnected: publicEvent = .reconnected
        case .connectionTerminated(let code, let error):
            let typed: ShellStreamError?
            switch error {
            case .sessionFailed(let value)?: typed = .sessionFailed(value)
            case .hostTimedOut?: typed = .hostTimedOut
            case .hostUnreachable(let value)?: typed = .hostUnreachable(value)
            case nil: typed = nil
            }
            publicEvent = .connectionTerminated(errorCode: code, error: typed)
        }
        let phase = shell.use { $0.receive(publicEvent); return String(describing: $0.phase) }
        shellPhases.use { $0.append(phase) }
        values.use''', 1)
handoff_fixture = handoff_fixture.replace("            case .hdrActive:", "            case .stopped: value.append(\"stopped\")\n            case .waitingForVideo(let value): value ? value.append(\"waiting-true\") : value.append(\"waiting-false\")\n            case .hdrActive:", 1)
# Avoid shadowing the recorded event array with the waiting payload.
handoff_fixture = handoff_fixture.replace("case .waitingForVideo(let value): value ? value.append(\"waiting-true\") : value.append(\"waiting-false\")", "case .waitingForVideo(let waiting): value.append(waiting ? \"waiting-true\" : \"waiting-false\")", 1)
waiting_method = block(watchdog_source, "package func setWaitingForVideo(").replace("package ", "")
handoff_fixture = handoff_fixture.replace("    func setWaitingForVideo(_ waiting: Bool) {}; func resetStallLatches() {}", "    var waitingForVideo = false\n    " + waiting_method + "\n    func resetStallLatches() { setWaitingForVideo(false) }", 1)
handoff_fixture = handoff_fixture.replace("final class NativeBackend: @unchecked Sendable {", r'''
struct InertWakeRTT { let rttMs: Double }
struct InertWakeHealth { let sinceLastAckMs: UInt32 }
struct InertWakeServices: Sendable { func stopWake() {} }
final class WakeHandoff: @unchecked Sendable {
    private let lock = NSLock(); private var used = false
    let passed = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    func pauseOnce() {
        guard lock.withLock({ if used { return false }; used = true; return true }) else { return }
        passed.signal(); wait(release)
    }
}
final class SelfEntryHook: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: (@MainActor @Sendable () -> Void)?
    func set(_ operation: @escaping @MainActor @Sendable () -> Void) { lock.withLock { self.operation = operation } }
    @MainActor func fire() {
        let operation = lock.withLock { let value = self.operation; self.operation = nil; return value }
        operation?()
    }
}
let wakeHandoff = WakeHandoff(), selfEntryHook = SelfEntryHook()
final class NativeBackend: @unchecked Sendable {
    func wakeReanchorAndPing() {}
    func estimatedRtt() -> InertWakeRTT? { nil }
    func enetHealth() -> InertWakeHealth? { nil }
''', 1)
handoff_fixture = handoff_fixture.replace("    func showRecovery(_ value: String?) { values.append(value) }", "    func showRecovery(_ value: String?) { values.append(value); if value != nil { selfEntryHook.fire() } }", 1)
wake_methods = "\n".join(block(wake_source, signature).replace("package ", "") for signature in (
    "package func teardownWakeObservers(", "package func handleSystemWake(", "private func startWakeProbe(", "private func finishWakeProbe("))
# One explicit inert scheduling seam at the existing guard → actor-handoff gap.
# The replacement uses the real stored producer and real cancellation statement.
needle = "            await self.finishWakeProbe(budgetMs: budgetMs, probeID: probeID, armedAttempt: armedAttempt)"
assert wake_methods.count(needle) == 1
wake_methods = wake_methods.replace(needle, "            wakeHandoff.pauseOnce()\n" + needle, 1)
handoff_fixture = handoff_fixture.replace("actor StreamSession {", """actor StreamSession {
    static let wakeProbeFloorMs: UInt64 = 50, wakeProbeCeilingMs: UInt64 = 50, wakeProbeRttMultiple: UInt64 = 1
    var wakeProbeTask: Task<Void, Never>?
    var wakeProbeID: UUID?
    let services = InertWakeServices()
    var stopCalls = 0
    var stopCause: DisconnectReason?
""" + wake_methods + r'''
    func runDefensiveCanceledEpisode() async {
        await prepareLive()
        withUnsafeCurrentTask { $0?.cancel() }
        await runReconnectEpisode(code: -1, cause: "defensive synthetic API cancellation", initialTermination: -1)
    }
    func startObservedWake() async -> Task<Void, Never> { await handleSystemWake(); return wakeProbeTask! }
    func cleanupState() -> (Bool, Bool, Bool, Int) { (isStreaming, isReconnecting, reconnectAttemptID == nil, stopCalls) }
    func beginWaiting() { bridge?.emit(.firstFrame); setWaitingForVideo(true) }
    func runWaitingLive() async { beginWaiting(); await runLive() }
    func runObservedSelf() async {
        await prepareLive()
        let bridge = self.bridge!, original = backend, attempt = attemptID
        let events = NativeConnectionEvents(bridge: bridge, backend: original), decoder = originalDecoder!
        selfEntryHook.set {
            decoder.onFirstDecodedFrame?()
            precondition(decodedFrames.use { $0 } == 0, "self-entry fences delayed old decoder before first suspension")
            precondition(bridge.terminationIntent(from: original, attempt: attempt) == nil, "self-entry never seeds a fake local termination")
            original.hostTermination(Int32(bitPattern: 0x80030023), events: events)
            precondition(bridge.terminationIntent(from: original, attempt: attempt) == Int32(bitPattern: 0x80030023), "real PC intent remains admitted after self-entry decoder fence")
        }
        await runSelfInitiatedReconnect(cause: "inert self-entry race")
    }
''', 1)
# Execute the active-session production stop prefix, including its actual
# waiting flag behavior; only unrelated native disposal is an inert stand-in.
actual_stop = block(lifecycle_source, "package func stop(cause:")
stop_prefix_start = actual_stop.index("        guard isStreaming || stopInProgress else { return }")
stop_prefix_end = actual_stop.index("        initialServerInfoTask?.cancel()", stop_prefix_start)
stop_prefix = actual_stop[stop_prefix_start:stop_prefix_end]
assert "waitingForVideo = false" in stop_prefix
handoff_stop = "func stop(cause: DisconnectReason) async {\n" + stop_prefix + """
        stopCalls += 1
        teardownWakeObservers()
        backend.stopConnection() // Inert native disposal, same terminal suffix below.
        bridge?.emit(.stopped)
        stopInProgress = false
    }"""
handoff_fixture = handoff_fixture.replace("func stop(cause: DisconnectReason) async { cancelCurrent() }", handoff_stop, 1)
handoff_fixture = handoff_fixture.replace("        probeCalls += 1\n", "        probeCalls += 1\n        if mode == .stopInitialProbe { await session?.stop(cause: .hostClosedClean); return 0 }\n        if mode == .waitingPCIdle || mode == .selfEntryPC { return 0 }\n", 1)
self_entry = block(reconnect, "package func runSelfInitiatedReconnect(")
assert self_entry.index("bridge?.beginAttempt(UUID())") < self_entry.index("await runReconnectEpisode(")
assert "initialTermination:" not in self_entry
assert "retiringSource:" not in self_entry
handoff_fixture += r'''
@main struct PreannouncementClosureChecks {
    static func main() async {
        var checks = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        for mode: Schedule.Mode in [.defensiveCanceledEpisode, .stopInitialProbe, .waitingPCIdle, .waitingSameApp, .selfEntryPC] {
            inputTrace.use { $0 = [] }; decodedFrames.use { $0 = 0 }
            let schedule = Schedule(mode), bridge = Bridge(), presentation = await MainActor.run { Presentation() }
            let session = StreamSession(schedule: schedule, bridge: bridge, presentation: presentation)
            bridge.session = session; await schedule.setSession(session)
            if mode == .defensiveCanceledEpisode {
                await Task { await session.runDefensiveCanceledEpisode() }.value
            } else if mode == .selfEntryPC { await session.runObservedSelf() }
            else { await session.runWaitingLive() }
            let state = await session.cleanupState(), events = bridge.values.use { $0 }, phases = bridge.shellPhases.use { $0 }
            let banners = await MainActor.run { presentation.values }, stats = await schedule.policyStats()
            expect(!state.1 && state.2, "all initial verdicts release reconnect ownership and attempt identity")
            expect(await session.liveInputStops() == 1, "initial input owner stops exactly once")
            if mode == .defensiveCanceledEpisode {
                expect(!state.0 && state.3 == 1, "defensive canceled API driver reaches one shared terminal stop")
                expect(events == ["terminated", "stopped"] && banners.allSatisfy { $0 == nil }, "preannouncement cancellation never shows false recovery UI")
                expect(stats.2 == 0 && stats.1.isEmpty, "defensive canceled API never selects or launches replacement")
            }
            if mode == .stopInitialProbe {
                expect(!state.0 && state.3 == 1, "stop during initial probe is not stopped twice")
                expect(events.filter { $0 == "terminated" }.isEmpty && !events.contains("reconnecting"), "stopped initial probe cannot emit duplicate terminal or recovery")
                expect(phases == ["live", "waiting", "ended"], "actual stop prefix clears waiting silently without restoring old live frame")
            }
            if mode == .waitingPCIdle {
                expect(events == ["frame", "waiting-true", "terminated", "stopped"], "actual PC-ended stop has no stray event between terminal and stopped")
                expect(Array(phases.prefix(3)) == ["live", "waiting", "ended"] && phases.dropFirst(2).allSatisfy { $0 == "ended" }, "actual shell stays ended through the real stop prefix and suffix")
                expect(banners.isEmpty && stats.1.isEmpty, "clean waiting PC-end has no card or host launch")
            }
            if mode == .waitingSameApp {
                expect(events.firstIndex(of: "reconnecting")! < events.firstIndex(of: "waiting-false")!, "surviving recovery announces before clearing old waiting")
                expect(!phases.dropFirst(2).contains("live"), "actual shell stays recovering/waiting until fresh replacement picture")
            }
            if mode == .selfEntryPC {
                expect(!state.0 && stats.2 == 0 && stats.1.isEmpty, "self-entry admits real PC stop before another backend or launch")
                expect(decodedFrames.use { $0 } == 0, "old self-entry callback cannot clear recovery")
                expect(inputTrace.use { $0.filter { $0 == "epoch" }.count } == 1, "self fence and later real PC intent share one decoder epoch retirement")
            }
            await session.finalCleanup()
        }
        print("{\"status\":\"passed\",\"preannouncementClosureChecks\":\(checks),\"scope\":\"defensive direct canceled API episode, complete LIVE episode/shared cleanup, actual active-session stop prefix/waiting policy/decoder/input and shell reducer; inert resources only\"}")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="knot-preannouncement-closure-", dir="/tmp") as directory:
    temporary = Path(directory)
    source = temporary / "Checks.swift"; source.write_text(handoff_fixture)
    executable = temporary / "checks"
    argv = ["/usr/bin/swiftc", "-swift-version", "6", "-parse-as-library", "-O", "-module-cache-path", str(temporary / "module-cache"), str(source), "-o", str(executable)]
    print(json.dumps({"compileArgv": argv, "checksArgv": [str(executable)]}), flush=True)
    subprocess.run(argv, check=True, timeout=90)
    subprocess.run([str(executable)], check=True, timeout=30)
    print(json.dumps({"preannouncementClosureFixtureSHA256": hashlib.sha256(handoff_fixture.encode()).hexdigest(),
                      "productionSourceSHA256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in (ENGINE / "Session/StreamSession+Reconnect.swift", ENGINE / "Session/StreamSession+Wake.swift", ENGINE / "Session/StreamSession+FrameWatchdog.swift", ENGINE / "Session/StreamSession+Start.swift", ENGINE / "Session/StreamBridgeContext.swift", ROOT / "Sources/DeskBridgeApp/Streaming/DesktopRecoveryPresentation.swift")}}))

# Real Wake verdicts have a generation owner. Park every producer after its
# guard, then choose both finish orders explicitly; no timer race decides order.
wake_owner_fixture = handoff_fixture[:handoff_fixture.index("@main struct PreannouncementClosureChecks")]
wake_gates = r'''
actor WakeGate {
    private var entered = false, released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releasedWaiters: [CheckedContinuation<Void, Never>] = []
    func enterAndWait() async {
        entered = true
        let waiters = enteredWaiters; enteredWaiters = []
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { releasedWaiters.append($0) }
    }
    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
    func release() {
        released = true
        let waiters = releasedWaiters; releasedWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}
actor WakeHandoff {
    private var gates: [UUID: WakeGate] = [:]
    private func gate(_ id: UUID) -> WakeGate {
        if let gate = gates[id] { return gate }
        let gate = WakeGate(); gates[id] = gate; return gate
    }
    func pause(probeID: UUID) async { await gate(probeID).enterAndWait() }
    func waitUntilEntered(_ id: UUID) async { await gate(id).waitUntilEntered() }
    func release(_ id: UUID) async { await gate(id).release() }
}
'''
wake_owner_fixture = wake_owner_fixture.replace(block(wake_owner_fixture, "final class WakeHandoff:"), wake_gates, 1)
wake_owner_fixture = wake_owner_fixture.replace("wakeHandoff.pauseOnce()", "await wakeHandoff.pause(probeID: probeID)", 1)
wake_owner_fixture = wake_owner_fixture.replace("struct InertWakeRTT", "let wakeHealthReads = Locked(0), wakeTelemetryReasonWrites = Locked(0)\nstruct InertWakeRTT", 1)
wake_owner_fixture = wake_owner_fixture.replace("    func enetHealth() -> InertWakeHealth? { nil }", "    var syntheticWakeHealth: InertWakeHealth?\n    func enetHealth() -> InertWakeHealth? { wakeHealthReads.use { $0 += 1 }; return withState { syntheticWakeHealth } }", 1)
wake_owner_fixture = wake_owner_fixture.replace("func setDisconnectReason(_ reason: DisconnectReason) {}", "func setDisconnectReason(_ reason: DisconnectReason) { wakeTelemetryReasonWrites.use { $0 += 1 } }", 1)
wake_owner_fixture = wake_owner_fixture.replace("    var wakeProbeTask: Task<Void, Never>?", "    var wakeTerminationEntries: [Bool] = []\n    var wakeProbeTask: Task<Void, Never>?", 1)
# This entry recorder observes the full production consumer without replacing it.
handler = block(wake_owner_fixture, "func handleHostTerminate(")
opening = handler.index("{")
recorded_handler = handler[:opening + 1] + "\n        wakeTerminationEntries.append(Task.isCancelled)" + handler[opening + 1:]
wake_owner_fixture = wake_owner_fixture.replace(handler, recorded_handler, 1)
wake_owner_fixture = wake_owner_fixture.replace("    func startObservedWake()", r'''
    var stopWindow: WakeGate?
    func pauseNextStop() -> WakeGate { let gate = WakeGate(); stopWindow = gate; return gate }
    func startTaggedWake() async -> (Task<Void, Never>, UUID) {
        await handleSystemWake()
        return (wakeProbeTask!, wakeProbeID!)
    }
    func wakeOwnerState() -> (UUID?, Bool, [Bool], ObjectIdentifier) {
        (wakeProbeID, wakeProbeTask != nil, wakeTerminationEntries, ObjectIdentifier(backend))
    }
    func invalidateWakeOwner() { teardownWakeObservers() }
    func configureWakeHealth(_ sinceLastAckMs: UInt32) { backend.withState { backend.syntheticWakeHealth = InertWakeHealth(sinceLastAckMs: sinceLastAckMs) } }
    func recoverIndependently() async { await runSelfInitiatedReconnect(cause: "inert independent transport replacement") }
    func defensiveProbeEntry(_ id: UUID, cancelDriver: Bool) async {
        // A deliberate package-entry contract check, separate from real producers.
        if cancelDriver { withUnsafeCurrentTask { $0?.cancel() } }
        await finishWakeProbe(budgetMs: 1, probeID: id, armedAttempt: attemptID)
    }
    func startObservedWake()''', 1)
# Production can suspend after this actual stop prefix and before observer
# invalidation. Model that window explicitly without adding a production await.
owner_stop = block(wake_owner_fixture, "func stop(cause:")
owner_stop_window = owner_stop.replace("        teardownWakeObservers()", "        if let gate = stopWindow { await gate.enterAndWait(); stopWindow = nil }\n        teardownWakeObservers()", 1)
assert owner_stop_window != owner_stop
wake_owner_fixture = wake_owner_fixture.replace(owner_stop, owner_stop_window, 1)
owner_finish = block(wake_source, "private func finishWakeProbe(")
assert owner_finish.index("guard !Task.isCancelled, wakeProbeID == probeID else { return }") < owner_finish.index("wakeProbeTask = nil")
assert block(wake_source, "package func teardownWakeObservers(").index("wakeProbeID = nil") < block(wake_source, "package func teardownWakeObservers(").index("wakeProbeTask?.cancel()")
assert "package var wakeProbeID: UUID?" in session_source
wake_owner_fixture += r'''
@main struct WakeOwnershipChecks {
    static func main() async {
        var checks = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func makeSession() async -> (StreamSession, Schedule, Bridge) {
            inputTrace.use { $0 = [] }; decodedFrames.use { $0 = 0 }; wakeHealthReads.use { $0 = 0 }; wakeTelemetryReasonWrites.use { $0 = 0 }
            let schedule = Schedule(.waitingSameApp), bridge = Bridge(), presentation = await MainActor.run { Presentation() }
            let session = StreamSession(schedule: schedule, bridge: bridge, presentation: presentation)
            bridge.session = session; await schedule.setSession(session); await session.prepareLive()
            return (session, schedule, bridge)
        }
        let releasedEarly = WakeGate()
        await releasedEarly.release(); await releasedEarly.release()
        await releasedEarly.enterAndWait(); await releasedEarly.waitUntilEntered()
        expect(true, "async gate remembers release before arrival and repeated release is idempotent")
        for oldFirst in [true, false] {
            let (session, schedule, bridge) = await makeSession()
            let (first, firstID) = await session.startTaggedWake(); await wakeHandoff.waitUntilEntered(firstID)
            let (replacement, replacementID) = await session.startTaggedWake(); await wakeHandoff.waitUntilEntered(replacementID)
            expect(first.isCancelled && firstID != replacementID, "real replacement cancels old producer and owns a fresh generation")
            let pending = await session.wakeOwnerState()
            expect(pending.0 == replacementID && pending.1 && pending.2.isEmpty, "both producer handoffs are parked with replacement handle intact")
            if oldFirst {
                await wakeHandoff.release(firstID); await first.value
                let discarded = await session.wakeOwnerState()
                expect(discarded.0 == replacementID && discarded.1, "old finish cannot clear replacement handle or generation")
                expect(discarded.2.isEmpty && bridge.values.use { $0 }.isEmpty, "discarded old finish never enters termination consumer")
                await wakeHandoff.release(replacementID); await replacement.value
            } else {
                await wakeHandoff.release(replacementID); await replacement.value
                let recovered = await session.wakeOwnerState(), before = await session.cleanupState()
                expect(before.0 && before.3 == 0 && recovered.2 == [false], "replacement alone completes uncancelled recovery before old release")
                await wakeHandoff.release(firstID); await first.value
                let after = await session.wakeOwnerState()
                expect(after.3 == recovered.3 && after.2 == [false], "late old finish cannot tear down or replace recovered transport")
            }
            let owner = await session.wakeOwnerState(), state = await session.cleanupState(), stats = await schedule.policyStats()
            expect(owner.0 == nil && !owner.1 && owner.2 == [false], "only current replacement consumes its handle and delivers one valid verdict")
            expect(state.0 && !state.1 && state.2 && state.3 == 0, "replacement recovery stays live with no stop or sticky episode")
            expect(stats.2 == 1 && stats.1 == ["resume"], "replacement alone selects and resumes exactly once")
            expect(bridge.values.use { $0 } == ["reconnecting", "reconnected"], "neither completion order emits a stale terminal outcome")
            expect(await session.liveInputStops() == 1, "discarded probe never revokes input of current recovery")
            await session.finalCleanup()
        }

        // An uncancelled sole probe still belongs to its arm-time transport,
        // even after another actual reconnect has committed a replacement.
        do {
            let (session, schedule, bridge) = await makeSession()
            let (old, oldID) = await session.startTaggedWake(); await wakeHandoff.waitUntilEntered(oldID)
            await session.recoverIndependently()
            let recovered = await session.wakeOwnerState(), before = await session.cleanupState()
            expect(!old.isCancelled && recovered.0 == oldID && recovered.1, "independent reconnect leaves old uncancelled wake owner parked")
            expect(before.0 && before.3 == 0 && recovered.2.isEmpty, "independent replacement completes without wake termination")
            await wakeHandoff.release(oldID); await old.value
            let after = await session.wakeOwnerState(), state = await session.cleanupState()
            expect(after.0 == nil && !after.1 && after.3 == recovered.3, "old current owner may consume only its finished handle, never the new backend")
            expect(wakeHealthReads.use { $0 } == 0 && after.2.isEmpty, "stale arm-time attempt cannot read new health or drive any terminate")
            expect(state.0 && state.3 == 0 && bridge.values.use { $0 } == ["reconnecting", "reconnected"], "late uncancelled verdict cannot tear down recovered session")
            expect(await schedule.policyStats().1 == ["resume"], "independent replacement is not relaunched by old wake")
            await session.finalCleanup()
        }
        // Non-nil healthy ACK liveness must remain a no-op, while a stale ACK
        // sample takes the existing bounded wake-recovery branch.
        for fresh in [true, false] {
            let (session, schedule, bridge) = await makeSession()
            await session.configureWakeHealth(fresh ? 0 : 10_000)
            let (probe, probeID) = await session.startTaggedWake(); await wakeHandoff.waitUntilEntered(probeID)
            await wakeHandoff.release(probeID); await probe.value
            let owner = await session.wakeOwnerState(), state = await session.cleanupState()
            expect(owner.0 == nil && !owner.1 && wakeHealthReads.use { $0 } == 1, "current owner consumes exactly one configured health sample")
            expect(owner.2 == (fresh ? [] : [false]), "fresh ACK does not terminate; stale ACK alone drives valid wake verdict")
            expect(state.0 && state.3 == 0 && bridge.values.use { $0 } == (fresh ? [] : ["reconnecting", "reconnected"]), "configured fresh/stale health preserves bounded existing recovery semantics")
            expect(await schedule.policyStats().1 == (fresh ? [] : ["resume"]), "healthy wake sends no launch; stale current wake resumes once")
            await session.finalCleanup()
        }
        // Actual observer teardown invalidates before cancellation; stale verdicts
        // cannot consume a newly armed generation while the session remains live.
        do {
            let (session, schedule, bridge) = await makeSession()
            let (first, firstID) = await session.startTaggedWake(); await wakeHandoff.waitUntilEntered(firstID)
            let (second, secondID) = await session.startTaggedWake(); await wakeHandoff.waitUntilEntered(secondID)
            await session.invalidateWakeOwner()
            let invalid = await session.wakeOwnerState()
            expect(invalid.0 == nil && !invalid.1 && first.isCancelled && second.isCancelled, "observer teardown invalidates ownership and cancels stored task")
            let (third, thirdID) = await session.startTaggedWake(); await wakeHandoff.waitUntilEntered(thirdID)
            await wakeHandoff.release(firstID); await wakeHandoff.release(secondID)
            await first.value; await second.value
            let untouched = await session.wakeOwnerState()
            expect(untouched.0 == thirdID && untouched.1 && untouched.2.isEmpty, "invalidated old finishes cannot clear rearmed generation")
            expect(bridge.values.use { $0 }.isEmpty && await session.liveInputStops() == 0, "invalidated old probes have no terminal or input effects")
            await wakeHandoff.release(thirdID); await third.value
            let state = await session.cleanupState()
            expect(state.0 && state.3 == 0, "only rearmed current generation may recover")
            expect(await schedule.policyStats().1 == ["resume"], "rearmed current producer resumes once")
            await session.finalCleanup()
        }
        // A full stop invalidates both parked producers before either can act.
        do {
            let (session, _, bridge) = await makeSession()
            let (first, firstID) = await session.startTaggedWake(); await wakeHandoff.waitUntilEntered(firstID)
            let (second, secondID) = await session.startTaggedWake(); await wakeHandoff.waitUntilEntered(secondID)
            await session.stop(cause: .hostClosedClean)
            await wakeHandoff.release(secondID); await wakeHandoff.release(firstID)
            await first.value; await second.value
            let owner = await session.wakeOwnerState(), state = await session.cleanupState()
            expect(owner.0 == nil && !owner.1 && owner.2.isEmpty, "stopped probe cannot consume handle or deliver stale verdict")
            expect(!state.0 && state.3 == 1 && bridge.values.use { $0 } == ["stopped"], "stopped probes cannot duplicate terminal or revive a stopped stream")
            await session.finalCleanup()
        }

        // Exercise the real lifecycle flags before observer invalidation. The
        // current producer is deliberately uncancelled throughout this window.
        do {
            let (session, _, bridge) = await makeSession()
            let (current, currentID) = await session.startTaggedWake(); await wakeHandoff.waitUntilEntered(currentID)
            let window = await session.pauseNextStop()
            let stopping = Task { await session.stop(cause: .hostClosedClean) }
            await window.waitUntilEntered()
            let before = await session.wakeOwnerState(), stoppedPrefix = await session.cleanupState()
            expect(!current.isCancelled && before.0 == currentID && before.1, "stop prefix suspends before canceling the still-owned current probe")
            expect(!stoppedPrefix.0 && stoppedPrefix.3 == 1, "actual stop prefix has already marked the session stopped")
            await wakeHandoff.release(currentID); await current.value
            let consumed = await session.wakeOwnerState()
            expect(consumed.0 == nil && !consumed.1 && consumed.2.isEmpty && wakeHealthReads.use { $0 } == 0 && wakeTelemetryReasonWrites.use { $0 } == 0, "uncancelled stopped owner cleans only its handle without health, telemetry or terminate effects")
            expect(bridge.values.use { $0 }.isEmpty, "stop suffix remains suspended while stopped verdict is discarded")
            expect(!current.isCancelled, "lifecycle rejection does not depend on task cancellation")
            await window.release(); await stopping.value
            let state = await session.cleanupState()
            expect(!state.0 && state.3 == 1 && bridge.values.use { $0 } == ["stopped"], "resumed stop finishes once after the stopped-owner window")
            await session.finalCleanup()
        }
        // Defensive entry checks deliberately call the actual actor consumer from
        // a fresh task; these are separate from real stored-producer schedules.
        for cancelDriver in [false, true] {
            let (session, _, bridge) = await makeSession()
            let (current, currentID) = await session.startTaggedWake(); await wakeHandoff.waitUntilEntered(currentID)
            let attemptedID = cancelDriver ? currentID : UUID()
            await Task { await session.defensiveProbeEntry(attemptedID, cancelDriver: cancelDriver) }.value
            let pending = await session.wakeOwnerState()
            expect(pending.0 == currentID && pending.1 && pending.2.isEmpty, "noncurrent generation or canceled entry cannot consume valid owner")
            expect(bridge.values.use { $0 }.isEmpty && await session.liveInputStops() == 0, "defensive rejected entry has no liveness side effects")
            await wakeHandoff.release(currentID); await current.value
            let state = await session.cleanupState()
            expect(state.0 && state.3 == 0, "valid current producer still recovers after rejected synthetic entry")
            await session.finalCleanup()
        }
        print("{\"status\":\"passed\",\"wakeProbeOwnershipChecks\":\(checks),\"scope\":\"actual Wake generation producer/replacement/finish/teardown and complete recovery; both handoffs use async continuation barriers for both orders, observer rearm and uncancelled stop-prefix window; separate defensive actor-entry checks; inert resources only\"}")
    }
}
'''
# Read actor-isolated diagnostics before combining them with synchronous values.
wake_owner_fixture = wake_owner_fixture.replace("expect(bridge.values.use { $0 }.isEmpty && await session.liveInputStops() == 0,", "let inputStops = await session.liveInputStops()\n            expect(bridge.values.use { $0 }.isEmpty && inputStops == 0,")
with tempfile.TemporaryDirectory(prefix="knot-wake-owner-", dir="/tmp") as directory:
    temporary = Path(directory)
    source = temporary / "Checks.swift"; source.write_text(wake_owner_fixture)
    executable = temporary / "checks"
    argv = ["/usr/bin/swiftc", "-swift-version", "6", "-parse-as-library", "-O", "-module-cache-path", str(temporary / "module-cache"), str(source), "-o", str(executable)]
    print(json.dumps({"compileArgv": argv, "checksArgv": [str(executable)]}), flush=True)
    subprocess.run(argv, check=True, timeout=90)
    binary_sha256 = hashlib.sha256(executable.read_bytes()).hexdigest()
    normal_env = os.environ.copy()
    normal_env.pop("LIBDISPATCH_COOPERATIVE_POOL_STRICT", None)
    normal = subprocess.run([str(executable)], env=normal_env, capture_output=True, text=True, timeout=30)
    sys.stdout.write(normal.stdout); sys.stdout.flush()
    sys.stderr.write(normal.stderr)
    normal.check_returncode()
    strict_env = normal_env.copy(); strict_env["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] = "1"
    strict = subprocess.run([str(executable)], env=strict_env, capture_output=True, text=True, timeout=30)
    if strict.returncode != 0:
        sys.stderr.write(strict.stdout); sys.stderr.write(strict.stderr)
    strict.check_returncode()
    assert json.loads(normal.stdout) == json.loads(strict.stdout), "same Wake binary must pass identical checks in normal and strict configurations"
    assert binary_sha256 == hashlib.sha256(executable.read_bytes()).hexdigest()
    # Strict is a repeated configuration of this same suite, not another set of checks.
    print(json.dumps({"wakeProbeOwnershipStrictRun": {
        "sameCompiledBinarySHA256": binary_sha256, "exitCode": strict.returncode,
        "environmentOverride": {"LIBDISPATCH_COOPERATIVE_POOL_STRICT": "1"},
        "repeatedAssertionCount": json.loads(strict.stdout)["wakeProbeOwnershipChecks"],
        "stdoutSHA256": hashlib.sha256(strict.stdout.encode()).hexdigest(),
        "stderrSHA256": hashlib.sha256(strict.stderr.encode()).hexdigest()}}), flush=True)
    print(json.dumps({"wakeProbeOwnershipFixtureSHA256": hashlib.sha256(wake_owner_fixture.encode()).hexdigest(),
                      "productionSourceSHA256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in (ENGINE / "Session/StreamSession+Wake.swift", ENGINE / "Session/StreamSession.swift", ENGINE / "Session/StreamSession+Reconnect.swift", ENGINE / "Session/StreamSession+Lifecycle.swift")}}))
