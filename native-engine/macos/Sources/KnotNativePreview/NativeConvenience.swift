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
        model.$phase.sink { [weak self, weak model] phase in
            guard phase == .streaming, let self, let model,
                  let raw = self.defaults.object(forKey: "native.quality") as? Int,
                  let value = QualityModel.Preference(rawValue: UInt8(clamping: raw)) else { return }
            model.quality?.choose(value)
        }.store(in: &observations)
    }
}

/// One registered chord; no event monitor, event tap or Accessibility permission.
@MainActor
final class NativeQuickActivation: ObservableObject {
    @Published private(set) var shortcutAvailable = false
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?
    func register(action: @escaping () -> Void) {
        self.action = action
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x4B4E4F54, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Unmanaged<NativeQuickActivation>.fromOpaque(context).takeUnretainedValue().action?() }
            return noErr
        }, 1, &type, pointer, &handler) == noErr else { return }
        shortcutAvailable = RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(controlKey | optionKey | cmdKey),
            EventHotKeyID(signature: 0x4B4E4F54, id: 1), GetApplicationEventTarget(), 0, &hotkey) == noErr
    }
    func stop() {
        if let hotkey { UnregisterEventHotKey(hotkey) }; hotkey = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
        shortcutAvailable = false; action = nil
    }
}
