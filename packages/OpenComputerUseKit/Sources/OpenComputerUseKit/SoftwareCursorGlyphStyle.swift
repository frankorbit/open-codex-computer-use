import AppKit

/// 只改变配色与光晕强度，不参与轮廓、锚点或运动计算。
enum SoftwareCursorGlyphStyle: Equatable {
    case upstream
    case today

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        let value = environment["OPEN_COMPUTER_USE_VISUAL_CURSOR_THEME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "today" ? .today : .upstream
    }

    var tintColor: NSColor? {
        switch self {
        case .upstream: nil
        case .today: NSColor(srgbRed: 0.01, green: 0.66, blue: 0.96, alpha: 1)
        }
    }

    var haloOpacity: CGFloat {
        self == .today ? 0.35 : 1
    }

    func makeReferenceArtwork(from image: NSImage) -> NSImage? {
        guard self == .today else { return image }
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(
                  data: nil,
                  width: source.width,
                  height: source.height,
                  bitsPerComponent: 8,
                  bytesPerRow: source.width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let data = bitmap.data
        else {
            return nil
        }
        bitmap.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        // 参考图合并了本体和光晕；平滑淡化半透明区域，保留不透明本体。
        for offset in stride(from: 0, to: source.width * source.height * 4, by: 4) {
            let alpha = CGFloat(pixels[offset + 3]) / 255
            let progress = min(1, max(0, (alpha - 0.65) / 0.25))
            let smooth = progress * progress * (3 - 2 * progress)
            let opacity = haloOpacity + (1 - haloOpacity) * smooth
            // 预乘 RGBA 同比缩放，避免透明边缘色边；不修改原始资源。
            for component in 0 ..< 4 {
                pixels[offset + component] = UInt8((CGFloat(pixels[offset + component]) * opacity).rounded())
            }
        }
        guard let result = bitmap.makeImage() else { return nil }
        return NSImage(cgImage: result, size: image.size)
    }
}
