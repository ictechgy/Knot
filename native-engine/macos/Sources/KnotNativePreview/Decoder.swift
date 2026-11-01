import Foundation
import AVFoundation
import VideoToolbox
import KnotNativeCore

/// VideoToolbox emits synthetic or host-provided H.264 pixels only. No capture APIs.
@MainActor
final class NativeDecoder {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps: [Data] = [], pps: [Data] = []
    private var dimensions: (Int, Int)
    private var waitingForIDR = true
    private var generation: UInt64 = 0
    private var inFlight = 0
    var onImage: ((CVPixelBuffer) -> Void)?
    var onFailure: (() -> Void)?

    init(width: Int, height: Int) { dimensions = (width, height) }
    func stop() {
        generation &+= 1
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil; sps = []; pps = []; waitingForIDR = true; inFlight = 0
    }

    func decode(_ unit: AccessUnit) throws {
        let nextSPS = unit.sps.isEmpty ? sps : unit.sps, nextPPS = unit.pps.isEmpty ? pps : unit.pps
        let changed = nextSPS != sps || nextPPS != pps
        if changed {
            // Never retain a stale session when parameter sets change midstream.
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil; format = nil; waitingForIDR = true; generation &+= 1; inFlight = 0
            sps = nextSPS; pps = nextPPS
        }
        guard !sps.isEmpty, !pps.isEmpty else { return }
        if waitingForIDR {
            guard unit.isIDR else { return }
            try createSession(); waitingForIDR = false
        }
        guard let session, let format else { throw NativeFailure.decoder }
        guard inFlight < 3 else { throw NativeFailure.decoder }
        let bytes = unit.avcc
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { throw NativeFailure.decoder }
        let copied = bytes.withUnsafeBytes { raw in CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }
        guard copied == noErr else { throw NativeFailure.decoder }
        var sample: CMSampleBuffer?, size = bytes.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { throw NativeFailure.decoder }
        let expectedGeneration = generation
        inFlight += 1
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            let transferred = image.map { PixelTransfer(buffer: $0) }
            Task { @MainActor [weak self] in
                guard let self, self.generation == expectedGeneration else { return }
                self.inFlight = max(0, self.inFlight - 1)
                guard status == noErr, let transferred else { self.onFailure?(); return }
                self.onImage?(transferred.buffer)
            }
        }
        guard status == noErr else { inFlight = max(0, inFlight - 1); throw NativeFailure.decoder }
    }

    private func createSession() throws {
        // NSData buffers keep every parameter-set pointer stable for this call.
        let sets = (sps + pps).map { $0 as NSData }
        let pointers = sets.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        let lengths = sets.map(\.length)
        var description: CMFormatDescription?
        let status = pointers.withUnsafeBufferPointer { pointers in lengths.withUnsafeBufferPointer { lengths in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers.baseAddress!, parameterSetSizes: lengths.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        } }
        guard status == noErr, let description else { throw NativeFailure.decoder }
        let size = CMVideoFormatDescriptionGetDimensions(description)
        guard size.width == dimensions.0, size.height == dimensions.1, size.width <= 1920, size.height <= 1080 else { throw NativeFailure.decoder }
        var created: VTDecompressionSession?
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                          kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description, decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &created) == noErr, let created else { throw NativeFailure.decoder }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        format = description; session = created
    }
}

/// CoreVideo owns the pixel storage; transfer a retained immutable decoded buffer.
private struct PixelTransfer: @unchecked Sendable { let buffer: CVPixelBuffer }
