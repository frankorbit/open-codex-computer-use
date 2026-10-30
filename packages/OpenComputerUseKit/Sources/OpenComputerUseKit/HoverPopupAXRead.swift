import ApplicationServices

/// 保留一次 AX 读取的失败阶段；不重试、不读额外属性、不改变原有预算。
enum HoverPopupAXRead {
    enum Failure: Equatable {
        case prepareFailed
        case copyFailed(Int32)
        case deadlineExpired
    }

    static func read(
        prepare: () -> Bool,
        copy: (inout CFTypeRef?) -> AXError,
        expired: () -> Bool,
        report: (Failure) -> Void
    ) -> CFTypeRef? {
        guard prepare() else { report(.prepareFailed); return nil }
        var value: CFTypeRef?
        let error = copy(&value)
        guard error == .success else { report(.copyFailed(error.rawValue)); return nil }
        guard !expired() else { report(.deadlineExpired); return nil }
        return value
    }
}
