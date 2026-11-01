import CoreVideo

enum PresentationResult: Equatable { case presented, backpressure, failed }

/// Keeps renderer failure separate from ordinary bounded frame dropping. Tests
/// exercise the real session lifecycle with synthetic pixels and an inert sink.
@MainActor
protocol NativePresenter: AnyObject {
    var onFailure: (() -> Void)? { get set }
    func display(_ image: CVPixelBuffer) -> PresentationResult
    func clear()
    func forgetHeldKeys()
}
