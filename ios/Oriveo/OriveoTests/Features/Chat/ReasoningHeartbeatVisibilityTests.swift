import Combine
import OriveoProviderKit
import Testing
import UIKit

@testable import Oriveo

/// End-to-end coverage for "the UI must show something during a long reasoning phase that only
/// sends heartbeats".
///
/// Background: some upstreams emit `reasoning_content: ""` heartbeats while they think and only
/// deliver the real reasoning text in one burst at the end - measured at over four minutes before
/// the first non-empty chunk. The parser was changed to let the empty string through, but three
/// gates further down still required non-empty text, so the heartbeat was swallowed again on the
/// production path and the screen stayed blank for minutes.
///
/// The tests written for that fix stayed green because each of them only exercised its own layer.
/// This suite deliberately drives the **production parser** and asserts on the observable state of a
/// **real UI view** (`isHidden` plus the header text), with no hand-built stream events anywhere in
/// between.
@MainActor
@Suite("Heartbeat feedback during long reasoning")
struct ReasoningHeartbeatVisibilityTests {

    /// The full chain: production parser, chat manager, streaming controller, reasoning block view.
    @Test("empty-string heartbeats reveal the reasoning block with its thinking header")
    func emptyReasoningHeartbeatRevealsThinkingHeader() throws {
        // 1. Parsing: the production assembler consumes real-shaped heartbeat chunks whose
        //    reasoning content is an empty string.
        var assembler = OpenAICompatibleStreamAssembler(profile: .deepSeek)
        var streamState = OpenAICompatibleStreamState()
        var producedEvents: [StreamEvent] = []
        for _ in 0..<3 {
            producedEvents += streamState.consume(
                try assembler.ingest(#"data: {"choices":[{"delta":{"reasoning_content":""}}]}"#)
            )
        }
        #expect(producedEvents.count == 3, "the parser must produce one reasoning event per heartbeat")
        #expect(streamState.accumulatedReasoning.isEmpty, "a heartbeat must not add a single character to the accumulated reasoning")

        // 2 and 3. State and UI: wire up the production subscription chain with a real reasoning block.
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

        let controller = AssistantStreamingController()
        let block = UIKitReasoningBlock()
        var typingIndicatorHidden = false
        controller.start(
            publisher: Empty<Void, Never>().eraseToAnyPublisher(),
            reasoningPublisher: state.streamingReasoningDidChange(in: conversationID),
            textProvider: { "" },
            reasoningSnapshotProvider: { state.streamingReasoningSnapshot(in: conversationID) },
            isBound: { true },
            enqueueText: { _ in },
            applyInitialText: { _ in },
            applyInitialReasoning: { block.applyStreamingSnapshot($0) },
            hideTypingIfNeeded: { typingIndicatorHidden = true },
            applyReasoning: { block.appendStreamingDelta($0) }
        )

        #expect(block.isHidden, "the reasoning block stays hidden until a reasoning event arrives")

        // Feed the events the parser produced straight into the production append path.
        for event in producedEvents {
            guard case let .reasoning(chunk) = event else {
                Issue.record("the parser produced something other than a reasoning event: \(event)")
                continue
            }
            state.chatManager._testingAppendReasoning(
                chunk,
                in: conversationID,
                messageID: messageID,
                sendTaskID: sendTaskID
            )
        }

        #expect(
            !block.isHidden,
            """
            The reasoning block is still hidden during a heartbeat-only window, so the user stares at
            a blank screen for minutes with no way to tell thinking from a hang.
            Check whether the gates on the chain require non-empty text again: ChatManager.appendReasoning /
            AssistantStreamingController.handleReasoningDelta / flushPendingReasoningDelta.
            """
        )
        #expect(block._testHeaderTitle == L10n.tr("Thinking…", table: .chat))
        #expect(typingIndicatorHidden, "once the reasoning block is visible, the generic typing dots must give way to its own pulsing indicator")
        #expect(block._testContentPlainText.isEmpty, "an empty heartbeat must not write any character into the content area")
        #expect(
            state.chatManager.streamingReasoning(in: conversationID).isEmpty,
            "an empty heartbeat must not pollute the accumulated reasoning text, which is persisted only when non-empty after trimming"
        )
    }

    /// The reverse: when the reasoning field is absent no event is produced and the block stays
    /// hidden. This stops "let the empty string through" from turning into "always reveal", which
    /// would pop an empty thinking block open for models that do not reason at all.
    @Test("a missing reasoning field produces no event and leaves the block hidden")
    func absentReasoningFieldKeepsBlockHidden() throws {
        var assembler = OpenAICompatibleStreamAssembler(profile: .deepSeek)
        var streamState = OpenAICompatibleStreamState()
        let events = streamState.consume(
            try assembler.ingest(#"data: {"choices":[{"delta":{"content":"answer"}}]}"#)
        )
        #expect(!events.contains { if case .reasoning = $0 { return true } else { return false } })

        let state = AppState(seedDemoData: true)
        let conversationID = UUID()
        let messageID = UUID()
        state.chatManager._testingBeginStreamingSession(
            conversationID: conversationID,
            assistantMessageID: messageID
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

        #expect(block.isHidden)
        #expect(controller.isReasoningEmpty())
    }
}
