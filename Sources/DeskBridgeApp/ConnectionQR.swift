// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreImage.CIFilterBuiltins
import DeskBridgeCore

/// QR rendering is UI-owned. Reuse the expensive context, without keeping image
/// intermediates containing a short-lived enrollment capability in its cache.
@MainActor
private enum ConnectionQRRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func code(_ text: String, scale: Int) -> CGImage? {
        // Filters are mutable and remain local to this render. Only the context
        // is shared; no text, filter or enrollment image is retained here.
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let raw = filter.outputImage else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: raw.extent.width + 8, height: raw.extent.height + 8)
        let white = CIImage(color: .white).cropped(to: bounds)
        let composed = raw.transformed(by: .init(translationX: 4, y: 4))
            .composited(over: white)
            .transformed(by: .init(scaleX: CGFloat(scale), y: CGFloat(scale)))
        return context.createCGImage(composed, from: composed.extent)
    }
}

@MainActor
enum EnrollmentQR {
    static func image(_ text: String) -> NSImage? {
        guard (try? EnrollmentProtocol.Link(text)) != nil,
              let image = ConnectionQRRenderer.code(text, scale: 4) else { return nil }
        // Deliberately no value cache: clearing/expiring the enrollment link
        // must not leave its bearer capability in a process-wide QR cache.
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

@MainActor
enum MacHostQR {
    private struct Entry {
        let text: String
        let code: CGImage
        let image: NSImage
    }
    // Address-only invitations carry no credentials. Keep just the latest one,
    // rather than accumulating every address shown during interface changes.
    private static var current: Entry?

    static func image(_ invitation: ConnectionInvitation) -> NSImage? { entry(invitation)?.image }

    static func png(_ invitation: ConnectionInvitation) -> Data? {
        guard let entry = entry(invitation) else { return nil }
        return NSBitmapImageRep(cgImage: entry.code).representation(using: .png, properties: [:])
    }

    private static func entry(_ invitation: ConnectionInvitation) -> Entry? {
        let text = invitation.url.absoluteString
        if let current, current.text == text { return current }
        current = nil
        guard let code = ConnectionQRRenderer.code(text, scale: 8) else { return nil }
        let image = NSImage(cgImage: code, size: NSSize(width: code.width, height: code.height))
        let replacement = Entry(text: text, code: code, image: image)
        current = replacement
        return replacement
    }
}
