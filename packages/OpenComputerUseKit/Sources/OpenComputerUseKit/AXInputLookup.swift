import ApplicationServices

/// 可选 AX 查询并未执行输入；不可用时可在独立校验窗口后采用定向输入。
/// 权限关闭、参数错误等不属于能力缺失，不得悄悄降级。
func inputAXLookupIsUnavailable(_ result: AXError) -> Bool {
    switch result {
    case .noValue, .attributeUnsupported, .notImplemented, .cannotComplete, .failure, .invalidUIElement:
        true
    default:
        false
    }
}

func readOptionalInputAXAttribute(
    _ attribute: String, read: () -> (AXError, CFTypeRef?)
) throws -> CFTypeRef? {
    let (result, value) = read()
    if result == .success { return value }
    if inputAXLookupIsUnavailable(result) { return nil }
    throw ComputerUseError.stateUnavailable(
        "Input target query for \(attribute) failed (AXError \(result.rawValue)); no input was sent."
    )
}
