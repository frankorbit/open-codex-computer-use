import CoreGraphics
import Foundation

/// 预览图片必须覆盖完整窗口；不将裁剪图或父子窗组合图拉伸到另一块屏幕区域。
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

    static func matchesIndependentContent(_ content: CGRect, window: CGRect) -> Bool {
        // 独立窗口的 contentRect 可为局部坐标；不能将它的原点当成屏幕坐标。
        valid(content) && valid(window) && content.size == window.size
    }

    static func frameRect(_ value: Any?) -> CGRect? {
        if let rect = value as? CGRect, valid(rect) { return rect }
        if let value = value as? NSValue,
           String(cString: value.objCType) == String(cString: NSValue(rect: .zero).objCType),
           valid(value.rectValue) { return value.rectValue }
        guard let dictionary = value as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dictionary), valid(rect) else { return nil }
        return rect
    }

    static func matchesCapturedFrame(_ screenRect: Any?, window: CGRect) -> Bool {
        guard let rect = frameRect(screenRect), valid(window) else { return false }
        // 实际帧的屏幕区域才是回退采集的映射依据；固定输出宽高并不能证明未被裁剪或缩放。
        return rect == window
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }
}
