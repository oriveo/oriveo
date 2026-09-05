import Foundation
import Testing
import UIKit
@testable import Oriveo

/// `StreamingPacer` paces streamed text one block at a time, advancing block boundaries through
/// `StreamingBlockChunker`. The suite covers:
/// - state transitions (`snapToInitial` / `enqueue` / `snapToTarget` / `cancel` / `reset`);
/// - when `shouldSnap` fires: a non-prefix update, or an extreme backlog;
/// - block semantics: the first block breaks out synchronously in word or line units, and a hold
///   keeps the schedule alive without advancing;
/// - delegate callback ordering (`didAdvanceTo` / `pacerDidReachTarget`);
/// - `codeStepSize` and `isInsideUnclosedCodeFence`, the fast-path pure functions the chunker reuses.
///
/// The display-clock path depends on a real `CADisplayLink`, so the tests inject nil to take the
/// dispatch-queue path and focus on the synchronously testable part.
@Suite("StreamingPacer")
@MainActor
struct StreamingPacerTests {


    @MainActor
    final class MockDelegate: StreamingPacerDelegate {
        var isPacerEnabled: Bool = true
        var pacerHasPendingFinalRender: Bool = false
        var advancedTexts: [String] = []
        var reachedTargetCount: Int = 0

        func pacer(_ pacer: StreamingPacer, didAdvanceTo visibleText: String) {
            advancedTexts.append(visibleText)
        }

        func pacerDidReachTarget(_ pacer: StreamingPacer) {
            reachedTargetCount += 1
        }
    }

    private func makePacer(delegate: MockDelegate) -> StreamingPacer {
        let pacer = StreamingPacer(displayClock: nil)
        pacer.delegate = delegate
        return pacer
    }

    // MARK: - snapToInitial / snapToTarget

    @Test("Snap To Initial Sets Both Fields")
    func snapToInitialSetsBothFields() {
        let delegate = MockDelegate()
        let pacer = makePacer(delegate: delegate)
        pacer.snapToInitial("hello")
        #expect(pacer.visibleText == "hello")
        #expect(pacer.targetText == "hello")
        #expect(delegate.advancedTexts.isEmpty)
        #expect(delegate.reachedTargetCount == 0)
    }

    @Test("Snap To Target Notifies")
    func snapToTargetNotifies() {
        let delegate = MockDelegate()
        let pacer = makePacer(delegate: delegate)
        pacer.snapToTarget("done")
        #expect(pacer.visibleText == "done")
        #expect(pacer.targetText == "done")
        #expect(delegate.advancedTexts == ["done"])
        #expect(delegate.reachedTargetCount == 1)
    }


    @Test("Enqueue First Word Chunk Synchronous")
    func enqueueFirstWordChunkSynchronous() {
        let delegate = MockDelegate()
        let pacer = makePacer(delegate: delegate)
        pacer.enqueue("hello world")
        #expect(pacer.visibleText == "hello ")
        #expect(delegate.advancedTexts == ["hello "])
    }

    @Test("Enqueue Complete Line Synchronous")
    func enqueueCompleteLineSynchronous() {
        let delegate = MockDelegate()
        let pacer = makePacer(delegate: delegate)
        pacer.enqueue("# Heading\nthe body is still being generated")
        #expect(pacer.visibleText == "# Heading\n")
        #expect(delegate.advancedTexts == ["# Heading\n"])
    }

    @Test("Enqueue Held Keeps Scheduling")
    func enqueueHeldKeepsScheduling() {
        let delegate = MockDelegate()
        let pacer = makePacer(delegate: delegate)
        pacer.enqueue("**unclo")
        #expect(pacer.visibleText.isEmpty)
        #expect(delegate.advancedTexts.isEmpty)
        #expect(pacer.isScheduled)
    }

    @Test("Enqueue Disabled No Op")
    func enqueueDisabledNoOp() {
        let delegate = MockDelegate()
        delegate.isPacerEnabled = false
        let pacer = makePacer(delegate: delegate)
        pacer.enqueue("hello")
        #expect(pacer.visibleText.isEmpty)
        #expect(pacer.targetText.isEmpty)
        #expect(delegate.advancedTexts.isEmpty)
    }

    @Test("Enqueue Duplicate No Op")
    func enqueueDuplicateNoOp() {
        let delegate = MockDelegate()
        let pacer = makePacer(delegate: delegate)
        pacer.snapToInitial("hello")
        pacer.enqueue("hello")
        #expect(delegate.advancedTexts.isEmpty)
    }

    // MARK: - shouldSnap

    @Test("Enqueue Long Backlog Does Not Snap")
    func enqueueLongBacklogDoesNotSnap() {
        let delegate = MockDelegate()
        let pacer = makePacer(delegate: delegate)
        let bigTarget = String(repeating: "a", count: 2_100)
        pacer.enqueue(bigTarget)
        #expect(pacer.visibleText.count == BlockCommitCadence.default.wordChunkLenASCII)
        #expect(delegate.reachedTargetCount == 0)
        #expect(bigTarget.hasPrefix(pacer.visibleText))
    }

    @Test("Enqueue Extreme Backlog Snaps")
    func enqueueExtremeBacklogSnaps() {
        let delegate = MockDelegate()
        let pacer = makePacer(delegate: delegate)
        let hugeTarget = String(repeating: "a", count: StreamingPacer.snapBacklog + 100)
        pacer.enqueue(hugeTarget)
        #expect(pacer.visibleText == hugeTarget)
        #expect(delegate.reachedTargetCount == 1)
        #expect(delegate.advancedTexts.last == hugeTarget)
    }

    @Test("Enqueue Non Prefix Snaps")
    func enqueueNonPrefixSnaps() {
        let delegate = MockDelegate()
        let pacer = makePacer(delegate: delegate)
        pacer.snapToInitial("hello")
        pacer.enqueue("HELLO world")
        #expect(pacer.visibleText == "HELLO world")
        #expect(delegate.reachedTargetCount == 1)
    }

    // MARK: - cancel / reset

    @Test("Cancel Keeps Text Clears Schedule")
    func cancelKeepsTextClearsSchedule() {
        let delegate = MockDelegate()
        let pacer = makePacer(delegate: delegate)
        pacer.snapToInitial("abc")
        pacer.cancel()
        #expect(pacer.visibleText == "abc")
        #expect(pacer.targetText == "abc")
        #expect(pacer.isScheduled == false)
    }

    @Test("Reset Clears Everything")
    func resetClearsEverything() {
        let delegate = MockDelegate()
        let pacer = makePacer(delegate: delegate)
        pacer.snapToInitial("あいうえ")
        pacer.reset()
        #expect(pacer.visibleText.isEmpty)
        #expect(pacer.targetText.isEmpty)
        #expect(pacer.profile == .ascii)
        #expect(pacer.isScheduled == false)
    }

    @Test("Cancel Then Enqueue Resumes")
    func cancelThenEnqueueResumes() {
        let delegate = MockDelegate()
        let pacer = makePacer(delegate: delegate)
        pacer.enqueue("alpha beta")
        #expect(pacer.visibleText == "alpha ")
        pacer.cancel()
        pacer.enqueue("brand new ")
        #expect(pacer.visibleText == "brand new ")
    }


    @Test("Code Step Size Scales With Backlog")
    func codeStepSizeScalesWithBacklog() {
        #expect(StreamingPacer.codeStepSize(for: 0) == 4)
        #expect(StreamingPacer.codeStepSize(for: 80) == 4)
        #expect(StreamingPacer.codeStepSize(for: 81) == 8)
        #expect(StreamingPacer.codeStepSize(for: 400) == 8)
        #expect(StreamingPacer.codeStepSize(for: 401) == 16)
        #expect(StreamingPacer.codeStepSize(for: 1_200) == 16)
        #expect(StreamingPacer.codeStepSize(for: 5_000) == 32)
    }

    @Test("Is Inside Unclosed Code Fence Counting")
    func isInsideUnclosedCodeFenceCounting() {
        #expect(StreamingPacer.isInsideUnclosedCodeFence("```swift\nlet a = 1") == true)
        #expect(StreamingPacer.isInsideUnclosedCodeFence("```swift\nx\n```\n") == false)
        #expect(StreamingPacer.isInsideUnclosedCodeFence("plain text with no code fence") == false)
        #expect(StreamingPacer.isInsideUnclosedCodeFence("") == false)
    }


    @Test("Catchup Delay Scaling")
    func catchupDelayScaling() {
        let cadence = BlockCommitCadence.default
        #expect(StreamingPacer.scaledDelay(base: 0.14, backlogUTF16: 200, cadence: cadence) == 0.14)
        #expect(StreamingPacer.scaledDelay(base: 0.14, backlogUTF16: cadence.catchupBacklogUTF16 + 1, cadence: cadence)
                == 0.14 * cadence.catchupDelayScale)
    }


    @Test("Profile Ascii")
    func profileAscii() {
        #expect(StreamingPacerLanguageProfile.detect(in: "hello world") == .ascii)
    }

    @Test("Profile CJK")
    func profileCJK() {
        #expect(StreamingPacerLanguageProfile.detect(in: "あいうえおかきく") == .cjk)
    }

    @Test("Profile Empty Fallback")
    func profileEmptyFallback() {
        #expect(StreamingPacerLanguageProfile.detect(in: "") == .ascii)
    }


    @Test("Fence Parity Equivalent To Full Scan")
    func fenceParityEquivalentToFullScan() {
        let samples = [
            "intro\n```swift\nlet a = 1\n```\nmiddle\n```python\nprint(1)\n```\ntail",
            "```\ncode\n``\n`\n```",              // `` and ` lines inside a fence
            "  ```indent\nx\n  ```\nafter",       // indented fence, closed while indented
            "plain text with no code block\nspanning\nseveral lines",
            "```a\n\u{3000}```\ntail",            // closing line indented with an ideographic space
            "text```not at line start\n```\ncode", // a fence marker mid-line is not a fence
        ]
        for sample in samples {
            var parity = StreamingFenceParity()
            let chars = Array(sample)
            var prefix = ""
            for ch in chars {
                prefix.append(ch)
                parity.advance(to: prefix)
                let incremental = parity.isInsideUnclosedFence(in: prefix)
                let fullScan = StreamingPacer.isInsideUnclosedCodeFence(prefix)
                #expect(
                    incremental == fullScan,
                    "not equivalent at prefix length \(prefix.count), sample=\(sample.prefix(20))..."
                )
            }
        }
    }

    @Test("Fence Parity Rebuild Matches Advance")
    func fenceParityRebuildMatchesAdvance() {
        let text = "head\n```js\nx()\n```\nmid\n```\ny"
        var stepwise = StreamingFenceParity()
        var prefix = ""
        for ch in text {
            prefix.append(ch)
            stepwise.advance(to: prefix)
        }
        var rebuilt = StreamingFenceParity()
        rebuilt.rebuild(for: text)
        #expect(stepwise.isInsideUnclosedFence(in: text) == rebuilt.isInsideUnclosedFence(in: text))
        #expect(rebuilt.isInsideUnclosedFence(in: text) == StreamingPacer.isInsideUnclosedCodeFence(text))
    }
}
