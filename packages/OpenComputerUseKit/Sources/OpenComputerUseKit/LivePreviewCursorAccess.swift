import AppKit
import Darwin
import OSLog

/// 非激活预览的悬停周期内允许更新光标，不激活 App、不移动真实指针。
@MainActor
final class LivePreviewCursorAccess {
    struct Backend {
        var read: () throws -> CFTypeRef?
        var write: (CFTypeRef?) throws -> Void
    }

    private enum AccessError: Error {
        case unavailable
        case system(Int32)
    }

    private static let logger = Logger(subsystem: "ai.today.ocu", category: "preview")
    private static let backend = loadBackend()
    private let backend: Backend?
    private var savedValue: CFTypeRef?
    private var reportedFailure = false
    private(set) var isActive = false

    init(backend: Backend? = LivePreviewCursorAccess.backend) {
        self.backend = backend
    }

    func begin() {
        guard !isActive else { return }
        do {
            guard let backend else { throw AccessError.unavailable }
            let previous = try backend.read()
            try backend.write(kCFBooleanTrue)
            savedValue = previous
            isActive = true
        } catch {
            report(error)
        }
    }

    func end() {
        guard isActive, let backend else { return }
        do {
            try backend.write(savedValue)
            savedValue = nil
            isActive = false
        } catch {
            // 保留原值，后续退出/收起时仍可重试恢复。
            report(error)
        }
    }

    private func report(_ error: any Error) {
        guard !reportedFailure else { return }
        reportedFailure = true
        Self.logger.error("background_cursor_access failed: \(String(describing: error), privacy: .public)")
    }

    private static func loadBackend() -> Backend? {
        typealias Connection = @convention(c) () -> Int32
        typealias Copy = @convention(c) (
            Int32, Int32, CFString, UnsafeMutablePointer<Unmanaged<CFTypeRef>?>
        ) -> Int32
        typealias Set = @convention(c) (Int32, Int32, CFString, CFTypeRef?) -> Int32
        // SkyLight 私有能力只用于本进程；动态解析失败时不切前台或接管输入。
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            return nil
        }
        guard let connectionSymbol = dlsym(handle, "CGSMainConnectionID"),
              let copySymbol = dlsym(handle, "CGSCopyConnectionProperty"),
              let setSymbol = dlsym(handle, "CGSSetConnectionProperty") else {
            dlclose(handle)
            return nil
        }
        // 函数指针与静态 backend 同寿命，不提前卸载 framework。
        let connection = unsafeBitCast(connectionSymbol, to: Connection.self)
        let copy = unsafeBitCast(copySymbol, to: Copy.self)
        let set = unsafeBitCast(setSymbol, to: Set.self)
        let key = "SetsCursorInBackground" as CFString
        return Backend(read: {
            let identifier = connection()
            var value: Unmanaged<CFTypeRef>?
            let result = copy(identifier, identifier, key, &value)
            let retainedValue = value?.takeRetainedValue()
            guard result == 0 else { throw AccessError.system(result) }
            return retainedValue
        }, write: { value in
            let identifier = connection()
            let result = set(identifier, identifier, key, value)
            guard result == 0 else { throw AccessError.system(result) }
        })
    }
}
