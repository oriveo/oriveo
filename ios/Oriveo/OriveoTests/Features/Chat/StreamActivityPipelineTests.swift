import Combine
import Testing
import UIKit

@testable import Oriveo

/// The lifecycle of an activity inside ChatManager (set, then cleared), and the observable state
/// it produces on `AssistantMessageCell` through the activity channel.
///
/// Every activity event comes from the **production parser** reading an upstream frame in its
/// real shape; no test builds `.activity` by hand. Setting and clearing go through the production
/// `recordStreamActivity`, `commitStreamingBodyDelta`, `appendReasoning` and `removeSession`.
@MainActor
@Suite("Stream activity status line: pipeline and cell")
struct StreamActivityPipelineTests {

    // MARK: - Fixtures

    private struct Harness {
        let state: AppState
        let conversationID: UUID
        let messageID: UUID
        let sendTaskID: UUID
    }

    private func makeHarness(text: String = "") throws -> Harness {
        let state = AppState(seedDemoData: true)
        let conversationID = UUID()
        let messageID = UUID()
        state.chatManager._testingBeginStreamingSession(
            conversationID: conversationID,
            assistantMessageID: messageID,
            text: text
        )
        let sendTaskID = try #require(state.chatManager._testingSendTaskID(in: conversationID))
        return Harness(state: state, conversationID: conversationID, messageID: messageID, sendTaskID: sendTaskID)
    }

    /// The "web search started" events the production parser emits for an Anthropic
    /// server_tool_use frame.
    private func parsedWebSearchStartEvents() -> [StreamEvent] {
        let strategy = TransportRegistry.strategy(for: .anthropicMessages)
        var ctx = StreamContext()
        return strategy.parseStreamLine(
            #"{"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"srvtoolu_01A","name":"web_search","input":{}}}"#,
            ctx: &ctx,
            shape: nil
        )
    }

    private func dispatchWebSearchStart(_ harness: Harness, sendTaskID: UUID? = nil) {
        let events = parsedWebSearchStartEvents()
        #expect(events.contains { if case .activity(.webSearch) = $0 { return true } else { return false } })
        for event in events {
            harness.state.chatManager._testingDispatchActivityStreamEvent(
                event,
                in: harness.conversationID,
                messageID: harness.messageID,
                sendTaskID: sendTaskID ?? harness.sendTaskID
            )
        }
    }

    private func makeRenderModel(
        id: UUID,
        text: String,
        state: ChatMessageState
    ) -> ChatCollectionProjectionBuilder.MessageRenderModel {
        let message = TestFactories.makeMessage(id: id, role: .assistant, text: text, state: state)
        return ChatCollectionProjectionBuilder.MessageRenderModel(
            messageID: message.id,
            message: message,
            presentationKind: .assistant,
            showMetadata: false,
            resolvedProviderName: "Anthropic",
            resolvedModelName: "Claude",
            relayKind: nil,
            renderHint: nil,
            topPadding: 16,
            displayText: nil,
            textHash: text.hashValue,
            isStreaming: state == .generating,
            providerMetadataVersion: 1
        )
    }

    /// Wired the same way production `ChatStreamingCoordinator.attachStreaming` does it: the body,
    /// reasoning and activity channels all point at AppState's production publishers and snapshots.
    private func makeStreamingCell(_ harness: Harness) -> AssistantMessageCell {
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        let state = harness.state
        let conversationID = harness.conversationID
        cell.configure(
            model: makeRenderModel(id: harness.messageID, text: "", state: .generating),
            parentViewController: UIViewController(),
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )
        cell.startStreamingSubscription(
            publisher: state.streamingTextDidChange(in: conversationID),
            reasoningPublisher: state.streamingReasoningDidChange(in: conversationID),
            textProvider: { state.streamingText(in: conversationID) },
            reasoningSnapshotProvider: { state.streamingReasoningSnapshot(in: conversationID) },
            activityPublisher: state.streamingActivityDidChange(in: conversationID),
            activityProvider: { state.streamingActivity(in: conversationID) }
        )
        return cell
    }

    private var webSearchCaption: String { L10n.tr("Searching the web", table: .chat) }
    private var neutralCaption: String { L10n.tr("Generating") }

    // MARK: - Pipeline (ChatManager)

    @Test("Once an activity is set, the next body delta clears it")
    func bodyDeltaClearsActivity() throws {
        let harness = try makeHarness(text: "Let me look that up.")
        var published: [StreamActivityState] = []
        let cancellable = harness.state.streamingActivityDidChange(in: harness.conversationID)
            .sink { published.append($0) }
        defer { cancellable.cancel() }

        #expect(harness.state.streamingActivity(in: harness.conversationID)?.activity == nil)

        dispatchWebSearchStart(harness)
        #expect(harness.state.streamingActivity(in: harness.conversationID)
            == StreamActivityState(messageID: harness.messageID, activity: .webSearch))
        // A repeated start signal (several searches in one turn) is not published again.
        dispatchWebSearchStart(harness)
        #expect(published == [StreamActivityState(messageID: harness.messageID, activity: .webSearch)])

        harness.state.chatManager._testingCommitStreamingBodyDelta(" Found it.", in: harness.conversationID)
        #expect(harness.state.streamingActivity(in: harness.conversationID)?.activity == nil)
        #expect(harness.state.streamingText(in: harness.conversationID) == "Let me look that up. Found it.")
        #expect(published == [
            StreamActivityState(messageID: harness.messageID, activity: .webSearch),
            StreamActivityState(messageID: harness.messageID, activity: nil),
        ])
    }

    @Test("A non-empty reasoning delta clears the activity; an empty heartbeat does not")
    func nonEmptyReasoningClearsActivityButHeartbeatDoesNot() throws {
        let harness = try makeHarness()
        dispatchWebSearchStart(harness)

        harness.state.chatManager._testingAppendReasoning(
            "", in: harness.conversationID, messageID: harness.messageID, sendTaskID: harness.sendTaskID
        )
        #expect(
            harness.state.streamingActivity(in: harness.conversationID)?.activity == .webSearch,
            "an empty heartbeat does not mean the model is talking; the search is still running"
        )

        harness.state.chatManager._testingAppendReasoning(
            "Based on the search results", in: harness.conversationID, messageID: harness.messageID, sendTaskID: harness.sendTaskID
        )
        #expect(harness.state.streamingActivity(in: harness.conversationID)?.activity == nil)
    }

    @Test("Stopping the stream clears the activity and tells subscribers once that the session is gone")
    func stoppingTheStreamClearsActivity() throws {
        let harness = try makeHarness(text: "Let me look that up.")
        var published: [StreamActivityState] = []
        let cancellable = harness.state.streamingActivityDidChange(in: harness.conversationID)
            .sink { published.append($0) }
        defer { cancellable.cancel() }

        dispatchWebSearchStart(harness)
        harness.state.chatManager.cancelGeneration(in: harness.conversationID)

        #expect(harness.state.streamingActivity(in: harness.conversationID) == nil)
        #expect(published.last
            == StreamActivityState(messageID: harness.messageID, activity: nil, isStreaming: false))
    }

    @Test("A stream that finishes normally (completeStreamingMessage) clears the activity")
    func completingTheStreamClearsActivity() throws {
        let state = AppState(seedDemoData: true)
        let assistant = TestFactories.makeMessage(role: .assistant, text: "", state: .generating)
        let conversation = TestFactories.makeConversation(messages: [assistant])
        state.upsertConversationProjection(conversation)
        state.chatManager._testingBeginStreamingSession(
            conversationID: conversation.id,
            assistantMessageID: assistant.id,
            text: "Let me look that up."
        )
        let sendTaskID = try #require(state.chatManager._testingSendTaskID(in: conversation.id))
        let harness = Harness(
            state: state, conversationID: conversation.id, messageID: assistant.id, sendTaskID: sendTaskID
        )
        var published: [StreamActivityState] = []
        let cancellable = state.streamingActivityDidChange(in: conversation.id).sink { published.append($0) }
        defer { cancellable.cancel() }

        dispatchWebSearchStart(harness)
        #expect(state.streamingActivity(in: conversation.id)?.activity == .webSearch)

        state.chatManager._testingCompleteStreamingMessage(
            conversationID: conversation.id,
            messageID: assistant.id,
            sendTaskID: sendTaskID
        )
        #expect(!state.isBusyStreaming(in: conversation.id), "completeStreamingMessage should have removed the session")
        #expect(state.streamingActivity(in: conversation.id) == nil)
        #expect(published.last == StreamActivityState(messageID: assistant.id, activity: nil, isStreaming: false))
    }

    @Test("A late activity event from a superseded task must not attach to the current session")
    func staleTaskCannotSetActivity() throws {
        let harness = try makeHarness()
        dispatchWebSearchStart(harness, sendTaskID: UUID())
        #expect(harness.state.streamingActivity(in: harness.conversationID)?.activity == nil)
    }

    // MARK: - cell

    @Test("Body text plus an activity: the status line shows the activity label and the typing indicator stays hidden; it hides as soon as body text resumes")
    func bodyTextPlusActivityShowsStatusLine() async throws {
        let harness = try makeHarness(text: "Let me look that up.")
        let cell = makeStreamingCell(harness)
        #expect(cell.hasStreamedBodyOnScreen)
        #expect(!cell.isTypingIndicatorOnScreen)
        #expect(cell.streamActivityLineHost.isHidden, "no status line without an activity or a pause")
        let invalidationsBefore = cell._testContentDidChangeCount

        dispatchWebSearchStart(harness)

        #expect(!cell.streamActivityLineHost.isHidden)
        #expect(cell.streamActivityLine.isPresenting)
        #expect(cell.streamActivityLine.text == webSearchCaption)
        #expect(cell.streamActivityLine.accessibilityLabel == webSearchCaption)
        #expect(!cell.isTypingIndicatorOnScreen, "the typing indicator must not return once there is body text; at most one waiting label at a time")
        #expect(cell.typingIndicator.caption == neutralCaption)
        // The height invalidation goes through the single streaming gate: right after the previous
        // body height update it is throttled to 15 Hz and delivered by the trailing task.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(
            cell._testContentDidChangeCount > invalidationsBefore,
            "showing the status line changes the natural height of the cell and has to go through self-size invalidation"
        )
        // Position: directly below the body text, above the tool-call card, citations and
        // metadata, aligned with the leading edge of the body, 8 pt below it.
        let arranged = cell.contentStack.arrangedSubviews
        let lineIndex = try #require(arranged.firstIndex(of: cell.streamActivityLineHost))
        #expect(arranged[lineIndex - 1] === cell.bodyStack)
        let toolCallIndex = try #require(arranged.firstIndex(of: cell.unhandledToolCallView))
        let citationsIndex = try #require(arranged.firstIndex(of: cell.citationsHost))
        let metadataIndex = try #require(arranged.firstIndex(of: cell.metadataView))
        #expect(lineIndex < toolCallIndex)
        #expect(lineIndex < citationsIndex)
        #expect(lineIndex < metadataIndex)
        cell.layoutIfNeeded()
        let textBottom = cell.textView.convert(cell.textView.bounds, to: cell.contentView).maxY
        let lineFrame = cell.streamActivityLine.convert(cell.streamActivityLine.bounds, to: cell.contentView)
        #expect(abs((lineFrame.minY - textBottom) - 8) < 0.75)
        let textLeading = cell.textView.convert(cell.textView.bounds, to: cell.contentView).minX
        #expect(abs(lineFrame.minX - textLeading) < 0.75)

        // The next body delta: ChatManager clears the activity and the status line hides at once,
        // without waiting for the pacer and without holding its space.
        harness.state.chatManager._testingCommitStreamingBodyDelta(" Found it.", in: harness.conversationID)
        #expect(cell.streamActivityLineHost.isHidden)
        #expect(!cell.streamActivityLine.isPresenting)
    }

    @Test("Empty body plus an activity: the typing indicator carries the activity label with no status line on top; clearing the activity restores Generating")
    func emptyBodyPlusActivityOverridesTypingCaption() throws {
        let harness = try makeHarness()
        let cell = makeStreamingCell(harness)
        #expect(cell.isTypingIndicatorOnScreen)
        #expect(cell.typingIndicator.caption == neutralCaption)

        dispatchWebSearchStart(harness)

        #expect(cell.isTypingIndicatorOnScreen)
        #expect(cell.typingIndicator.caption == webSearchCaption)
        #expect(cell.streamActivityLineHost.isHidden, "while the typing indicator is visible it carries the label; no status line on top")

        // The activity clears through the other path besides a non-empty reasoning delta, a body
        // delta entering the session, and the label goes back to the default.
        harness.state.chatManager._testingCommitStreamingBodyDelta("A", in: harness.conversationID)
        #expect(cell.typingIndicator.caption == neutralCaption)
    }

    @Test("A cell bound halfway through a search (reuse or rebinding) picks up the current activity")
    func rebindingCellPicksUpCurrentActivity() throws {
        let harness = try makeHarness(text: "Let me look that up.")
        dispatchWebSearchStart(harness)

        let cell = makeStreamingCell(harness)
        #expect(!cell.streamActivityLineHost.isHidden)
        #expect(cell.streamActivityLine.text == webSearchCaption)

        // Reuse resets the status line, the activity and the pause timer.
        cell.prepareForReuse()
        #expect(cell.streamActivityLineHost.isHidden)
        #expect(cell.streamActivity == nil)
        #expect(!cell.streamQuietTimer.isArmed)
        #expect(cell.typingIndicator.caption == neutralCaption)
    }

    @Test("Pause fallback: body text and no visible change for 1500 ms show the neutral status line; the next visible change hides it")
    func quietWithBodyShowsNeutralLineUntilNextVisibleChange() throws {
        let harness = try makeHarness(text: "First sentence.")
        let cell = makeStreamingCell(harness)
        #expect(cell.streamQuietTimer.isArmed, "setting up the subscription starts the pause clock")
        #expect(cell.streamActivityLineHost.isHidden)

        cell.streamQuietTimer._testElapseThreshold()
        #expect(!cell.streamActivityLineHost.isHidden)
        #expect(cell.streamActivityLine.text == neutralCaption)
        #expect(!cell.isTypingIndicatorOnScreen)

        // An activity is observed: the same line switches to the activity label in place.
        dispatchWebSearchStart(harness)
        #expect(cell.streamActivityLine.text == webSearchCaption)

        // The pacer advances the visible body text, so the pause is over; ChatManager clears the
        // activity when the body text enters the session.
        harness.state.chatManager._testingCommitStreamingBodyDelta(" Second sentence.", in: harness.conversationID)
        cell.pacer(cell.pacer, didAdvanceTo: "First sentence. Second sentence.")
        #expect(cell.streamActivityLineHost.isHidden)
        #expect(!cell.streamQuietTimer.isQuiet)
    }

    @Test("An empty reasoning heartbeat does not push the pause clock back; only non-empty reasoning text is a visible change")
    func emptyReasoningHeartbeatDoesNotResetQuiet() async throws {
        let harness = try makeHarness(text: "First sentence.")
        let cell = makeStreamingCell(harness)
        cell.streamQuietTimer._testElapseThreshold()
        #expect(cell.streamActivityLine.text == neutralCaption)
        #expect(!cell.streamActivityLineHost.isHidden)

        harness.state.chatManager._testingAppendReasoning(
            "", in: harness.conversationID, messageID: harness.messageID, sendTaskID: harness.sendTaskID
        )
        // The reasoning channel coalesces over an 80 ms window; wait for it to reach the cell.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(cell.streamQuietTimer.isQuiet, "an empty heartbeat changes nothing visible and must not reset the pause")
        #expect(!cell.streamActivityLineHost.isHidden)

        harness.state.chatManager._testingAppendReasoning(
            "Based on the search results", in: harness.conversationID, messageID: harness.messageID, sendTaskID: harness.sendTaskID
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!cell.streamQuietTimer.isQuiet)
        #expect(cell.streamActivityLineHost.isHidden)
    }

    @Test("A pause with an empty body shows no status line (the typing indicator is already moving)")
    func quietWithEmptyBodyStaysHidden() throws {
        let harness = try makeHarness()
        let cell = makeStreamingCell(harness)
        cell.streamQuietTimer._testElapseThreshold()
        #expect(cell.streamQuietTimer.isQuiet)
        #expect(cell.streamActivityLineHost.isHidden)
        #expect(cell.isTypingIndicatorOnScreen)
        #expect(cell.typingIndicator.caption == neutralCaption)
    }

    @Test("Stream stopped: the status line hides at once without falling back to the neutral label, and stays hidden once the message leaves the generating state")
    func streamEndHidesStatusLineImmediately() throws {
        let harness = try makeHarness(text: "Let me look that up.")
        let cell = makeStreamingCell(harness)
        cell.streamQuietTimer._testElapseThreshold()
        dispatchWebSearchStart(harness)
        #expect(cell.streamActivityLine.text == webSearchCaption)

        // When the session is removed the reconfigure for the message state has not arrived yet:
        // the cell still believes it is generating and the pause still holds. Clearing the
        // activity must not let the pause fallback flash the neutral label.
        harness.state.chatManager.cancelGeneration(in: harness.conversationID)
        #expect(cell.streamActivityLineHost.isHidden)
        #expect(!cell.streamQuietTimer.isArmed)

        cell.configure(
            model: makeRenderModel(id: harness.messageID, text: "Let me look that up.", state: .interrupted),
            parentViewController: UIViewController(),
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )
        #expect(cell.streamActivityLineHost.isHidden)
        #expect(cell.streamActivity == nil)
        #expect(!cell.streamQuietTimer.isArmed)
    }

    @Test("Showing and hiding the status line keeps the streaming height floor monotonic: taller when shown, no drop after it hides")
    func statusLineKeepsStreamingHeightFloorMonotonic() throws {
        let harness = try makeHarness(text: "Let me look that up.")
        let cell = makeStreamingCell(harness)
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.frame = CGRect(x: 0, y: 0, width: 390, height: 44)

        let before = cell.preferredLayoutAttributesFitting(attributes).size.height
        dispatchWebSearchStart(harness)
        let withLine = cell.preferredLayoutAttributesFitting(attributes).size.height
        #expect(withLine > before, "the status line counts towards the natural height of the cell (one footnote line plus its top spacing)")

        harness.state.chatManager._testingCommitStreamingBodyDelta(" Found it.", in: harness.conversationID)
        #expect(cell.streamActivityLineHost.isHidden)
        let afterHide = cell.preferredLayoutAttributesFitting(attributes).size.height
        #expect(afterHide >= withLine, "while streaming the height only grows: hiding the status line must not lower the reported height")
    }
}
