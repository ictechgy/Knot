// SPDX-License-Identifier: GPL-3.0-only
// DeskBridge additions: ownership-aware desktop input over the existing encrypted uplink.
import Foundation


extension StreamInput {
    // The active text is separately limited to InputText.maxBytes. Later actions
    // retain at most this many closures and UTF-8 text bytes during backpressure.
    static let desktopEventLimit = 256
    static let desktopTextByteLimit = 16 * 1024

    @MainActor private func enqueueDesktopEvent(textBytes: Int = 0, _ event: @escaping @MainActor () -> Void) {
        guard desktopEvents.count < Self.desktopEventLimit,
              textBytes <= Self.desktopTextByteLimit - desktopEventBytes else {
            // Nothing that has not reached the uplink is replayed after saturation.
            // Accepted downs remain release obligations, including rejected ups.
            cancelDesktopText()
            core.withLock {
                guard !terminal, !desktopInputBlocked else { return }
                desktopInputBlocked = true
                core.snapshot.focused = false
                core.snapshot.acceptEventsAfter = ProcessInfo.processInfo.systemUptime
                releaseOwnership()
                emit(.desktopInputBlocked(true))
            }
            return
        }
        desktopEventBytes += textBytes
        desktopEvents.append(event)
    }

    @MainActor func cancelDesktopText() {
        desktopTextGeneration = UUID()
        desktopTextTask?.cancel()
        desktopTextTask = nil
        desktopEvents.removeAll()
        desktopEventBytes = 0
        let batcher = core.withLock { () -> InputBatcher? in
            guard let native = core.backend as? NativeBackend else { return nil }
            return native.withState { native.inputBatcher }
        }
        batcher?.abandonTextSubmission()
    }

    @MainActor func cancelRevokedDesktopText() {
        let epoch = core.withLock { desktopRevocationEpoch }
        guard desktopTextEpoch != epoch else { return }
        cancelDesktopText()
        desktopTextEpoch = epoch
    }

    /// Windows virtual key in 0...255. Keys are positional; the Mac adapter owns layout mapping.
    @MainActor public func setKey(_ virtualKey: UInt16, pressed: Bool, modifiers: UInt8 = 0,
                                   capturedAt: TimeInterval) {
        cancelRevokedDesktopText()
        guard virtualKey <= 255, core.withLock({ accepts(capturedAt) }) else { return }
        if desktopTextTask != nil {
            enqueueDesktopEvent { [weak self] in
                self?.setKey(virtualKey, pressed: pressed, modifiers: modifiers, capturedAt: capturedAt)
            }
            return
        }
        core.withLock {
            guard accepts(capturedAt) else { return }
            defer { scheduleReconciliation() }
            (core.backend as? NativeBackend)?.enableDesktopInputOrdering()
            let key = VKScanCode(vk: Int16(virtualKey))
            if pressed {
                guard core.flushReleases() else { return }
                guard !core.releases.held.contains(.key(key)) else { return }
                let result = core.backend?.sendKeyboard(keyCode: key.wireCode,
                    action: Int8(StreamProtocol.KEY_ACTION_DOWN), modifiers: Int8(bitPattern: modifiers), flags: 0) ?? -2
                core.record("desktop key down", result)
                if result == 0 { core.releases.hold(.key(key)) }
            } else {
                // Record every owned release before retrying older releases. Otherwise an
                // older rejected key up can discard this key up and leave its key held.
                core.releases.release(.key(key), modifiers: Int8(bitPattern: modifiers))
                _ = core.flushReleases()
            }
        }
    }

    /// Host pixels within the displayed image; finite coordinates are clamped to the host rectangle.
    public func positionPointer(x: Double, y: Double, width: Int, height: Int, capturedAt: TimeInterval) {
        core.withLock {
            guard accepts(capturedAt), x.isFinite, y.isFinite,
                  (1...32767).contains(width), (1...32767).contains(height) else { return }
            (core.backend as? NativeBackend)?.enableDesktopInputOrdering()
            guard core.flushReleases() else { return }
            let result = core.backend?.sendMousePosition(x: Int16(max(0, min(Double(width - 1), x))),
                y: Int16(max(0, min(Double(height - 1), y))), refW: Int16(width), refH: Int16(height)) ?? -2
            core.record("desktop absolute pointer", result)
        }
    }

    /// Text commits are bounded and ordered before later keys, including rejected-packet retries.
    @MainActor public func commitText(_ value: String, capturedAt: TimeInterval) {
        cancelRevokedDesktopText()
        let text = InputText.prepared(value)
        guard !text.isEmpty, core.withLock({ accepts(capturedAt) }) else { return }
        if desktopTextTask != nil {
            enqueueDesktopEvent(textBytes: text.utf8.count) { [weak self] in self?.commitText(text, capturedAt: capturedAt) }
            return
        }
        let attempt = core.withLock { () -> UUID? in
            if let native = core.backend as? NativeBackend {
                native.enableDesktopInputOrdering()
                // This is a new logical commit. InputText's internal retries bypass this reset.
                native.readyBatcher()?.abandonTextSubmission()
            }
            let held = core.releases.held.filter { if case .key = $0 { return true }; return false }
            for key in held { core.releases.release(key) }
            _ = core.flushReleases()
            return activeAttempt
        }
        let token = UUID()
        desktopTextGeneration = token
        desktopTextEpoch = core.withLock { desktopRevocationEpoch }
        desktopTextTask = InputText.send(text, core: core, waitForRelease: false,
            isCurrent: { [weak self] in
                guard let self else { return false }
                return self.core.withLock { self.activeAttempt == attempt && self.accepts(capturedAt) }
            }, flushReleases: { [weak self] in self?.core.withLock { self?.core.flushReleases() ?? false } ?? false },
            finished: { [weak self] in
                guard let self, self.desktopTextGeneration == token else { return }
                self.desktopTextTask = nil
                let queued = self.desktopEvents
                self.desktopEvents.removeAll()
                self.desktopEventBytes = 0
                for event in queued { event() }
            })
    }

    /// Reuse the existing text continuation FIFO for a click/caret action after a pending commit.
    @MainActor public func afterDesktopText(capturedAt: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        cancelRevokedDesktopText()
        guard core.withLock({ accepts(capturedAt) }) else { return }
        let attempt = core.withLock { activeAttempt }
        let guarded: @MainActor () -> Void = { [weak self] in
            guard let self, self.core.withLock({ self.activeAttempt == attempt && self.accepts(capturedAt) }) else { return }
            action()
        }
        if desktopTextTask != nil {
            // Re-enter at replay: an earlier queued commit may have opened another acceptance wait.
            enqueueDesktopEvent { [weak self] in self?.afterDesktopText(capturedAt: capturedAt, guarded) }
        } else { guarded() }
    }

    /// The native view invokes this before focus is lost or its window closes.
    @MainActor public func releaseDesktopInput() {
        cancelDesktopText()
        setFocused(false)
    }
}
