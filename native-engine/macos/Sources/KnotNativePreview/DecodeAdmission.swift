import Foundation
import CoreVideo
import KnotNativeCore

/// One compressed-stream reader waits here instead of dropping predictive units.
/// A ticket covers VT work AND the retained output until MainActor delivery ends.
@MainActor
final class DecodeAdmission {
    static let capacity = 3
    private var tickets: Set<UUID> = []
    private var waiter: (id: UUID, exclusive: Bool, continuation: CheckedContinuation<UUID, any Error>)?
    private var stopped = false
    private(set) var peak = 0
    var count: Int { tickets.count }
    var waiting: Bool { waiter != nil }

    func acquire(exclusive: Bool = false) async throws -> UUID {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, !stopped else { continuation.resume(throwing: CancellationError()); return }
                guard waiter == nil else { continuation.resume(throwing: NativeFailure.state); return }
                if eligible(exclusive) { admit(id); continuation.resume(returning: id) }
                else { waiter = (id, exclusive, continuation) }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel(id) }
        }
    }
    private func eligible(_ exclusive: Bool) -> Bool { exclusive ? tickets.isEmpty : tickets.count < Self.capacity }
    private func admit(_ id: UUID) { tickets.insert(id); peak = max(peak, tickets.count) }
    func release(_ id: UUID) {
        guard tickets.remove(id) != nil, !stopped, let pending = waiter, eligible(pending.exclusive) else { return }
        waiter = nil; admit(pending.id); pending.continuation.resume(returning: pending.id)
    }
    private func cancel(_ id: UUID) {
        guard waiter?.id == id else { return }
        let pending = waiter; waiter = nil; pending?.continuation.resume(throwing: CancellationError())
    }
    func stop() {
        stopped = true; let pending = waiter; waiter = nil
        pending?.continuation.resume(throwing: CancellationError())
    }
}

enum DecodeCompletion: Equatable {
    case image, dropped, failure
    static func classify(status: Int32, frameDropped: Bool, hasImage: Bool) -> Self {
        guard status == 0 else { return .failure }
        if frameDropped { return .dropped }
        return hasImage ? .image : .failure
    }
}

@MainActor
enum DecodeDelivery {
    static func finish(ticket: UUID, admission: DecodeAdmission, status: Int32, frameDropped: Bool,
                       image: CVPixelBuffer?, width: Int, height: Int, onImage: (CVPixelBuffer) -> Void, onFailure: () -> Void) {
        defer { admission.release(ticket) }
        switch DecodeCompletion.classify(status: status, frameDropped: frameDropped, hasImage: image != nil) {
        case .dropped: break
        case .failure: onFailure()
        case .image:
            // A format-description match does not authorize an unexpected
            // output buffer. Ready's immutable dimensions apply to every frame.
            guard let image, CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height else {
                onFailure(); return
            }
            onImage(image)
        }
    }
}

/// A one-sample submission has one completion. Defensively reject duplicate
/// foreign callbacks before retaining another output for MainActor delivery.
final class DecodeCallbackToken: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; guard !claimed else { return false }; claimed = true; return true }
}
