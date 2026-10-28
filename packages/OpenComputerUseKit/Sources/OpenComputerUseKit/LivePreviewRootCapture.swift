import CoreGraphics
import ScreenCaptureKit

/// 本地预览的覆盖范围；不能作为模型截图或输入凭证。
enum LivePreviewRootCapture {
    enum Plan: Equatable {
        case display(frame: CGRect, sourceRect: CGRect)
        case independent

        var isolatesRoot: Bool {
            if case .display = self { return true }
            return false
        }

        func acceptsFrame(captured: CGRect, current: CGRect) -> Bool {
            // 固定显示器裁剪不能沿用窗口移动前的帧；独立窗口流继续跟随窗口。
            isolatesRoot ? captured == current : captured.size == current.size
        }
    }

    static func plan(bounds: CGRect, visible: Bool, displays: [CGRect]) -> Plan {
        guard #available(macOS 14.2, *), visible,
              let region = LivePreviewPopupRegion.displayRegion(window: bounds, displays: displays)
        else { return .independent }
        return .display(frame: displays[region.index], sourceRect: region.sourceRect)
    }

    static func configure(_ configuration: SCStreamConfiguration, plan: Plan) {
        // 独立流可能包含系统窗口组；保持比例且不与独立 popup 再次合成。
        configuration.preservesAspectRatio = !plan.isolatesRoot
        if #available(macOS 14.2, *) { configuration.includeChildWindows = false }
        if case let .display(_, sourceRect) = plan {
            configuration.sourceRect = sourceRect
            configuration.ignoreShadowsDisplay = true
        }
    }

    static func render(root: CGImage, bounds: CGRect, layers: [LivePreviewPopup.Layer], plan: Plan)
        -> (image: CGImage, canvas: CGRect) {
        // 独立流的窗口组已包含子窗，不能再次叠加或扩张它的画布。
        guard plan.isolatesRoot,
              let image = LivePreviewPopup.composite(root: root, bounds: bounds, layers: layers)
        else { return (root, bounds) }
        return (image, LivePreviewPopup.canvas(root: bounds, layers: layers))
    }
}
