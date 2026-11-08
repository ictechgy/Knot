import AppKit
import Combine

/// All timestamps come from this application's focus and accepted actions.
struct NativeVideoIdlePolicy {
    static let allowedMinutes = [0, 1, 5, 10, 15, 30, 60]
    private(set) var applicationActive = true
    private(set) var lastInteraction: ContinuousClock.Instant
    private var backgroundSince: ContinuousClock.Instant?
    init(now: ContinuousClock.Instant = .now) { lastInteraction = now }
    mutating func reset(now: ContinuousClock.Instant) { lastInteraction = now; backgroundSince = applicationActive ? nil : now }
    mutating func interaction(now: ContinuousClock.Instant) { lastInteraction = now }
    mutating func focus(_ active: Bool, now: ContinuousClock.Instant) {
        if applicationActive != active { backgroundSince = active ? nil : now }
        applicationActive = active
        if active { interaction(now: now) }
    }
    func shouldPause(minutes: Int, backgroundOnly: Bool, now: ContinuousClock.Instant) -> Bool {
        guard Self.allowedMinutes.contains(minutes), minutes > 0, !backgroundOnly || !applicationActive else { return false }
        let began = backgroundOnly ? max(lastInteraction, backgroundSince ?? lastInteraction) : lastInteraction
        return now - began >= .seconds(minutes * 60)
    }
}

private final class NativeFocusNotifications: @unchecked Sendable {
    let center: NotificationCenter
    let tokens: [NSObjectProtocol]
    init(center: NotificationCenter, tokens: [NSObjectProtocol]) { self.center = center; self.tokens = tokens }
    deinit { for token in tokens { center.removeObserver(token) } }
}

/// Inert until production injects its notification center and app focus.
/// No global event monitors, OS idle reads, preferences, or workspace inspection.
@MainActor
final class NativeVideoIdleMonitor: ObservableObject {
    private var notifications: NativeFocusNotifications?
    private weak var model: SessionModel?
    func bind(_ model: SessionModel, notificationCenter: NotificationCenter, initiallyActive: Bool) {
        guard self.model !== model || notifications?.center !== notificationCenter else { return }
        notifications = nil; self.model = model; model.setApplicationActive(initiallyActive)
        notifications = NativeFocusNotifications(center: notificationCenter, tokens: [
            notificationCenter.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak model] _ in
                MainActor.assumeIsolated { model?.setApplicationActive(true) }
            },
            notificationCenter.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak model] _ in
                MainActor.assumeIsolated { model?.setApplicationActive(false) }
            }
        ])
    }
}
