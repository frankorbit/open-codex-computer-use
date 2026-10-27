import AppKit
import Darwin

struct SnapshotProcessIdentity: Equatable {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    init(pid: pid_t, startSeconds: UInt64, startMicroseconds: UInt64 = 0) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }

    static func current(for pid: pid_t) -> Self? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return capture(app: app, pid: pid)
    }

    static func capture(app: NSRunningApplication, pid: pid_t) -> Self? {
        capture(pid: pid, isLiveOriginal: {
            app.processIdentifier == pid && !app.isTerminated
        }, read: readKernelIdentity)
    }

    static func capture(
        pid: pid_t,
        isLiveOriginal: () -> Bool,
        read: (pid_t) -> Self?
    ) -> Self? {
        // 读取两侧均验证原对象，不能把退出后复用的 PID 绑定到旧 descriptor。
        guard pid > 0, isLiveOriginal(), let identity = read(pid),
              identity.pid == pid, isLiveOriginal() else { return nil }
        return identity
    }

    static func bound(to app: RunningAppDescriptor) -> Self? {
        guard app.runningApplication.processIdentifier == app.pid,
              !app.runningApplication.isTerminated,
              let identity = app.observedProcessIdentity,
              identity.pid == app.pid else { return nil }
        // 只使用 descriptor 创建时的证据，恢复时不按 PID 重新生成绑定身份。
        return identity
    }

    private static func readKernelIdentity(for pid: pid_t) -> Self? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        return decode(info, bytesRead: bytes, pid: pid)
    }

    static func decode(_ info: proc_bsdinfo, bytesRead: Int32, pid: pid_t) -> Self? {
        // Finder 等登录时启动的 App 没有 AppKit launchDate；内核启动时间仍可区分 PID 复用。
        guard pid > 0, bytesRead == MemoryLayout<proc_bsdinfo>.stride,
              info.pbi_pid == UInt32(pid), info.pbi_status != SZOMB,
              info.pbi_start_tvsec > 0, info.pbi_start_tvusec < 1_000_000 else { return nil }
        return Self(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }
}
