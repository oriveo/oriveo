import Foundation
import UIKit

// MARK: - StreamingPacerDelegate

@MainActor
protocol StreamingPacerDelegate: AnyObject {
    var isPacerEnabled: Bool { get }

    var pacerHasPendingFinalRender: Bool { get }

    func pacer(_ pacer: StreamingPacer, didAdvanceTo visibleText: String)

    func pacerDidReachTarget(_ pacer: StreamingPacer)
}

// MARK: - StreamingFenceParity

struct StreamingFenceParity {
    private var completedFenceCount = 0
    private var currentLineStart = 0
    private var scanned = 0

    mutating func reset() {
        completedFenceCount = 0
        currentLineStart = 0
        scanned = 0
    }

    mutating func rebuild(for text: String) {
        reset()
        advance(to: text)
    }

    mutating func advance(to text: String) {
        let ns = text as NSString
        let len = ns.length
        guard len > scanned else { return }
        var cursor = scanned
        while cursor < len {
            let nl = ns.range(of: "\n", range: NSRange(location: cursor, length: len - cursor))
            guard nl.location != NSNotFound else { break }
            if Self.isFenceLine(ns, start: currentLineStart, end: nl.location) {
                completedFenceCount += 1
            }
            currentLineStart = nl.location + 1
            cursor = nl.location + 1
        }
        scanned = len
    }

    func isInsideUnclosedFence(in text: String) -> Bool {
        let ns = text as NSString
        var count = completedFenceCount
        if currentLineStart < ns.length,
           Self.isFenceLine(ns, start: currentLineStart, end: ns.length) {
            count += 1
        }
        return count % 2 == 1
    }

    private static func isFenceLine(_ ns: NSString, start: Int, end: Int) -> Bool {
        var i = start
        while i < end, isWhitespace(ns.character(at: i)) { i += 1 }
        return i + 2 < end
            && ns.character(at: i) == 0x60
            && ns.character(at: i + 1) == 0x60
            && ns.character(at: i + 2) == 0x60
    }

    private static func isWhitespace(_ c: unichar) -> Bool {
        switch c {
        case 0x20, 0x09, 0xA0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }
}

// MARK: - StreamingPacer

@MainActor
final class StreamingPacer {


    static let snapBacklog = 20_000


    private(set) var visibleText: String = ""

    private(set) var targetText: String = ""

    private var visibleUTF16Count = 0
    private var targetUTF16Count = 0

    private var fenceParity = StreamingFenceParity()

    private(set) var profile: StreamingPacerLanguageProfile = .ascii

    var cadence: BlockCommitCadence = .default

    private var lastProfileSampleLength = 0


    weak var displayClock: StreamingDisplayClock?
    private var clockSubscription: StreamingDisplayClock.SubscriberToken?
    private var workItem: DispatchWorkItem?
    private var lastTimestamp: CFTimeInterval = 0
    private var accumulatedDelay: TimeInterval = 0

    weak var delegate: StreamingPacerDelegate?


    var hasBacklog: Bool { visibleUTF16Count < targetUTF16Count }

    var isScheduled: Bool { clockSubscription != nil || workItem != nil }


    init(displayClock: StreamingDisplayClock?) {
        self.displayClock = displayClock
    }


    func snapToInitial(_ text: String) {
        cancel()
        visibleText = text
        targetText = text
        let utf16 = (text as NSString).length
        visibleUTF16Count = utf16
        targetUTF16Count = utf16
        fenceParity.rebuild(for: text)
        profile = .ascii
        lastProfileSampleLength = 0
    }

    func enqueue(_ newTarget: String) {
        guard delegate?.isPacerEnabled == true else { return }
        if newTarget == targetText {
            if visibleText != targetText, !isScheduled {
                schedule(after: 0)
            }
            return
        }

        let newTargetUTF16 = (newTarget as NSString).length

        if newTargetUTF16 - lastProfileSampleLength > 200 || lastProfileSampleLength == 0 {
            let sample = String(newTarget.prefix(200))
            profile = StreamingPacerLanguageProfile.detect(in: sample)
            lastProfileSampleLength = newTargetUTF16
        }

        if !newTarget.hasPrefix(visibleText) || newTargetUTF16 - visibleUTF16Count > Self.snapBacklog {
            applySnapshot(newTarget)
            return
        }

        targetText = newTarget
        targetUTF16Count = newTargetUTF16

        if visibleText.isEmpty {
            performStep()
            return
        }
        schedule(after: 0)
    }

    func snapToTarget(_ text: String) {
        applySnapshot(text)
    }

    func cancel() {
        if let token = clockSubscription, let clock = displayClock {
            clock.removeSubscriber(token)
        }
        clockSubscription = nil
        workItem?.cancel()
        workItem = nil
        lastTimestamp = 0
        accumulatedDelay = 0
    }

    func reset() {
        cancel()
        visibleText = ""
        targetText = ""
        visibleUTF16Count = 0
        targetUTF16Count = 0
        fenceParity.reset()
        profile = .ascii
        lastProfileSampleLength = 0
    }

    nonisolated deinit {}


    private func applySnapshot(_ text: String) {
        cancel()
        visibleText = text
        targetText = text
        let utf16 = (text as NSString).length
        visibleUTF16Count = utf16
        targetUTF16Count = utf16
        fenceParity.rebuild(for: text)
        delegate?.pacer(self, didAdvanceTo: text)
        delegate?.pacerDidReachTarget(self)
    }


    private func schedule(after delay: TimeInterval) {
        guard visibleUTF16Count != targetUTF16Count else {
            delegate?.pacerDidReachTarget(self)
            return
        }

        if let clock = displayClock {
            scheduleViaDisplayClock(initialDelay: delay, clock: clock)
            return
        }

        guard workItem == nil else { return }
        let wi = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.workItem = nil
            self.performStep()
        }
        workItem = wi
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: wi)
    }

    private func scheduleViaDisplayClock(initialDelay: TimeInterval, clock: StreamingDisplayClock) {
        if clockSubscription != nil {
            accumulatedDelay = max(accumulatedDelay, initialDelay)
            return
        }
        accumulatedDelay = initialDelay
        lastTimestamp = 0
        clockSubscription = clock.addSubscriber { [weak self] timestamp in
            self?.handleClockTick(timestamp)
        }
        clock.resume()
    }

    private func handleClockTick(_ timestamp: CFTimeInterval) {
        guard delegate?.isPacerEnabled == true else {
            cancel()
            return
        }
        if lastTimestamp == 0 {
            lastTimestamp = timestamp
            return
        }
        let elapsed = timestamp - lastTimestamp
        lastTimestamp = timestamp
        accumulatedDelay -= elapsed
        guard accumulatedDelay <= 0 else { return }
        performStep()
    }


    private func performStep() {
        guard delegate?.isPacerEnabled == true else {
            cancel()
            return
        }

        if targetUTF16Count - visibleUTF16Count > Self.snapBacklog {
            applySnapshot(targetText)
            return
        }

        let boundary = StreamingBlockChunker.nextBoundary(
            visible: visibleText,
            target: targetText,
            profile: profile,
            cadence: cadence,
            isStreamEnd: delegate?.pacerHasPendingFinalRender == true,
            isInsideFence: fenceParity.isInsideUnclosedFence(in: visibleText)
        )

        switch boundary.kind {
        case .snap:
            applySnapshot(targetText)
            return
        case .held:
            scheduleNext(after: cadence.chunkDelay)
            return
        case .wordChunk, .lineEnd, .paragraphEnd, .tableRows, .codeChunk:
            break
        }

        visibleText = boundary.newVisible
        visibleUTF16Count = (boundary.newVisible as NSString).length
        fenceParity.advance(to: boundary.newVisible)
        delegate?.pacer(self, didAdvanceTo: boundary.newVisible)

        if visibleUTF16Count == targetUTF16Count {
            delegate?.pacerDidReachTarget(self)
            return
        }
        scheduleNext(after: delay(for: boundary.kind))
    }

    private func delay(for kind: StreamingBlockChunker.BoundaryKind) -> TimeInterval {
        let base: TimeInterval
        switch kind {
        case .wordChunk:    base = cadence.chunkDelay
        case .lineEnd:      base = cadence.lineEndDelay
        case .paragraphEnd: base = cadence.paragraphDelay
        case .tableRows:    base = cadence.tableRowDelay
        case .codeChunk:    return profile.frameDelay
        case .snap, .held:  base = cadence.chunkDelay
        }
        let backlog = targetUTF16Count - visibleUTF16Count
        return Self.scaledDelay(base: base, backlogUTF16: backlog, cadence: cadence)
    }

    nonisolated static func scaledDelay(
        base: TimeInterval,
        backlogUTF16: Int,
        cadence: BlockCommitCadence
    ) -> TimeInterval {
        backlogUTF16 > cadence.catchupBacklogUTF16 ? base * cadence.catchupDelayScale : base
    }

    private func scheduleNext(after delay: TimeInterval) {
        if displayClock != nil, clockSubscription != nil {
            accumulatedDelay += delay
        } else {
            schedule(after: delay)
        }
    }


    static func isInsideUnclosedCodeFence(_ text: String) -> Bool {
        guard text.contains("```") else { return false }
        var fenceCount = 0
        text.enumerateLines { line, _ in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                fenceCount += 1
            }
        }
        return fenceCount % 2 == 1
    }

    static func codeStepSize(for backlog: Int) -> Int {
        switch backlog {
        case 0...80:      return 4
        case 81...400:    return 8
        case 401...1_200: return 16
        default:          return 32
        }
    }
}
