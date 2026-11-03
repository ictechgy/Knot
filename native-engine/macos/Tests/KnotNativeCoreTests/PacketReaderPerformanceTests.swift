import Foundation
import Testing
import KnotNativeCore
@testable import KnotNativePreview

/// Fresh framed bytes only; no socket, decoder, screen or actual input sink.
private final class ReaderFixtureChannel: NativeChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data
    private var offset = 0
    private var requests: [Int] = []
    private var writes: [Packet] = []
    init(_ packets: [Packet]) { bytes = packets.reduce(into: Data()) { $0.append($1.encoded) } }
    init(raw: Data) { bytes = raw }
    func start() async throws {}
    func readExactly(_ count: Int, timeout: Duration) async throws -> Data {
        try lock.withLock {
            requests.append(count)
            guard count >= 0, count <= bytes.count - offset else { throw NativeFailure.transport }
            defer { offset += count }
            return bytes.subdata(in: offset..<(offset + count))
        }
    }
    func send(_ packet: Packet) async throws { lock.withLock { writes.append(packet) } }
    func close() {}
    var requested: [Int] { lock.withLock { requests } }
    var sent: [Packet] { lock.withLock { writes } }
}

private final class SuspendedReaderFixture: NativeChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var read: CheckedContinuation<Data, any Error>?
    private var observer: CheckedContinuation<Void, Never>?
    func start() async throws {}
    func send(_ packet: Packet) async throws {}
    func readExactly(_ count: Int, timeout: Duration) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); read = continuation
            let pending = observer; observer = nil
            lock.unlock(); pending?.resume()
        }
    }
    func waitUntilReadPending() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if read != nil { lock.unlock(); continuation.resume() }
            else { observer = continuation; lock.unlock() }
        }
    }
    func close() {
        lock.lock(); let pending = read; read = nil; lock.unlock()
        pending?.resume(throwing: NativeFailure.transport)
    }
}

private func readerReady() -> Packet {
    Packet(kind: .ready, payload: Data(#"{"v":1,"codec":"h264-annexb","width":3840,"height":2160,"fps":60,"bitrate":40000000,"hardwareEncoder":true}"#.utf8))
}

private func readerVideo(_ sequence: UInt64, size: Int = 131_072) -> Packet {
    var payload = Data()
    payload.appendBE(sequence); payload.appendBE(UInt64(1_000_000 + sequence * 16_666))
    payload.append(1)
    // Parser fixture, not a claim of decodable H.264: one bounded IDR NAL with
    // no accidental Annex B prefixes in the synthetic payload.
    payload.append(contentsOf: [0, 0, 0, 1, 0x65])
    payload.append(Data(repeating: 0x55, count: size - 5))
    return Packet(kind: .video, payload: payload)
}

/// A bounded synchronous stand-in for expensive media preparation. The timeout
/// turns an accidental MainActor regression into an assertion, not a deadlock.
private final class MediaPreparationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var timedOut = false
    private var observer: CheckedContinuation<Void, Never>?
    func hold() {
        condition.lock()
        entered = true
        let pending = observer; observer = nil
        pending?.resume()
        let deadline = Date().addingTimeInterval(3)
        while !released {
            if !condition.wait(until: deadline) { timedOut = true; break }
        }
        condition.unlock()
    }
    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if entered { condition.unlock(); continuation.resume() }
            else { observer = continuation; condition.unlock() }
        }
    }
    var isHeld: Bool {
        condition.lock(); defer { condition.unlock() }
        return entered && !released && !timedOut
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

@Test @MainActor func mediaPreparationKeepsUIInputResponsiveWithOrderedFrames() async throws {
    let channel = ReaderFixtureChannel([readerReady(), readerVideo(1, size: 2_097_152), readerVideo(2)])
    let gate = MediaPreparationGate()
    let reader = NativePacketReader(channel: channel, parse: { packet, state in
        if packet.kind == .video { gate.hold() }
        return try state.accept(packet)
    })
    guard case .ready(let ready) = try await reader.next(timeout: .seconds(10)) else { Issue.record("Missing ready"); return }
    #expect(ready.width == 3840 && ready.height == 2160 && ready.fps == 60)
    let first = Task { try await reader.next(timeout: .seconds(10)) }
    defer { gate.release() }
    await gate.waitUntilEntered()
    // This code resumes on MainActor while the serial media executor is held.
    #expect(gate.isHeld)
    let pointer = try Input.pointer(action: 0, x: 200, y: 300)
    try await channel.send(pointer)
    #expect(channel.sent == [pointer] && gate.isHeld)
    gate.release()
    guard case .video(let video) = try await first.value else { Issue.record("Missing video"); return }
    #expect(video.sequence == 1 && video.accessUnit.nals.count == 1)
    #expect(video.accessUnit.avcc.count == video.accessUnit.nals[0].count + 4)
    #expect(video.accessUnit.avcc.readBE(UInt32.self, at: 0) == UInt32(video.accessUnit.nals[0].count))
    guard case .video(let next) = try await reader.next(timeout: .seconds(10)) else { Issue.record("Missing ordered video"); return }
    #expect(next.sequence == 2)
}

@Test func serialMediaReaderRejectsSequenceReuseAndCannotResumeAfterFailure() async throws {
    let channel = ReaderFixtureChannel([readerReady(), readerVideo(1), readerVideo(1), readerVideo(2)])
    let reader = NativePacketReader(channel: channel)
    _ = try await reader.next(timeout: .seconds(10))
    _ = try await reader.next(timeout: .seconds(10))
    await #expect(throws: NativeFailure.malformed) { try await reader.next(timeout: .seconds(10)) }
    let count = channel.requested.count
    await #expect(throws: NativeFailure.state) { try await reader.next(timeout: .seconds(10)) }
    #expect(channel.requested.count == count)
}

@Test func serialMediaReaderBoundsPayloadBeforeRequestingBytes() async throws {
    var header = Data([Kind.video.rawValue]); header.appendBE(UInt32(4_194_305))
    let channel = ReaderFixtureChannel(raw: header)
    let reader = NativePacketReader(channel: channel)
    await #expect(throws: NativeFailure.oversized) { try await reader.next(timeout: .seconds(10)) }
    #expect(channel.requested == [5])

    // Actor methods can reenter while waiting for network bytes. Reject a
    // second consumer there rather than interleaving their framed reads.
    let suspended = SuspendedReaderFixture()
    let serial = NativePacketReader(channel: suspended)
    let first = Task { try await serial.next(timeout: .seconds(10)) }
    await suspended.waitUntilReadPending()
    await #expect(throws: NativeFailure.state) { try await serial.next(timeout: .seconds(10)) }
    suspended.close()
    await #expect(throws: NativeFailure.transport) { try await first.value }
}
