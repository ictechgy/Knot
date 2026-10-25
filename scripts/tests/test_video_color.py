#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Run the complete production color resolver/attachment code on synthetic buffers.

CoreVideo, CoreMedia and CoreImage are real. Decoder lifecycle/telemetry leaves
are inert: no capture, existing media, display, preferences, keys or network.
"""
from pathlib import Path
import hashlib
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / "Vendor/Glimmer/GlimmerEngine"


def block(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[start:end]


fixture = r'''
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import os

__ACTUAL_TYPES__
enum StreamProtocol { static let VIDEO_FORMAT_MASK_10BIT: Int32 = 0x100 }
struct Metadata { var mdcv: Data?; var contentLightLevel: Data? }
struct MetadataStore { var snapshot = Metadata() }
final class VideoDecoder: @unchecked Sendable {
    let requestedColorSpace: ColorSpace
    let requestedColorRange = ColorRange.full
    let sdrColorMode: SDRColorMode
    var formatDescription: CMFormatDescription?
    var streamVideoFormat: Int32 = 0
    let resolvedColor = OSAllocatedUnfairLock<VideoColorDescription?>(initialState: nil)
    let pixelFormatRanges = OSAllocatedUnfairLock(initialState: [OSType: String]())
    var lastColorSpace: CGColorSpace?
    var cachedHDRFormatDescription: CMVideoFormatDescription?
    var hdrMetadataStore = MetadataStore()
    init(_ mode: SDRColorMode, space: ColorSpace = .rec709) { sdrColorMode = mode; requestedColorSpace = space }
    func noteColorSpaceChangeTelemetry(_ summary: String) {}
    @MainActor func configureLayerColorspace() {}
}

@main struct Checks {
    @MainActor static func main() throws {
        var count = 0
        func expect(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: message, code: count) }
            count += 1
        }
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.cacheIntermediates: false])
        let p709 = kCVImageBufferColorPrimaries_ITU_R_709_2 as String
        let m709 = kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
        let t709 = kCVImageBufferTransferFunction_ITU_R_709_2 as String
        let tsRGB = kCVImageBufferTransferFunction_sRGB as String
        let pq = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
        let hlg = kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
        func buffer(_ format: OSType, rgb: (Double, Double, Double) = (0.5, 0.5, 0.5),
                    iosurface: Bool = true) throws -> CVPixelBuffer {
            var value: CVPixelBuffer?
            try expect(CVPixelBufferCreate(nil, 16, 16, format,
                iosurface ? [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary : nil, &value) == 0, "create synthetic buffer")
            let b = value!
            let ten = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            let full = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            // Independent Rec.709 matrix, with range quantization in the actual output format.
            let y = 0.2126 * rgb.0 + 0.7152 * rgb.1 + 0.0722 * rgb.2
            let u = (rgb.2 - y) / (2 * (1 - 0.0722))
            let v = (rgb.0 - y) / (2 * (1 - 0.2126))
            let scale = ten ? 4.0 : 1.0
            let peak = ten ? 1023.0 : 255.0
            let samples = [(full ? 0 : 16 * scale) + y * (full ? peak : 219 * scale),
                           128 * scale + u * (full ? peak : 224 * scale),
                           128 * scale + v * (full ? peak : 224 * scale)]
            CVPixelBufferLockBaseAddress(b, [])
            defer { CVPixelBufferUnlockBaseAddress(b, []) }
            for plane in 0..<2 {
                let base = CVPixelBufferGetBaseAddressOfPlane(b, plane)!
                let stride = CVPixelBufferGetBytesPerRowOfPlane(b, plane)
                for row in 0..<(plane == 0 ? 16 : 8) {
                    for column in 0..<16 {
                        let sample = samples[plane == 0 ? 0 : 1 + column % 2].rounded()
                        if ten { base.advanced(by: row * stride).assumingMemoryBound(to: UInt16.self)[column] = UInt16(sample) << 6 }
                        else { base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)[column] = UInt8(sample) }
                    }
                }
            }
            return b
        }
        func tag(_ b: CVPixelBuffer, primaries: String? = nil, transfer: String? = nil,
                 matrix: String? = nil, gamma: Double? = nil) {
            let entries: [(CFString, Any?)] = [(kCVImageBufferColorPrimariesKey, primaries),
                (kCVImageBufferTransferFunctionKey, transfer), (kCVImageBufferYCbCrMatrixKey, matrix),
                (kCVImageBufferGammaLevelKey, gamma)]
            for (key, value) in entries { if let value { CVBufferSetAttachment(b, key, value as CFTypeRef, .shouldPropagate) } }
        }
        func render(_ b: CVPixelBuffer) -> [UInt8] {
            var rgba = [UInt8](repeating: 0, count: 16 * 16 * 4)
            context.render(CIImage(cvPixelBuffer: b), toBitmap: &rgba, rowBytes: 16 * 4,
                bounds: CGRect(x: 0, y: 0, width: 16, height: 16), format: .RGBA8, colorSpace: sRGB)
            return Array(rgba.prefix(4))
        }
        func planeBytes(_ b: CVPixelBuffer) -> [Data] {
            CVPixelBufferLockBaseAddress(b, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
            return (0..<CVPixelBufferGetPlaneCount(b)).map { plane in
                Data(bytes: CVPixelBufferGetBaseAddressOfPlane(b, plane)!,
                    count: CVPixelBufferGetBytesPerRowOfPlane(b, plane) * CVPixelBufferGetHeightOfPlane(b, plane))
            }
        }
        let formats = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                       kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]
        var maximumError = 0
        for format in formats {
            let decoder = VideoDecoder(.desktopSRGB)
            decoder.streamVideoFormat = (format == formats[2] || format == formats[3]) ? StreamProtocol.VIDEO_FORMAT_MASK_10BIT : 0
            for value in [0.0, 0.04, 0.125, 0.25, 0.5, 0.75, 1.0] {
                for tagged in [false, true] {
                    let b = try buffer(format, rgb: (value, value, value))
                    if tagged { tag(b, primaries: p709, transfer: t709, matrix: m709) }
                    let color = decoder.resolveColorDescription(for: b, controlHDR: false)
                    let before = planeBytes(b)
                    let interpretsDesktop = tagged || decoder.streamVideoFormat == 0
                    try expect(color.transfer == (interpretsDesktop ? tsRGB : t709), "guarded desktop transfer")
                    let full = format == formats[0] || format == formats[2]
                    try expect(color.range == (full ? kCVPixelFormatComponentRange_FullRange : kCVPixelFormatComponentRange_VideoRange) as String,
                        "output pixel format owns range, even when full range was requested")
                    if !interpretsDesktop { continue }
                    decoder.attachColorAndHDRMetadata(to: b, color: color)
                    let repeated = decoder.resolveColorDescription(for: b, controlHDR: false)
                    try expect(repeated.attachments === color.attachments, "unchanged frames reuse cached color attachments")
                    try expect(planeBytes(b) == before, "color policy never modifies YUV planes")
                    let rgba = render(b)
                    let expected = Int((value * 255).rounded())
                    let error = rgba.prefix(3).map { abs(Int($0) - expected) }.max()!
                    maximumError = max(maximumError, error)
                    try expect(error <= 3 && rgba[3] == 255, "synthetic gray ramp roundtrip: \(format) \(value) \(rgba)")
                    var description: CMVideoFormatDescription?
                    try expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: b,
                        formatDescriptionOut: &description) == 0, "create display format")
                    try expect(CMFormatDescriptionGetExtension(description!, extensionKey: kCVImageBufferTransferFunctionKey) as? String == tsRGB,
                        "display format has coherent transfer")
                    try expect(CMVideoFormatDescriptionMatchesImageBuffer(description!, imageBuffer: b), "display format matches attachments")
                }
            }
            // Independent RGB -> YCbCr -> color-managed RGB checks catch matrix and chroma regressions.
            for rgb in [(0.8, 0.2, 0.1), (0.1, 0.8, 0.2), (0.2, 0.1, 0.8), (0.6, 0.4, 0.2)] {
                let b = try buffer(format, rgb: rgb)
                tag(b, primaries: p709, transfer: t709, matrix: m709)
                decoder.attachColorAndHDRMetadata(to: b, color: decoder.resolveColorDescription(for: b, controlHDR: false))
                let actual = render(b)
                for (index, expected) in [rgb.0, rgb.1, rgb.2].enumerated() {
                    try expect(abs(Int(actual[index]) - Int((expected * 255).rounded())) <= 3, "color patch roundtrip")
                }
            }
        }
        let source = VideoDecoder(.source)
        let original = try buffer(formats[0])
        tag(original, primaries: p709, transfer: t709, matrix: m709)
        let sourceColor = source.resolveColorDescription(for: original, controlHDR: false)
        try expect(sourceColor.transfer == t709, "source policy preserves declared transfer")
        source.attachColorAndHDRMetadata(to: original, color: sourceColor)
        let baseline = render(original)
        try expect(Int(baseline[0]) >= 135, "fixture must expose original lifted midtones")
        let desktop = VideoDecoder(.desktopSRGB)
        let controlledHDR = try buffer(formats[0])
        tag(controlledHDR, primaries: p709, transfer: t709, matrix: m709)
        try expect(desktop.resolveColorDescription(for: controlledHDR, controlHDR: true).transfer == t709,
            "HDR control excludes desktop SDR reinterpretation")
        for transfer in [pq, hlg, tsRGB, kCVImageBufferTransferFunction_Linear as String, "unknown-transfer"] {
            // IOSurface validates named transfer values and drops arbitrary strings.
            let b = try buffer(formats[2], iosurface: transfer != "unknown-transfer")
            tag(b, primaries: p709, transfer: transfer, matrix: m709)
            try expect(CVBufferCopyAttachment(b, kCVImageBufferTransferFunctionKey, nil) as? String == transfer,
                "fixture attachment: \(CVBufferCopyAttachment(b, kCVImageBufferTransferFunctionKey, nil) as Any)")
            let color = desktop.resolveColorDescription(for: b, controlHDR: true)
            try expect(color.transfer == transfer, "preserve transfer: \(transfer) -> \(color.transfer)")
            try expect(color.isHDR == (transfer == pq || transfer == hlg), "HDR classification")
        }
        for gamma in [2.2, 2.4] {
            let b = try buffer(formats[0], iosurface: false)
            tag(b, primaries: p709, transfer: t709, matrix: m709, gamma: gamma)
            let color = desktop.resolveColorDescription(for: b, controlHDR: false)
            try expect(color.transfer == t709 && color.gamma == gamma, "preserve explicit source gamma")
        }
        for (primaries, matrix) in [(kCVImageBufferColorPrimaries_ITU_R_2020 as String, m709),
                (p709, kCVImageBufferYCbCrMatrix_ITU_R_2020 as String), ("unknown-primaries", m709),
                (p709, kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)] {
            let b = try buffer(formats[0], iosurface: primaries != "unknown-primaries")
            tag(b, primaries: primaries, transfer: t709, matrix: matrix)
            let color = desktop.resolveColorDescription(for: b, controlHDR: false)
            try expect(color.transfer == t709 && color.primaries == primaries && color.matrix == matrix, "preserve other gamuts and matrices")
        }
        let inferredHDR = try buffer(formats[2])
        desktop.streamVideoFormat = StreamProtocol.VIDEO_FORMAT_MASK_10BIT
        try expect(desktop.resolveColorDescription(for: inferredHDR, controlHDR: true).transfer == pq, "preserve inferred PQ")
        try expect(desktop.resolveColorDescription(for: inferredHDR, controlHDR: false).transfer == t709,
                   "untagged ten-bit stream does not imply desktop sRGB")
        // Reuse one buffer through HDR -> SDR, as the decoder's pool may do.
        let transition = try buffer(formats[2])
        tag(transition, primaries: kCVImageBufferColorPrimaries_ITU_R_2020 as String, transfer: pq,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
        desktop.hdrMetadataStore.snapshot = Metadata(mdcv: Data([0x3a,0x98,0x75,0x30,0x1d,0x4c,0x0b,0xb8,
            0x7d,0x00,0x40,0x74,0x3d,0x13,0x40,0x42,0x00,0x98,0x96,0x80,0,0,0,50]),
            contentLightLevel: Data([3,232,1,144]))
        desktop.attachColorAndHDRMetadata(to: transition, color: desktop.resolveColorDescription(for: transition, controlHDR: true))
        try expect(CVBufferCopyAttachment(transition, kCVImageBufferMasteringDisplayColorVolumeKey, nil) != nil,
                   "HDR metadata attached before transition")
        var cached: CMVideoFormatDescription?
        try expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: transition,
            formatDescriptionOut: &cached) == 0, "HDR format fixture")
        desktop.cachedHDRFormatDescription = cached
        tag(transition, primaries: p709, transfer: t709, matrix: m709)
        desktop.attachColorAndHDRMetadata(to: transition, color: desktop.resolveColorDescription(for: transition, controlHDR: false))
        try expect(desktop.cachedHDRFormatDescription == nil, "HDR to SDR invalidates display format cache")
        try expect(CVBufferCopyAttachment(transition, kCVImageBufferMasteringDisplayColorVolumeKey, nil) == nil
            && CVBufferCopyAttachment(transition, kCVImageBufferContentLightLevelInfoKey, nil) == nil, "SDR clears HDR metadata")
        try expect(CVBufferCopyAttachment(transition, kCVImageBufferTransferFunctionKey, nil) as? String == tsRGB,
                   "HDR to SDR restores desktop transfer")
        // Compressed-format metadata is used when VT omits a buffer tag.
        var input: CMVideoFormatDescription?
        try expect(CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264, width: 16, height: 16,
            extensions: [kCVImageBufferColorPrimariesKey: p709, kCVImageBufferTransferFunctionKey: hlg,
                         kCVImageBufferYCbCrMatrixKey: m709] as CFDictionary, formatDescriptionOut: &input) == 0, "synthetic input description")
        desktop.formatDescription = input
        try expect(desktop.resolveColorDescription(for: try buffer(formats[2]), controlHDR: false).transfer == hlg, "preserve input format HDR tags")
        print("{\"status\":\"passed\",\"checks\":\(count),\"maximumGrayError8bit\":\(maximumError),\"sourceMidGray\":\(baseline[0]),\"scope\":\"fresh synthetic buffers; real CoreVideo/CoreMedia/CoreImage; inert lifecycle\"}")
    }
}
'''

types = (ENGINE / "Models/Types.swift").read_text()
configuration = (ENGINE / "Session/StreamConnection+Configuration.swift").read_text()
# Keep actual enum declarations, but omit unrelated protocol numeric wire mappings.
color_types = "\n".join(block(types, "package enum " + name).split("    package var cValue:")[0] + "}" for name in ["ColorSpace", "ColorRange"])
fixture = fixture.replace("__ACTUAL_TYPES__", block(configuration, "public enum SDRColorMode:") + "\n" + color_types)
color_source = ENGINE / "Video/VideoDecoder+Color.swift"
with tempfile.TemporaryDirectory(prefix="knot-video-color-") as temporary:
    directory = Path(temporary)
    swift = directory / "ColorChecks.swift"
    swift.write_text(fixture)
    binary = directory / "color-checks"
    subprocess.run(["/usr/bin/swiftc", "-swift-version", "6", "-package-name", "Glimmer", "-parse-as-library",
                    str(color_source), str(swift), "-o", str(binary)], check=True)
    result = subprocess.run([str(binary)], capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(result.stderr + result.stdout)
    receipt = json.loads(result.stdout)
    receipt["productionColorSHA256"] = hashlib.sha256(color_source.read_bytes()).hexdigest()
    print(json.dumps(receipt, indent=2))
