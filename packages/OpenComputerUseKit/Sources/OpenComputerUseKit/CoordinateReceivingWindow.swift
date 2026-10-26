import ApplicationServices
import CoreGraphics
import Foundation

/// 按元素点击时，目标元素可能显示在同一应用的弹层里：AX 树中它属于快照主窗口，WindowServer 中却是盖在
/// 主窗口之上的另一个窗口（例如提醒事项详情弹层里的日期框）。这个弹层是接收这次点击的窗口，不是遮挡物；
/// 坐标校验把它当作接收窗口，窗口定向的点击也投递给它。
struct CoordinateReceivingWindow: Equatable {
    let windowID: CGWindowID
    let bounds: CGRect
}

/// 在主窗口之上、按 WindowServer 前后顺序排列的窗口中，取同一进程、屏上可见、包含点击位置的最上层窗口；
/// 只有该点的 AX 命中结果与目标同属这个窗口（`hitIsHosted(窗口范围)`）时，它才是承载目标的窗口。命中的是
/// 别的窗口里的元素，说明有真正的遮挡物，返回 nil，由遮挡校验照常拦截。
func coordinateReceivingWindow(
    above windows: [[String: Any]], pid: pid_t, point: CGPoint, hitIsHosted: (CGRect) -> Bool
) -> CoordinateReceivingWindow? {
    let topmost = windows.lazy.compactMap { info -> CoordinateReceivingWindow? in
        guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
              (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
              let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let value = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: value as CFDictionary),
              WindowCaptureGeometry.isValid(bounds), bounds.contains(point) else { return nil }
        return CoordinateReceivingWindow(windowID: id, bounds: bounds)
    }.first
    guard let topmost, hitIsHosted(topmost.bounds) else { return nil }
    return topmost
}

/// 命中元素与目标是否同在一个窗口范围内：二者最近的共同祖先是目标本身，或整个落在 `bounds` 内。
/// 点击点可能取目标所在整行的中心，命中的是行或行内其他元素，共同祖先是行；弹层元素与主窗口
/// 元素的共同祖先是主窗口本身（范围大于弹层），不算同一窗口。父链最多上溯 32 层。
func axHit(
    _ hit: AXUIElement?, sharesHostWith target: AXUIElement, within bounds: CGRect,
    parent: (AXUIElement) -> AXUIElement? = axParent,
    frame: (AXUIElement) -> CGRect? = axFrame
) -> Bool {
    guard let hit else { return false }
    var targetChain: [AXUIElement] = []
    var current: AXUIElement? = target
    while let element = current, targetChain.count < 32 {
        targetChain.append(element)
        current = parent(element)
    }
    current = hit
    for _ in 0..<32 {
        guard let element = current else { return false }
        if let shared = targetChain.first(where: { CFEqual($0, element) }) {
            if CFEqual(shared, target) { return true }
            guard let sharedFrame = frame(shared), WindowCaptureGeometry.isValid(sharedFrame) else { return false }
            return bounds.insetBy(dx: -1, dy: -1).contains(sharedFrame)
        }
        current = parent(element)
    }
    return false
}

func axParent(_ element: AXUIElement) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
}

func axFrame(_ element: AXUIElement) -> CGRect? {
    var position: CFTypeRef?
    var size: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
          let position, let size,
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
          AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
    return CGRect(origin: point, size: dimensions)
}
