import Combine
import Foundation
import Testing
import UIKit
@testable import Oriveo

/// Performance invariants for the reasoning streaming path.
///
/// Every step on this path used to be O(n) per tick, or even per token, so the longer the reasoning
/// grew the hotter the main thread ran and the total cost was quadratic: the data layer copied the
/// whole reasoning for every chunk, the render layer scanned the full text several times per tick,
/// and the throttle rescheduled its timer on every token. An earlier pass over streaming heat fixed
/// all of that for the answer body and missed the reasoning path entirely.
///
/// These assertions pin *complexity*, not wall-clock time, so they do not depend on machine speed
/// and cannot fail spuriously under load.
@MainActor
@Suite("Reasoning Streaming Performance Tests")
struct ReasoningStreamingPerformanceTests {


    /// `ChatManager.appendReasoning` must append in place through the modify accessor.
    ///
    /// The measure is how often the underlying UTF-8 storage base address changes: a
    /// copy-on-write copy always allocates a new buffer and therefore a new address, so the old
    /// implementation (read the session out, mutate, write it back) changed address once per chunk,
    /// while an in-place append only changes address on a geometric growth step, which is
    /// logarithmic. The threshold is a quarter of the chunk count - far above the real number of
    /// growth steps, far below one per chunk.
    @Test("Append Reasoning Does Not Copy Whole Text Per Chunk")
    func appendReasoningDoesNotCopyWholeTextPerChunk() {
        let state = AppState(seedDemoData: true)
        let conversationID = UUID()
        let messageID = UUID()
        state.chatManager._testingBeginStreamingSession(
            conversationID: conversationID,
            assistantMessageID: messageID
        )
        guard let sendTaskID = state.chatManager._testingSendTaskID(in: conversationID) else {
            Issue.record("the test seam did not produce a sendTaskID")
            return
        }

        state.chatManager._testingAppendReasoning(
            String(repeating: "あい", count: 32),
            in: conversationID, messageID: messageID, sendTaskID: sendTaskID
        )

        let controller = AssistantStreamingController()
        let block = UIKitReasoningBlock()
        controller.start(
            publisher: Empty<Void, Never>().eraseToAnyPublisher(),
            reasoningPublisher: state.streamingReasoningDidChange(in: conversationID),
            textProvider: { "" },
            reasoningSnapshotProvider: { state.streamingReasoningSnapshot(in: conversationID) },
            isBound: { true },
            enqueueText: { _ in },
            applyInitialText: { _ in },
            applyInitialReasoning: { block.applyStreamingSnapshot($0) },
            hideTypingIfNeeded: {},
            applyReasoning: { block.appendStreamingDelta($0) }
        )

        let chunkCount = 200
        var previous = state.chatManager._testingReasoningStorageIdentity(in: conversationID)
        #expect(previous != 0, Comment(rawValue: "the seed text still fits in a small string, so the assertion would prove nothing"))

        var reallocations = 0
        for index in 0..<chunkCount {
            state.chatManager._testingAppendReasoning(
                "あ\(index)いうえ。",
                in: conversationID, messageID: messageID, sendTaskID: sendTaskID
            )
            let current = state.chatManager._testingReasoningStorageIdentity(in: conversationID)
            if current != previous { reallocations += 1 }
            previous = current
        }

        #expect(
            reallocations < chunkCount / 4,
            Comment(rawValue: """
                \(chunkCount) chunks triggered \(reallocations) storage reallocations -- \
                a count close to the chunk count means every append copies the whole reasoning \
                text (O(n²), and it gets hotter the longer the reasoning runs).
                appendReasoning must append in place through the `sessions[id]?.appendReasoning(...)` \
                modify accessor, rather than binding StreamingSession to a local and writing it back.
                """)
        )
        #expect(block._testStreamingPreviewUTF8Count <= ReasoningPreviewText.defaultSourceByteLimit)
    }

    @Test("Append Reasoning Keeps Accumulated Text Correct")
    func appendReasoningKeepsAccumulatedTextCorrect() {
        let state = AppState(seedDemoData: true)
        let conversationID = UUID()
        let messageID = UUID()
        state.chatManager._testingBeginStreamingSession(
            conversationID: conversationID,
            assistantMessageID: messageID
        )
        guard let sendTaskID = state.chatManager._testingSendTaskID(in: conversationID) else {
            Issue.record("the test seam did not produce a sendTaskID")
            return
        }

        let chunks = ["First", "analyze the question, ", "then", "give a conclusion.", "😀 end"]
        for chunk in chunks {
            state.chatManager._testingAppendReasoning(
                chunk, in: conversationID, messageID: messageID, sendTaskID: sendTaskID
            )
        }

        #expect(state.chatManager.streamingReasoning(in: conversationID) == chunks.joined())
    }

    @Test("Append Reasoning Rejects Foreign Chunks")
    func appendReasoningRejectsForeignChunks() {
        let state = AppState(seedDemoData: true)
        let conversationID = UUID()
        let messageID = UUID()
        state.chatManager._testingBeginStreamingSession(
            conversationID: conversationID,
            assistantMessageID: messageID
        )
        guard let sendTaskID = state.chatManager._testingSendTaskID(in: conversationID) else {
            Issue.record("the test seam did not produce a sendTaskID")
            return
        }

        state.chatManager._testingAppendReasoning(
            "belongs to this stream", in: conversationID, messageID: messageID, sendTaskID: sendTaskID
        )
        state.chatManager._testingAppendReasoning(
            "left over from an older message", in: conversationID, messageID: UUID(), sendTaskID: sendTaskID
        )
        state.chatManager._testingAppendReasoning(
            "left over from an older task", in: conversationID, messageID: messageID, sendTaskID: UUID()
        )

        #expect(state.chatManager.streamingReasoning(in: conversationID) == "belongs to this stream")
    }

    @Test("Reasoning Publisher Emits Validated Monotonic Deltas")
    func reasoningPublisherEmitsValidatedMonotonicDeltas() {
        let state = AppState(seedDemoData: true)
        let conversationID = UUID()
        let messageID = UUID()
        state.chatManager._testingBeginStreamingSession(
            conversationID: conversationID,
            assistantMessageID: messageID
        )
        let sendTaskID = state.chatManager._testingSendTaskID(in: conversationID)!
        var received: [ReasoningStreamDelta] = []
        let cancellable = state.streamingReasoningDidChange(in: conversationID)
            .sink { received.append($0) }
        defer { cancellable.cancel() }

        state.chatManager._testingAppendReasoning(
            "A", in: conversationID, messageID: messageID, sendTaskID: sendTaskID
        )
        state.chatManager._testingAppendReasoning(
            "stale", in: conversationID, messageID: UUID(), sendTaskID: sendTaskID
        )
        state.chatManager._testingAppendReasoning(
            "B", in: conversationID, messageID: messageID, sendTaskID: sendTaskID
        )

        #expect(received.map(\.revision) == [1, 2])
        #expect(received.map(\.delta) == ["A", "B"])
        #expect(received.allSatisfy { $0.messageID == messageID && $0.sendTaskID == sendTaskID })
    }


    @Test("Repeated Start Reuses Subscription Without Snapshot Read")
    func repeatedStartReusesSubscriptionWithoutSnapshotRead() {
        let controller = AssistantStreamingController()
        let messageID = UUID()
        let sendTaskID = UUID()
        let bodyPublisher = Empty<Void, Never>().eraseToAnyPublisher()
        let reasoningPublisher = Empty<ReasoningStreamDelta, Never>().eraseToAnyPublisher()

        func bind() {
            controller.start(
                publisher: bodyPublisher,
                reasoningPublisher: reasoningPublisher,
                textProvider: { "" },
                reasoningSnapshotProvider: {
                    ReasoningStreamSnapshot(
                        messageID: messageID,
                        sendTaskID: sendTaskID,
                        revision: 0,
                        text: String(repeating: "think", count: 10_000)
                    )
                },
                isBound: { true },
                enqueueText: { _ in },
                applyInitialText: { _ in },
                applyInitialReasoning: { _ in },
                hideTypingIfNeeded: {},
                applyReasoning: { _ in }
            )
        }

        bind()
        bind()

        #expect(controller._testReasoningSnapshotReadCount == 1)
    }

    @Test("Reasoning Throttle Schedules Only Once Per Window")
    func reasoningThrottleSchedulesOnlyOncePerWindow() {
        let controller = AssistantStreamingController()
        let subject = PassthroughSubject<ReasoningStreamDelta, Never>()
        let messageID = UUID()
        let sendTaskID = UUID()
        var applied: [ReasoningStreamDelta] = []

        controller.start(
            publisher: Empty<Void, Never>().eraseToAnyPublisher(),
            reasoningPublisher: subject.eraseToAnyPublisher(),
            textProvider: { "" },
            reasoningSnapshotProvider: {
                ReasoningStreamSnapshot(
                    messageID: messageID,
                    sendTaskID: sendTaskID,
                    revision: 0,
                    text: ""
                )
            },
            isBound: { true },
            enqueueText: { _ in },
            applyInitialText: { _ in },
            applyInitialReasoning: { _ in },
            hideTypingIfNeeded: {},
            applyReasoning: { applied.append($0) }
        )

        for revision in 1...50 {
            subject.send(ReasoningStreamDelta(
                messageID: messageID,
                sendTaskID: sendTaskID,
                revision: UInt64(revision),
                delta: "step \(revision)."
            ))
        }

        #expect(
            controller._testScheduledReasoningWorkItemCount <= 1,
            Comment(rawValue: """
                 \(controller._testScheduledReasoningWorkItemCount)  work item( ≤1)--\
                 token  cancel +  +  main queue ,.
                """)
        )
        #expect(controller._testReasoningSnapshotReadCount == 1,
                Comment(rawValue: "the hot path for a normal delta read a snapshot of the whole accumulated text"))
    }

    @Test("Throttled Reasoning Preserves Delta Order")
    func throttledReasoningPreservesDeltaOrder() async {
        let controller = AssistantStreamingController()
        let subject = PassthroughSubject<ReasoningStreamDelta, Never>()
        let messageID = UUID()
        let sendTaskID = UUID()
        var applied = ""

        controller.start(
            publisher: Empty<Void, Never>().eraseToAnyPublisher(),
            reasoningPublisher: subject.eraseToAnyPublisher(),
            textProvider: { "" },
            reasoningSnapshotProvider: {
                ReasoningStreamSnapshot(
                    messageID: messageID,
                    sendTaskID: sendTaskID,
                    revision: 0,
                    text: ""
                )
            },
            isBound: { true },
            enqueueText: { _ in },
            applyInitialText: { _ in },
            applyInitialReasoning: { _ in },
            hideTypingIfNeeded: {},
            applyReasoning: { applied.append($0.delta) }
        )

        for (offset, text) in ["first paragraph", "second paragraph", "third paragraph"].enumerated() {
            subject.send(ReasoningStreamDelta(
                messageID: messageID,
                sendTaskID: sendTaskID,
                revision: UInt64(offset + 1),
                delta: text
            ))
        }

        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(applied == "first paragraphsecond paragraphthird paragraph",
                Comment(rawValue: "the coalesced deltas were reordered or lost: \(applied)"))
    }

    @Test("Reasoning Revision Gap Resynchronizes Once")
    func reasoningRevisionGapResynchronizesOnce() async {
        let controller = AssistantStreamingController()
        let subject = PassthroughSubject<ReasoningStreamDelta, Never>()
        let messageID = UUID()
        let sendTaskID = UUID()
        var snapshot = ReasoningStreamSnapshot(
            messageID: messageID,
            sendTaskID: sendTaskID,
            revision: 0,
            text: ""
        )
        var snapshots: [String] = []
        var deltas = ""

        controller.start(
            publisher: Empty<Void, Never>().eraseToAnyPublisher(),
            reasoningPublisher: subject.eraseToAnyPublisher(),
            textProvider: { "" },
            reasoningSnapshotProvider: { snapshot },
            isBound: { true },
            enqueueText: { _ in },
            applyInitialText: { _ in },
            applyInitialReasoning: { snapshots.append($0?.text ?? "") },
            hideTypingIfNeeded: {},
            applyReasoning: { deltas.append($0.delta) }
        )

        subject.send(ReasoningStreamDelta(
            messageID: messageID, sendTaskID: sendTaskID, revision: 1, delta: "A"
        ))
        snapshot = ReasoningStreamSnapshot(
            messageID: messageID,
            sendTaskID: sendTaskID,
            revision: 3,
            text: "ABC"
        )
        subject.send(ReasoningStreamDelta(
            messageID: messageID, sendTaskID: sendTaskID, revision: 3, delta: "BC"
        ))
        subject.send(ReasoningStreamDelta(
            messageID: messageID, sendTaskID: sendTaskID, revision: 3, delta: "repeat"
        ))
        subject.send(ReasoningStreamDelta(
            messageID: messageID, sendTaskID: UUID(), revision: 4, delta: "from an older task"
        ))
        subject.send(ReasoningStreamDelta(
            messageID: messageID, sendTaskID: sendTaskID, revision: 4, delta: "D"
        ))

        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(controller._testReasoningSnapshotReadCount == 2)
        #expect(snapshots == ["", "ABC"])
        #expect(deltas == "AD")
    }


    @Test("Body And Reasoning Share Self Size Throttle")
    func bodyAndReasoningShareSelfSizeThrottle() {
        let cell = makeStreamingCell()
        cell.lastStreamingInvalidateTimestamp = 0
        cell._testContentDidChangeCount = 0

        cell.requestStreamingSelfSizeInvalidate()
        #expect(cell._testContentDidChangeCount == 1, Comment(rawValue: "the first remeasure must always go through"))

        cell.reasoningBlock.onHeightDidChange?()
        #expect(
            cell._testContentDidChangeCount == 1,
            Comment(rawValue: """
                ( \(cell._testContentDidChangeCount))--\
                 cell systemLayoutSizeFitting .
                """)
        )
        #expect(cell.pendingStreamingHeightFlush,
                Comment(rawValue: "a throttled remeasure must be recorded as pending and delivered by the trailing task or the settle flush"))
    }

    @Test("Streaming Height Throttle Has Trailing Flush")
    func streamingHeightThrottleHasTrailingFlush() async {
        let cell = makeStreamingCell()
        cell.lastStreamingInvalidateTimestamp = 0
        cell._testContentDidChangeCount = 0

        cell.requestStreamingSelfSizeInvalidate()
        cell.requestStreamingSelfSizeInvalidate()
        #expect(cell._testContentDidChangeCount == 1)
        #expect(cell._testScheduledStreamingHeightFlushCount == 1)

        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(cell._testContentDidChangeCount == 2,
                Comment(rawValue: "the last height update stayed pending forever"))
        #expect(!cell.pendingStreamingHeightFlush)
    }

    @Test("Streaming Height Trailing Flush Cancels On Reuse")
    func streamingHeightTrailingFlushCancelsOnReuse() async {
        let cell = makeStreamingCell()
        cell.lastStreamingInvalidateTimestamp = 0
        cell._testContentDidChangeCount = 0
        cell.requestStreamingSelfSizeInvalidate()
        cell.requestStreamingSelfSizeInvalidate()
        let countBeforeReuse = cell._testContentDidChangeCount

        cell.prepareForReuse()
        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(cell._testContentDidChangeCount == countBeforeReuse)
        #expect(cell.pendingStreamingHeightWorkItem == nil)
    }

    @Test("Finalized Reasoning Height Is Never Throttled")
    func finalizedReasoningHeightIsNeverThrottled() {
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        let vc = UIViewController()
        cell.configure(
            model: makeRenderModel(text: "a completed answer", isGenerating: false),
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )
        #expect(cell.isStreamingActive == false)

        cell.lastStreamingInvalidateTimestamp = 0
        cell._testContentDidChangeCount = 0
        cell.requestStreamingSelfSizeInvalidate()
        cell.requestStreamingSelfSizeInvalidate()

        #expect(cell._testContentDidChangeCount == 2,
                Comment(rawValue: "throttling outside the streaming phase swallows the height that lands when markdown finishes rendering in an expanded reasoning block"))
    }

    // MARK: - Helpers

    private func makeStreamingCell() -> AssistantMessageCell {
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        let vc = UIViewController()
        cell.configure(
            model: makeRenderModel(text: "", isGenerating: true),
            parentViewController: vc,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )
        cell.startStreamingSubscription(
            publisher: PassthroughSubject<Void, Never>().eraseToAnyPublisher(),
            textProvider: { "" }
        )
        return cell
    }

    private func makeRenderModel(
        text: String,
        isGenerating: Bool
    ) -> ChatCollectionProjectionBuilder.MessageRenderModel {
        let message = TestFactories.makeMessage(
            id: UUID(),
            role: .assistant,
            text: text,
            state: isGenerating ? .generating : .delivered
        )
        return ChatCollectionProjectionBuilder.MessageRenderModel(
            messageID: message.id,
            message: message,
            presentationKind: .assistant,
            showMetadata: false,
            resolvedProviderName: "OpenAI",
            resolvedModelName: "GPT-4o",
            relayKind: nil,
            renderHint: nil,
            topPadding: 16,
            displayText: nil,
            textHash: text.hashValue,
            isStreaming: isGenerating,
            providerMetadataVersion: 1
        )
    }
}
