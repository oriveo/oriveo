import Foundation
import Testing
import UIKit
@testable import Oriveo

/// `ChunkFadeAnimator` fades a whole committed block in at once.
///
/// Contract:
/// - `enqueueChunk(range:)` records the existing `.foregroundColor` runs in the range and sets the
///   whole block to alpha 0;
/// - `applyAlphas` advances every pending chunk along the same ease-out cubic curve and, when a
///   chunk finishes, restores its exact original colours and dequeues it;
/// - ranges stay valid because the text is append-only; an out-of-bounds range (after a freeze
///   cleared the storage) is defensively dropped;
/// - scrolling does not suspend the animator: chunks are still enqueued and still advance. The old
///   "yield while scrolling" behaviour was why blocks committed while the user sat at the bottom of
///   a live stream snapped straight to their final colour instead of fading, so do not restore it;
/// - calls outside a batch are throttled to 30fps, calls inside one are not;
/// - beyond `maxActiveChunkFades` the oldest chunk settles immediately, and Reduce Motion goes
///   straight to the final colour.
@Suite("Chunk fade animator")
@MainActor
struct ChunkFadeAnimatorTests {

    private func makeStorage(_ text: String, color: UIColor = .red) -> NSTextStorage {
        NSTextStorage(string: text, attributes: [.foregroundColor: color])
    }

    private func makeAnimator(
        _ storage: NSTextStorage,
        scrolling: Bool = false,
        reduceMotion: Bool = false
    ) -> ChunkFadeAnimator {
        let a = ChunkFadeAnimator()
        a.textStorageProvider = { storage }
        a.isScrollingProvider = { scrolling }
        a.reduceMotionProvider = { reduceMotion }
        a.nowProvider = { 1000 }
        return a
    }

    private func alpha(of storage: NSTextStorage, at index: Int) -> CGFloat {
        guard let color = storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor else {
            return -1
        }
        var a: CGFloat = -1
        color.getRed(nil, green: nil, blue: nil, alpha: &a)
        return a
    }

    @Test("Enqueue Hides And Completes To Exact Color")
    func enqueueHidesAndCompletesToExactColor() {
        let storage = makeStorage("hello world")
        storage.addAttribute(.foregroundColor, value: UIColor.blue, range: NSRange(location: 6, length: 5))
        let animator = makeAnimator(storage)

        animator.enqueueChunk(range: NSRange(location: 0, length: 11))
        #expect(animator.pendingChunks.count == 1)
        #expect(alpha(of: storage, at: 0) == 0)
        #expect(alpha(of: storage, at: 6) == 0)

        animator.applyAlphas(now: 1000 + animator.cadence.fadeDuration + 0.01, alreadyInEditingTransaction: true)
        #expect(animator.pendingChunks.isEmpty)
        let head = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        let tail = storage.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? UIColor
        #expect(head == UIColor.red)
        #expect(tail == UIColor.blue)
    }

    @Test("Midway Ease Out")
    func midwayEaseOut() {
        let storage = makeStorage("hello")
        let animator = makeAnimator(storage)
        animator.enqueueChunk(range: NSRange(location: 0, length: 5))

        animator.applyAlphas(now: 1000 + animator.cadence.fadeDuration / 2, alreadyInEditingTransaction: true)
        let mid = alpha(of: storage, at: 0)
        #expect(mid > 0 && mid < 1)
        #expect(animator.pendingChunks.count == 1)
    }

    @Test("Settle All Restores")
    func settleAllRestores() {
        let storage = makeStorage("hello")
        let animator = makeAnimator(storage)
        animator.enqueueChunk(range: NSRange(location: 0, length: 5))
        animator.settleAll()
        #expect(animator.pendingChunks.isEmpty)
        #expect(alpha(of: storage, at: 0) == 1)
    }

    @Test("Scrolling Enqueue Still Fades")
    func scrollingEnqueueStillFades() {
        let storage = makeStorage("hello")
        let animator = makeAnimator(storage, scrolling: true)
        animator.enqueueChunk(range: NSRange(location: 0, length: 5))
        #expect(animator.pendingChunks.count == 1)
        #expect(alpha(of: storage, at: 0) == 0)
    }

    @Test("Scrolling Apply Still Advances")
    func scrollingApplyStillAdvances() {
        let storage = makeStorage("hello")
        var scrolling = false
        let animator = ChunkFadeAnimator()
        animator.textStorageProvider = { storage }
        animator.isScrollingProvider = { scrolling }
        animator.nowProvider = { 1000 }
        animator.enqueueChunk(range: NSRange(location: 0, length: 5))
        scrolling = true
        animator.applyAlphas(now: 1000 + animator.cadence.fadeDuration / 2, alreadyInEditingTransaction: true)
        let mid = alpha(of: storage, at: 0)
        #expect(mid > 0 && mid < 1, "the fade must keep advancing while scrolling (mid-point alpha between 0 and 1), measured \(mid)")
        #expect(animator.pendingChunks.count == 1)

        animator.applyAlphas(now: 1000 + animator.cadence.fadeDuration + 0.01, alreadyInEditingTransaction: true)
        #expect(alpha(of: storage, at: 0) == 1)
        #expect(animator.pendingChunks.isEmpty)
    }

    @Test("Queue Drain Hook Fires On Natural Completion Only")
    func queueDrainHookFiresOnNaturalCompletionOnly() {
        let storage = makeStorage("hello")
        let animator = makeAnimator(storage)
        var drainCount = 0
        animator.onQueueDidDrain = { drainCount += 1 }

        animator.enqueueChunk(range: NSRange(location: 0, length: 5))
        animator.applyAlphas(now: 1000 + animator.cadence.fadeDuration / 2, alreadyInEditingTransaction: true)
        #expect(drainCount == 0, "drain must not fire while a fade is still in progress")

        animator.applyAlphas(now: 1000 + animator.cadence.fadeDuration + 0.01, alreadyInEditingTransaction: true)
        #expect(drainCount == 1, "draining the queue naturally must fire exactly once")
        #expect(animator.onQueueDidDrain == nil, "the hook clears itself after firing so it cannot fire twice")

        animator.onQueueDidDrain = { drainCount += 1 }
        animator.enqueueChunk(range: NSRange(location: 0, length: 5))
        animator.settleAll()
        #expect(drainCount == 1, "settleAll forces the chunks to settle and must not fire the drain callback")
        #expect(animator.onQueueDidDrain == nil, "settleAll must clear the hook")
    }

    @Test("Throttle Non Batch Applies")
    func throttleNonBatchApplies() {
        let storage = makeStorage("hello")
        let animator = makeAnimator(storage)
        animator.enqueueChunk(range: NSRange(location: 0, length: 5))

        animator.applyAlphas(now: 1000.05, alreadyInEditingTransaction: false)
        let a1 = alpha(of: storage, at: 0)
        #expect(a1 > 0)
        animator.applyAlphas(now: 1000.058, alreadyInEditingTransaction: false)
        #expect(alpha(of: storage, at: 0) == a1)
        animator.applyAlphas(now: 1000.066, alreadyInEditingTransaction: true)
        #expect(alpha(of: storage, at: 0) > a1)
    }

    @Test("Max Active Settles Oldest")
    func maxActiveSettlesOldest() {
        let animator0 = ChunkFadeAnimator()
        let limit = animator0.cadence.maxActiveChunkFades
        let storage = makeStorage(String(repeating: "x", count: (limit + 1) * 10))
        let animator = makeAnimator(storage)
        for i in 0...(limit) {
            animator.enqueueChunk(range: NSRange(location: i * 10, length: 10))
        }
        #expect(animator.pendingChunks.count == limit)
        #expect(alpha(of: storage, at: 0) == 1)
        #expect(alpha(of: storage, at: limit * 10) == 0)
    }

    @Test("Reduce Motion Immediate")
    func reduceMotionImmediate() {
        let storage = makeStorage("hello")
        let animator = makeAnimator(storage, reduceMotion: true)
        animator.enqueueChunk(range: NSRange(location: 0, length: 5))
        #expect(animator.pendingChunks.isEmpty)
        #expect(alpha(of: storage, at: 0) == 1)
    }

    @Test("Long Chunk Staggers Into Segments")
    func longChunkStaggersIntoSegments() {
        let storage = makeStorage(String(repeating: "x", count: 40))
        let animator = makeAnimator(storage)
        animator.enqueueChunk(range: NSRange(location: 0, length: 40))

        let segs = animator.pendingChunks
        #expect(segs.count > 1)
        var cursor = 0
        for seg in segs {
            #expect(seg.range.location == cursor)
            cursor = seg.range.location + seg.range.length
        }
        #expect(cursor == 40)
        for i in 1..<segs.count {
            #expect(segs[i].start > segs[i - 1].start)
        }
    }

    @Test("Staggered Segments Complete In Order")
    func staggeredSegmentsCompleteInOrder() {
        let storage = makeStorage(String(repeating: "x", count: 40))
        let animator = makeAnimator(storage)
        animator.enqueueChunk(range: NSRange(location: 0, length: 40))
        let lastStart = animator.pendingChunks.last!.start
        #expect(lastStart > 1000)

        animator.applyAlphas(now: 1000 + animator.cadence.fadeDuration + 0.01, alreadyInEditingTransaction: true)
        #expect(alpha(of: storage, at: 0) == 1)
        #expect(alpha(of: storage, at: 39) < 1)
        #expect(!animator.pendingChunks.isEmpty)

        animator.applyAlphas(
            now: lastStart + animator.cadence.fadeDuration + 0.01,
            alreadyInEditingTransaction: true
        )
        #expect(animator.pendingChunks.isEmpty)
        #expect(alpha(of: storage, at: 39) == 1)
    }

    @Test("Short Chunk Stays Single")
    func shortChunkStaysSingle() {
        let storage = makeStorage("short text")
        let animator = makeAnimator(storage)
        animator.enqueueChunk(range: NSRange(location: 0, length: 10))
        #expect(animator.pendingChunks.count == 1)
    }

    @Test("Out Of Bounds Chunk Dropped")
    func outOfBoundsChunkDropped() {
        let storage = makeStorage("hello world")
        let animator = makeAnimator(storage)
        animator.enqueueChunk(range: NSRange(location: 6, length: 5))
        storage.setAttributedString(NSAttributedString(string: "hi", attributes: [.foregroundColor: UIColor.red]))
        animator.applyAlphas(now: 1000.1, alreadyInEditingTransaction: true)
        #expect(animator.pendingChunks.isEmpty)
    }

    @Test("Backpressure Coalesces Segments Within Capacity")
    func backpressureCoalescesSegmentsWithinCapacity() {
        let animator0 = ChunkFadeAnimator()
        let limit = animator0.cadence.maxActiveChunkFades
        let storage = makeStorage(String(repeating: "x", count: limit * 10 + 200))
        let animator = makeAnimator(storage)
        for i in 0..<(limit - 2) {
            animator.enqueueChunk(range: NSRange(location: i * 10, length: 10))
        }
        animator.enqueueChunk(range: NSRange(location: limit * 10, length: 200))
        #expect(animator.pendingChunks.count == limit, "coalescing fills the budget exactly without overflowing it")
        #expect(alpha(of: storage, at: 0) == 0, "existing chunks must not be force-settled by the trim")
        #expect(alpha(of: storage, at: limit * 10) == 0, "a new chunk starts fully transparent and fades in normally")

        let bigSegs = animator.pendingChunks.suffix(2)
        var cursor = limit * 10
        for seg in bigSegs {
            #expect(seg.range.location == cursor)
            cursor = seg.range.location + seg.range.length
        }
        #expect(cursor == limit * 10 + 200)
    }

    @Test("Zero Capacity Falls Back To Single Segment")
    func zeroCapacityFallsBackToSingleSegment() {
        let animator0 = ChunkFadeAnimator()
        let limit = animator0.cadence.maxActiveChunkFades
        let storage = makeStorage(String(repeating: "x", count: limit * 10 + 200))
        let animator = makeAnimator(storage)
        for i in 0..<limit {
            animator.enqueueChunk(range: NSRange(location: i * 10, length: 10))
        }
        animator.enqueueChunk(range: NSRange(location: limit * 10, length: 200))
        #expect(animator.pendingChunks.count == limit)
        #expect(animator.pendingChunks.last!.range == NSRange(location: limit * 10, length: 200))
        #expect(alpha(of: storage, at: limit * 10) == 0, "even under maximum pressure a block fades in rather than appearing at once")
    }
}
