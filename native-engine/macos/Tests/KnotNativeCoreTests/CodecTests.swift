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
    // The decoder must reject the fixture against a different advertised size.
    let wrongSize = NativeDecoder(width: 128, height: 64)
    defer { wrongSize.stop() }
    #expect(throws: (any Error).self) { try wrongSize.decode(access) }
}
