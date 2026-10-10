import AppKit
import CoreGraphics

func mouseReceiverWindow(
    at point: CGPoint,
    screenMappings: [VisualCursorScreenMapping],
    windowAtAppKitPoint: (CGPoint) -> Int
) -> CGWindowID? {
    // 无法对应到实际屏幕时不猜测坐标，避免把 Quartz 坐标直接交给 AppKit。
    guard point.x.isFinite, point.y.isFinite,
          screenMappings.contains(where: { $0.screenStateFrame.contains(point) }) else { return nil }
    let converted = screenStatePointToAppKitGlobalPoint(fromScreenStatePoint: point, screenMappings: screenMappings)
    let number = windowAtAppKitPoint(converted)
    guard number > 0 else { return nil }
    return CGWindowID(exactly: number)
}

func foregroundMouseReceiver(at point: CGPoint) -> CGWindowID? {
    let lookup: @MainActor () -> CGWindowID? = {
        mouseReceiverWindow(at: point, screenMappings: currentVisualCursorScreenMappings()) {
            // 从最上层开始，不排除 helper 或 Dock；只让系统跳过真正穿透的窗口。
            NSWindow.windowNumber(at: $0, belowWindowWithWindowNumber: 0)
        }
    }
    if Thread.isMainThread {
        return MainActor.assumeIsolated { lookup() }
    }
    return DispatchQueue.main.sync { MainActor.assumeIsolated { lookup() } }
}
