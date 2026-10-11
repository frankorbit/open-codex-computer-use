import Foundation

/// 只计算本地预览几何，不修改被观察窗口。
enum LivePreviewLayout {
    static let margin: CGFloat = 12

    static func fit(_ aspect: CGSize, inside limit: CGSize) -> CGSize {
        guard aspect.width > 0, aspect.height > 0,
              aspect.width.isFinite, aspect.height.isFinite else { return .zero }
        let scale = max(0, min(limit.width / aspect.width, limit.height / aspect.height))
        return CGSize(width: aspect.width * scale, height: aspect.height * scale)
    }

    static func available(in visibleFrame: CGRect) -> CGRect {
        visibleFrame.insetBy(dx: min(margin, visibleFrame.width / 4), dy: min(margin, visibleFrame.height / 4))
    }

    static func maximumSize(aspect: CGSize, visibleFrame: CGRect) -> CGSize {
        let available = available(in: visibleFrame)
        return fit(aspect, inside: CGSize(width: min(960, available.width), height: min(720, available.height)))
    }

    static func minimumSize(aspect: CGSize, maximum: CGSize) -> CGSize {
        fit(aspect, inside: CGSize(width: min(240, maximum.width), height: min(240, maximum.height)))
    }

    static func sourceChangeFrame(aspect: CGSize, current: CGRect, visibleFrame: CGRect) -> CGRect {
        let available = available(in: visibleFrame)
        let longEdge = min(640, max(240, max(current.width, current.height)))
        let minimum = minimumSize(aspect: aspect, maximum: maximumSize(aspect: aspect, visibleFrame: visibleFrame))
        let size = fit(aspect, inside: CGSize(
            width: min(longEdge, available.width),
            height: min(longEdge, max(minimum.height, min(480, available.height * 0.55)))
        ))
        // 保留原来的右上角，然后整体移回可见区域；竖屏不继承横屏宽度。
        return contained(CGRect(x: current.maxX - size.width, y: current.maxY - size.height,
                                width: size.width, height: size.height), in: available)
    }

    static func contained(_ frame: CGRect, in available: CGRect) -> CGRect {
        let size = fit(frame.size, inside: CGSize(width: min(frame.width, available.width),
                                                  height: min(frame.height, available.height)))
        return CGRect(x: min(max(frame.minX, available.minX), available.maxX - size.width),
                      y: min(max(frame.minY, available.minY), available.maxY - size.height),
                      width: size.width, height: size.height)
    }
}

enum LivePreviewResizeEdge: CaseIterable {
    case top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight

    var horizontal: CGFloat {
        switch self {
        case .left, .topLeft, .bottomLeft: -1
        case .right, .topRight, .bottomRight: 1
        default: 0
        }
    }

    var vertical: CGFloat {
        switch self {
        case .bottom, .bottomLeft, .bottomRight: -1
        case .top, .topLeft, .topRight: 1
        default: 0
        }
    }

    func hitRect(in bounds: CGRect) -> CGRect {
        let thickness: CGFloat = min(8, min(bounds.width, bounds.height) / 3)
        let originX = horizontal < 0 ? bounds.minX : bounds.maxX - thickness
        let originY = vertical < 0 ? bounds.minY : bounds.maxY - thickness
        if horizontal == 0 {
            return CGRect(
                x: bounds.minX + thickness,
                y: originY,
                width: bounds.width - 2 * thickness,
                height: thickness
            )
        }
        if vertical == 0 {
            return CGRect(
                x: originX,
                y: bounds.minY + thickness,
                width: thickness,
                height: bounds.height - 2 * thickness
            )
        }
        return CGRect(x: originX, y: originY, width: thickness, height: thickness)
    }

    static func hit(at point: CGPoint, in bounds: CGRect) -> Self? {
        allCases.first { $0.hitRect(in: bounds).contains(point) }
    }

    func resizedFrame(from frame: CGRect, delta: CGSize, minimum: CGSize, maximum: CGSize,
                      visibleFrame: CGRect) -> CGRect {
        let available = LivePreviewLayout.available(in: visibleFrame)
        let vector = CGSize(width: horizontal * frame.width, height: vertical * frame.height)
        let requested = 1 + (delta.width * vector.width + delta.height * vector.height)
            / (vector.width * vector.width + vector.height * vector.height)
        let anchor = CGPoint(x: horizontal < 0 ? frame.maxX : horizontal > 0 ? frame.minX : frame.midX,
                             y: vertical < 0 ? frame.maxY : vertical > 0 ? frame.minY : frame.midY)
        let room = CGSize(
            width: horizontal < 0 ? anchor.x - available.minX : horizontal > 0 ? available.maxX - anchor.x
                : 2 * min(anchor.x - available.minX, available.maxX - anchor.x),
            height: vertical < 0 ? anchor.y - available.minY : vertical > 0 ? available.maxY - anchor.y
                : 2 * min(anchor.y - available.minY, available.maxY - anchor.y)
        )
        let upper = max(0, min(min(maximum.width, room.width) / frame.width,
                               min(maximum.height, room.height) / frame.height))
        // 拖拽期间屏幕可能被拔掉，旧锚点已在新屏幕外；先恢复可见窗口。
        guard upper > 0 else { return LivePreviewLayout.contained(frame, in: available) }
        let lower = min(upper, max(minimum.width / frame.width, minimum.height / frame.height))
        let scale = min(upper, max(lower, requested))
        let size = CGSize(width: frame.width * scale, height: frame.height * scale)
        return CGRect(x: anchor.x - (horizontal < 0 ? size.width : horizontal == 0 ? size.width / 2 : 0),
                      y: anchor.y - (vertical < 0 ? size.height : vertical == 0 ? size.height / 2 : 0),
                      width: size.width, height: size.height)
    }
}
