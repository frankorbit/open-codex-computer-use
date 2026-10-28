import AppKit

/// 控件跟随主窗画面，不把合成画布的透明空白当作标题栏。
@MainActor
final class LivePreviewControls: NSView {
    let hideButton = NSButton()
    var rootUnitRect = CGRect(x: 0, y: 0, width: 1, height: 1) {
        didSet { if oldValue != rootUnitRect { needsLayout = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hideButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        hideButton.imageScaling = .scaleProportionallyDown
        hideButton.bezelStyle = .circular
        hideButton.isBordered = true
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
        let side = max(0, min(24, root.width - 4, root.height - 4))
        let insetX = min(10, (root.width - side) / 2)
        let insetY = min(10, (root.height - side) / 2)
        hideButton.isHidden = side < 12
        hideButton.frame = CGRect(x: root.minX + insetX, y: root.maxY - insetY - side,
                                  width: side, height: side)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 仅按钮消费事件，其他区域继续由预览处理拖动和八方向缩放。
        guard window?.ignoresMouseEvents != true, !hideButton.isHidden else { return nil }
        let local = convert(point, from: superview)
        return hideButton.frame.contains(local) ? hideButton : nil
    }

    @objc private func hidePreview() {
        guard window?.ignoresMouseEvents != true else { return }
        (window as? LivePreviewPanel)?.performClose(nil)
    }
}
