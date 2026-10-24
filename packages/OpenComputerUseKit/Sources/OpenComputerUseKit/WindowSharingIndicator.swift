import ApplicationServices
import CoreGraphics
import Foundation

/// macOS shows a "window sharing" indicator on a window that ScreenCaptureKit is
/// streaming. It is a small window inside the captured app's own process (measured
/// on macOS 26: 66×20 pt, layer 0, 16 pt inside the captured window's top-left
/// corner) that exists only while the stream runs and is not app content. The live
/// preview streams the target window, so popup discovery, coordinate occlusion and
/// target window selection must ignore it. It is recognized only while this process
/// streams a window of the same app; its title may be localized and is not used.
enum WindowSharingIndicator {
    struct Captured: Hashable, Sendable {
        let windowID: CGWindowID
        let pid: pid_t
    }

    static let maximumSize = CGSize(width: 120, height: 32)
    static let maximumInset: CGFloat = 48

    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: Set<Captured> = []

    static func captureStarted(windowID: CGWindowID, pid: pid_t) {
        lock.withLock { _ = captured.insert(Captured(windowID: windowID, pid: pid)) }
    }

    static func captureEnded(windowID: CGWindowID, pid: pid_t) {
        lock.withLock { _ = captured.remove(Captured(windowID: windowID, pid: pid)) }
    }

    static var capturedWindows: Set<Captured> {
        lock.withLock { captured }
    }

    /// A small layer-0 window of the same app inside the streamed window's top-left corner.
    static func matches(
        windowID: CGWindowID, pid: pid_t, bounds: CGRect, layer: Int,
        root: Captured, rootBounds: CGRect
    ) -> Bool {
        guard windowID != root.windowID, pid == root.pid, layer == 0,
              bounds.width > 0, bounds.height > 0,
              bounds.width <= maximumSize.width, bounds.height <= maximumSize.height
        else {
            return false
        }
        let insetX = bounds.minX - rootBounds.minX
        let insetY = bounds.minY - rootBounds.minY
        return insetX >= 0 && insetY >= 0 && insetX <= maximumInset && insetY <= maximumInset
    }

    static func isIndicator(
        windowID: CGWindowID, pid: pid_t, bounds: CGRect, layer: Int,
        captured: Set<Captured> = capturedWindows,
        rootBounds: (CGWindowID) -> CGRect?
    ) -> Bool {
        captured.contains { root in
            guard root.pid == pid, let rootBounds = rootBounds(root.windowID) else {
                return false
            }
            return matches(windowID: windowID, pid: pid, bounds: bounds, layer: layer, root: root, rootBounds: rootBounds)
        }
    }

    /// A WindowServer row, with the streamed window's bounds read from the same list or,
    /// when it is not part of it, from WindowServer directly.
    static func isIndicator(
        _ info: [String: Any], windows: [[String: Any]],
        captured: Set<Captured> = capturedWindows,
        query: (CGWindowListOption, CGWindowID) -> [[String: Any]]? = {
            CGWindowListCopyWindowInfo($0, $1) as? [[String: Any]]
        }
    ) -> Bool {
        guard !captured.isEmpty, let row = Row(info) else {
            return false
        }
        return isIndicator(
            windowID: row.windowID, pid: row.pid, bounds: row.bounds, layer: row.layer, captured: captured
        ) { rootID in
            if let root = windows.lazy.compactMap(Row.init).first(where: { $0.windowID == rootID }) {
                return root.bounds
            }
            return query(.optionIncludingWindow, rootID)?.lazy.compactMap(Row.init)
                .first(where: { $0.windowID == rootID })?.bounds
        }
    }

    /// An accessibility window, identified through its WindowServer window.
    static func isIndicator(axWindow: AXUIElement) -> Bool {
        guard !capturedWindows.isEmpty, let windowID = SkyLightSPI.shared.windowID(for: axWindow),
              let row = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let info = row.first(where: { Row($0)?.windowID == windowID })
        else {
            return false
        }
        return isIndicator(info, windows: row)
    }

    private struct Row {
        let windowID: CGWindowID
        let pid: pid_t
        let bounds: CGRect
        let layer: Int

        init?(_ info: [String: Any]) {
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary)
            else {
                return nil
            }
            self.windowID = number.uint32Value
            self.pid = pid
            self.bounds = bounds
            self.layer = layer
        }
    }
}
