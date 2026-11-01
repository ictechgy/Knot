import Foundation
import Testing
@testable import KnotNativeCore

private func drain(_ queue: inout InputBuffer) -> [Packet] {
    var result: [Packet] = []
    while let packet = queue.pop() { result.append(packet) }
    return result
}

@Test func pointerCoalescingPreservesWheelAndPhysicalKeyBarriers() throws {
    let first = try Input.pointer(action: 0, x: 100, y: 200)
    let latest = try Input.pointer(action: 0, x: 300, y: 400)
    let wheel = try Input.wheel(vertical: 120, horizontal: -240)
    let key = try Input.key(down: true, scan: 0x1e, extended: false)
    for barrier in [wheel, key] {
        var queue = InputBuffer()
        try queue.append(first); try queue.append(barrier); try queue.append(latest)
        #expect(drain(&queue) == [first, barrier, latest])
        #expect(queue.byteCount == 0)
    }
    var consecutive = InputBuffer()
    try consecutive.append(first); try consecutive.append(latest)
    #expect(consecutive.count == 1 && consecutive.byteCount == latest.encoded.count)
    #expect(drain(&consecutive) == [latest])
}

@Test func adjacentWheelCoalescingIsBoundedAndPreservesBarriers() throws {
    let wheel = try Input.wheel(vertical: 120, horizontal: -60)
    let combined = try Input.wheel(vertical: 240, horizontal: -120)
    var queue = InputBuffer()
    try queue.append(wheel); try queue.append(wheel)
    #expect(queue.count == 1 && queue.byteCount == combined.encoded.count)
    #expect(drain(&queue) == [combined])
    let limit = try Input.wheel(vertical: 1200, horizontal: -1200)
    try queue.append(limit); try queue.append(wheel)
    #expect(drain(&queue) == [limit, wheel]) // preserve excess, never clamp it away
    let move = try Input.pointer(action: 0, x: 10, y: 20)
    let key = try Input.key(down: false, scan: 0x1e, extended: false)
    for barrier in [move, key] {
        try queue.append(wheel); try queue.append(barrier); try queue.append(wheel)
        #expect(drain(&queue) == [wheel, barrier, wheel])
    }
}

@Test func zeroWheelSuppressionAndQueueLimitsRemainExact() throws {
    var queue = InputBuffer()
    try queue.append(Input.wheel(vertical: 0, horizontal: 0))
    #expect(queue.count == 0 && queue.byteCount == 0)
    let up = try Input.wheel(vertical: 120, horizontal: 0), down = try Input.wheel(vertical: -120, horizontal: 0)
    try queue.append(up); try queue.append(down)
    #expect(drain(&queue) == [up, down]) // a reversal remains observable at edges
    let full = try Input.wheel(vertical: 1200, horizontal: 1200)
    for _ in 0..<256 { try queue.append(full) }
    #expect(queue.count == 256 && queue.byteCount == 256 * full.encoded.count)
    #expect(throws: (any Error).self) { try queue.append(full) }
    #expect(queue.needsRecovery && queue.count == 1 && queue.pop()?.kind == .releaseAll)
    #expect(throws: (any Error).self) { try queue.append(full) }
}

@Test func scrollConversionSeparatesPixelAndLinePolicyAndIgnoresZero() throws {
    let precise = try #require(Input.scroll(vertical: 1, horizontal: -2, precise: true))
    let lines = try #require(Input.scroll(vertical: 1, horizontal: -2, precise: false))
    let preciseExpected = try Input.wheel(vertical: 12, horizontal: -24)
    let lineExpected = try Input.wheel(vertical: 120, horizontal: -240)
    let clampedExpected = try Input.wheel(vertical: 1200, horizontal: -1200)
    #expect(precise == preciseExpected)
    #expect(lines == lineExpected)
    #expect(Input.scroll(vertical: 0, horizontal: 0, precise: true) == nil)
    #expect(Input.scroll(vertical: 0.001, horizontal: -0.001, precise: true) == nil)
    #expect(Input.scroll(vertical: .nan, horizontal: 1, precise: true) == nil)
    #expect(Input.scroll(vertical: 1, horizontal: .infinity, precise: false) == nil)
    #expect(Input.scroll(vertical: .greatestFiniteMagnitude, horizontal: -.greatestFiniteMagnitude, precise: true) == clampedExpected)
}

@Test func aspectFitRejectsLetterboxByDefaultAndClampsOnlyWhenRequested() {
    let rejected = Input.point(x: 50, y: 0, viewWidth: 100, viewHeight: 100, imageWidth: 200, imageHeight: 100)
    #expect(rejected == nil)
    let release = Input.point(x: 50, y: 0, viewWidth: 100, viewHeight: 100, imageWidth: 200, imageHeight: 100, clamp: true)
    #expect(release?.0 == 32768 && release?.1 == 0)
    let opposite = Input.point(x: 150, y: 150, viewWidth: 100, viewHeight: 100, imageWidth: 200, imageHeight: 100, clamp: true)
    #expect(opposite?.0 == 65535 && opposite?.1 == 65535)
    #expect(Input.point(x: .nan, y: 0, viewWidth: 100, viewHeight: 100, imageWidth: 200, imageHeight: 100, clamp: true) == nil)
}
