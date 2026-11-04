import AppKit
import Combine
import SwiftUI

/// Tokens are immutable; NotificationCenter removal is safe from deinit's thread.
final class NativeWindowNotifications: @unchecked Sendable {
    let tokens: [NSObjectProtocol]
    init(_ tokens: [NSObjectProtocol]) { self.tokens = tokens }
    deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}

@MainActor
final class NativeWindowState: ObservableObject {
    @Published private(set) var isFullscreen = false
    private var onClose: (@MainActor @Sendable () -> Void)?
    private weak var window: NSWindow?
    private var notifications: NativeWindowNotifications?
    func bindSession(_ model: SessionModel, enrollment: EnrollmentModel) {
        onClose = { [weak model, weak enrollment] in
            model?.disconnect()
            enrollment?.cancel()
        }
    }
    func attach(_ next: NSWindow?) {
        // The probe can temporarily lose its window during SwiftUI/fullscreen
        // transitions. Keep observing the owner until its actual willClose.
        guard let next else { return }
        guard window !== next else { return }
        notifications = nil; window = next
        isFullscreen = next.styleMask.contains(.fullScreen)
        notifications = NativeWindowNotifications([
            NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification, NSWindow.willCloseNotification
        ].map { name in
            NotificationCenter.default.addObserver(forName: name, object: next, queue: .main) { [weak self, weak next] _ in
                MainActor.assumeIsolated {
                    guard let self, let next, self.window === next else { return }
                    if name == NSWindow.willCloseNotification {
                        let revoke = self.onClose
                        self.onClose = nil
                        revoke?() // Revokes TLS and queued input before close returns.
                        self.notifications = nil; self.window = nil; self.isFullscreen = false
                    } else {
                        self.isFullscreen = name == NSWindow.didEnterFullScreenNotification
                    }
                }
            }
        })
    }
    func toggleFullscreen() { window?.toggleFullScreen(nil) }
    func canToggleFullscreenControls(for model: SessionModel) -> Bool { isFullscreen && model.active }
    func toggleFullscreenControls(for model: SessionModel) {
        guard canToggleFullscreenControls(for: model) else { return }
        model.releaseInput()
        model.showFullscreenControls.toggle()
    }
}

struct NativeWindowProbe: NSViewRepresentable {
    let state: NativeWindowState
    final class Probe: NSView {
        var state: NativeWindowState?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); state?.attach(window) }
    }
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.state = state; return view }
    func updateNSView(_ view: Probe, context: Context) { view.state = state; state.attach(view.window) }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.state?.attach(nil); view.state = nil }
}
