// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreImage
import DeskBridgeCore
import ImageIO
import UniformTypeIdentifiers

enum ConnectionQRReader {
    static let maximumFileBytes = 8 * 1024 * 1024
    static let supportedImageTypes: [UTType] = [.png, .jpeg, .heic, .tiff, .bmp]
    static func decode(data: Data) throws -> ConnectionInvitation {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= maximumFileBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let sourceType = CGImageSourceGetType(source),
              supportedImageTypes.contains(where: { $0.identifier == sourceType as String }),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...8192).contains(width), (1...8192).contains(height), width * height <= 16_777_216,
              // Preserve small QR regions inside an otherwise valid image. The
              // source stays capped at 16MP (64MiB for an RGBA8 bitmap).
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways: true,
                 kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                 kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw AppFailure("8MB 이하의 QR 이미지 한 장을 선택하세요. PNG·JPEG·HEIC·TIFF·BMP를 사용할 수 있습니다.") }
        try Task.checkCancellation()
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        guard (1...8).contains(orientation) else { throw AppFailure("QR 이미지의 방향 정보를 확인하지 못했습니다.") }
        let oriented = CIImage(cgImage: image).oriented(forExifOrientation: orientation)
        let codes = detector?.features(in: oriented).compactMap { ($0 as? CIQRCodeFeature)?.messageString } ?? []
        try Task.checkCancellation()
        guard codes.count == 1, let text = codes.first else {
            throw AppFailure("PC 연결 QR이 하나 보이는 이미지를 선택하세요.")
        }
        return try ConnectionInvitation(text: text)
    }

    static func decodeImage(at url: URL) async throws -> ConnectionInvitation {
        let decoding = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try decode(data: BoundedRegularFile.read(url, maximumBytes: maximumFileBytes))
        }
        return try await withTaskCancellationHandler {
            try await decoding.value
        } onCancel: { decoding.cancel() }
    }
    @MainActor static func chooseImage() async throws -> ConnectionInvitation? {
        let panel = NSOpenPanel()
        panel.title = "PC 연결 QR 이미지 열기"
        panel.allowedContentTypes = supportedImageTypes
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try await decodeImage(at: url)
    }
}
