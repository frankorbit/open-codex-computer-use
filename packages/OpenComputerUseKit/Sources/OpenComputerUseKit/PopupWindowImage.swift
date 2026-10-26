import CoreGraphics
import CoreImage
import CoreMedia
import ScreenCaptureKit

/// 弹层（sheet、popover、菜单）图片必须正好是该窗口自身。macOS 会把 sheet / popover 与父窗口分组，
/// ScreenCaptureKit 的独立窗口过滤器因此把整组窗口缩放进弹层尺寸（实测 Numbers 保存面板、提醒事项
/// 详情面板都成了整窗缩略图）。所以按显示器过滤、只包含弹层和它的主窗口并裁剪到弹层位置。
/// 弹层的半透明材质在渲染时与背后内容混合：背后什么都没有时合成为不透明深灰（实测 RGB 71），事后无法还原。
/// 因此渲染时带上主窗口，并用跟随系统外观的窗口背景色作底（伸出主窗口的部分也有东西可模糊）；不包含桌面
/// 层，不截壁纸、桌面图标或其他应用。底色会填满弹层圆角外和不可见区域，所以再按硬件缓冲区里弹层自身的
/// 透明度做蒙版，圆角与不可见的辅助窗口仍是透明。弹层不在屏幕上或跨屏时退回硬件缓冲区。
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

    /// ScreenCaptureKit 的 backgroundColor 不持有 CGColor，必须全程存活。取值近似系统窗口背景色。
    private static let lightBackdrop = CGColor(srgbRed: 0.925, green: 0.925, blue: 0.925, alpha: 1)
    private static let darkBackdrop = CGColor(srgbRed: 0.196, green: 0.196, blue: 0.196, alpha: 1)

    static func backdrop(darkMode: Bool = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark") -> CGColor {
        darkMode ? darkBackdrop : lightBackdrop
    }

    /// 首选路径：只包含弹层和它的主窗口（精确 window ID）的显示器过滤器，用显示器本地坐标裁剪到弹层位置。
    /// 跨屏或部分离屏的窗口不猜裁剪偏移；输出尺寸由调用方的配置决定，并按该尺寸校验。
    /// 在调用方的隔离域内执行，SCK 元数据不跨 actor 传递。
    nonisolated(nonsending) static func displayCrop(
        _ target: SCWindow, root: SCWindow?, bounds: CGRect, content: SCShareableContent,
        configuration: SCStreamConfiguration, alphaMask: CGImage?
    ) async throws -> CGImage? {
        guard #available(macOS 14.2, *),
              let region = LivePreviewPopupRegion.displayRegion(window: bounds, displays: content.displays.map(\.frame))
        else { return nil }
        let filter = SCContentFilter(display: content.displays[region.index], including: captureWindows(target, root: root))
        configuration.sourceRect = region.sourceRect
        // display-bound 过滤器默认包含子窗，必须显式关闭，关联弹层由各自采集负责。
        configuration.includeChildWindows = false
        configuration.ignoreShadowsDisplay = true
        configuration.backgroundColor = backdrop()
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
        return alphaMask.flatMap { masked(image, alphaFrom: $0) } ?? image
    }

    /// 用蒙版图片的透明度裁出图片：蒙版透明处变透明，半透明处按比例淡出（预乘），不透明处保持原样。
    /// 蒙版缩放到图片尺寸；两者覆盖同一窗口范围。
    static func masked(_ image: CGImage, alphaFrom mask: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let output = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width * 4, space: space,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let alpha = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        output.draw(image, in: rect)
        alpha.interpolationQuality = CGInterpolationQuality.high
        alpha.draw(mask, in: rect)
        guard let pixels = output.data?.assumingMemoryBound(to: UInt8.self),
              let alphas = alpha.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        for row in 0..<height {
            for column in 0..<width {
                let factor = UInt16(alphas[row * alpha.bytesPerRow + column * 4 + 3])
                guard factor < 255 else { continue }
                let index = row * output.bytesPerRow + column * 4
                for channel in 0..<4 {
                    pixels[index + channel] = UInt8((UInt16(pixels[index + channel]) * factor + 127) / 255)
                }
            }
        }
        return output.makeImage()
    }

    /// 渲染列表：弹层加上它的主窗口（同一进程、不是同一个窗口时），主窗口在弹层之下提供模糊底色。
    static func captureWindows(_ target: SCWindow, root: SCWindow?) -> [SCWindow] {
        guard let root, root.windowID != target.windowID,
              root.owningApplication?.processID == target.owningApplication?.processID else { return [target] }
        return [target, root]
    }

    /// 单张截图（SCScreenshotManager）的样本不带帧状态，实测为 nil；只有带了状态时才要求 complete，
    /// 完整性由随后按配置尺寸的校验保证。
    static func frameIsComplete(_ attachments: [[SCStreamFrameInfo: Any]]?) -> Bool {
        guard let status = attachments?.first?[.status] else { return true }
        return status as? Int == SCFrameStatus.complete.rawValue
    }
}
