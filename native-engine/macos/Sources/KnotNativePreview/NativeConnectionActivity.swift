import Foundation

protocol NativeConnectionActivityHolding: AnyObject {
    func stop()
}

/// Keeps user-requested networking out of App Nap while still allowing the
/// display and the Mac itself to sleep. The token never authorizes a session.
/// Production opts in at app construction; synthetic sessions have no activity.
final class NativeConnectionActivity: NativeConnectionActivityHolding, @unchecked Sendable {
    static let options: ProcessInfo.ActivityOptions = .userInitiatedAllowingIdleSystemSleep
    private let lock = NSLock()
    private var token: (any NSObjectProtocol)?
    private let end: (any NSObjectProtocol) -> Void

    init(begin: () -> any NSObjectProtocol = {
        ProcessInfo.processInfo.beginActivity(options: NativeConnectionActivity.options,
                                               reason: "Maintain the requested remote desktop connection")
    }, end: @escaping (any NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }) {
        self.end = end
        token = begin()
    }

    func stop() {
        lock.lock(); let owned = token; token = nil; lock.unlock()
        if let owned { end(owned) }
    }

    deinit { stop() }
}
