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

    func capture(_ window: HoverPopupObservation.Window, budget: HoverPopupBudget) async throws -> CGImage? {
        guard !budget.expired else { return nil }
        let content = try await shareableContent()
        guard !budget.expired,
              let target = content.windows.first(where: {
                  $0.windowID == window.windowID && $0.owningApplication?.processID == window.pid
                      && $0.frame == window.bounds && $0.isOnScreen
              }) else { return nil }
        // sourceRect 保持未设置，按 SCK 的独立窗口契约采集完整窗口，绝不推算裁剪偏移。
        let filter = SCContentFilter(desktopIndependentWindow: target)
        guard filter.contentRect.size == window.bounds.size,
              let width = Int(exactly: ceil(window.bounds.width)),
              let height = Int(exactly: ceil(window.bounds.height)) else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        // 填满全部输出像素，避免缩放或比例舍入引入留边。
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard !budget.expired, image.width == width, image.height == height else { return nil }
        return image
    }
}
