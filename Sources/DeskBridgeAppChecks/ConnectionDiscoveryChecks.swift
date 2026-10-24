// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreImage
import Darwin
import DeskBridgeCore
import ImageIO

@MainActor
func runConnectionDiscoveryChecks(temporary: URL) async throws -> Int {
    var count = 0
    func expect(_ condition: Bool, _ message: String) throws { guard condition else { throw ModelCheckFailure(message: message) }; count += 1 }
    func rejectImage(_ data: Data) throws {
        var rejected = false
        do { _ = try ConnectionQRReader.decode(data: data) } catch { rejected = true }
        try expect(rejected, "invalid QR image rejected")
    }
    let invitation = try ConnectionInvitation(name: "Synthetic PC", addresses: ["192.168.1.20", "100.80.10.20"])
    let generator = CIFilter(name: "CIQRCodeGenerator")!
    generator.setValue(Data(invitation.url.absoluteString.utf8), forKey: "inputMessage")
    generator.setValue("M", forKey: "inputCorrectionLevel")
    let context = CIContext(options: [.useSoftwareRenderer: true])
    let ci = generator.outputImage!.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
    let image = context.createCGImage(ci, from: ci.extent)!
    let png = NSMutableData()
    let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    try expect(CGImageDestinationFinalize(destination), "synthetic PNG fixture generated")
    try expect(try ConnectionQRReader.decode(data: png as Data) == invitation, "actual QR image decoder roundtrip")

    // A valid three-pixel module becomes subpixel if an 8000-wide image is
    // forced down to 2048. Keep the accepted canvas bounded, without losing QR detail.
    let rawQR = context.createCGImage(generator.outputImage!, from: generator.outputImage!.extent)!
    let canvasWidth = 8000, canvasHeight = 2000, modulePixels = 3
    let canvas = CGContext(data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8,
        bytesPerRow: canvasWidth * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    canvas.setFillColor(CGColor(gray: 1, alpha: 1))
    canvas.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
    canvas.interpolationQuality = .none
    canvas.draw(rawQR, in: CGRect(x: (canvasWidth - rawQR.width * modulePixels) / 2,
        y: (canvasHeight - rawQR.height * modulePixels) / 2,
        width: rawQR.width * modulePixels, height: rawQR.height * modulePixels))
    let largePNG = NSMutableData()
    let largeDestination = CGImageDestinationCreateWithData(largePNG, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(largeDestination, canvas.makeImage()!, nil)
    try expect(CGImageDestinationFinalize(largeDestination) && largePNG.length < ConnectionQRReader.maximumFileBytes,
               "bounded large-canvas QR fixture generation failed")
    try expect(try ConnectionQRReader.decode(data: largePNG as Data) == invitation,
               "small QR region in accepted large image lost its module detail")
    let cancelledDecode = Task { () throws -> ConnectionInvitation in
        withUnsafeCurrentTask { $0?.cancel() }
        return try ConnectionQRReader.decode(data: largePNG as Data)
    }
    var cancellationKept = false
    do { _ = try await cancelledDecode.value } catch is CancellationError { cancellationKept = true }
    try expect(cancellationKept, "cancelled QR decoding must stop before parsing an image")
    for (format, accepted) in [("com.microsoft.bmp", true), ("com.compuserve.gif", false)] {
        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, format as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        try expect(CGImageDestinationFinalize(destination), "synthetic image format fixture generated")
        if accepted {
            try expect(try ConnectionQRReader.decode(data: encoded as Data) == invitation,
                       "Windows-compatible BMP QR did not decode")
        } else { try rejectImage(encoded as Data) }
    }
    for orientation in [3, 6, 8] {
        let tiff = NSMutableData()
        let destination = CGImageDestinationCreateWithData(tiff, "public.tiff" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        try expect(CGImageDestinationFinalize(destination), "synthetic oriented image generated")
        try expect(try ConnectionQRReader.decode(data: tiff as Data) == invitation, "EXIF-oriented QR decode changed invitation")
    }
    let qrFile = temporary.appendingPathComponent("synthetic-qr.png"); try (png as Data).write(to: qrFile)
    let decodedImage = try await ConnectionQRReader.decodeImage(at: qrFile)
    try expect(decodedImage == invitation, "detached bounded image read/decode changed the invitation")
    try rejectImage(Data("not an image".utf8))
    try rejectImage(Data(repeating: 0, count: ConnectionQRReader.maximumFileBytes + 1))

    var socket = sockaddr_in()
    socket.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); socket.sin_family = sa_family_t(AF_INET)
    socket.sin_port = UInt16(47989).bigEndian
    socket.sin_addr.s_addr = inet_addr("192.168.1.20")
    let data = withUnsafeBytes(of: &socket) { Data($0) }
    try expect(NearbyPCBrowser.ipv4(data) == "192.168.1.20", "actual DNS-SD sockaddr parser")
    try expect(NearbyPCBrowser.ipv4(data.prefix(5)) == nil, "truncated sockaddr rejected")
    socket.sin_port = UInt16(443).bigEndian
    try expect(NearbyPCBrowser.ipv4(withUnsafeBytes(of: &socket) { Data($0) }) == nil, "alternate service port rejected")
    socket.sin_family = sa_family_t(AF_INET6)
    try expect(NearbyPCBrowser.ipv4(withUnsafeBytes(of: &socket) { Data($0) }) == nil, "IPv6 is not misread as IPv4")

    let directory = temporary.appendingPathComponent("connection-discovery")
    var saved = SavedSettings(); saved.address = "192.168.1.9"
    saved.host = SavedHost(address: saved.address, uniqueID: "saved-PC", name: "Saved",
                          certificatePEM: "SYNTHETIC SAVED PIN", httpPort: 47989, httpsPort: 47984)
    saved.sshHostPublicKey = "SYNTHETIC SSH PIN"
    let store = SettingsStore(directory: directory); try store.save(saved)
    let suite = "org.deskbridge.synthetic." + UUID().uuidString
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let model = DesktopModel(storageDirectory: directory, identitySuite: suite)
    let files = FilesModel(desktop: model)
    let macInvitation = try ConnectionInvitation(name: "Synthetic Mac", addresses: ["192.168.1.20"], platform: .macos)
    _ = InvitationRouting.review(macInvitation.url.absoluteString, windows: model, linux: nil)
    try expect(model.pendingInvitation == nil && model.invitationError != nil && model.address == saved.address,
               "Mac sharing invitation was accepted into the Windows desktop role")
    try expect(model.invitationError?.contains("Windows의 Knot") == true,
               "Mac sharing link gave a nonexistent Mac-client tab as recovery guidance")
    model.invitationError = nil
    try expect(!model.nearby.searching && model.nearby.hosts.isEmpty, "constructing models starts no network search")
    let invalidLinkPage = InvitationRouting.review("deskbridge://connect?v=invalid", windows: model, linux: nil)
    try expect(invalidLinkPage == .desktop && model.invitationError == ConnectionInvitation.Failure.invalid.localizedDescription,
               "malformed external link did not show actionable invalid-link guidance")
    try expect(model.pendingInvitation == nil && model.address == saved.address && !model.busy && !model.nearby.searching,
               "malformed external link staged a target or started connection/discovery work")
    try expect(model.settings.host?.certificatePEM == saved.host?.certificatePEM &&
               model.settings.sshHostPublicKey == saved.sshHostPublicKey &&
               (try store.load()).host?.uniqueID == saved.host?.uniqueID,
               "malformed external link changed stored target or trust")
    model.invitationError = nil
    try model.reviewInvitation(invitation)
    try expect(model.pendingInvitation == invitation && model.address == saved.address, "QR import only stages a user preview")
    for kind in 0..<4 {
        files.connected = kind == 0; files.busy = kind == 1; model.busy = kind == 2; model.streaming = kind == 3
        var rejected = false
        do { try model.selectCandidateAddress(invitation.addresses[0]) } catch { rejected = true }
        try expect(rejected && model.address == saved.address, "active screen/files prevent QR/discovery target change")
    }
    files.connected = false; files.busy = false; model.busy = false; model.streaming = false
    model.paired = true
    model.invitationError = "synthetic invalid QR"
    try expect(model.paired && model.errorMessage == nil, "QR input error changed host verification status")
    try model.selectCandidateAddress(invitation.addresses[0])
    try expect(model.address == invitation.addresses[0] && model.pendingInvitation == nil && !model.paired, "selection clears provisional state and requires PC verification")
    try expect(model.settings.host?.certificatePEM == saved.host?.certificatePEM && model.settings.sshHostPublicKey == saved.sshHostPublicKey,
               "QR selection never replaces screen or SSH trust")
    try expect(try store.load().address == saved.address && store.load().host?.uniqueID == saved.host?.uniqueID, "selection does not silently persist or connect")
    return count
}
