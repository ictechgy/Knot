import AppKit
import Combine
import SwiftUI

/// Tokens are immutable; NotificationCenter removal is safe from deinit's thread.
private final class NativeWindowNotifications: @unchecked Sendable {
    let tokens: [NSObjectProtocol]
    init(_ tokens: [NSObjectProtocol]) { self.tokens = tokens }
    deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}

@MainActor
final class NativeWindowState: ObservableObject {
    @Published private(set) var isFullscreen = false
    var onClose: (@MainActor @Sendable () -> Void)?
    private weak var window: NSWindow?
    private var notifications: NativeWindowNotifications?
    func attach(_ next: NSWindow?) {
        guard window !== next else { return }
        notifications = nil; window = next
        isFullscreen = next?.styleMask.contains(.fullScreen) == true
        guard let next else { return }
        notifications = NativeWindowNotifications([
            NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification, NSWindow.willCloseNotification
        ].map { name in
            NotificationCenter.default.addObserver(forName: name, object: next, queue: .main) { [weak self, weak next] _ in
                MainActor.assumeIsolated {
                    guard let self, self.window === next else { return }
                    if name == NSWindow.willCloseNotification { self.onClose?() }
                    self.isFullscreen = next?.styleMask.contains(.fullScreen) == true
                }
            }
        })
    }
    func toggleFullscreen() { window?.toggleFullScreen(nil) }
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
