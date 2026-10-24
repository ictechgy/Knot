// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import AVFoundation
import Combine
import DeskBridgeCore
import SwiftUI

/// Configured once on MainActor before start. Start/stop are ordered on the
/// capture queue; the preview only retains the session. No frames are saved.
final class QRCaptureSession: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "org.deskbridge.qr-camera")
    func start() { queue.async { self.session.startRunning() } }
    func stop() { queue.async { self.session.stopRunning() } }
}

@MainActor
final class ConnectionCamera: NSObject, ObservableObject, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    @Published private(set) var capture: QRCaptureSession?
    @Published private(set) var status = "카메라 사용 권한을 확인하는 중…"
    var onFound: ((ConnectionInvitation) -> Void)?
    private var generation: UUID?
    private var metadata: AVCaptureMetadataOutput?

    func start() async {
        stop()
        let current = UUID(); generation = current
        let allowed = await AVCaptureDevice.requestAccess(for: .video)
        guard generation == current, !Task.isCancelled else { return }
        guard allowed else {
            status = "카메라 권한이 없습니다. QR 이미지 또는 연결 링크를 사용하거나 시스템 설정에서 카메라를 허용하세요."
            return
        }
        do {
            guard let device = AVCaptureDevice.default(for: .video) else { throw AppFailure("사용 가능한 카메라가 없습니다.") }
            let input = try AVCaptureDeviceInput(device: device)
            let box = QRCaptureSession()
            let output = AVCaptureMetadataOutput()
            do {
                box.session.beginConfiguration()
                defer { box.session.commitConfiguration() }
                box.session.sessionPreset = .medium
                guard box.session.canAddInput(input) else { throw AppFailure("이 카메라를 사용할 수 없습니다.") }
                box.session.addInput(input)
                guard box.session.canAddOutput(output) else { throw AppFailure("카메라의 QR 인식을 사용할 수 없습니다. QR 이미지를 사용하세요.") }
                box.session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                guard output.availableMetadataObjectTypes.contains(.qr) else { throw AppFailure("이 카메라는 QR 인식을 지원하지 않습니다. QR 이미지를 사용하세요.") }
                output.metadataObjectTypes = [.qr]
            }
            metadata = output
            capture = box
            status = "공유할 PC의 Knot의 연결 QR을 카메라에 보여주세요."
            box.start()
        } catch let error as AppFailure {
            status = error.localizedDescription
        } catch {
            status = "카메라를 열지 못했습니다. QR 이미지나 연결 링크를 사용할 수 있습니다."
        }
    }

    func stop() {
        generation = nil
        metadata?.setMetadataObjectsDelegate(nil, queue: nil); metadata = nil
        capture?.stop(); capture = nil
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard generation != nil, capture != nil, metadata === output else { return }
        let texts = Set(objects.prefix(8).compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue })
        guard texts.count == 1, let text = texts.first else { return }
        guard let invitation = try? ConnectionInvitation(text: text) else {
            let message = "공유할 PC의 Knot에서 만든 연결 QR을 보여주세요."
            if status != message { status = message }
            return
        }
        stop()
        onFound?(invitation)
    }
}

private struct CameraPreview: NSViewRepresentable {
    let capture: QRCaptureSession
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel("PC 연결 QR 카메라 미리보기")
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: capture.session)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { }
    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view.layer as? AVCaptureVideoPreviewLayer)?.session = nil
    }
}

struct ConnectionCameraSheet: View {
    let onFound: (ConnectionInvitation) -> Void
    @StateObject private var camera = ConnectionCamera()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("연결 QR 스캔", systemImage: "qrcode.viewfinder").font(.title2.weight(.semibold))
            if let capture = camera.capture {
                CameraPreview(capture: capture).frame(width: 480, height: 300).background(.black)
            }
            Text(camera.status).font(.callout).fixedSize(horizontal: false, vertical: true)
            QuietHelp(text: "카메라는 이 창에서만 사용하고 이미지를 저장하거나 전송하지 않습니다. 같은 모니터를 번갈아 쓴다면 QR 이미지나 연결 링크를 가져오는 방법도 있습니다.")
            HStack { Spacer(); Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 528)
            .task {
                camera.onFound = { invitation in onFound(invitation); dismiss() }
                await camera.start()
            }
            .onDisappear { camera.stop() }
    }
}
