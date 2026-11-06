import Foundation

/// Pure admission for a gesture that started in the remote image. Leaving the
/// image must follow our accepted left-down, never an ambient button state.
enum ExplorerDragGesture {
    static func shouldHandoff(origin: CGPoint?, point: CGPoint, ownsLeft: Bool,
                              insideImage: Bool, available: Bool) -> Bool {
        guard available, ownsLeft, !insideImage, let origin,
              origin.x.isFinite, origin.y.isFinite, point.x.isFinite, point.y.isFinite else { return false }
        return hypot(point.x - origin.x, point.y - origin.y) >= 6
    }
}
