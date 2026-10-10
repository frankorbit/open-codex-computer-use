import ApplicationServices
import Foundation

func foregroundHoverEnabled(environment: [String: String]) -> Bool {
    environment["OPEN_COMPUTER_USE_FOREGROUND_HOVER"] == "1"
}

// MARK: - HoverRequest

struct HoverRequest {
    enum Target {
        case element(String)
        case coordinates(Double, Double)
    }

    let target: Target
    let durationMilliseconds: Int

    init(arguments: [String: Any]) throws {
        if let rawIndex = arguments["element_index"] {
            guard arguments["x"] == nil, arguments["y"] == nil,
                  !(rawIndex is NSNumber && CFGetTypeID(rawIndex as CFTypeRef) == CFBooleanGetTypeID()),
                  let index = normalizedElementIndexArgument(rawIndex),
                  let integer = Int(index), integer >= 0
            else {
                throw ComputerUseError
                    .invalidArguments("hover requires either a valid element_index or x/y, never both")
            }
            target = .element(index)
        } else {
            target = try .coordinates(Self.number(arguments["x"], key: "x"), Self.number(arguments["y"], key: "y"))
        }
        let duration = try arguments["duration_ms"].map { try Self.number($0, key: "duration_ms") } ?? 500
        guard duration >= 0, duration <= 2000, duration.rounded(.towardZero) == duration else {
            throw ComputerUseError.invalidArguments("duration_ms must be an integer from 0 to 2000")
        }
        durationMilliseconds = Int(duration)
    }

    private static func number(_ value: Any?, key: String) throws -> Double {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite
        else {
            throw ComputerUseError.invalidArguments("\(key) must be a finite number")
        }
        return number.doubleValue
    }
}

/// 悬停不点击，也不在回读失败后重放；等待只服务于 App 的 tracking area。
func dispatchForegroundHover<Result>(
    validateTarget: () throws -> Void,
    prepare: () throws -> Void,
    validateReceiver: () throws -> Void,
    submit: () throws -> Void,
    dwell: () -> Void,
    readBack: () throws -> Result
)
    throws -> Result {
    try validateTarget()
    try prepare()
    try validateReceiver()
    do {
        try submit()
        dwell()
        return try readBack()
    } catch {
        throw ComputerUseError
            .message(
                "Hover input may have occurred; observe before further input. No retry was sent. \(error.localizedDescription)"
            )
    }
}

extension InputSimulation {
    static func requireReleasedMouseButtons() throws {
        for rawValue in 0 ..< 32 {
            guard let button = CGMouseButton(rawValue: UInt32(rawValue)) else {
                continue
            }
            if CGEventSource.buttonState(.combinedSessionState, button: button) {
                throw ComputerUseError.stateUnavailable("A mouse button is held; release it before hover")
            }
        }
    }

    static func movePointerForHover(at point: CGPoint) throws {
        try requireReleasedMouseButtons()
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                  mouseEventSource: source,
                  mouseType: .mouseMoved,
                  mouseCursorPosition: point,
                  mouseButton: .left
              )
        else {
            throw ComputerUseError.message("Could not construct hover mouse event")
        }
        event.post(tap: .cghidEventTap)
    }
}

extension ToolDefinitions {
    public static func available(environment: [String: String] = ProcessInfo.processInfo
        .environment)
        -> [ToolDefinition] {
        foregroundHoverEnabled(environment: environment) ? all + [hover] : all
    }

    private static var hover: ToolDefinition {
        ToolDefinition(
            name: "hover",
            description: "Move the real pointer over an observed element or screenshot point; may foreground it. "
                + "Returns fresh state: inspect before clicking. Does not click or prove a menu opened.",
            annotations: ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": true],
            inputSchema: [
                "type": "object", "additionalProperties": false,
                "properties": [
                    "app": ["type": "string"],
                    "element_index": ["type": "string"],
                    "x": ["type": "number"], "y": ["type": "number"],
                    "duration_ms": ["type": "integer", "minimum": 0, "maximum": 2000, "default": 500],
                ],
                "required": ["app"],
                "oneOf": [
                    ["required": ["element_index"], "not": ["anyOf": [["required": ["x"]], ["required": ["y"]]]]],
                    ["required": ["x", "y"], "not": ["required": ["element_index"]]],
                ],
            ]
        )
    }
}
