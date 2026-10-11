import ApplicationServices

/// 只注入系统边界，派发顺序与前后台分支仍由生产 dispatcher 决定。
struct SkyKeyboardDeliveryBackend {
    var frontmostPID: () -> pid_t?
    var validateTarget: (SkyKeyboardTarget) throws -> Void
    var requireCapability: () throws -> Void
    var begin: (SkyKeyboardTarget) throws -> SkyLightSyntheticFocusContext
    var makeKey: (SkyLightSyntheticFocusContext) throws -> Void
    var waitForKey: (SkyKeyboardTarget) -> Void
    var releaseWait: () -> Void
    var end: (SkyLightSyntheticFocusContext) throws -> Void
}
