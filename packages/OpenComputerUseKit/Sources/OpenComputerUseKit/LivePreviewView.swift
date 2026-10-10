//
//  LivePreviewView.swift
//  {project}
//
//  Copyright © 2026 Today AI. All rights reserved.
//

import AppKit

// MARK: - LivePreviewPanel

@MainActor
final class LivePreviewPanel: NSPanel {
    var onHide: (() -> Void)?
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    override func close() {
        onHide?()
    }

    override func performClose(_ sender: Any?) {
        onHide?()
    }

    func finish() {
        super.close()
    }
}

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

    var sourceSize: CGSize = .zero
    var cursorPoint: CGPoint?
    var cursorState: SoftwareCursorGlyphRenderState?

    func showFrame(_ frame: CGImage) {
        if image?.width != frame.width || image?.height != frame.height, let window {
            let size = CGSize(width: frame.width, height: frame.height)
            // 与旧版一致：比例约束不会调整现有尺寸，首帧和换尺寸时必须同步内容高度。
            window.contentAspectRatio = size
            let width = min(640, max(240, bounds.width))
            window.setContentSize(CGSize(width: width, height: width * size.height / size.width))
        }
        image = frame
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let image, let context = NSGraphicsContext.current?.cgContext else {
            (message as NSString).draw(at: CGPoint(x: 12, y: bounds.midY), withAttributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.lightGray,
            ])
            return
        }
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let destination = CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        context.draw(image, in: destination)
        guard let cursorPoint, let cursorState, sourceSize.width > 0, sourceSize.height > 0 else {
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
}
