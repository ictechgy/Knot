import Foundation
import CoreVideo
import Testing
@testable import KnotNativePreview
import KnotNativeCore

@Test @MainActor func decoderCapacityWaitsAndStopWakesWithoutRaisingCap() async throws {
    let gate = DecodeAdmission()
    let a = try await gate.acquire(), b = try await gate.acquire(), c = try await gate.acquire()
    let fourth = Task { try await gate.acquire() }
    for _ in 0..<20 { if gate.waiting { break }; await Task.yield() }
    #expect(gate.count == 3 && gate.waiting && gate.peak == 3)
    gate.release(a)
    let d = try await fourth.value
    #expect(gate.count == 3 && gate.peak == 3)
    let blocked = Task { try await gate.acquire() }
    for _ in 0..<20 { if gate.waiting { break }; await Task.yield() }
    gate.stop()
    do { _ = try await blocked.value; Issue.record("Stop admitted work") } catch {}
    #expect(!gate.waiting)
    for ticket in [b,c,d] { gate.release(ticket) }
    #expect(gate.count == 0)
}

@Test @MainActor func decoderAdmissionCancellationAndExclusiveDrain() async throws {
    let gate = DecodeAdmission()
    let first = try await gate.acquire()
    let exclusive = Task { try await gate.acquire(exclusive: true) }
    for _ in 0..<20 { if gate.waiting { break }; await Task.yield() }
    #expect(gate.count == 1 && gate.waiting)
    exclusive.cancel()
    do { _ = try await exclusive.value; Issue.record("Canceled drain admitted") } catch {}
    #expect(!gate.waiting && gate.count == 1)
    gate.release(first)
    let next = try await gate.acquire(exclusive: true); gate.release(next)
    #expect(gate.count == 0)
}

@Test func decoderDroppedCompletionIsNonfatalButUnexplainedNilIsFailure() {
    #expect(DecodeCompletion.classify(status: 0, frameDropped: true, hasImage: false) == .dropped)
    #expect(DecodeCompletion.classify(status: 0, frameDropped: false, hasImage: false) == .failure)
    #expect(DecodeCompletion.classify(status: -1, frameDropped: true, hasImage: false) == .failure)
    #expect(DecodeCompletion.classify(status: 0, frameDropped: false, hasImage: true) == .image)
}

@Test @MainActor func documentedDropReturnsCapacityAndUnexpectedNilStillFails() async throws {
    let gate = DecodeAdmission()
    let a = try await gate.acquire(), b = try await gate.acquire(), c = try await gate.acquire()
    let waiting = Task { try await gate.acquire() }
    for _ in 0..<20 { if gate.waiting { break }; await Task.yield() }
    var failed = false, image = false, completions: [Bool] = []
    DecodeDelivery.finish(ticket: a, admission: gate, status: 0, frameDropped: true, image: nil, width: 64, height: 64,
        onImage: { _ in image = true }, onFailure: { failed = true }, onCompletion: { completions.append($0) })
    let next = try await waiting.value
    #expect(!failed && !image && gate.count == 3 && gate.peak == 3 && completions == [true])
    DecodeDelivery.finish(ticket: next, admission: gate, status: 0, frameDropped: false, image: nil, width: 64, height: 64,
        onImage: { _ in image = true }, onFailure: { failed = true }, onCompletion: { completions.append($0) })
    #expect(failed && !image && gate.count == 2 && completions == [true])
    gate.release(b); gate.release(c)
    let token = DecodeCallbackToken(); #expect(token.claim()); #expect(!token.claim())
}

@Test @MainActor func decodedPixelsMustMatchReadyBeforeDeliveryAndAlwaysReturnCapacity() async throws {
    for (width, height) in [(128, 64), (64, 32)] {
        let gate = DecodeAdmission()
        let a = try await gate.acquire(), b = try await gate.acquire(), c = try await gate.acquire()
        let waiting = Task { try await gate.acquire() }
        let deadline = ContinuousClock.now + .seconds(1)
        while !gate.waiting, ContinuousClock.now < deadline { await Task.yield() }
        try #require(gate.waiting)
        var pixels: CVPixelBuffer?
        try #require(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixels) == kCVReturnSuccess)
        let wrong = try #require(pixels)
        var failures = 0, delivered = 0
        DecodeDelivery.finish(ticket: a, admission: gate, status: 0, frameDropped: false,
            image: wrong, width: 64, height: 64, onImage: { _ in delivered += 1 }, onFailure: { failures += 1 })
        let next = try await waiting.value
        #expect(failures == 1 && delivered == 0 && gate.count == 3 && gate.peak == 3)

        pixels = nil
        try #require(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixels) == kCVReturnSuccess)
        let correct = try #require(pixels)
        DecodeDelivery.finish(ticket: next, admission: gate, status: 0, frameDropped: false,
            image: correct, width: 64, height: 64,
            onImage: { image in
                #expect(CVPixelBufferGetWidth(image) == 64 && CVPixelBufferGetHeight(image) == 64)
                delivered += 1
            }, onFailure: { failures += 1 })
        #expect(failures == 1 && delivered == 1 && gate.count == 2)
        gate.release(b); gate.release(c)
        #expect(gate.count == 0)
    }
}
