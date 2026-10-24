//
//  LiveWindowPreview.swift
//  {project}
//
//  Copyright © 2026 Today AI. All rights reserved.
//

import AppKit
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
    private var capture: LivePreviewCaptureSession?
    private var worker: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private let popupCapture = LivePreviewPopupCapture()
    private var popupWorker: Task<Void, Never>?
    private var popupState = LivePreviewPopupState()
    private var rootImage: CGImage?
    private var canvasBounds: CGRect?
    private var windowBounds: CGRect?
    private var observingReopen = false
    private var inputActive = false
    private lazy var keyboardPresentation: LivePreviewKeyboardPresentation =
        LivePreviewKeyboardPresentation { [weak self] in
            guard let self else { return }
            view.keyboardInputVisible = keyboardPresentation.isVisible
            if !keyboardPresentation.isHoldingFrames { render() }
        }

    private lazy var frameGrace: LivePreviewFrameGrace = LivePreviewFrameGrace { [weak self] in
        self?.clear("等待窗口完整画面")
    }

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
        let panel = LivePreviewPanel.make(view: view, inputActive: inputActive) { [weak self] in self?.hide() }
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
        clear("正在连接窗口镜像…")
        restart()
    }

    private func hide() {
        keyboardPresentation.reset()
        state.hide()
        panel?.orderOut(nil)
        clear("画中画已收起")
        restart()
    }

    func reset() {
        keyboardPresentation.reset()
        state.reset()
        restart()
        clear("镜像已结束")
        panel?.finish()
        panel = nil
        view.setFrameSize(CGSize(width: 360, height: 240))
        if observingReopen {
            DistributedNotificationCenter.default().removeObserver(self)
            observingReopen = false
        }
    }

    nonisolated static func setInputActive(_ active: Bool, keyboard: Bool = false) {
        guard livePreviewEnabled(environment: ProcessInfo.processInfo.environment) else {
            return
        }
        VisualCursorSupport.performOnMain {
            shared.inputActive = active
            if active {
                if keyboard {
                    // 隐藏上一次点击的虚拟光标，不移动真实鼠标。
                    SoftwareCursorOverlay.reset()
                }
                shared.keyboardPresentation.beginInput(keyboard: keyboard)
            } else if keyboard {
                shared.keyboardPresentation.endKeyboardInput()
            }
            // 展示窗口不能挡住前台点击的真实接收者；空闲时仍可拖动或收起。
            if active { shared.view.cancelInteraction() }
            shared.panel?.ignoresMouseEvents = active
        }
    }

    /// 只合并本地展示帧；不延长合成焦点、不改变输入或模型截图。
    nonisolated static func setKeyboardFocusActive(_ active: Bool) {
        guard livePreviewEnabled(environment: ProcessInfo.processInfo.environment) else { return }
        VisualCursorSupport.performOnMain {
            shared.keyboardPresentation.setFocusActive(active)
        }
    }

    private func restart() {
        let previous = worker
        previous?.cancel()
        monitor?.cancel()
        monitor = nil
        popupWorker?.cancel()
        popupWorker = nil
        popupState.reset()
        rootImage = nil
        canvasBounds = nil
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
        let session = try LivePreviewCapture.makeStream(for: window)
        // 取消、建流失败或切窗时也要保留回调接收者，直到消费循环和清理退出。
        defer { withExtendedLifetime(session) {} }
        do {
            // 先登记再开流：指示器随流出现，读取窗口时必须已经能识别它。
            if let captured = session.captured {
                WindowSharingIndicator.captureStarted(windowID: captured.windowID, pid: captured.pid)
            }
            try await session.stream.startCapture()
            guard !Task.isCancelled, state.accepts(generation) else {
                await Self.stopCapture(session)
                return
            }
            capture = session
            windowBounds = window.frame
            monitorTarget(target, app: app, size: window.frame.size, generation: generation)
            for await event in session.events {
                guard !Task.isCancelled, state.accepts(generation) else {
                    break
                }
                receive(event, target: target, captureSize: window.frame.size)
            }
        } catch {
            await Self.stopCapture(session)
            throw error
        }
    }

    private func receive(_ event: PreviewFrameEvent, target: LivePreviewTarget, captureSize: CGSize) {
        switch event {
        case let .frame(image):
            frameGrace.cancel()
            receive(image, target: target, captureSize: captureSize)
        case .transient:
            frameGrace.waitForCompleteFrame()
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

    private func notifyUserStopped() {
        guard let session = ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_PREVIEW_SESSION"] else {
            return
        }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("ai.today.ocu.stop-run"), object: session, userInfo: nil, deliverImmediately: true
        )
    }
}

// MARK: - 本地弹层刷新与合成

extension LiveWindowPreview {
    private func monitorTarget(_ target: LivePreviewTarget, app: NSRunningApplication, size: CGSize, generation: UUID) {
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, state.accepts(generation) else {
                    return
                }
                let now = ProcessInfo.processInfo.systemUptime
                guard !app.isTerminated,
                      let update = popupState.updateTarget(target, appIsHidden: app.isHidden, now: now)
                else {
                    select(nil)
                    return
                }
                let bounds = update.bounds
                if bounds.size != size {
                    select(
                        LivePreviewTarget(pid: target.pid, windowID: target.windowID, bounds: bounds),
                        forceGeometry: true
                    )
                    return
                }
                let previousBounds = windowBounds
                windowBounds = bounds
                if LivePreviewPopupState.needsRender(
                    previousBounds: previousBounds, bounds: bounds, popupInvalidated: update.invalidated
                ) { render() }
                if rootImage != nil,
                   let current = LivePreviewTarget(pid: target.pid, windowID: target.windowID, bounds: bounds),
                   !LivePreviewPopup.candidates(target: current, state: .init(windows: popupState.windows)).isEmpty,
                   let request = popupState.begin(now: now) {
                    refreshPopups(current, request: request, generation: generation)
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

    private func receive(_ image: CGImage, target: LivePreviewTarget, captureSize: CGSize) {
        guard let app = targetApp, !app.isTerminated,
              let bounds = LivePreviewCapture.currentBounds(target)
        else {
            select(nil)
            return
        }
        // 窗口改尺寸就丢掉旧尺寸的帧，重新建流；不能将旧 buffer 与新几何混用。
        guard bounds.size == captureSize else {
            select(LivePreviewTarget(pid: target.pid, windowID: target.windowID, bounds: bounds), forceGeometry: true)
            return
        }
        windowBounds = bounds
        rootImage = image
        // root 移动后，旧弹层必须等下一次 metadata 观察重新确认。
        if app.isHidden || popupState.windows.first(where: { $0.windowID == target.windowID })?.bounds != bounds {
            popupState.observe([], now: ProcessInfo.processInfo.systemUptime)
        }
        render()
    }

    private func refreshPopups(
        _ target: LivePreviewTarget, request: LivePreviewPopupState.Request, generation: UUID
    ) {
        popupWorker?.cancel()
        popupWorker = Task { [weak self, popupCapture] in
            let layers = await popupCapture.refresh(target: target, expected: request.windows)
            guard let self, !Task.isCancelled, state.accepts(generation),
                  let app = targetApp, !app.isTerminated else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard let update = popupState.updateTarget(target, appIsHidden: app.isHidden, now: now) else {
                select(nil)
                return
            }
            let accepted = popupState.finish(request, layers: layers, now: now)
            if update.invalidated || accepted { render() }
        }
    }

    private func render() {
        guard !keyboardPresentation.isHoldingFrames, let rootImage, let windowBounds else { return }
        // 只有 root 新帧、弹层新图或失效时重绘；idle 不做逐帧 AX/截图。
        popupState.observe(popupState.windows, now: ProcessInfo.processInfo.systemUptime)
        let layers = popupState.layers
        let composed = LivePreviewPopup.composite(root: rootImage, bounds: windowBounds, layers: layers)
        let canvas = composed == nil ? windowBounds : LivePreviewPopup.canvas(root: windowBounds, layers: layers)
        if canvasBounds != canvas {
            // 坐标空间改变时，不沿用上一幅合成画面的虚拟光标位置。
            view.cursorState = nil
            view.cursorPoint = nil
        }
        canvasBounds = canvas
        view.showFrame(composed ?? rootImage)
        view.sourceSize = canvas.size
    }

    private static func stopCapture(_ session: LivePreviewCaptureSession) async {
        defer { withExtendedLifetime(session) {} }
        do { try await session.stream.stopCapture() } catch {
            // 不记录屏幕正文；系统可能已经先行终止流。
            Logger(subsystem: "ai.today.ocu", category: "preview")
                .debug("capture_cleanup code=\((error as NSError).code)")
        }
        // 流停止后指示器随之消失，再取消登记。
        if let captured = session.captured {
            WindowSharingIndicator.captureEnded(windowID: captured.windowID, pid: captured.pid)
        }
    }

    private func clear(_ message: String) {
        frameGrace.cancel()
        popupWorker?.cancel()
        popupWorker = nil
        popupState.reset()
        rootImage = nil
        canvasBounds = nil
        view.cancelInteraction()
        view.image = nil
        view.message = message
        view.cursorState = nil
        view.cursorPoint = nil
    }

    func cursor(tip: CGPoint?, windowID: CGWindowID?, state cursorState: SoftwareCursorGlyphRenderState?) {
        guard !view.keyboardInputVisible, let tip, windowID == state.target?.windowID, let bounds = canvasBounds,
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
}

// MARK: - PreviewCaptureError

private enum PreviewCaptureError: Error {
    case targetUnavailable
}
