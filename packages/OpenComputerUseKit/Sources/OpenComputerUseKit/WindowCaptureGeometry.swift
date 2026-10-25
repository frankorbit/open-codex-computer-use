import CoreGraphics

enum WindowCaptureGeometry {
    static func isValid(_ bounds: CGRect) -> Bool {
        [bounds.origin.x, bounds.origin.y, bounds.width, bounds.height].allSatisfy(\.isFinite)
            && bounds.width > 0 && bounds.height > 0
    }

    static func matchesFullWindow(pixelSize: CGSize, bounds: CGRect) -> Bool {
        guard
            isValid(bounds), pixelSize.width.isFinite, pixelSize.height.isFinite,
            pixelSize.width > 0, pixelSize.height > 0 else { return false }
        // 等比编码会产生整数像素舍入；不允许把裁剪图分别拉伸到完整窗口。
        let scale = min(pixelSize.width / bounds.width, pixelSize.height / bounds.height)
        return abs(pixelSize.width - bounds.width * scale) <= 2
            && abs(pixelSize.height - bounds.height * scale) <= 2
    }

    static func capture(
        bounds: CGRect, displayBounds: [CGRect],
        hardware: () -> CGImage?, fullWindow: () -> CGImage?
    ) -> CGImage? {
        guard isValid(bounds) else { return nil }
        // 跨屏或部分出屏时，即便裁剪后的比例恰好相同，也不能使用硬件截图。
        if
            displayBounds.contains(where: { $0.contains(bounds) }),
            let image = hardware(), matchesFullWindow(pixelSize: size(of: image), bounds: bounds) {
            return image
        }
        guard
            let image = fullWindow(),
            matchesFullWindow(pixelSize: size(of: image), bounds: bounds) else { return nil }
        return image
    }

    static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    static func size(of image: CGImage) -> CGSize {
        CGSize(width: image.width, height: image.height)
    }

    static func fullWindowPixelSize(
        bounds: CGRect, capturedFrame: CGRect, contentSize: CGSize, scale: CGFloat
    ) -> CGSize? {
        guard
            isValid(bounds), capturedFrame == bounds, contentSize == bounds.size,
            scale.isFinite, scale > 0 else { return nil }
        let size = CGSize(width: ceil(bounds.width * scale), height: ceil(bounds.height * scale))
        guard
            size.width.isFinite, size.height.isFinite,
            size.width < CGFloat(Int.max), size.height < CGFloat(Int.max) else { return nil }
        return size
    }

    static func windowPoint(_ point: CGPoint, pixelSize: CGSize?, bounds: CGRect?) throws -> CGPoint {
        guard let pixelSize, let bounds, matchesFullWindow(pixelSize: pixelSize, bounds: bounds) else {
            throw ComputerUseError
                .stateUnavailable(
                    "Screenshot coverage does not match the complete window; observe again. No input was sent."
                )
        }
        guard
            point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
            point.x < pixelSize.width, point.y < pixelSize.height
        else {
            throw ComputerUseError
                .invalidArguments("Coordinates must be finite and inside the delivered screenshot. No input was sent.")
        }
        return screenshotPixelToWindowPoint(point, screenshotPixelSize: pixelSize, windowBounds: bounds)
    }
}
