import Foundation

/// 临时缺帧只保留旧画面一个有界周期；连续缺帧不能续期。
@MainActor
final class LivePreviewFrameGrace {
    private let duration: Duration
    private let onExpire: @MainActor () -> Void
    private var task: Task<Void, Never>?

    init(duration: Duration = .milliseconds(250), onExpire: @escaping @MainActor () -> Void) {
        self.duration = duration
        self.onExpire = onExpire
    }

    func waitForCompleteFrame() {
        guard task == nil else { return }
        task = Task { [weak self, duration] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self else { return }
            task = nil
            onExpire()
        }
    }

    /// 完整帧、真实不可用或窗口/会话切换时撤销旧回调。
    func cancel() {
        task?.cancel()
        task = nil
    }
}
