#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Actual QR renderer with fresh synthetic addresses/capabilities; no UI or IO.

Compile in Swift 6, decode both QR domains, verify the integer-scale white quiet
zone and PNG export, and exercise replacement of the single public-address entry.
Enrollment images remain uncached; neither generated links nor pixels are logged.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SWIFT = r'''
import AppKit
import CoreImage
import DeskBridgeCore

@main struct Checks {
    @MainActor static func main() throws {
        var count = 0
        func expect(_ condition: @autoclosure () -> Bool) {
            precondition(condition(), "synthetic QR check failed")
            count += 1
        }
        func cgImage(_ image: NSImage) -> CGImage {
            guard let result = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                fatalError("missing synthetic QR pixels")
            }
            return result
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: context,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!
        func decoded(_ image: CGImage) -> String? {
            let codes = detector.features(in: CIImage(cgImage: image)).compactMap { $0 as? CIQRCodeFeature }
            return codes.count == 1 ? codes[0].messageString : nil
        }
        func quietZone(_ image: CGImage, pixels: Int) {
            expect(image.width > pixels * 2 && image.height > pixels * 2)
            let bitmap = NSBitmapImageRep(cgImage: image)
            // Inspect every outer quiet-zone pixel, including its inner edge,
            // rather than relying on QR detection to tolerate a bad border.
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide where x < pixels || y < pixels ||
                    x >= bitmap.pixelsWide - pixels || y >= bitmap.pixelsHigh - pixels {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                        fatalError("unreadable synthetic QR pixel")
                    }
                    precondition(color.redComponent > 0.99 && color.greenComponent > 0.99 &&
                                 color.blueComponent > 0.99 && color.alphaComponent > 0.99,
                                 "synthetic QR quiet zone lost")
                }
            }
            count += 1
        }

        let first = try ConnectionInvitation(name: "Synthetic Mac", addresses: ["192.168.1.20"], platform: .macos)
        let second = try ConnectionInvitation(name: "Synthetic Mac", addresses: ["100.64.1.20"], platform: .macos)
        let image = MacHostQR.image(first)!
        expect(MacHostQR.image(first) === image)
        let pixels = cgImage(image)
        expect(pixels.width % 8 == 0 && pixels.width == pixels.height)
        expect(decoded(pixels) == first.url.absoluteString)
        quietZone(pixels, pixels: 32)
        let data = MacHostQR.png(first)!
        expect(Array(data.prefix(8)) == [137,80,78,71,13,10,26,10])
        let exported = NSBitmapImageRep(data: data)!.cgImage!
        expect(exported.width == pixels.width && exported.height == pixels.height)
        expect(decoded(exported) == first.url.absoluteString)
        quietZone(exported, pixels: 32)
        // PNG export and unrelated renders do not invalidate the current public
        // entry. Switching to another address evicts it instead of growing a map.
        expect(MacHostQR.image(first) === image)
        let replacement = MacHostQR.image(second)!
        expect(replacement !== image && MacHostQR.image(second) === replacement)
        expect(decoded(cgImage(replacement)) == second.url.absoluteString)
        expect(MacHostQR.image(first) !== image)

        let link = try EnrollmentProtocol.Link(address: "192.168.1.20", port: 20000,
            sessionID: "00000000-0000-0000-0000-000000000001",
            certificateSHA256: String(repeating: "a", count: 64), capability: String(repeating: "b", count: 64))
        let enrollment = EnrollmentQR.image(link.text)!
        expect(EnrollmentQR.image(link.text) !== enrollment)
        let enrollmentPixels = cgImage(enrollment)
        expect(enrollmentPixels.width % 4 == 0 && enrollmentPixels.width == enrollmentPixels.height)
        expect(decoded(enrollmentPixels) == link.text)
        quietZone(enrollmentPixels, pixels: 16)
        expect(EnrollmentQR.image("") == nil)
        expect(EnrollmentQR.image(link.text + "\n") == nil)
        expect(EnrollmentQR.image(first.url.absoluteString) == nil)
        print("{\"status\":\"passed\",\"checks\":\(count),\"network\":false,\"ui\":false,\"persistent_cache\":false}")
    }
}
'''


def main():
    with tempfile.TemporaryDirectory(prefix="knot-qr-synthetic-") as folder:
        temp = Path(folder)
        os.chmod(temp, 0o700)

        def run(argv):
            result = subprocess.run(list(map(str, argv)), cwd=temp, capture_output=True, text=True)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)
            return result.stdout

        run(["/usr/bin/swiftc", "-swift-version", "6", "-parse-as-library", "-emit-library", "-static",
             "-emit-module", "-module-name", "DeskBridgeCore", *sorted((ROOT / "Sources/DeskBridgeCore").rglob("*.swift")),
             "-emit-module-path", temp / "DeskBridgeCore.swiftmodule", "-o", temp / "libDeskBridgeCore.a"])
        (temp / "Checks.swift").write_text(SWIFT)
        run(["/usr/bin/swiftc", "-swift-version", "6", "-parse-as-library", "-I", temp, "-L", temp,
             "-lDeskBridgeCore", ROOT / "Sources/DeskBridgeApp/ConnectionQR.swift", temp / "Checks.swift",
             "-o", temp / "Checks"])
        print(run([temp / "Checks"]).strip())


if __name__ == "__main__":
    main()
