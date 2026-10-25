import CoreGraphics
import ScreenCaptureKit

/// 每轮观察独立持有；SCK 非 Sendable 元数据只在此 actor 内使用，不跨 worker 共享。
actor HoverPopupWindowCapture {
    private var content: Result<SCShareableContent, Error>?

    private func shareableContent() async throws -> SCShareableContent {
        if let content { return try content.get() }
        do {
            let value = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            content = .success(value)
            return value
        } catch {
            // 同轮不因多个候选重复枚举；下一轮重新查询。
            content = .failure(error)
            throw error
        }
    }

    /// 退回路径（硬件采集不可用或尺寸不符时）：按显示器过滤、只包含该窗口并裁剪，输出为窗口点尺寸。
    /// 不再使用独立窗口过滤器：它会把 sheet / popover 与父窗口整组缩放进弹层尺寸。
    func capture(_ window: HoverPopupObservation.Window, budget: HoverPopupBudget) async throws -> CGImage? {
        guard !budget.expired else { return nil }
        let content = try await shareableContent()
        guard !budget.expired,
              let target = content.windows.first(where: {
                  $0.windowID == window.windowID && $0.owningApplication?.processID == window.pid
                      && $0.frame == window.bounds && $0.isOnScreen
              }),
              let width = Int(exactly: ceil(window.bounds.width)),
              let height = Int(exactly: ceil(window.bounds.height)) else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = false
        let image = try await PopupWindowImage.displayCrop(target, bounds: window.bounds, content: content,
                                                          configuration: configuration)
        guard !budget.expired else { return nil }
        return image
    }
}
