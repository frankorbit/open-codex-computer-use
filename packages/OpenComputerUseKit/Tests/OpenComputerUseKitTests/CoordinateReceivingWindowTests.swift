import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class CoordinateReceivingWindowTests: XCTestCase {
    // 提醒事项实测：详情弹层盖在主窗口之上，日期框在 AX 树中属于主窗口。
    private let mainBounds = CGRect(x: 200, y: 100, width: 1140, height: 600)
    private let popup = CGRect(x: 900, y: 150, width: 290, height: 640)
    private let point = CGPoint(x: 1100, y: 320)

    private func window(id: Int, pid: Int = 1234, rect: CGRect, visible: Bool = true,
                        alpha: Double = 1) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: id), kCGWindowOwnerPID as String: NSNumber(value: pid),
         kCGWindowBounds as String: rect.dictionaryRepresentation,
         kCGWindowIsOnscreen as String: NSNumber(value: visible), kCGWindowAlpha as String: NSNumber(value: alpha)]
    }

    func testTopmostSameProcessWindowHostsTheTargetOnlyWhenTheHitIsTheTarget() {
        let above = [window(id: 77, pid: 999, rect: popup), window(id: 60, rect: popup)]
        var asked: [CGRect] = []
        XCTAssertEqual(coordinateReceivingWindow(above: above, pid: 1234, point: point) { asked.append($0); return true },
                       CoordinateReceivingWindow(windowID: 60, bounds: popup))
        XCTAssertEqual(asked, [popup], "the hit is checked against the candidate window's bounds")
        // 命中的是别的窗口里的元素：那是真正的遮挡物，不能当作接收窗口。
        XCTAssertNil(coordinateReceivingWindow(above: above, pid: 1234, point: point) { _ in false })
    }

    func testOnlyVisibleWindowsContainingThePointAreConsidered() {
        var hits = 0
        let ignored = [window(id: 61, rect: popup, visible: false), window(id: 62, rect: popup, alpha: 0),
                       window(id: 63, rect: CGRect(x: 0, y: 0, width: 50, height: 50))]
        XCTAssertNil(coordinateReceivingWindow(above: ignored, pid: 1234, point: point) { _ in hits += 1; return true })
        XCTAssertEqual(hits, 0, "no candidate, no hit test")
        // 最上层的候选才可能是承载窗口；下面那个即使包含该点也不算。
        let stacked = [window(id: 64, rect: popup), window(id: 60, rect: popup)]
        XCTAssertEqual(coordinateReceivingWindow(above: stacked, pid: 1234, point: point) { _ in true }?.windowID, 64)
    }

    func testHitSharesTheHostWhenTheNearestCommonAncestorLiesInsideTheWindow() {
        // 主窗口 W > 弹层 P > 日期行 R > {日期文字 T, 标签 L}；T 的子元素 C；主窗口上的 sheet S 挂在 W 下。
        let w = AXUIElementCreateApplication(42001), p = AXUIElementCreateApplication(42002)
        let r = AXUIElementCreateApplication(42003), t = AXUIElementCreateApplication(42004)
        let l = AXUIElementCreateApplication(42005), c = AXUIElementCreateApplication(42006)
        let sheet = AXUIElementCreateApplication(42007)
        let parents: [(AXUIElement, AXUIElement)] = [(p, w), (r, p), (t, r), (l, r), (c, t), (sheet, w)]
        let frames: [(AXUIElement, CGRect)] = [
            (w, mainBounds), (p, popup), (r, CGRect(x: 910, y: 280, width: 270, height: 90)),
            (t, CGRect(x: 950, y: 310, width: 200, height: 14)), (sheet, CGRect(x: 600, y: 120, width: 400, height: 300)),
        ]
        let parent: (AXUIElement) -> AXUIElement? = { e in parents.first { CFEqual($0.0, e) }?.1 }
        let frame: (AXUIElement) -> CGRect? = { e in frames.first { CFEqual($0.0, e) }?.1 }
        func hosted(_ hit: AXUIElement?) -> Bool {
            axHit(hit, sharesHostWith: t, within: popup, parent: parent, frame: frame)
        }
        XCTAssertTrue(hosted(t))
        XCTAssertTrue(hosted(c), "a child of the target")
        XCTAssertTrue(hosted(r), "the row whose center is the click point")
        XCTAssertTrue(hosted(l), "another element of the same row")
        XCTAssertTrue(hosted(p))
        // 共同祖先是主窗口（大于弹层）：真正的遮挡物。
        XCTAssertFalse(hosted(sheet))
        XCTAssertFalse(hosted(w))
        XCTAssertFalse(hosted(nil))
        XCTAssertFalse(hosted(AXUIElementCreateApplication(42999)), "an unrelated element")
        XCTAssertFalse(axHit(c, sharesHostWith: t, within: popup, parent: { _ in c }, frame: frame),
                       "a parent loop stops at the depth limit")
    }

    func testReceivingPopupIsNotAnObstructionButOthersStillAre() throws {
        let receiving = CoordinateReceivingWindow(windowID: 60, bounds: popup)
        let main = window(id: 42, rect: mainBounds)
        func validate(_ windows: [[String: Any]], global: Bool = false, receiver: CGWindowID? = 42,
                      host: CoordinateReceivingWindow? = receiving, at location: CGPoint? = nil) throws {
            try validateCoordinateWindow(
                windowID: 42, pid: 1234, bounds: mainBounds, point: location ?? point, windows: windows,
                requireUnoccludedPoint: global, spacesForWindow: { _ in [1] }, mouseReceiver: { _ in receiver },
                backgroundWindows: { _ in
                    let target = windows.firstIndex { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == 42 } ?? 0
                    return .onScreenAbove(Array(windows.prefix(target)))
                },
                receivingWindow: host
            )
        }
        // 承载目标的弹层在主窗口之上：后台点击放行，前台命中它也放行。
        try validate([window(id: 60, rect: popup), main])
        try validate([window(id: 60, rect: popup), main], global: true, receiver: 60)
        // 没有承载窗口时，同一个弹层仍是遮挡物（原有行为）。
        XCTAssertThrowsError(try validate([window(id: 60, rect: popup), main], host: nil))
        // 弹层之上还有同进程的其他窗口：仍然拦截；前台命中别的窗口也拦截。
        XCTAssertThrowsError(try validate([window(id: 70, rect: popup), window(id: 60, rect: popup), main]))
        XCTAssertThrowsError(try validate([window(id: 60, rect: popup), main], global: true, receiver: 70))
        // 弹层关闭或移动后不能沿用。
        XCTAssertThrowsError(try validate([main]))
        XCTAssertThrowsError(try validate([window(id: 60, rect: popup.offsetBy(dx: 5, dy: 0)), main]))
        XCTAssertThrowsError(try validate([window(id: 60, pid: 999, rect: popup), main]))
        // 点击位置伸出主窗口但在弹层内：允许；两者之外：拒绝。
        let outside = CGPoint(x: 1100, y: 760)
        try validate([window(id: 60, rect: popup), main], at: outside)
        XCTAssertThrowsError(try validate([window(id: 60, rect: popup), main], host: nil, at: outside))
    }
}
