import Foundation
import UIKit

/// Opt-in render tracing for the chat list: layout invalidations, cell height preferences,
/// scroll ticks and fade batching. Every recorder is gated on `enabled` and compiled out of
/// release builds.
///
/// In summary mode a whole window collapses into one line instead of one line per event, which is
/// what keeps the trace readable while a stream is scrolling:
///
/// ```
/// s=00042 t=1.234 SUM INVAL=7 adj=[-15..814] sumAdj=903 | CELL=3 sumΔ=200 lastH=190 | SCROLL …
/// ```
@MainActor
enum ChatRenderDiagnostics {
    static var enabled: Bool = false
    static var enableSummaryMode: Bool = true

    private static var sessionStart: CFTimeInterval = CACurrentMediaTime()
    private static var sequence: UInt = 0
    private static let summaryInterval: CFTimeInterval = 0.2

    // MARK: Summary accumulators

    private static var summaryWindowStart: CFTimeInterval = CACurrentMediaTime()

    private static var invalCount: Int = 0
    private static var invalAdjMin: CGFloat = .infinity
    private static var invalAdjMax: CGFloat = -.infinity
    private static var invalAdjSum: CGFloat = 0
    private static var invalZeroedCount: Int = 0

    private static var cellPreferCount: Int = 0
    private static var cellDiffSum: CGFloat = 0
    private static var cellDiffMin: CGFloat = .infinity
    private static var cellDiffMax: CGFloat = -.infinity
    private static var cellLastNewH: CGFloat = 0
    private static var cellStreamCount: Int = 0

    private static var scrollFirstOff: CGFloat?
    private static var scrollLastOff: CGFloat = 0
    private static var scrollMinOff: CGFloat = .infinity
    private static var scrollMaxOff: CGFloat = -.infinity
    private static var scrollLastDrag: Bool = false
    private static var scrollLastDecel: Bool = false

    private static var fadeApplyCount: Int = 0
    private static var fadeSkipThrottleCount: Int = 0
    private static var fadeEnqueueCount: Int = 0

    static func resetSession() {
        sessionStart = CACurrentMediaTime()
        sequence = 0
        resetWindow()
        printRaw("SESSION_RESET")
    }

    private static func resetWindow() {
        summaryWindowStart = CACurrentMediaTime()
        invalCount = 0
        invalAdjMin = .infinity
        invalAdjMax = -.infinity
        invalAdjSum = 0
        invalZeroedCount = 0
        cellPreferCount = 0
        cellDiffSum = 0
        cellDiffMin = .infinity
        cellDiffMax = -.infinity
        cellLastNewH = 0
        cellStreamCount = 0
        scrollFirstOff = nil
        scrollLastOff = 0
        scrollMinOff = .infinity
        scrollMaxOff = -.infinity
        scrollLastDrag = false
        scrollLastDecel = false
        fadeApplyCount = 0
        fadeSkipThrottleCount = 0
        fadeEnqueueCount = 0
    }

    private static func flushIfNeeded() {
        #if DEBUG
        guard enableSummaryMode else { return }
        let now = CACurrentMediaTime()
        guard now - summaryWindowStart >= summaryInterval else { return }
        flushSummary(now: now)
        resetWindow()
        #endif
    }

    private static func flushSummary(now: CFTimeInterval) {
        let hasData = invalCount > 0 || cellPreferCount > 0 || scrollFirstOff != nil
            || fadeApplyCount > 0 || fadeEnqueueCount > 0
        guard hasData else { return }
        var parts: [String] = []
        if invalCount > 0 {
            let adjStr: String
            if invalAdjMin == invalAdjMax {
                adjStr = "adj=\(f(invalAdjMin))"
            } else {
                adjStr = "adj=[\(f(invalAdjMin))..\(f(invalAdjMax))]"
            }
            parts.append("INVAL=\(invalCount) \(adjStr) sumAdj=\(f(invalAdjSum)) zeroed=\(invalZeroedCount)")
        }
        if cellPreferCount > 0 {
            let diffStr: String
            if cellDiffMin == cellDiffMax {
                diffStr = "Δ=\(f(cellDiffMin))"
            } else {
                diffStr = "Δ=[\(f(cellDiffMin))..\(f(cellDiffMax))]"
            }
            parts.append("CELL=\(cellPreferCount) \(diffStr) sumΔ=\(f(cellDiffSum)) lastH=\(f(cellLastNewH)) stream=\(cellStreamCount)")
        }
        if let first = scrollFirstOff {
            parts.append("SCROLL off=\(f(first))→\(f(scrollLastOff)) Δ=\(f(scrollLastOff-first)) range=[\(f(scrollMinOff))..\(f(scrollMaxOff))] drag=\(b(scrollLastDrag)) decel=\(b(scrollLastDecel))")
        }
        if fadeApplyCount > 0 || fadeSkipThrottleCount > 0 || fadeEnqueueCount > 0 {
            parts.append("FADE apply=\(fadeApplyCount) skipThrottle=\(fadeSkipThrottleCount) enqueue=\(fadeEnqueueCount)")
        }
        printRaw("SUM " + parts.joined(separator: " | "))
    }


    static func recordLayoutInval(idx: Int, heightDiff: CGFloat, adjBefore: CGFloat, wasZeroed: Bool, isFollow: Bool?) {
        #if DEBUG
        guard enabled else { return }
        flushIfNeeded()
        if enableSummaryMode {
            invalCount += 1
            invalAdjMin = min(invalAdjMin, adjBefore)
            invalAdjMax = max(invalAdjMax, adjBefore)
            invalAdjSum += adjBefore
            if wasZeroed { invalZeroedCount += 1 }
        } else {
            printRaw("LAYOUT_INVAL idx=\(idx) heightDiff=\(f(heightDiff)) adjBefore=\(f(adjBefore)) wasZeroed=\(b(wasZeroed)) isFollow=\(isFollow.map(b) ?? "nil")")
        }
        #endif
    }

    static func recordCellPrefer(id: String, minY: CGFloat, oldH: CGFloat, newH: CGFloat, isStream: Bool) {
        #if DEBUG
        guard enabled else { return }
        flushIfNeeded()
        let diff = newH - oldH
        if enableSummaryMode {
            cellPreferCount += 1
            cellDiffSum += diff
            cellDiffMin = min(cellDiffMin, diff)
            cellDiffMax = max(cellDiffMax, diff)
            cellLastNewH = newH
            if isStream { cellStreamCount += 1 }
        } else {
            printRaw("CELL_PREFER id=\(id) minY=\(f(minY)) oldH=\(f(oldH)) newH=\(f(newH)) diff=\(f(diff)) isStream=\(b(isStream))")
        }
        #endif
    }

    static func recordScrollTick(off: CGFloat, contentH: CGFloat, vH: CGFloat, drag: Bool, decel: Bool, track: Bool) {
        #if DEBUG
        guard enabled else { return }
        flushIfNeeded()
        if enableSummaryMode {
            if scrollFirstOff == nil { scrollFirstOff = off }
            scrollLastOff = off
            scrollMinOff = min(scrollMinOff, off)
            scrollMaxOff = max(scrollMaxOff, off)
            scrollLastDrag = drag
            scrollLastDecel = decel
        } else {
            printRaw("SCROLL_TICK off=\(f(off)) contentH=\(f(contentH)) vH=\(f(vH)) drag=\(b(drag)) decel=\(b(decel)) track=\(b(track))")
        }
        #endif
    }

    static func recordFadeApply(pending: Int, inBatch: Bool) {
        #if DEBUG
        guard enabled else { return }
        flushIfNeeded()
        if enableSummaryMode {
            fadeApplyCount += 1
        } else {
            printRaw("FADE_APPLY pending=\(pending) inBatch=\(b(inBatch))")
        }
        #endif
    }

    static func recordFadeSkipThrottle(pending: Int) {
        #if DEBUG
        guard enabled else { return }
        flushIfNeeded()
        if enableSummaryMode {
            fadeSkipThrottleCount += 1
        }
        #endif
    }

    static func recordFadeEnqueue(length: Int, reduceMotionSkip: Bool, pending: Int) {
        #if DEBUG
        guard enabled else { return }
        flushIfNeeded()
        if enableSummaryMode {
            fadeEnqueueCount += 1
        } else {
            printRaw("FADE_ENQUEUE len=\(length) rmSkip=\(b(reduceMotionSkip)) pending=\(pending)")
        }
        #endif
    }


    static func recordUserDragBegan(off: CGFloat) {
        #if DEBUG
        guard enabled else { return }
        flushIfNeeded()
        printRaw("USER_DRAG_BEGAN off=\(f(off))")
        #endif
    }

    static func recordUserDragEnded(off: CGFloat, willDecel: Bool) {
        #if DEBUG
        guard enabled else { return }
        flushIfNeeded()
        printRaw("USER_DRAG_ENDED off=\(f(off)) willDecel=\(b(willDecel))")
        #endif
    }

    static func recordUserSettled(off: CGFloat, distBottom: CGFloat) {
        #if DEBUG
        guard enabled else { return }
        flushIfNeeded()
        printRaw("USER_SETTLED off=\(f(off)) distBottom=\(f(distBottom))")
        #endif
    }

    static func recordFollowDidSet(from: Bool, to: Bool) {
        #if DEBUG
        guard enabled else { return }
        flushIfNeeded()
        printRaw("FOLLOW_DIDSET from=\(b(from)) to=\(b(to))")
        #endif
    }


    private static func printRaw(_ msg: String) {
        sequence &+= 1
        let elapsed = CACurrentMediaTime() - sessionStart
        let seqStr = String(format: "%05d", sequence)
        let tStr = String(format: "%.3f", elapsed)
        AppLog.info("s=\(seqStr) t=\(tStr) \(msg)", module: "ChatRender")
    }

    static func f(_ v: CGFloat) -> String {
        if v == .infinity || v == -.infinity { return "-" }
        return String(format: "%.1f", v)
    }

    static func b(_ v: Bool) -> String { v ? "T" : "F" }
}
