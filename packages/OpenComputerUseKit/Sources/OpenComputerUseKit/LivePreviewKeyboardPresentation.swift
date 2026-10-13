import Foundation

/// 仅控制本地展示；任务取消不会影响真实键盘输入或合成焦点的生命周期。
@MainActor
final class LivePreviewKeyboardPresentation {
    private(set) var isVisible = false
    private(set) var isHoldingFrames = false
    private let maximumHold: Duration
    private let settle: Duration
    private let badgeLinger: Duration
    private let onChange: @MainActor () -> Void
    private let clock = ContinuousClock()
    private var holdDeadline: ContinuousClock.Instant?
    private var releaseTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    init(
        maximumHold: Duration = .milliseconds(300),
        settle: Duration = .milliseconds(150),
        badgeLinger: Duration = .milliseconds(650),
        onChange: @escaping @MainActor () -> Void
    ) {
        self.maximumHold = maximumHold
        self.settle = settle
        self.badgeLinger = badgeLinger
        self.onChange = onChange
    }

    func beginInput(keyboard: Bool) {
        guard keyboard else {
            reset()
            return
        }
        hideTask?.cancel()
        hideTask = nil
        if !isVisible {
            isVisible = true
            onChange()
        }
    }

    func endKeyboardInput() {
        hideTask?.cancel()
        hideTask = Task { [weak self, badgeLinger] in
            do { try await Task.sleep(for: badgeLinger) } catch { return }
            guard let self else { return }
            isVisible = false
            hideTask = nil
            onChange()
        }
    }

    func setFocusActive(_ active: Bool) {
        let now = clock.now
        // 主线程忙时到期回调可能尚未运行；新事件必须先放行上一轮最新帧。
        if let holdDeadline, now >= holdDeadline { releaseFrames() }
        releaseTask?.cancel()
        if !isHoldingFrames {
            holdDeadline = now.advanced(by: maximumHold)
            isHoldingFrames = true
            onChange()
        }
        guard let holdDeadline else { return }
        // 焦点稳定等待可以重置，首次暂停的硬截止不能被后续按键续期。
        let deadline = active ? holdDeadline : min(holdDeadline, now.advanced(by: settle))
        releaseTask = Task { [weak self, clock] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard !Task.isCancelled else { return }
            self?.releaseFrames()
        }
    }

    private func releaseFrames() {
        releaseTask?.cancel()
        releaseTask = nil
        holdDeadline = nil
        isHoldingFrames = false
        onChange()
    }

    func reset() {
        releaseTask?.cancel()
        releaseTask = nil
        holdDeadline = nil
        hideTask?.cancel()
        hideTask = nil
        let changed = isVisible || isHoldingFrames
        isVisible = false
        isHoldingFrames = false
        if changed { onChange() }
    }
}
