import Foundation
import QuartzCore
import UIKit

@MainActor
final class ChunkFadeAnimator {

    nonisolated static let minApplyInterval: CFTimeInterval = 1.0 / 30.0

    // MARK: - Dependencies

    weak var displayClock: StreamingDisplayClock?
    var textStorageProvider: () -> NSTextStorage? = { nil }
    var isScrollingProvider: () -> Bool = { false }
    var reduceMotionProvider: () -> Bool = { UIAccessibility.isReduceMotionEnabled }
    var nowProvider: () -> CFTimeInterval = { CACurrentMediaTime() }
    var cadence: BlockCommitCadence = .default

    // MARK: - State

    struct FadeChunk {
        let range: NSRange
        let colorRuns: [(NSRange, UIColor)]
        let start: CFTimeInterval
        var lastAlpha255: Int = -1
    }

    private(set) var pendingChunks: [FadeChunk] = []
    private var lastApplyTime: CFTimeInterval = 0
    private var clockSubscription: StreamingDisplayClock.SubscriberToken?

    var onQueueDidDrain: (() -> Void)?

    // MARK: - API

    func enqueueChunk(range: NSRange) {
        guard range.length > 0,
              let storage = textStorageProvider(),
              range.location >= 0,
              range.location + range.length <= storage.length else { return }
        let skip = reduceMotionProvider()
        ChatRenderDiagnostics.recordFadeEnqueue(length: range.length, reduceMotionSkip: skip, pending: pendingChunks.count)
        guard !skip else { return }

        let capacity = max(1, cadence.maxActiveChunkFades - pendingChunks.count)
        let segments = staggerSegments(for: range, in: storage, maxSegments: capacity)
        let step: TimeInterval = segments.count > 1
            ? min(cadence.fadeStaggerStep, cadence.fadeStaggerMaxDelay / Double(segments.count - 1))
            : 0
        let now = nowProvider()
        for (i, segment) in segments.enumerated() {
            var runs: [(NSRange, UIColor)] = []
            storage.enumerateAttribute(.foregroundColor, in: segment, options: []) { value, sub, _ in
                guard let color = value as? UIColor else { return }
                runs.append((sub, color))
                storage.addAttribute(.foregroundColor, value: color.withAlphaComponent(0), range: sub)
            }
            guard !runs.isEmpty else { continue }
            pendingChunks.append(FadeChunk(range: segment, colorRuns: runs, start: now + Double(i) * step))
        }
        trimIfNeeded()
        startSubscriptionIfNeeded()
    }

    private func staggerSegments(
        for range: NSRange,
        in storage: NSTextStorage,
        maxSegments: Int
    ) -> [NSRange] {
        guard range.length > cadence.fadeStaggerThresholdUTF16, maxSegments > 1 else { return [range] }
        let desired = (range.length + cadence.fadeStaggerSegmentUTF16 - 1) / cadence.fadeStaggerSegmentUTF16
        let count = min(desired, maxSegments)
        let segmentLen = (range.length + count - 1) / count
        var segments: [NSRange] = []
        var cursor = range.location
        let end = range.location + range.length
        while cursor < end {
            var segmentEnd = min(cursor + segmentLen, end)
            if segmentEnd < end {
                let composed = storage.mutableString.rangeOfComposedCharacterSequence(at: segmentEnd - 1)
                if composed.location < segmentEnd, composed.location + composed.length > segmentEnd {
                    segmentEnd = max(cursor + 1, composed.location)
                }
            }
            segments.append(NSRange(location: cursor, length: segmentEnd - cursor))
            cursor = segmentEnd
        }
        return segments
    }

    func applyAlphas(now: CFTimeInterval, alreadyInEditingTransaction: Bool) {
        guard !pendingChunks.isEmpty else { return }
        if !alreadyInEditingTransaction {
            if now - lastApplyTime < Self.minApplyInterval {
                ChatRenderDiagnostics.recordFadeSkipThrottle(pending: pendingChunks.count)
                return
            }
            lastApplyTime = now
        }
        ChatRenderDiagnostics.recordFadeApply(pending: pendingChunks.count, inBatch: alreadyInEditingTransaction)
        guard let storage = textStorageProvider() else { return }
        let storageLen = storage.length
        if !alreadyInEditingTransaction { storage.beginEditing() }
        var remaining: [FadeChunk] = []
        remaining.reserveCapacity(pendingChunks.count)
        for chunk in pendingChunks {
            guard chunk.range.location + chunk.range.length <= storageLen else { continue }
            let t = (now - chunk.start) / cadence.fadeDuration
            if t >= 1 {
                for (sub, color) in chunk.colorRuns {
                    storage.addAttribute(.foregroundColor, value: color, range: sub)
                }
            } else {
                let eased = 1.0 - pow(1.0 - max(0, t), 3)
                let alpha255 = Int((CGFloat(eased) * 255).rounded())
                var updated = chunk
                if alpha255 != chunk.lastAlpha255 {
                    for (sub, color) in chunk.colorRuns {
                        storage.addAttribute(
                            .foregroundColor,
                            value: color.withAlphaComponent(CGFloat(eased)),
                            range: sub
                        )
                    }
                    updated.lastAlpha255 = alpha255
                }
                remaining.append(updated)
            }
        }
        if !alreadyInEditingTransaction { storage.endEditing() }
        pendingChunks = remaining
        if pendingChunks.isEmpty {
            cancelSubscription()
            let drained = onQueueDidDrain
            onQueueDidDrain = nil
            drained?()
        }
    }

    func applyAlphasInCurrentTransaction() {
        applyAlphas(now: nowProvider(), alreadyInEditingTransaction: true)
    }

    func settleAll() {
        onQueueDidDrain = nil
        if let storage = textStorageProvider() {
            let storageLen = storage.length
            for chunk in pendingChunks {
                guard chunk.range.location + chunk.range.length <= storageLen else { continue }
                for (sub, color) in chunk.colorRuns {
                    storage.addAttribute(.foregroundColor, value: color, range: sub)
                }
            }
        }
        pendingChunks.removeAll()
        cancelSubscription()
    }

    func cancel() {
        settleAll()
    }

    nonisolated deinit {}

    // MARK: - Private

    private func trimIfNeeded() {
        while pendingChunks.count > cadence.maxActiveChunkFades {
            let oldest = pendingChunks.removeFirst()
            guard let storage = textStorageProvider(),
                  oldest.range.location + oldest.range.length <= storage.length else { continue }
            for (sub, color) in oldest.colorRuns {
                storage.addAttribute(.foregroundColor, value: color, range: sub)
            }
        }
    }

    private func startSubscriptionIfNeeded() {
        guard clockSubscription == nil, let clock = displayClock else { return }
        clockSubscription = clock.addSubscriber { [weak self] _ in
            self?.applyAlphas(now: CACurrentMediaTime(), alreadyInEditingTransaction: false)
        }
        clock.resume()
    }

    private func cancelSubscription() {
        if let token = clockSubscription, let clock = displayClock {
            clock.removeSubscriber(token)
        }
        clockSubscription = nil
    }
}
