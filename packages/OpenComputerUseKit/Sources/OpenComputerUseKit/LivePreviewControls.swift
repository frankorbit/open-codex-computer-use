import AppKit

/// 控件跟随主窗画面，不把合成画布的透明空白当作标题栏。
@MainActor
final class LivePreviewControls: NSView {
    let hideButton = LivePreviewHideButton()
    private var pointerInside = false
    var rootUnitRect = CGRect(x: 0, y: 0, width: 1, height: 1) {
        didSet { if oldValue != rootUnitRect { needsLayout = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hideButton.isBordered = false
        hideButton.isHidden = true
        hideButton.title = ""
        hideButton.target = self
        hideButton.action = #selector(hidePreview)
        hideButton.toolTip = "收起画中画，任务继续"
        hideButton.setAccessibilityLabel("收起画中画，任务继续")
        addSubview(hideButton)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    func updatePointerPresence(_ inside: Bool) {
        pointerInside = inside && window?.ignoresMouseEvents != true
        updateVisibility()
    }

    private func updateVisibility() {
        hideButton.isHidden = !pointerInside || min(hideButton.frame.width, hideButton.frame.height) < 12
    }

    func anchor(root: CGRect, canvas: CGRect) {
        guard canvas.width > 0, canvas.height > 0, canvas.contains(root) else {
            rootUnitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            return
        }
        let rect = LivePreviewPopup.destination(root, canvas: canvas)
        rootUnitRect = CGRect(x: rect.minX / canvas.width, y: rect.minY / canvas.height,
                              width: rect.width / canvas.width, height: rect.height / canvas.height)
    }

    override func layout() {
        super.layout()
        let root = CGRect(x: bounds.minX + rootUnitRect.minX * bounds.width,
                          y: bounds.minY + rootUnitRect.minY * bounds.height,
                          width: rootUnitRect.width * bounds.width, height: rootUnitRect.height * bounds.height)
        // 窄画面缩小内边距；仍把按钮完整放在画面内，避免丢失收起入口。
        let side = max(0, min(28, root.width - 4, root.height - 4))
        let insetX = min(10, (root.width - side) / 2)
        let insetY = min(10, (root.height - side) / 2)
        hideButton.frame = CGRect(x: root.minX + insetX, y: root.maxY - insetY - side,
                                  width: side, height: side)
        updateVisibility()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 仅按钮消费事件，其他区域继续由预览处理拖动和八方向缩放。
        guard window?.ignoresMouseEvents != true, !hideButton.isHidden else { return nil }
        let local = convert(point, from: superview)
        return hideButton.frame.contains(local) ? hideButton : nil
    }

    @objc private func hidePreview() {
        guard window?.ignoresMouseEvents != true, !hideButton.isHidden else { return }
        (window as? LivePreviewPanel)?.performClose(nil)
    }
}

/// 固定深色底衬和白色符号，避免被源窗口的浅色标题栏吞没。
@MainActor
final class LivePreviewHideButton: NSButton {
    override func draw(_: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        shadow.set()
        NSColor(calibratedWhite: isHighlighted ? 0.3 : 0.12, alpha: 0.94).setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.45).setStroke()
        circle.lineWidth = 1
        circle.stroke()
        let radius = min(4, bounds.width / 6)
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: bounds.midX - radius, y: bounds.midY - radius))
        cross.line(to: CGPoint(x: bounds.midX + radius, y: bounds.midY + radius))
        cross.move(to: CGPoint(x: bounds.midX - radius, y: bounds.midY + radius))
        cross.line(to: CGPoint(x: bounds.midX + radius, y: bounds.midY - radius))
        cross.lineWidth = 1.8
        cross.lineCapStyle = .round
        NSColor.white.setStroke()
        cross.stroke()
    }
}
