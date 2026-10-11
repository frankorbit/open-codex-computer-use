import AppKit

extension LivePreviewResizeEdge {
    @MainActor var cursor: NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition = switch self {
            case .top: .top
            case .bottom: .bottom
            case .left: .left
            case .right: .right
            case .topLeft: .topLeft
            case .topRight: .topRight
            case .bottomLeft: .bottomLeft
            case .bottomRight: .bottomRight
            }
            return .frameResize(position: position, directions: .all)
        }
        if horizontal == 0 { return .resizeUpDown }
        if vertical == 0 { return .resizeLeftRight }
        return horizontal == vertical ? Self.risingCursor : Self.fallingCursor
    }

    @MainActor private static let risingCursor = diagonalCursor(rising: true)
    @MainActor private static let fallingCursor = diagonalCursor(rising: false)

    /// macOS 14 没有公开的对角缩放光标，提供与命中方向一致的双向箭头。
    @MainActor private static func diagonalCursor(rising: Bool) -> NSCursor {
        let image = NSImage(size: CGSize(width: 24, height: 24))
        image.lockFocus()
        let transform = NSAffineTransform()
        transform.translateX(by: 12, yBy: 12)
        transform.rotate(byDegrees: rising ? 45 : -45)
        transform.concat()
        let path = NSBezierPath()
        path.move(to: CGPoint(x: -8, y: 0))
        path.line(to: CGPoint(x: 8, y: 0))
        for direction: CGFloat in [-1, 1] {
            path.move(to: CGPoint(x: direction * 4, y: -4))
            path.line(to: CGPoint(x: direction * 8, y: 0))
            path.line(to: CGPoint(x: direction * 4, y: 4))
        }
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        NSColor.white.setStroke()
        path.lineWidth = 4
        path.stroke()
        NSColor.black.setStroke()
        path.lineWidth = 2
        path.stroke()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: CGPoint(x: 12, y: 12))
    }
}
