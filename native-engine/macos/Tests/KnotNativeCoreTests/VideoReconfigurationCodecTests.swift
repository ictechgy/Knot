import Foundation
import CoreVideo
import Testing
import KnotNativeCore
@testable import KnotNativePreview

private struct ReconfigurationCodecFixture: Decodable {
    let v: Int, synthetic: Bool, captureInvoked: Bool, hardwareEncoder: Bool, codec: String
    let frames: Int, keyframes: Int, parserChecks: Bool, reconfigurationFixture: Bool, drainChecks: Bool, emptyDrainChecks: Bool
    struct Segment: Decodable {
        let epoch: Int, width: Int, height: Int, fps: Int, bitrate: Int, firstSequence: Int, frames: Int
        let drainComplete: Bool, drainInFlight: Int, firstOutputIDR: Bool
    }
    struct Unit: Decodable {
        let sequence: UInt64, offset: Int, length: Int, flags: UInt8, timestampMicros: UInt64, epoch: Int
    }
    let segments: [Segment], accessUnits: [Unit]
}

private func hasReconfigurationFixture() -> Bool {
    guard let root = ProcessInfo.processInfo.environment["KNOT_NATIVE_WINDOWS_FIXTURES"] else { return false }
    return FileManager.default.fileExists(atPath: URL(fileURLWithPath: root).appendingPathComponent("synthetic-reconfigure.json").path)
}

/// CI requires the files independently in WindowsFixtureRequirement. Local
/// runs without the new Windows output explicitly skip, never inventing data.
@Test(.enabled(if: hasReconfigurationFixture(), "Needs fresh Windows multi-epoch software-MFT fixture"))
@MainActor func windowsReconfigurationFixtureDecodesEveryDrainedEpochAtItsActualDimensions() async throws {
    let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["KNOT_NATIVE_WINDOWS_FIXTURES"]), isDirectory: true)
    let json = try Data(contentsOf: root.appendingPathComponent("synthetic-reconfigure.json"))
    let bytes = try Data(contentsOf: root.appendingPathComponent("synthetic-reconfigure.h264"))
    try #require(json.count <= 131_072 && !bytes.isEmpty && bytes.count <= 64 * 1024 * 1024)
    let fixture = try JSONDecoder().decode(ReconfigurationCodecFixture.self, from: json)
    try #require(fixture.v == 1 && fixture.synthetic && !fixture.captureInvoked && !fixture.hardwareEncoder)
    try #require(fixture.codec == "h264-annexb" && fixture.parserChecks && fixture.reconfigurationFixture && fixture.drainChecks && fixture.emptyDrainChecks)
    try #require(fixture.frames == 36 && fixture.accessUnits.count == 36 && fixture.segments.count == 3)
    let profiles = [(320, 180, 30, 2_000_000), (640, 360, 60, 4_000_000), (320, 180, 30, 2_000_000)]
    var offset = 0, sequence: UInt64 = 0, timestamp: UInt64 = 0, keyframes = 0, decodedTotal = 0
    for (epoch, segment) in fixture.segments.enumerated() {
        let expected = profiles[epoch]
        try #require(segment.epoch == epoch && segment.width == expected.0 && segment.height == expected.1 && segment.fps == expected.2 && segment.bitrate == expected.3)
        try #require(segment.firstSequence == epoch * 12 + 1 && segment.frames == 12 && segment.drainComplete && segment.firstOutputIDR && (1...2).contains(segment.drainInFlight))
        let decoder = NativeDecoder(width: segment.width, height: segment.height)
        var decoded = 0, failed = false, dimensionsCorrect = true
        decoder.onImage = { image in
            decoded += 1
            dimensionsCorrect = dimensionsCorrect && CVPixelBufferGetWidth(image) == segment.width && CVPixelBufferGetHeight(image) == segment.height
        }
        decoder.onFailure = { failed = true }
        do {
            for index in 0..<12 {
                let unit = fixture.accessUnits[epoch * 12 + index]
                try #require(unit.epoch == epoch && unit.sequence == sequence + 1 && unit.offset == offset)
                try #require((1...4_194_287).contains(unit.length) && unit.offset <= bytes.count && unit.length <= bytes.count - unit.offset)
                try #require(unit.flags <= 1 && unit.timestampMicros > timestamp)
                let access = try AccessUnit(annexB: bytes.subdata(in: unit.offset..<(unit.offset + unit.length)))
                try #require(access.isIDR == (unit.flags == 1))
                if index == 0 { try #require(access.isIDR && !access.sps.isEmpty && !access.pps.isEmpty) }
                if access.isIDR { keyframes += 1 }
                try await decoder.decode(access)
                sequence = unit.sequence; timestamp = unit.timestampMicros; offset += unit.length
            }
            try await NativeVideoDecoderDrain.wait(decoder, timeout: .seconds(5))
            #expect(!failed && dimensionsCorrect && decoded == 12 && decoder.outstanding == 0 && decoder.maximumOutstanding <= DecodeAdmission.capacity)
            decodedTotal += decoded
            decoder.stop()
        } catch { decoder.stop(); throw error }
    }
    #expect(offset == bytes.count && sequence == 36 && decodedTotal == 36 && keyframes == fixture.keyframes)
    print("Windows MF reconfiguration: decoded=\(decodedTotal), epochs=3, dimensions320x180→640x360→320x180; all old callbacks drained, synthetic pixels only")
}
