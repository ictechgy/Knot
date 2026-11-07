import AppKit
import Combine

/// Keep the originating center with its tokens: workspace notifications do not
/// use NotificationCenter.default. Removal is safe from deinit's thread.
private final class NativePowerNotifications: @unchecked Sendable {
    let center: NotificationCenter
    let tokens: [NSObjectProtocol]
    init(center: NotificationCenter, tokens: [NSObjectProtocol]) {
        self.center = center; self.tokens = tokens
    }
    deinit { for token in tokens { center.removeObserver(token) } }
}

@MainActor
final class NativePowerMonitor: ObservableObject {
    private var notifications: NativePowerNotifications?
    private weak var model: SessionModel?

    // No default workspace access here: production binds at actual app startup,
    // and tests inject a fresh, isolated center without live power events.
    func bind(_ model: SessionModel, notificationCenter: NotificationCenter) {
        guard self.model !== model || notifications?.center !== notificationCenter else { return }
        notifications = nil; self.model = model
        notifications = NativePowerNotifications(center: notificationCenter, tokens: [
            notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak model] _ in
                MainActor.assumeIsolated { model?.systemWillSleep() }
            },
            notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak model] _ in
                MainActor.assumeIsolated { model?.systemDidWake() }
            }
        ])
    }
}
