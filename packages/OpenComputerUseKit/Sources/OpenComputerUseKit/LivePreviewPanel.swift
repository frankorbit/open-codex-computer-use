import AppKit

@MainActor
final class LivePreviewPanel: NSPanel, NSWindowDelegate {
    var onHide: (() -> Void)?
    var userInteractionActive = false
    private var sourceAspect = CGSize(width: 3, height: 2)
    private var adjusting = false

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        delegate = self
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    static func make(view: LivePreviewView, inputActive: Bool, onHide: @escaping () -> Void) -> LivePreviewPanel {
        let panel = LivePreviewPanel(
            contentRect: view.frame,
            styleMask: [
                .titled,
                .closable,
                .resizable,
                .fullSizeContentView,
                .nonactivatingPanel
            ],
            backing: .buffered,
            defer: false
        )
        panel.title = "Today · 画中画"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.ignoresMouseEvents = inputActive
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.onHide = onHide
        view.autoresizingMask = [.width, .height]
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("Computer Use 本地实时画中画")
        view.controls.frame = view.bounds
        view.controls.autoresizingMask = [.width, .height]
        view.addSubview(view.controls)
        panel.contentView = view
        if let screen = NSScreen.main {
            panel.setFrameOrigin(CGPoint(
                x: screen.visibleFrame.maxX - panel.frame.width - 24,
                y: screen.visibleFrame.minY + 24
            ))
        }
        panel.constrainToScreen()
        return panel
    }

    override func close() {
        onHide?()
    }

    override func performClose(_: Any?) {
        onHide?()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func orderOut(_ sender: Any?) {
        (contentView as? LivePreviewView)?.cancelInteraction()
        super.orderOut(sender)
    }

    func finish() {
        (contentView as? LivePreviewView)?.cancelInteraction()
        super.close()
    }

    var visibleFrame: CGRect? {
        (screen ?? NSScreen.main)?.visibleFrame
    }

    func showSource(size: CGSize) {
        sourceAspect = size
        contentAspectRatio = size
        guard let visibleFrame else { return }
        updateLimits(visibleFrame: visibleFrame)
        applyFrame(LivePreviewLayout.sourceChangeFrame(aspect: size, current: frame, visibleFrame: visibleFrame))
    }

    func constrainToScreen() {
        guard !adjusting, !userInteractionActive, let visibleFrame else { return }
        updateLimits(visibleFrame: visibleFrame)
        applyFrame(LivePreviewLayout.contained(frame, in: LivePreviewLayout.available(in: visibleFrame)))
    }

    private func updateLimits(visibleFrame: CGRect) {
        // 使用同一比例生成 min/max，避免固定最小宽度与竖向窗口的最大高度冲突。
        minSize = .zero
        maxSize = LivePreviewLayout.maximumSize(aspect: sourceAspect, visibleFrame: visibleFrame)
        minSize = LivePreviewLayout.minimumSize(aspect: sourceAspect, maximum: maxSize)
    }

    private func applyFrame(_ newFrame: CGRect) {
        guard !adjusting else { return }
        adjusting = true
        setFrame(newFrame, display: true)
        adjusting = false
        if let contentView { invalidateCursorRects(for: contentView) }
    }

    @objc private func screenParametersChanged() {
        constrainToScreen()
    }

    func windowDidChangeScreen(_: Notification) {
        constrainToScreen()
    }

    func windowDidEndLiveResize(_: Notification) {
        constrainToScreen()
    }

    func windowDidResize(_: Notification) {
        if let contentView { invalidateCursorRects(for: contentView) }
    }
}
