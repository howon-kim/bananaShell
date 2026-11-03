import Foundation

struct ActivityPaneSize: Codable, Equatable {
    let width: CGFloat
    let height: CGFloat

    static let minimumHeight: CGFloat = 160
    static let maximumHeight: CGFloat = 2000

    static func defaultWidth(available: CGFloat) -> CGFloat {
        available >= 652 ? (available - 12) / 2 : available
    }

    static func clampedWidth(_ width: CGFloat, available: CGFloat) -> CGFloat {
        let available = max(1, available.isFinite ? available : 320)
        return min(available, max(min(320, available), width.isFinite ? width : available))
    }

    static func clampedHeight(_ height: CGFloat) -> CGFloat {
        min(maximumHeight, max(minimumHeight, height.isFinite ? height : 280))
    }

    func fitting(available: CGFloat) -> CGSize {
        CGSize(width: Self.clampedWidth(width, available: available),
               height: Self.clampedHeight(height))
    }

    static func resized(from start: CGSize, translation: CGSize, available: CGFloat) -> Self {
        Self(width: clampedWidth(start.width + translation.width, available: available),
             height: clampedHeight(start.height + translation.height))
    }
}
