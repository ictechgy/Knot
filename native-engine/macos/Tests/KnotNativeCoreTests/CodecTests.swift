import Foundation
import Testing
import CoreVideo
import VideoToolbox
import KnotNativeCore
@testable import KnotNativePreview

private final class EncodedSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CMSampleBuffer] = []
    func append(_ value: CMSampleBuffer) { lock.lock(); storage.append(value); lock.unlock() }
    func samples() -> [CMSampleBuffer] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Fresh software-encoded pixels are a codec fixture, never a runtime fallback.
@Test @MainActor func freshSyntheticH264EncodeDecode() async throws {
    let output = EncodedSamples()
    var encoder: VTCompressionSession?
    let specification = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: false] as CFDictionary
    let result = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: 64, height: 64, codecType: kCMVideoCodecType_H264, encoderSpecification: specification, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: { context, _, status, _, sample in
        guard status == noErr, let context, let sample else { return }
        Unmanaged<EncodedSamples>.fromOpaque(context).takeUnretainedValue().append(sample)
    }, refcon: Unmanaged.passUnretained(output).toOpaque(), compressionSessionOut: &encoder)
    #expect(result == noErr)
    let session = try #require(encoder)
    defer { VTCompressionSessionInvalidate(session) }
    #expect(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue) == noErr)
    #expect(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse) == noErr)
    var buffer: CVPixelBuffer?
    #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
    let pixels = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    let base = try #require(CVPixelBufferGetBaseAddress(pixels))
    let stride = CVPixelBufferGetBytesPerRow(pixels)
    for y in 0..<64 { for x in 0..<64 {
        let pointer = base.advanced(by: y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
        pointer[0] = UInt8(x * 4); pointer[1] = UInt8(y * 4); pointer[2] = 80; pointer[3] = 255
    } }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    #expect(VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: CMTime(value: 0, timescale: 30), duration: CMTime(value: 1, timescale: 30), frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary, sourceFrameRefcon: nil, infoFlagsOut: nil) == noErr)
    #expect(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) == noErr)
    let sample = try #require(output.samples().first)
    let description = try #require(CMSampleBufferGetFormatDescription(sample))
    var annexB = Data()
    for index in 0..<2 {
        var pointer: UnsafePointer<UInt8>?, size = 0, count = 0
        #expect(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr)
        annexB.append(contentsOf: [0,0,0,1]); annexB.append(try #require(pointer), count: size)
    }
    let block = try #require(CMSampleBufferGetDataBuffer(sample)), length = CMBlockBufferGetDataLength(block)
    var avcc = Data(count: length)
    #expect(avcc.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) } == noErr)
    var cursor = 0
    while cursor < avcc.count {
        #expect(cursor + 4 <= avcc.count)
        let size = Int(avcc.readBE(UInt32.self, at: cursor)); cursor += 4
        #expect(size > 0 && cursor + size <= avcc.count)
        annexB.append(contentsOf: [0,0,0,1]); annexB.append(avcc.subdata(in: cursor..<(cursor+size))); cursor += size
    }
    let access = try AccessUnit(annexB: annexB)
    #expect(access.isIDR && !access.sps.isEmpty && !access.pps.isEmpty)
    let decoder = NativeDecoder(width: 64, height: 64)
    defer { decoder.stop() }
    var decoded = false, failed = false
    decoder.onImage = { image in decoded = CVPixelBufferGetWidth(image) == 64 && CVPixelBufferGetHeight(image) == 64 }
    decoder.onFailure = { failed = true }
    try decoder.decode(access)
    let deadline = ContinuousClock.now + .seconds(5)
    while !decoded && !failed && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(decoded && !failed)
    let stopped = NativeDecoder(width: 64, height: 64)
    var staleFrames = 0
    stopped.onImage = { _ in staleFrames += 1 }
    try stopped.decode(access); stopped.stop()
    try await Task.sleep(for: .milliseconds(50))
    #expect(staleFrames == 0)
    // The decoder must reject the fixture against a different advertised size.
    let wrongSize = NativeDecoder(width: 128, height: 64)
    defer { wrongSize.stop() }
    #expect(throws: (any Error).self) { try wrongSize.decode(access) }
}

private struct WindowsCodecFixture: Decodable {
    struct Unit: Decodable {
        let sequence: UInt64, offset: Int, length: Int, flags: UInt8, timestampMicros: UInt64
    }
    let v: Int, synthetic: Bool, captureInvoked: Bool, codec: String
    let width: Int, height: Int, fps: Int, bitrate: Int, hardwareEncoder: Bool
    let frames: Int, keyframes: Int, parserChecks: Bool
    let accessUnits: [Unit]
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["KNOT_NATIVE_WINDOWS_FIXTURES"] != nil,
               "Windows MF artifact path not supplied locally; CI supplies and requires it."))
@MainActor func windowsMediaFoundationFixtureDecodesWithNativeVideoToolbox() async throws {
    let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["KNOT_NATIVE_WINDOWS_FIXTURES"]), isDirectory: true)
    let json = try Data(contentsOf: root.appendingPathComponent("synthetic-codec.json"))
    let data = try Data(contentsOf: root.appendingPathComponent("synthetic.h264"))
    try #require(json.count <= 131_072 && data.count <= 64 * 1024 * 1024)
    let fixture = try JSONDecoder().decode(WindowsCodecFixture.self, from: json)
    try #require(fixture.v == 1 && fixture.synthetic && !fixture.captureInvoked && fixture.parserChecks)
    try #require(fixture.codec == "h264-annexb" && fixture.width == 320 && fixture.height == 180)
    try #require(fixture.fps == 30 && fixture.bitrate == 2_000_000 && !fixture.hardwareEncoder)
    try #require(fixture.frames == 120 && fixture.accessUnits.count == fixture.frames && fixture.keyframes >= 2)
    let decoder = NativeDecoder(width: fixture.width, height: fixture.height)
    defer { decoder.stop() }
    var decoded = 0, failed = false, validDimensions = true
    decoder.onImage = { image in
        decoded += 1
        validDimensions = validDimensions && CVPixelBufferGetWidth(image) == 320 && CVPixelBufferGetHeight(image) == 180
    }
    decoder.onFailure = { failed = true }
    var offset = 0, keyframes = 0, sequence: UInt64 = 0, timestamp: UInt64 = 0
    for unit in fixture.accessUnits {
        try #require(unit.sequence == sequence + 1 && unit.offset == offset && unit.length > 0 && unit.length <= 4_194_287)
        try #require(unit.offset <= data.count && unit.length <= data.count - unit.offset && unit.flags <= 1 && unit.timestampMicros > timestamp)
        let access = try AccessUnit(annexB: data.subdata(in: unit.offset..<(unit.offset + unit.length)))
        try #require(access.isIDR == (unit.flags == 1))
        if access.isIDR { keyframes += 1; try #require(!access.sps.isEmpty && !access.pps.isEmpty) }
        let expected = decoded + 1
        try decoder.decode(access)
        let deadline = ContinuousClock.now + .seconds(5)
        while decoded < expected && !failed && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(decoded == expected && !failed && validDimensions)
        sequence = unit.sequence; timestamp = unit.timestampMicros; offset += unit.length
    }
    #expect(offset == data.count && decoded == fixture.frames && keyframes == fixture.keyframes)
}
