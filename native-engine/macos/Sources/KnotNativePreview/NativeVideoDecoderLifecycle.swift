import Foundation
import CoreVideo
import KnotNativeCore

/// The production implementation is VideoToolbox. Inert tests can hold a drain
/// and replay stale callbacks without touching a real decoder or display.
@MainActor
protocol NativeVideoDecoding: AnyObject, Sendable {
    var onImage: ((CVPixelBuffer) -> Void)? { get set }
    var onFailure: (() -> Void)? { get set }
    var onPerformanceEvent: ((DecodePerformanceEvent) -> Void)? { get set }
    func decode(_ unit: AccessUnit) async throws
    func waitForPendingFrames() async throws
    func stop()
}

@MainActor
enum NativeVideoDecoderDrain {
    static func wait(_ decoder: any NativeVideoDecoding, timeout: Duration = .seconds(5),
                     waitForDeadline: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await decoder.waitForPendingFrames() }
            group.addTask { try await waitForDeadline(timeout); throw NativeFailure.decoder }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}
