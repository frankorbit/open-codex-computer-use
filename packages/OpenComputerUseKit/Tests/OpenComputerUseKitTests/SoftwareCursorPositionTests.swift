import AppKit
@testable import OpenComputerUseKit
import Testing

struct SoftwareCursorPositionTests {
    @Test @MainActor
    func `edge targets keep their tip and preview coordinates`() throws {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 900
        let frames = NSScreen.screens.map(\.frame) + [
            CGRect(x: -5000, y: -2000, width: 1440, height: 900)
        ]
        let geometry = CursorWindowGeometry(
            windowSize: SoftwareCursorGlyphMetrics.windowSize,
            tipAnchor: SoftwareCursorGlyphMetrics.tipAnchor
        )
        defer { SoftwareCursorOverlay.reset() }

        for frame in frames {
            let points = [
                CGPoint(x: frame.midX, y: frame.maxY - 1),
                CGPoint(x: frame.minX + 1, y: frame.midY),
                CGPoint(x: frame.maxX - 1, y: frame.midY),
                CGPoint(x: frame.midX, y: frame.minY + 1),
                CGPoint(x: frame.midX, y: frame.midY)
            ]
            for target in points {
                SoftwareCursorOverlay.reset()
                // 直接运行生产动画路径；不创建窗口、不投递输入。
                let initial = SoftwareCursorOverlay.advanceVisualDynamics(toward: target, at: 0)
                #expect(initial.tipPosition == target)
                let idle = SoftwareCursorOverlay.advanceVisualDynamics(
                    toward: target, idleAngleOffset: 0.09, at: 0.5
                )
                #expect(idle.tipPosition == target)
                let tip = geometry.tipPosition(forOrigin: geometry.origin(forTipPosition: idle.tipPosition))
                #expect(abs(tip.x - target.x) < 0.000001)
                #expect(abs(tip.y - target.y) < 0.000001)

                // 屏幕外目标也保持原位置，避免后台窗口的预览被挪到主屏边缘。
                let window = CGRect(
                    x: frame.minX, y: primaryHeight - frame.maxY,
                    width: frame.width, height: frame.height
                )
                let point = try #require(livePreviewCursorPoint(
                    tip: idle.tipPosition, window: window, primaryHeight: primaryHeight
                ))
                #expect(point == CGPoint(x: target.x - frame.minX, y: target.y - frame.minY))
            }
        }
    }
}
