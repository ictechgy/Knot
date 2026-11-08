import AppKit
import Carbon
import Combine
import SwiftUI

/// Nonsecret preferences. Only the production App entry point creates this adapter.
@MainActor
final class NativePreferences: ObservableObject {
    private let defaults: UserDefaults
    private var observations = Set<AnyCancellable>()
    private var qualityObservation: AnyCancellable?
    @Published var preferFullscreen: Bool { didSet { defaults.set(preferFullscreen, forKey: "native.fullscreen") } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferFullscreen = defaults.bool(forKey: "native.fullscreen")
    }
    func bind(_ model: SessionModel) {
        guard observations.isEmpty else { return }
        if let value = defaults.string(forKey: "native.viewerLabel"), !value.isEmpty { model.viewerLabel = value }
        if defaults.object(forKey: "native.macShortcuts") != nil { model.macShortcuts = defaults.bool(forKey: "native.macShortcuts") }
        model.$viewerLabel.dropFirst().sink { [weak self] in self?.defaults.set($0, forKey: "native.viewerLabel") }.store(in: &observations)
        model.$macShortcuts.dropFirst().sink { [weak self] in self?.defaults.set($0, forKey: "native.macShortcuts") }.store(in: &observations)
        if defaults.object(forKey: "native.autoReconnect") != nil { model.autoReconnect = defaults.bool(forKey: "native.autoReconnect") }
        model.$autoReconnect.dropFirst().sink { [weak self] in self?.defaults.set($0, forKey: "native.autoReconnect") }.store(in: &observations)
        model.$quality.sink { [weak self] quality in
            self?.qualityObservation = quality?.$preference.dropFirst().sink { [weak self] in self?.defaults.set(Int($0.rawValue), forKey: "native.quality") }
        }.store(in: &observations)
    }
    func restoreQuality(_ model: SessionModel) {
        guard model.phase == .streaming, let raw = defaults.object(forKey: "native.quality") as? Int,
              let value = QualityModel.Preference(rawValue: UInt8(clamping: raw)) else { return }
        model.quality?.choose(value)
    }
}

/// Owns one app-scoped registration. Tests supply an inert registrar.
@MainActor
protocol NativeActivationRegistering: AnyObject {
    func register(action: @escaping () -> Void) -> Bool
    func stop()
}

@MainActor
private final class NativeCarbonActivationRegistration: NativeActivationRegistering {
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?
    func register(action: @escaping () -> Void) -> Bool {
        self.action = action
        if hotkey != nil { return true }
        // A chord conflict does not invalidate an already installed handler.
        // Retry the chord independently when the window appears again.
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let pointer = Unmanaged.passUnretained(self).toOpaque()
            guard InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let context, let event else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                      id.signature == 0x4B4E4F54, id.id == 1 else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated { Unmanaged<NativeCarbonActivationRegistration>.fromOpaque(context).takeUnretainedValue().action?() }
                return noErr
            }, 1, &type, pointer, &handler) == noErr else { return false }
        }
        return RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(controlKey | optionKey | cmdKey),
            EventHotKeyID(signature: 0x4B4E4F54, id: 1), GetApplicationEventTarget(), 0, &hotkey) == noErr
    }
    func stop() {
        if let hotkey { UnregisterEventHotKey(hotkey) }; hotkey = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
        action = nil
    }
}

/// One registered chord; no event monitor, event tap or Accessibility permission.
@MainActor
final class NativeQuickActivation: ObservableObject {
    @Published private(set) var shortcutAvailable = false
    private let registration: any NativeActivationRegistering
    private var termination: AnyCancellable?
    private let notificationCenter: NotificationCenter
    init(registration: (any NativeActivationRegistering)? = nil, notificationCenter: NotificationCenter = .default) {
        self.registration = registration ?? NativeCarbonActivationRegistration()
        self.notificationCenter = notificationCenter
    }
    func register(action: @escaping () -> Void) {
        if termination == nil {
            termination = notificationCenter.publisher(for: NSApplication.willTerminateNotification).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
        }
        shortcutAvailable = registration.register(action: action)
    }
    func stop() {
        registration.stop(); shortcutAvailable = false
        termination?.cancel(); termination = nil
    }
}
