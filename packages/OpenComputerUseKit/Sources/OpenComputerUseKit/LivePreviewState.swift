//
//  LivePreviewState.swift
//  {project}
//
//  Copyright © 2026 Today AI. All rights reserved.
//

import CoreGraphics
import Foundation

// MARK: - LivePreviewTarget

struct LivePreviewTarget: Equatable {
    let pid: Int32
    let windowID: CGWindowID
    let bounds: CGRect

    init?(pid: Int32, windowID: CGWindowID?, bounds: CGRect?) {
        guard pid > 0, let windowID, windowID > 0, let bounds,
              !bounds.isEmpty, !bounds.isNull, !bounds.isInfinite,
              [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite)
        else {
            return nil
        }
        self.pid = pid
        self.windowID = windowID
        self.bounds = bounds
    }

    func hasSameWindow(as other: Self) -> Bool {
        pid == other.pid && windowID == other.windowID
    }
}

// MARK: - LivePreviewState

/// 与输入引用完全独立；只用于丢弃切窗、收起和停止后的迟到视频帧。
struct LivePreviewState {
    private(set) var target: LivePreviewTarget?
    private(set) var generation = UUID()
    private(set) var hidden = false

    mutating func select(_ target: LivePreviewTarget?, forceGeometry: Bool = false) -> Bool {
        guard forceGeometry || self.target != target else {
            return false
        }
        self.target = target
        generation = UUID()
        return true
    }

    mutating func hide() {
        hidden = true
        generation = UUID()
    }

    mutating func reopen() {
        hidden = false
        generation = UUID()
    }

    mutating func reset() {
        target = nil
        hidden = false
        generation = UUID()
    }

    func accepts(_ generation: UUID) -> Bool {
        self.generation == generation && target != nil && !hidden
    }
}

func livePreviewEnabled(environment: [String: String]) -> Bool {
    environment["OPEN_COMPUTER_USE_LIVE_PREVIEW"] == "1"
}

func livePreviewCursorPoint(tip: CGPoint, window: CGRect, primaryHeight: CGFloat) -> CGPoint? {
    let local = CGPoint(x: tip.x - window.minX, y: tip.y - (primaryHeight - window.maxY))
    guard CGRect(origin: .zero, size: window.size).contains(local) else {
        return nil
    }
    return local
}
