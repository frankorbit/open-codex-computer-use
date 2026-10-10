//
//  LiveWindowPreview.swift
//  {project}
//
//  Copyright © 2026 Today AI. All rights reserved.
//

import AppKit
import CoreImage
import OSLog
import ScreenCaptureKit

// MARK: - LiveWindowPreview

/// 每个设备 helper 独享的展示状态；不开新工具，不把连续帧送进模型上下文。
@MainActor
final class LiveWindowPreview: NSObject {
    static let shared = LiveWindowPreview()
    static let reopenNotification = Notification.Name("ai.today.ocu.show-preview")

    private var state = LivePreviewState()
    private var panel: LivePreviewPanel?
    private let view = LivePreviewView(frame: CGRect(x: 0, y: 0, width: 360, height: 240))
    private var capture: SCStream?
    private var worker: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var windowBounds: CGRect?
    private var observingReopen = false
    private var inputActive = false
    private var captureFailed = false
    private var targetApp: NSRunningApplication?

    nonisolated static func publish(_ snapshot: AppSnapshot) {
        guard livePreviewEnabled(environment: ProcessInfo.processInfo.environment) else {
            return
        }
        let target = LivePreviewTarget(
            pid: snapshot.app.pid,
            windowID: snapshot.targetWindowID,
            bounds: snapshot.windowBounds
        )
        VisualCursorSupport.performOnMain { shared.select(target) }
    }

    nonisolated static func invalidate() {
        guard livePreviewEnabled(environment: ProcessInfo.processInfo.environment) else {
            return
        }
        VisualCursorSupport.performOnMain { shared.select(nil) }
    }

    private func select(_ target: LivePreviewTarget?, forceGeometry: Bool = false) {
        if let target, let current = state.target, current.hasSameWindow(as: target),
           !forceGeometry, !captureFailed {
            return
        }
        if !state.select(target, forceGeometry: forceGeometry) {
            guard captureFailed, !state.hidden else {
                return
            }
            state.reopen()
        }
        captureFailed = false
        targetApp = target.flatMap { NSRunningApplication(processIdentifier: $0.pid) }
        windowBounds = target?.bounds
        clear(target == nil ? "等待新的窗口观察" : "正在连接窗口镜像…")
        restart()
    }

    private func preparePanel() {
        guard panel == nil else {
            return
        }
        let panel = LivePreviewPanel(
            contentRect: view.frame,
            styleMask: [
                .titled,
                .closable,
                .resizable,
                .fullSizeContentView,
                .nonactivatingPanel,
            ],
            backing: .buffered,
            defer: false
        )
        panel.title = "Today · 画中画"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.ignoresMouseEvents = inputActive
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.minSize = CGSize(width: 240, height: 160)
        panel.maxSize = CGSize(width: 960, height: 720)
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.closeButton)?.setAccessibilityLabel("收起画中画，任务继续")
        panel.onHide = { [weak self] in self?.hide() }
        view.autoresizingMask = [.width, .height]
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel("Computer Use 本地实时画中画")
        panel.contentView = view
        if let screen = NSScreen.main {
            panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.maxX - 380, y: screen.visibleFrame.minY + 24))
        }
        self.panel = panel
        if let session = ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_PREVIEW_SESSION"], !session.isEmpty {
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(reopen),
                name: Self.reopenNotification,
                object: session
            )
            observingReopen = true
        }
    }

    @objc
    private func reopen() {
        guard state.target != nil else {
            return
        }
        state.reopen()
        restart()
    }

    private func hide() {
        state.hide()
        panel?.orderOut(nil)
        clear("画中画已收起")
        restart()
    }

    func reset() {
        state.reset()
        restart()
        clear("镜像已结束")
        panel?.finish()
        panel = nil
        if observingReopen {
            DistributedNotificationCenter.default().removeObserver(self)
            observingReopen = false
        }
    }

    nonisolated static func setInputActive(_ active: Bool) {
        guard livePreviewEnabled(environment: ProcessInfo.processInfo.environment) else {
            return
        }
        VisualCursorSupport.performOnMain {
            shared.inputActive = active
            // 展示窗口不能挡住前台点击的真实接收者；空闲时仍可拖动或收起。
            shared.panel?.ignoresMouseEvents = active
        }
    }

    private func restart() {
        let previous = worker
        previous?.cancel()
        monitor?.cancel()
        monitor = nil
        let oldCapture = capture
        capture = nil
        let generation = state.generation
        worker = Task { [weak self] in
            await previous?.value
            // 先结束旧流，再绑定新窗口；快速切窗不能让前一个 startCapture 迟到覆盖。
            if let oldCapture {
                await Self.stopCapture(oldCapture)
            }
            guard let self, !Task.isCancelled, state.accepts(generation), let target = state.target else {
                return
            }
            preparePanel()
            panel?.orderFrontRegardless()
            do {
                try await start(target, generation: generation)
            } catch {
                guard !Task.isCancelled, state.accepts(generation) else {
                    return
                }
                clear("窗口镜像暂不可用")
                captureFailed = true
            }
        }
    }

    private func start(_ target: LivePreviewTarget, generation: UUID) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard !Task.isCancelled, state.accepts(generation) else {
            return
        }
        guard let app = targetApp, !app.isTerminated,
              let window = content.windows.first(where: {
                  $0.windowID == target.windowID && $0.owningApplication?.processID == target.pid
              }), LivePreviewTarget(pid: target.pid, windowID: target.windowID, bounds: window.frame) != nil
        else {
            throw PreviewCaptureError.targetUnavailable
        }
        let config = Self.configuration(for: window.frame.size)
        // 只镜像已绑定窗口，即使被其他 App 遮住也不把遮挡者的内容带入预览。
        let events = AsyncStream<PreviewFrameEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let sink = PreviewFrameSink(continuation: events.continuation)
        let stream = SCStream(
            filter: SCContentFilter(desktopIndependentWindow: window),
            configuration: config,
            delegate: sink
        )
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "ocu.preview.frames"))
        do {
            try await stream.startCapture()
            guard !Task.isCancelled, state.accepts(generation) else {
                await Self.stopCapture(stream)
                return
            }
            capture = stream
            windowBounds = window.frame
            monitorTarget(target, app: app, size: window.frame.size, generation: generation)
            for await event in events.stream {
                guard !Task.isCancelled, state.accepts(generation) else {
                    break
                }
                switch event {
                case let .frame(image):
                    receive(image, target: target, captureSize: window.frame.size)
                case .unavailable:
                    clear("等待窗口完整画面")
                case .stopped:
                    clear("窗口镜像已停止")
                    captureFailed = true
                case .stoppedByUser:
                    clear("窗口共享已停止")
                    notifyUserStopped()
                }
            }
        } catch {
            await Self.stopCapture(stream)
            throw error
        }
    }

    private static func configuration(for size: CGSize) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = min(2, 960 / max(size.width, size.height))
        config.width = max(1, Int(size.width * scale))
        config.height = max(1, Int(size.height * scale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 20)
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false
        config.scalesToFit = true
        config.preservesAspectRatio = false
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        return config
    }

    private func notifyUserStopped() {
        guard let session = ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_PREVIEW_SESSION"] else {
            return
        }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("ai.today.ocu.stop-run"), object: session, userInfo: nil, deliverImmediately: true
        )
    }

    private func monitorTarget(_ target: LivePreviewTarget, app: NSRunningApplication, size: CGSize, generation: UUID) {
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, state.accepts(generation) else {
                    return
                }
                guard !app.isTerminated, let bounds = Self.currentBounds(target) else {
                    select(nil)
                    return
                }
                if bounds.size != size {
                    select(
                        LivePreviewTarget(pid: target.pid, windowID: target.windowID, bounds: bounds),
                        forceGeometry: true
                    )
                    return
                }
                windowBounds = bounds
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    private func receive(_ image: CGImage, target: LivePreviewTarget, captureSize: CGSize) {
        guard let bounds = Self.currentBounds(target) else {
            select(nil)
            return
        }
        // 窗口改尺寸就丢掉旧尺寸的帧，重新建流；不能将旧 buffer 与新几何混用。
        guard bounds.size == captureSize else {
            select(LivePreviewTarget(pid: target.pid, windowID: target.windowID, bounds: bounds), forceGeometry: true)
            return
        }
        windowBounds = bounds
        view.image = image
        view.sourceSize = captureSize
        panel?.contentAspectRatio = CGSize(width: image.width, height: image.height)
    }

    private static func stopCapture(_ stream: SCStream) async {
        do { try await stream.stopCapture() } catch {
            // 不记录屏幕正文；系统可能已经先行终止流。
            Logger(subsystem: "ai.today.ocu", category: "preview")
                .debug("capture_cleanup code=\((error as NSError).code)")
        }
    }

    private func clear(_ message: String) {
        view.image = nil
        view.message = message
        view.cursorState = nil
        view.cursorPoint = nil
    }

    func cursor(tip: CGPoint?, windowID: CGWindowID?, state cursorState: SoftwareCursorGlyphRenderState?) {
        guard let tip, windowID == state.target?.windowID, let bounds = windowBounds,
              let screen = NSScreen.screens.first, !state.hidden, view.image != nil
        else {
            view.cursorState = nil
            view.needsDisplay = true
            return
        }
        view.cursorPoint = livePreviewCursorPoint(tip: tip, window: bounds, primaryHeight: screen.frame.maxY)
        view.cursorState = cursorState
        view.needsDisplay = true
    }

    private static func currentBounds(_ target: LivePreviewTarget) -> CGRect? {
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, target.windowID) as? [[String: Any]],
              let row = rows.first(where: {
                  ($0[kCGWindowNumber as String] as? UInt32) == target.windowID &&
                      ($0[kCGWindowOwnerPID as String] as? Int32) == target.pid
              }), let bounds = row[kCGWindowBounds as String] as? NSDictionary
        else {
            return nil
        }
        return CGRect(dictionaryRepresentation: bounds)
    }
}

// MARK: - PreviewCaptureError

private enum PreviewCaptureError: Error {
    case targetUnavailable
}

// MARK: - PreviewFrameEvent

private enum PreviewFrameEvent {
    case frame(CGImage)
    case unavailable
    case stopped
    case stoppedByUser
}

// MARK: - PreviewFrameSink

/// 像素只保留最新一帧，慢 UI 不积压、不阻塞输入线程。
private final class PreviewFrameSink: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    private let continuation: AsyncStream<PreviewFrameEvent>.Continuation
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()

    init(continuation: AsyncStream<PreviewFrameEvent>.Continuation) {
        self.continuation = continuation
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.lock()
        defer { lock.unlock() }
        continuation
            .yield((error as NSError).code == SCStreamError.Code.userStopped.rawValue ? .stoppedByUser : .stopped)
        continuation.finish()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                  sample,
                  createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status != SCFrameStatus.idle.rawValue
        else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        guard status == SCFrameStatus.complete.rawValue, let buffer = sample.imageBuffer,
              let image = context.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(
                  x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)
              ))
        else {
            continuation.yield(.unavailable)
            return
        }
        continuation.yield(.frame(image))
    }
}
