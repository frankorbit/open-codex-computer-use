//
//  LivePreviewView.swift
//  {project}
//
//  Copyright © 2026 Today AI. All rights reserved.
//

import AppKit

// MARK: - LivePreviewView

/// 视频和虚拟指针在本地合成，画中画不会接收或转发目标 App 的输入。
@MainActor
final class LivePreviewView: NSView {
    var image: CGImage? {
        didSet { needsDisplay = true }
    }

    var message = "正在连接窗口镜像…" {
        didSet { needsDisplay = true }
    }

    var keyboardInputVisible = false {
        didSet {
            if keyboardInputVisible {
                cursorPoint = nil
                cursorState = nil
            }
            setAccessibilityValue(keyboardInputVisible ? "键盘输入中" : nil)
            needsDisplay = true
        }
    }

    var sourceSize: CGSize = .zero
    var cursorPoint: CGPoint?
    var cursorState: SoftwareCursorGlyphRenderState?
    private var hoverTracking: NSTrackingArea?
    private var hoverCursor: NSCursor?
    private var hoverTimer: Timer?
    private let cursorAccess = LivePreviewCursorAccess()
    private struct ResizeGesture {
        let edge: LivePreviewResizeEdge
        let frame: CGRect
        let point: CGPoint
    }

    private var resizeGesture: ResizeGesture?

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds.insetBy(dx: 8, dy: 8), cursor: .openHand)
        for edge in LivePreviewResizeEdge.allCases {
            addCursorRect(edge.hitRect(in: bounds), cursor: edge.cursor)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    /// 非激活 panel 不会收到 activeAlways + cursorUpdate，需跟踪真实悬停移动。
    override func mouseEntered(with event: NSEvent) {
        updateHoverCursor(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoverCursor(with: event)
    }

    override func mouseExited(with _: NSEvent) {
        if resizeGesture == nil { clearHoverCursor() }
    }

    private func updateHoverCursor(with event: NSEvent) {
        guard let window, window.isVisible, !window.ignoresMouseEvents else {
            clearHoverCursor()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else {
            clearHoverCursor()
            return
        }
        let edge = LivePreviewResizeEdge.hit(at: convert(event.locationInWindow, from: nil), in: bounds)
        setHoverCursor(edge?.cursor ?? .openHand)
    }

    private func setHoverCursor(_ cursor: NSCursor) {
        guard let window, window.isVisible, !window.ignoresMouseEvents else {
            clearHoverCursor()
            return
        }
        let hadAccess = cursorAccess.isActive
        cursorAccess.begin()
        // 进入前 AppKit 可能已缓存同一个 cursor；取得后台权限后先失效缓存再重设。
        if !hadAccess, cursorAccess.isActive { NSCursor.arrow.set() }
        cursor.set()
        hoverCursor = cursor
        if hoverTimer == nil {
            // 前台应用的退出事件可能晚到；仅在真实悬停期间维持光标，不常驻轮询。
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
                guard let self else {
                    timer.invalidate()
                    return
                }
                MainActor.assumeIsolated { self.refreshHoverCursor() }
            }
            RunLoop.main.add(timer, forMode: .common)
            hoverTimer = timer
        }
    }

    private func refreshHoverCursor() {
        guard let window, window.isVisible, !window.ignoresMouseEvents,
              let hoverCursor, cursorAccess.isActive
        else {
            clearHoverCursor()
            return
        }
        let point = NSEvent.mouseLocation
        // 不覆盖其他窗口、菜单或鼠标已离开后的光标；拖拽时允许越过边界。
        if resizeGesture == nil {
            guard NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == window.windowNumber,
                  bounds.contains(convert(window.convertPoint(fromScreen: point), from: nil))
            else {
                clearHoverCursor()
                return
            }
        }
        NSCursor.arrow.set()
        hoverCursor.set()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { cancelInteraction() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseDown(with event: NSEvent) {
        guard let panel = window as? LivePreviewPanel, !panel.ignoresMouseEvents else { return }
        panel.constrainToScreen()
        panel.userInteractionActive = true
        if let edge = LivePreviewResizeEdge.hit(at: convert(event.locationInWindow, from: nil), in: bounds) {
            resizeGesture = ResizeGesture(
                edge: edge,
                frame: panel.frame,
                point: panel.convertPoint(toScreen: event.locationInWindow)
            )
            setHoverCursor(edge.cursor)
        } else {
            setHoverCursor(.closedHand)
            panel.performDrag(with: event)
            finishInteraction(panel)
            clearHoverCursor()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panel = window as? LivePreviewPanel, let gesture = resizeGesture,
              let visibleFrame = panel.visibleFrame else { return }
        let point = panel.convertPoint(toScreen: event.locationInWindow)
        let frame = gesture.edge.resizedFrame(
            from: gesture.frame,
            delta: CGSize(width: point.x - gesture.point.x, height: point.y - gesture.point.y),
            minimum: panel.minSize, maximum: panel.maxSize, visibleFrame: visibleFrame
        )
        panel.setFrame(frame, display: true)
        setHoverCursor(gesture.edge.cursor)
    }

    override func mouseUp(with event: NSEvent) {
        guard let panel = window as? LivePreviewPanel else { return }
        finishInteraction(panel)
        updateHoverCursor(with: event)
    }

    private func finishInteraction(_ panel: LivePreviewPanel) {
        resizeGesture = nil
        panel.userInteractionActive = false
        panel.constrainToScreen()
        panel.invalidateCursorRects(for: self)
    }

    private func clearHoverCursor() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        // 不覆盖离开预览后由其他视图设置的光标。
        if let hoverCursor, NSCursor.current == hoverCursor { NSCursor.arrow.set() }
        hoverCursor = nil
        cursorAccess.end()
    }

    func cancelInteraction() {
        clearHoverCursor()
        guard let panel = window as? LivePreviewPanel, panel.userInteractionActive else { return }
        finishInteraction(panel)
    }

    func showFrame(_ frame: CGImage) {
        if image?.width != frame.width || image?.height != frame.height {
            (window as? LivePreviewPanel)?.showSource(size: CGSize(width: frame.width, height: frame.height))
        }
        image = frame
    }

    override func draw(_: NSRect) {
        defer { drawKeyboardBadge() }
        // 透明源像素和首帧加载阶段使用黑色底衬；比例由 panel 统一约束。
        NSColor.black.setFill()
        bounds.fill(using: .copy)
        guard let image, let context = NSGraphicsContext.current?.cgContext else {
            (message as NSString).draw(at: CGPoint(x: 12, y: bounds.midY), withAttributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.lightGray
            ])
            return
        }
        // AppKit 会取整到显示像素，直接填满内容区消除重复 aspect-fit 的细缝。
        let destination = bounds
        context.draw(image, in: destination)
        guard !keyboardInputVisible, let cursorPoint, let cursorState, sourceSize.width > 0,
              sourceSize.height > 0
        else {
            return
        }
        let scaleX = destination.width / sourceSize.width
        let scaleY = destination.height / sourceSize.height
        context.saveGState()
        context.clip(to: destination)
        context.translateBy(
            x: destination.minX + cursorPoint.x * scaleX,
            y: destination.minY + cursorPoint.y * scaleY
        )
        context.scaleBy(x: scaleX, y: scaleY)
        context.translateBy(x: -SoftwareCursorGlyphMetrics.tipAnchor.x, y: -SoftwareCursorGlyphMetrics.tipAnchor.y)
        SoftwareCursorGlyphRenderer.draw(
            in: CGRect(origin: .zero, size: SoftwareCursorGlyphMetrics.windowSize),
            context: context,
            state: cursorState
        )
        context.restoreGState()
    }

    private func drawKeyboardBadge() {
        guard keyboardInputVisible else { return }
        // 固定尺寸的静态提示，不改变镜像比例，不把提示烧进模型截图。
        let label = "键盘输入中" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = label.size(withAttributes: attributes)
        guard bounds.width >= 44, bounds.height >= 34 else { return }
        let showLabel = textSize.width + 58 <= bounds.width
        let width = showLabel ? textSize.width + 42 : 36
        let originX = bounds.midX - width / 2
        // 窄窗口下让开左上角收起按钮；极窄窗口只保留图标和完整 AX 提示。
        let topInset: CGFloat = originX < 38 ? 38 : 10
        let pill = CGRect(x: originX, y: max(4, bounds.maxY - topInset - 26), width: width, height: 26)
        NSColor(calibratedWhite: 0.12, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 13, yRadius: 13).fill()
        let icon = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.white]))
        icon?.draw(in: CGRect(x: pill.minX + 10, y: pill.minY + 6, width: 17, height: 14))
        if showLabel {
            label.draw(at: CGPoint(x: pill.minX + 32, y: pill.midY - textSize.height / 2), withAttributes: attributes)
        }
    }
}
