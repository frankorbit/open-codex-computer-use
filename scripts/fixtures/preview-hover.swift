import AppKit
import CryptoKit
@testable import OpenComputerUseKit

/// 显式 opt-in 的 WindowServer 验收：只移动指针，不向其他应用点击或输入。
@main @MainActor
final class PreviewHoverProbe {
    private let app = NSApplication.shared
    private let view = LivePreviewView(frame: CGRect(x: 0, y: 0, width: 360, height: 240))
    private var panel: LivePreviewPanel?
    private var timer: Timer?
    private var originalPoint = CGPoint.zero
    private var foregroundPID: pid_t?
    private var index = 0
    private var prepared = false
    private var originalAccess: Bool?
    private var failures = 0
    private struct HoverCase {
        let name: String
        let point: CGPoint
        let cursor: NSCursor?
    }

    private var cases: [HoverCase] = []

    static func main() {
        guard CommandLine.arguments.contains("--move-pointer") else {
            print("Pass --move-pointer to run the isolated hover test and restore the pointer afterwards.")
            return
        }
        let probe = PreviewHoverProbe()
        probe.run()
    }

    private func run() {
        app.setActivationPolicy(.accessory)
        foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        originalAccess = cursorAccessEnabled()
        originalPoint = CGEvent(source: nil)?.location ?? .zero
        view.message = "预览边缘悬停验收"
        let panel = LivePreviewPanel.make(view: view, inputActive: false, onHide: {})
        self.panel = panel
        if let screen = NSScreen.screens.first {
            panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - panel.frame.width / 2,
                                         y: screen.visibleFrame.midY - panel.frame.height / 2))
        }
        panel.orderFrontRegardless()
        view.updateTrackingAreas()
        cases = LivePreviewResizeEdge.allCases.map {
            let rect = $0.hitRect(in: view.bounds)
            return HoverCase(
                name: String(describing: $0),
                point: CGPoint(x: rect.midX, y: rect.midY),
                cursor: $0.cursor
            )
        }
        cases += [HoverCase(name: "center", point: CGPoint(x: 180, y: 120), cursor: .openHand),
                  HoverCase(name: "outside", point: CGPoint(x: -30, y: 120), cursor: nil),
                  HoverCase(name: "inputPassThrough", point: CGPoint(x: 356, y: 120),
                            cursor: LivePreviewResizeEdge.right.cursor),
                  HoverCase(name: "hideWhileHovering", point: CGPoint(x: 4, y: 120),
                            cursor: LivePreviewResizeEdge.left.cursor)]
        // 重复移出/移入，覆盖 AppKit 先缓存光标、后取得后台权限的顺序。
        for _ in 0 ..< 10 {
            cases.insert(contentsOf: [
                HoverCase(name: "outside", point: CGPoint(x: -30, y: 120), cursor: nil),
                HoverCase(name: "reenter", point: CGPoint(x: 356, y: 120),
                          cursor: LivePreviewResizeEdge.right.cursor)
            ], at: cases.count - 1)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [self] _ in
            MainActor.assumeIsolated { tick() }
        }
        app.run()
    }

    private func tick() {
        guard let panel else { return }
        if !prepared {
            // 命令行 AppKit 首次启动可能自动激活；先恢复原应用，再开始后台验收。
            app.deactivate()
            if let foregroundPID { NSRunningApplication(processIdentifier: foregroundPID)?.activate(options: []) }
            prepared = true
            return
        }
        if index > 0 {
            let sample = cases[index - 1]
            let name = sample.name
            let expected = sample.cursor
            // current 只反映进程内部状态；验收必须比较 WindowServer 的实际系统光标。
            let systemMatches = expected.map { digest($0) == digest(NSCursor.currentSystem) } ?? true
            let foregroundUnchanged = NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundPID
            let accessMatches = cursorAccessEnabled() == (expected == nil ? originalAccess : true)
            let passed = !app.isActive && !panel.isKeyWindow && systemMatches && foregroundUnchanged && accessMatches
            if !passed {
                failures += 1
                print("local=\(digest(NSCursor.current) ?? "nil") system=\(digest(NSCursor.currentSystem) ?? "nil")")
                print("bounds=\(view.bounds) sample=\(sample.point)")
            }
            print(
                "\(name): \(passed ? "PASS" : "FAIL") inactive=\(!app.isActive) systemCursor=\(systemMatches)" +
                    " foreground=\(foregroundUnchanged) access=\(accessMatches)"
            )
            checkCleanup(name: name, panel: panel)
            fflush(stdout)
        }
        guard index < cases.count else {
            timer?.invalidate()
            panel.finish()
            if cursorAccessEnabled() != originalAccess { failures += 1 }
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                    mouseCursorPosition: originalPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
            print("result: \(failures) failures; pointer restored")
            exit(failures == 0 ? 0 : 1)
        }
        let point = panel.convertPoint(toScreen: view.convert(cases[index].point, to: nil))
        let height = NSScreen.screens.first?.frame.maxY ?? 0
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: point.x, y: height - point.y), mouseButton: .left)?
            .post(tap: .cghidEventTap)
        index += 1
    }

    private func checkCleanup(name: String, panel: LivePreviewPanel) {
        if name == "inputPassThrough" {
            view.cancelInteraction()
            panel.ignoresMouseEvents = true
            if cursorAccessEnabled() != originalAccess { failures += 1 }
            panel.ignoresMouseEvents = false
        }
        if name == "hideWhileHovering" {
            panel.orderOut(nil)
            if cursorAccessEnabled() != originalAccess { failures += 1 }
        }
    }

    private func cursorAccessEnabled() -> Bool? {
        typealias Connection = @convention(c) () -> Int32
        typealias Copy = @convention(c) (Int32, Int32, CFString, UnsafeMutablePointer<Unmanaged<CFTypeRef>?>) -> Int32
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            failures += 1
            return nil
        }
        defer { dlclose(handle) }
        guard let mainSymbol = dlsym(handle, "CGSMainConnectionID"),
              let copySymbol = dlsym(handle, "CGSCopyConnectionProperty") else {
            failures += 1
            return nil
        }
        let connection = unsafeBitCast(mainSymbol, to: Connection.self)()
        let copy = unsafeBitCast(copySymbol, to: Copy.self)
        var value: Unmanaged<CFTypeRef>?
        let result = copy(connection, connection, "SetsCursorInBackground" as CFString, &value)
        if result != 0 { failures += 1 }
        return value?.takeRetainedValue() as? Bool
    }

    private func digest(_ cursor: NSCursor?) -> String? {
        cursor?.image.tiffRepresentation.map { data in
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}
