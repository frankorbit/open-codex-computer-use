import CoreGraphics
import Foundation

/// 弹层退回采集只在窗口完整落在一块显示器内时裁剪；不将裁剪图或父子窗组合图拉伸到另一块屏幕区域。
enum LivePreviewPopupRegion {
    struct DisplayRegion: Equatable {
        let index: Int
        let sourceRect: CGRect
    }

    static func displayRegion(window: CGRect, displays: [CGRect]) -> DisplayRegion? {
        guard valid(window),
              let index = displays.firstIndex(where: { valid($0) && $0.contains(window) }) else { return nil }
        let display = displays[index]
        return DisplayRegion(index: index, sourceRect: window.offsetBy(dx: -display.minX, dy: -display.minY))
    }

    /// 模型观察可返回已知覆盖范围的裁剪图；预览仍使用完整窗口路径，不拉伸裁剪内容。
    static func visibleCaptureBounds(window: CGRect, displays: [CGRect]) -> CGRect? {
        guard valid(window) else { return nil }
        if displayRegion(window: window, displays: displays) != nil { return window }
        var largest: CGRect?
        var largestArea: CGFloat = 0
        for display in displays where valid(display) {
            let intersection = window.intersection(display)
            guard valid(intersection) else { continue }
            let area = intersection.width * intersection.height
            guard area.isFinite, area > largestArea else { continue }
            largest = intersection
            largestArea = area
        }
        return largest
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }
}
