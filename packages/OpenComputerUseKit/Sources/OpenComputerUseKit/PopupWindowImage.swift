import CoreGraphics
import CoreImage
import CoreMedia
import ScreenCaptureKit

/// 弹层（sheet、popover、菜单）图片必须正好是该窗口自身。macOS 会把 sheet / popover 与父窗口分组，
/// ScreenCaptureKit 的独立窗口过滤器因此把整组窗口缩放进弹层尺寸（实测 Numbers 保存面板、提醒事项
/// 详情面板都成了整窗缩略图）。所以先读 WindowServer 中该窗口自己的缓冲区；拿不到或尺寸不对时，
/// 再按显示器过滤、只包含该窗口并裁剪到它的位置。两种结果都必须覆盖完整窗口，否则不返回。
enum PopupWindowImage {
    /// WindowServer 硬件采集：被遮挡也能读到，且只含该窗口。沿用主窗口截图的几何规则：窗口必须完整落在
    /// 一块显示器内（否则缓冲区可能被裁剪），图片必须与完整窗口等比，才能把像素映射回窗口坐标。
    static func hardware(
        _ windowID: CGWindowID, bounds: CGRect,
        displays: [CGRect] = WindowCaptureGeometry.activeDisplayBounds(),
        capture: (CGWindowID) -> CGImage? = { SkyLightSPI.shared.hardwareCaptureWindow($0) }
    ) -> CGImage? {
        guard WindowCaptureGeometry.isValid(bounds), displays.contains(where: { $0.contains(bounds) }),
              let image = capture(windowID),
              WindowCaptureGeometry.matchesFullWindow(pixelSize: WindowCaptureGeometry.size(of: image), bounds: bounds)
        else { return nil }
        return image
    }

    private static let imageContext = CIContext(options: [.cacheIntermediates: false])

    /// 退回路径：只包含精确 window ID 的显示器过滤器，用显示器本地坐标裁剪到窗口位置。
    /// 跨屏或部分离屏的窗口不猜裁剪偏移；输出尺寸由调用方的配置决定，并按该尺寸校验。
    /// 在调用方的隔离域内执行，SCK 元数据不跨 actor 传递。
    nonisolated(nonsending) static func displayCrop(
        _ target: SCWindow, bounds: CGRect, content: SCShareableContent, configuration: SCStreamConfiguration
    ) async throws -> CGImage? {
        guard #available(macOS 14.2, *),
              let region = LivePreviewPopupRegion.displayRegion(window: bounds, displays: content.displays.map(\.frame))
        else { return nil }
        let filter = SCContentFilter(display: content.displays[region.index], including: [target])
        configuration.sourceRect = region.sourceRect
        // display-bound 过滤器默认包含子窗，必须显式关闭，关联弹层由各自采集负责。
        configuration.includeChildWindows = false
        configuration.ignoreShadowsDisplay = true
        let sample = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter,
                                                                       configuration: configuration)
        guard sample.isValid, let buffer = sample.imageBuffer,
              frameIsComplete(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                  as? [[SCStreamFrameInfo: Any]]),
              let image = imageContext.createCGImage(
                  CIImage(cvPixelBuffer: buffer),
                  from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
              ),
              image.width == configuration.width, image.height == configuration.height else { return nil }
        return image
    }

    /// 单张截图（SCScreenshotManager）的样本不带帧状态，实测为 nil；只有带了状态时才要求 complete，
    /// 完整性由随后按配置尺寸的校验保证。
    static func frameIsComplete(_ attachments: [[SCStreamFrameInfo: Any]]?) -> Bool {
        guard let status = attachments?.first?[.status] else { return true }
        return status as? Int == SCFrameStatus.complete.rawValue
    }
}
