import Combine
import Foundation
import OriveoProviderKit
import UIKit

/// Streaming reasoning delta. `revision` increases monotonically from 1 within one send task.
///
/// The UI hot path only consumes `delta`; it never reads or holds ChatManager's accumulated full text on every token.
struct ReasoningStreamDelta: Equatable, Sendable {
    let messageID: UUID
    let sendTaskID: UUID
    let revision: UInt64
    let delta: String
}

/// A one-time authoritative snapshot for when a cell first binds or the revision sequence has a gap.
struct ReasoningStreamSnapshot: Equatable, Sendable {
    let messageID: UUID
    let sendTaskID: UUID
    let revision: UInt64
    let text: String
}

// Chat sending, streaming responses, message building and cost calculation.
// Extracted from AppState; owns all streaming state.
/// The outcome of one send: sent (carries the user message id), blocked because another send is already in flight in
/// the same conversation (the composer is not refilled, otherwise a hardware Return and the send button in the same frame
/// would put the already-sent content back), or refused (the composer is refilled with the original content).
enum ChatSendOutcome: Equatable, Sendable {
    case sent(UUID)
    case blockedWhileSending
    case refused

    var sentID: UUID? {
        if case .sent(let id) = self { return id }
        return nil
    }
}

@MainActor
final class ChatManager {
    unowned private(set) var appState: AppState!
    private let providerSession: URLSession
    /// Connection-level memory of tool capability. Tests inject an isolated store; production uses the shared instance.
    let toolCallMemory: ToolCallMemoryStore

    init(providerSession: URLSession = .shared, toolCallMemory: ToolCallMemoryStore = .shared) {
        self.providerSession = providerSession
        self.toolCallMemory = toolCallMemory
    }

    // MARK: - Multi-conversation streaming state

    /// The relay delivery route recorded when a relay send starts.
    private struct RelayDeliveryRoute {
        let providerID: UUID
        let modelID: String
        let transport: RelayTransport
        /// The effective key of this model at send time: on delivery it clears the no-access flag and records the key state as ok.
        let keyID: String
        /// The key value and outbound configuration actually sent: a write-back is dropped when it no longer matches the current ones.
        let keyWriteIdentity: RelayCatalogConnectionIdentity
        /// The protocol switched to when this message fell back at the protocol level.
        var switchedTo: RelayTransport? = nil
        /// This message fell back at the protocol level. A first-send reroute (`switchedTo` = first-send protocol) does not count.
        var protocolFallback = false
        /// The web switch was on for this turn (and within the relay web scope): when the delivering attempt carried no fragment, a reply notice is attached.
        var webOn = false
        /// The fragment hash each protocol carried this turn: on delivery it is looked up by the protocol actually used, and a citation writes searched / observed.
        var webFragmentHashes: [RelayTransport: String] = [:]
        /// Protocols whose fragment was rejected with 400 / 422 and resent without it: delivering on one of them records rejected / tested.
        var webStripped: Set<RelayTransport> = []
    }

    /// Context accounting of one chat request: fixed at assembly time, completed with observedInput / stopReason at the end, then written to the Ledger.
    private struct ContextLedgerAttempt {
        let requestId: String
        let conversationId: String
        let partitionUID: String
        let rhoKey: RhoCalibrationKey
        let transport: String
        let model: String
        let family: StopFamily
        let W: Int?
        let O: Int
        let B: Int?
        let U: Int?
        let estimatedInput: Int?
        let segments: [ContextManifestSegment]
        let unansweredMerged: Int
        let reminder: Bool
        let tailFrom: String?
        /// The checkpointId of the library row applied this time (nil for the in-memory fallback or an overflow re-projection): used after a compaction is cleared to decide cleared_since.
        let checkpointId: String?
        /// UTF-8 byte count of this request's text (system + each body), the denominator of the rho sample. It measures the message text finally sent:
        /// it is measured again after Library additions and after a relay image prompt swap.
        var textBytes: Int
        /// Requests carrying image / file attachments record no rho sample.
        let hasAttachments: Bool
        /// A single-leg chat request: false when this request has MCP / a tool loop / a Library retrieval leg or Library direct body text,
        /// in which case neither the rho sample nor "predicted no overflow but overflowed" is recorded.
        var singleChatLeg = true
        /// manifest.purpose: chat or continue, taken from the plan actually sent.
        var purpose: RequestPurpose = .chat
        /// Id of the memory items the final plan actually injected: written to the assistant message memoryItemIds at the end.
        var memoryIds: [String] = []

        func manifest(observedInput: Int?, stopReason: StopReason?) -> ContextManifest {
            ContextManifest(
                requestId: requestId,
                conversationId: conversationId,
                purpose: purpose,
                transport: transport,
                model: model,
                W: W,
                O: O,
                B: B,
                basis: observedInput != nil ? .observed : (estimatedInput == nil ? .unknown : .estimated),
                estimatedInput: estimatedInput ?? 0,
                observedInput: observedInput,
                segments: segments,
                checkpointId: checkpointId,
                tailFrom: tailFrom,
                unansweredMerged: unansweredMerged,
                reminder: reminder,
                stopReason: stopReason,
                createdAt: Int64((Date().timeIntervalSince1970 * 1000).rounded())
            )
        }
    }

    private struct StreamingSession {
        var messageID: UUID
        var text: String
        var attachments: [Attachment]
        /// Images decoded during streaming, held temporarily: messageID -> Data.
        /// Isolated in a local dictionary per conversation, so cleaning up one conversation cannot affect another even though messageID is globally unique.
        var pendingImageData: [UUID: Data]
        var sendTask: Task<Void, Never>?
        var sendTaskID: UUID
        /// Session start time, used to report elapsed_ms for chatMessageStopped (telemetry only, no business logic depends on it)
        var startedAt: Date = Date()
        /// Provider capability spec v2: Web Search citations accumulated during streaming.
        /// TransportStrategy already dedupes by URL key inside the accumulator; this field holds an overwriting snapshot.
        /// Persisted to ChatMessage.citations in completeStreamingMessage.
        var citations: [Citation] = []
        /// The stream-finish info the upstream handed over before an error (`StreamEvent.finish`): only the last one is kept, and the failure path records stopReason from it.
        var lastStreamFinish: StreamFinish?
        /// Accumulated reasoning text. Providers push into it through StreamEvent.reasoning(chunk).
        var reasoningText: String = ""
        /// Reasoning delta version of the current send task. Incremented only after a successful append.
        var reasoningRevision: UInt64 = 0
        /// When the first reasoning chunk was received; used to compute reasoningDurationMs.
        var reasoningStartedAt: Date?
        /// Timestamp of the first body .delta (or done); the difference from reasoningStartedAt is the thinking time.
        var reasoningEndedAt: Date?
        /// The protocol this model actually used when the relay send started: on delivery it is used to promote `reachable` to `observed`.
        var relayDeliveryRoute: RelayDeliveryRoute?
        /// How this round of the request was started (telemetry attempt_kind).
        var attemptKind: ChatAttemptKind = .send
        /// Context accounting for this chat request: writes the manifest at the end and the rho sample on success. nil on the legacy build path.
        var contextAttempt: ContextLedgerAttempt?
        /// The text / reasoning already present when this attempt started (continuation, retry keeping the old text): failure_phase only looks at what this attempt added.
        var baselineText: String = ""
        var baselineReasoning: String = ""
        /// The activity currently observed on this stream. Transient: it lives only in the
        /// session and is never persisted or copied onto a `ChatMessage`. `recordStreamActivity`
        /// is the only place that sets it; it is cleared by the next body delta, the next
        /// non-empty reasoning delta, and when the session is removed (finished, failed, stopped).
        var activity: StreamActivity?
        /// propose_memory state of this turn; nil when the send is not in tool mode.
        var proposeTurn: ProposeMemoryTurn?
        /// Plain resend after a thinking first leg with empty text: that leg's delivery, whose usage and
        /// cost are added to this attempt's delivered completion.
        var proposeCarriedDelivery: ProposeMemoryDeferredDelivery?

        /// Appends a reasoning delta in place; when messageID / sendTaskID do not match nothing is written and false is returned.
        ///
        /// WARNING: this **must** be called through the modify accessor of `sessions[id]?.appendReasoning(...)`. Never write it as
        /// `guard var session = sessions[id] ... session.reasoningText.append(chunk) ... sessions[id] = session`
        /// since binding the struct to a local variable raises the buffer reference count of `reasoningText` to 2, and every later append
        /// then triggers a copy-on-write **memcpy of the whole text**: O(n) per append and O(n^2) over a whole reasoning stream, so the
        /// longer the thinking the hotter the main thread (found while investigating device heating; the body side `flushBufferedDelta` always appended in place, and this method now matches it).
        /// The UI must also consume only the delta; if a Controller/Block held the accumulated String, the next
        /// append would still trigger CoW through the external shared reference even with `_modify` here. The regression lock must attach a real UI subscription and then measure storage growth count.
        mutating func appendReasoning(_ chunk: String, messageID: UUID, sendTaskID: UUID) -> UInt64? {
            guard self.messageID == messageID, self.sendTaskID == sendTaskID else { return nil }
            if reasoningStartedAt == nil {
                reasoningStartedAt = Date()
            }
            reasoningText.append(chunk)
            reasoningRevision &+= 1
            return reasoningRevision
        }
    }

    /// key = conversationID
    private var sessions: [UUID: StreamingSession] = [:]
    /// The pre-send confirmation was cancelled and this round has been rolled back: used to refill the composer when it is empty.
    let contextCapRollbacks = PassthroughSubject<ContextCapSendRollback, Never>()
    /// The user just tapped "Edit" and truncated these conversations: the next sendMessage is an edit resend (telemetry attempt_kind=edit).
    private var pendingEditResendConversationIDs: Set<UUID> = []
    /// Conversations whose pre-send rejection check is assembling in the background: while suspended, another send in the same conversation is blocked, preventing re-entry from rapid taps.
    private var contextPreflightInFlight: Set<UUID> = []
    /// Conversations that have already shown the "third compaction" hint in this process.
    private var compactionHintShownConversationIDs: Set<UUID> = []

    /// Per-conversation text-change signal: **held permanently** (created lazily, not released when a stream ends).
    /// Reason: if a new Subject were created when the same conversation sends again after a stream ended, the old Subject
    /// that AssistantMessageCell already subscribed to would never receive tokens. It is released only on the
    /// `discardStreamingResources(for:)` path (called by AppState when a conversation is deleted).
    private var streamingSubjects: [UUID: PassthroughSubject<Void, Never>] = [:]
    /// Reasoning uses its own delta channel, so the body publisher does not pull two copies of the accumulated text on every token.
    private var reasoningSubjects: [UUID: PassthroughSubject<ReasoningStreamDelta, Never>] = [:]
    /// Activity-state channel: it fires only when an activity is set or cleared, not per token. Same lifecycle as the two subjects above.
    private var activitySubjects: [UUID: PassthroughSubject<StreamActivityState, Never>] = [:]

    /// For list-level indication: the conversation IDs that are streaming. Updated only when sessions are added / removed
    /// (not per token), friendly to @Observable.
    private(set) var streamingConversationIDs: Set<UUID> = []

    /// Relay web reply notice: an assistant message delivered with the switch on but no fragment on the delivering attempt gets a one-line secondary-colour note under the reply.
    /// It lives only in this process's memory: not in `ChatMessage`, not persisted, not synced; it is gone after the app is reopened.
    private(set) var relayWebReplyNotices: [UUID: RelayWebReplyNotice] = [:]

    func relayWebReplyNotice(messageID: UUID) -> RelayWebReplyNotice? {
        relayWebReplyNotices[messageID]
    }

    /// Successful explicit continuation is compare-and-delete: it consumes the snapshot which
    /// was actually injected, without deleting a new opaque state produced by that same response.
    private var pendingRecipeContinuationAcknowledgements: [UUID: RecipeContinuationStore.ConsumptionToken] = [:]
    /// Compaction coordinators, one instance per partition (the circuit breaker is in-memory session state kept across sends).
    private var compactionCoordinators: [String: ContextCompactionCoordinator] = [:]
    /// Conversations with a pre-compaction in progress (including the snapshot assembly phase); the same conversation never starts a second one.
    private var precompactingConversationIDs: Set<UUID> = []
    /// Refreshes the provider configuration after a subscription request is rejected for its client version.
    /// It is an instance property only so that this step of the send path can be tested: the default goes
    /// straight to the network.
    var subscriptionConfigurationRefresher: () async -> Void = {
        await MetadataClient.shared.forceRefresh()
    }
    /// Credential preparation before a Grok subscription request goes out. The Keychain is the only source of truth for the credential and an unsigned test host cannot access it;
    /// as an instance property a test can hand in a prepared outbound context directly. The production default is the original direct call, so behaviour is unchanged.
    var grokSubscriptionPreparer: (UUID) async -> Result<GrokSubscriptionRuntime.Prepared, GrokSubscriptionError> = {
        providerID in
        await GrokSubscriptionRuntime.prepare(providerID: providerID)
    }
    /// Confirmation gate for remote MCP. nil in production, which uses `AppState.mcpConfirmationCoordinator`
    /// (the confirmation dialog on the chat page); tests swap in a gate that answers from a script.
    var mcpConfirmationGate: (any McpConfirmationGate)?
    /// Gate for an expired authorization. nil in production, which uses `AppState.mcpReauthorizationCoordinator`.
    var mcpReauthorizationGate: (any McpReauthorizationGate)?
    /// Resolves the Context Ledger per partition (manifest appends, rho samples and overflow-miss write-back). The production default is the original
    /// `ContextLedgerStore.forPartition`, so behaviour is unchanged; tests inject an isolated store instead of sharing the global singleton.
    var contextLedgerResolver: (String) -> ContextLedgerStore? = { uid in
        ContextLedgerStore.forPartition(uid)
    }
    /// MCP runtime configuration: `mcpRuntimeConfig` from the metadata snapshot, or the client's built-in fallback when the snapshot has none
    /// (a missing configuration falls back and never disables the feature).
    private var mcpRuntimeConfigProvider: () -> McpRuntimeConfig = {
        MetadataClient.shared.syncMcpRuntimeConfig()
    }
    /// Test seam: construction of the MCP protocol client (nil in production, which uses a real network session).
    private var mcpClientFactory: (@Sendable (URL) -> McpClient)?
    /// Test seam: the window input the latest main chat path handed to ContextAssembler and the plan.budget it produced (read-only, not part of sending).
    private(set) var debugLastContextWindowForTesting: ContextWindowInput?
    private(set) var debugLastContextBudgetForTesting: ContextPlanBudget?
    /// Test seam: the plan.budget assembled by the latest pre-send rejection check.
    private(set) var debugLastContextRejectPrecheckBudgetForTesting: ContextPlanBudget?
    /// Test seam: the B used by the latest manual / pre-compaction snapshot.
    private(set) var debugLastCompactionBudgetForTesting: Int?
    /// Whether the next send in this conversation is an edit resend (read before `sendMessage` consumes it).
    func isPendingEditResend(_ conversationID: UUID) -> Bool {
        pendingEditResendConversationIDs.contains(conversationID)
    }
    /// Test seam: whether this conversation still carries the "next send is an edit resend" flag.
    func debugHasPendingEditResendForTesting(_ conversationID: UUID) -> Bool {
        pendingEditResendConversationIDs.contains(conversationID)
    }

    /// The identifier held by UIApplication.beginBackgroundTask during the background grace period.
    /// Still a single value: iOS allows one BG task per app at a time; it is requested when any stream is active and released only when all streams end.
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private var isAppStateBound = false

    func bind(to appState: AppState) {
        self.appState = appState
        isAppStateBound = true
    }

    // MARK: - Convenience accessors

    private var conversations: [Conversation] {
        appState.conversations
    }

    /// Cold-start memory is a summary projection, so the thread must be loaded before its messages are read or written (see the AppState method of the same name).
    @discardableResult
    private func hydrateConversationMessagesIfNeeded(id: UUID) -> Bool {
        appState.hydrateConversationMessagesIfNeeded(id: id)
    }

    // MARK: - Session encapsulation (the only write entry for sessions)

    /// Adds or overwrites the streaming session of a conversation and updates `streamingConversationIDs`.
    /// This is the only entry allowed to write `sessions`.
    private func addSession(_ session: StreamingSession, for conversationID: UUID) {
        // A send that replaces an existing session ends the old stream here (same exit semantics as removeSession).
        publishStreamEnded(for: sessions[conversationID], in: conversationID)
        sessions[conversationID] = session
        streamingConversationIDs = Set(sessions.keys)
    }

    /// Removes the streaming session of a conversation. If no session remains, the BG task is released as well.
    /// This is the only entry allowed to remove from `sessions`.
    @discardableResult
    private func removeSession(for conversationID: UUID) -> StreamingSession? {
        appState.mcpConfirmationCoordinator.cancel(conversationID: conversationID)
        appState.mcpReauthorizationCoordinator.cancel(conversationID: conversationID)
        appState.contextCapConfirmCoordinator.cancel(conversationID: conversationID)
        let removed = sessions.removeValue(forKey: conversationID)
        streamingConversationIDs = Set(sessions.keys)
        // Finishing, failing and stopping all remove the session here: the activity is cleared with it and subscribed cells hide the status line at once.
        publishStreamEnded(for: removed, in: conversationID)
        if sessions.isEmpty {
            endSessionBoundary()
        }
        return removed
    }

    /// Lazily creates and returns the streamingSubject of a conversation.
    private func subject(for conversationID: UUID) -> PassthroughSubject<Void, Never> {
        if let existing = streamingSubjects[conversationID] {
            return existing
        }
        let new = PassthroughSubject<Void, Never>()
        streamingSubjects[conversationID] = new
        return new
    }

    private func reasoningSubject(for conversationID: UUID) -> PassthroughSubject<ReasoningStreamDelta, Never> {
        if let existing = reasoningSubjects[conversationID] {
            return existing
        }
        let new = PassthroughSubject<ReasoningStreamDelta, Never>()
        reasoningSubjects[conversationID] = new
        return new
    }

    private func activitySubject(for conversationID: UUID) -> PassthroughSubject<StreamActivityState, Never> {
        if let existing = activitySubjects[conversationID] {
            return existing
        }
        let new = PassthroughSubject<StreamActivityState, Never>()
        activitySubjects[conversationID] = new
        return new
    }

    /// Called by AppState when the user deletes a conversation for good, releasing its Subjects (so the memory does not leak after a delete).
    func discardStreamingResources(for conversationID: UUID) {
        if sessions[conversationID] != nil {
            cancelGeneration(in: conversationID, userInitiated: false)    // Deleting a conversation is not a user stop; this also removes the session
        }
        streamingSubjects.removeValue(forKey: conversationID)
        reasoningSubjects.removeValue(forKey: conversationID)
        activitySubjects.removeValue(forKey: conversationID)
    }

    // MARK: - Public API (queries by conversation id)

    /// The assistant message id currently streaming in `conversationID` (nil if none).
    func streamingMessageID(in conversationID: UUID) -> UUID? {
        sessions[conversationID]?.messageID
    }

    /// The accumulated text currently streaming in `conversationID` (empty string if none).
    func streamingText(in conversationID: UUID) -> String {
        sessions[conversationID]?.text ?? ""
    }

    /// The accumulated reasoning currently streaming in `conversationID` (empty string if none).
    /// Shares the streamingTextDidChange Subject with streamingText; AssistantMessageCell reads both through the same subscription.
    func streamingReasoning(in conversationID: UUID) -> String {
        sessions[conversationID]?.reasoningText ?? ""
    }

    /// Read once when a cell first mounts or the revision sequence has a gap. The normal token hot path must not call it.
    func streamingReasoningSnapshot(in conversationID: UUID) -> ReasoningStreamSnapshot? {
        guard let session = sessions[conversationID] else { return nil }
        return ReasoningStreamSnapshot(
            messageID: session.messageID,
            sendTaskID: session.sendTaskID,
            revision: session.reasoningRevision,
            text: session.reasoningText
        )
    }

    /// The token-change signal of `conversationID` (created lazily and held permanently).
    func streamingTextDidChange(in conversationID: UUID) -> AnyPublisher<Void, Never> {
        subject(for: conversationID).eraseToAnyPublisher()
    }

    func streamingReasoningDidChange(in conversationID: UUID) -> AnyPublisher<ReasoningStreamDelta, Never> {
        reasoningSubject(for: conversationID).eraseToAnyPublisher()
    }

    /// The activity snapshot of the message currently streaming (nil without a session). A cell reads it once on first bind / on rebind after reuse, then follows the delta channel.
    func streamingActivity(in conversationID: UUID) -> StreamActivityState? {
        guard let session = sessions[conversationID] else { return nil }
        return StreamActivityState(messageID: session.messageID, activity: session.activity)
    }

    func streamingActivityDidChange(in conversationID: UUID) -> AnyPublisher<StreamActivityState, Never> {
        activitySubject(for: conversationID).eraseToAnyPublisher()
    }

    /// Whether `conversationID` is streaming (for composer send/stop state and UI decisions).
    func isBusyStreaming(in conversationID: UUID) -> Bool {
        sessions[conversationID] != nil
    }

    /// Whether this connection x model can use MCP tools (for the tool panel and the capsule; the same decision as the send path).
    func mcpToolAvailability(provider: Provider, model: AIModel) -> McpToolAvailability {
        McpToolAvailability.resolve(provider: provider, model: model, memory: toolCallMemory)
    }

#if DEBUG
    /// Test seam for UI bridge contract tests. Production streaming sessions are created only
    /// through `queueAssistantResponse` / mock streaming harness.
    func _testingBeginStreamingSession(
        conversationID: UUID,
        assistantMessageID: UUID,
        text: String = ""
    ) {
        addSession(
            StreamingSession(
                messageID: assistantMessageID,
                text: text,
                attachments: [],
                pendingImageData: [:],
                sendTask: nil,
                sendTaskID: UUID()
            ),
            for: conversationID
        )
    }

    /// Test seam: the sendTaskID of the current session (the production `appendReasoning` guard needs it).
    func _testingSendTaskID(in conversationID: UUID) -> UUID? {
        sessions[conversationID]?.sendTaskID
    }

    /// Test seam: drives the production reasoning append path (without the mock streaming scaffold).
    func _testingAppendReasoning(
        _ chunk: String,
        in conversationID: UUID,
        messageID: UUID,
        sendTaskID: UUID
    ) {
        appendReasoning(chunk, in: conversationID, messageID: messageID, sendTaskID: sendTaskID)
    }

    /// Test seam: hands the `StreamEvent` produced by a Service to the tool call handler through the same dispatch as the production switch.
    /// It only accepts `.toolCallDeltas` (the other events are covered by existing seams / the production loop); the handler itself is the production
    /// `recordUnhandledToolCalls`, and a test must not build its own telemetry object.
    func _testingDispatchToolCallStreamEvent(
        _ event: StreamEvent,
        in conversationID: UUID,
        messageID: UUID,
        sendTaskID: UUID,
        provider: Provider,
        model: AIModel
    ) {
        switch event {
        case let .toolCallDeltas(calls):
            recordUnhandledToolCalls(
                calls, in: conversationID, messageID: messageID, sendTaskID: sendTaskID,
                provider: provider, model: model
            )
        case .delta, .reasoning, .imagePart, .citations, .activity, .finish, .done:
            break
        }
    }

    /// Test seam: hands the `StreamEvent` produced by the parsing layer to the activity handler through the same dispatch as the production switch
    /// (it only accepts `.activity`; the handler itself is the production `recordStreamActivity`).
    func _testingDispatchActivityStreamEvent(
        _ event: StreamEvent,
        in conversationID: UUID,
        messageID: UUID,
        sendTaskID: UUID
    ) {
        switch event {
        case let .activity(activity):
            recordStreamActivity(activity, in: conversationID, messageID: messageID, sendTaskID: sendTaskID)
        case .delta, .reasoning, .imagePart, .citations, .toolCallDeltas, .finish, .done:
            break
        }
    }

    /// Test seam: drives the production body-delta landing point (the step where `flushBufferedDelta` writes the body into the session).
    func _testingCommitStreamingBodyDelta(_ delta: String, in conversationID: UUID) {
        commitStreamingBodyDelta(delta, in: conversationID)
    }

    /// Test seam: goes through the production `completeStreamingMessage`, so the properties of `chat_message_completed`
    /// are actually produced by the production code path (a test must not synthesize the telemetry object itself).
    func _testingCompleteStreamingMessage(
        conversationID: UUID,
        messageID: UUID,
        sendTaskID: UUID,
        estimatedCost: Double? = nil,
        servedModelID: String? = nil,
        usageMetrics: ChatDeliveredUsageMetrics? = nil
    ) {
        completeStreamingMessage(
            conversationID: conversationID,
            messageID: messageID,
            expectedSendTaskID: sendTaskID,
            estimatedCost: estimatedCost,
            state: .delivered,
            servedModelID: servedModelID,
            usageMetrics: usageMetrics
        )
    }

    /// Test seam: goes through the production `failStreamingMessage`, same as above.
    func _testingFailStreamingMessage(
        conversationID: UUID,
        messageID: UUID,
        sendTaskID: UUID,
        userFacingText: String = "",
        estimatedCost: Double = 0,
        title: String = "",
        detail: String = ""
    ) {
        failStreamingMessage(
            conversationID: conversationID,
            messageID: messageID,
            expectedSendTaskID: sendTaskID,
            userFacingText: userFacingText,
            estimatedCost: estimatedCost,
            title: title,
            detail: detail
        )
    }

    /// Test seam: the base address of the UTF-8 storage underneath the accumulated reasoning text.
    ///
    /// A copy-on-write copy **always** changes the address; an in-place append changes it only when capacity grows geometrically. A regression test uses this to lock
    /// the performance invariant "each reasoning chunk does not copy the whole text" (the number of address changes should be O(log n), not O(n)).
    /// WARNING: short strings use SmallString (no heap buffer), so the caller must let the text exceed 15 bytes before sampling.
    func _testingReasoningStorageIdentity(in conversationID: UUID) -> UInt {
        guard let text = sessions[conversationID]?.reasoningText else { return 0 }
        return text.utf8.withContiguousStorageIfAvailable { buffer in
            UInt(bitPattern: buffer.baseAddress)
        } ?? 0
    }

    /// Test seam: swaps the MCP protocol client for a replayed session, so a test can run the whole production path starting at `sendMessage`.
    func debugUseMcpClientFactoryForTesting(_ factory: @escaping @Sendable (URL) -> McpClient) {
        mcpClientFactory = factory
    }

#endif

    /// True when any conversation has a stream (for the BG task decision and to suppress the global persist).
    var isAnyStreaming: Bool { !sessions.isEmpty }

    // MARK: - Mock streaming harness for end-to-end checks
    //
    // Without touching a real ProviderService network, it builds a user + assistant placeholder and simulates
    // tokens arriving one by one, to verify the real behaviour of chat rendering across the whole "send -> stream -> complete" flow
    // (user message pinned to the top / answer rendered below / short-answer spacer pushing to the bottom / long answer not stealing the viewport /
    // fade-in).

    #if DEBUG
    /// End-to-end bootstrap for a fresh-install simulator: when recentConversations is empty (fresh install / onboarding not finished)
    /// and the mock launch argument is set, builds an in-memory mock conversation automatically
    /// so the mock flow can run the full rendering check.
    /// Returns the id of the new conversation.
    @MainActor
    func bootstrapMockConversationForTesting(withHistory: Bool = false) -> UUID {
        let id = UUID()
        // Diagnose "history + reasoning" pinning: add a few settled user/assistant history messages (one of them with reasoningText to reproduce a DeepSeek "thought" collapsed block),
        // filling at least one screen so that the historyHeight of a later send is > 0 and the on-device "user message not pinned to the top" can be reproduced.
        var messages: [ChatMessage] = []
        if withHistory {
            let base = Date().addingTimeInterval(-600)
            func mk(_ role: ChatRole, _ text: String, _ offset: TimeInterval,
                    reasoning: String? = nil) -> ChatMessage {
                ChatMessage(
                    id: UUID(), role: role, text: text,
                    reasoningText: reasoning,
                    reasoningDurationMs: reasoning == nil ? nil : 4200,
                    providerID: nil, providerKind: .openAI,
                    providerName: "Mock", modelID: "mock-model-id", modelName: "mock-model",
                    state: .delivered, createdAt: base.addingTimeInterval(offset))
            }
            messages = [
                mk(.user, "Round one: write me a short poem about autumn", 0),
                mk(.assistant,
                   "Wheat fields ripple gold in the autumn wind,\nfallen leaves drift and scent the path.\nGeese write a line across the empty sky,\nmist and rain fold into the setting sun.\n\nThis short poem sketches an autumn scene; I hope you like it.",
                   1,
                   reasoning: "The user wants a poem about autumn. I should weigh rhyme, imagery and seasonal detail, pick classic autumn images such as wheat, falling leaves, geese and misty rain, and arrange them into four lines."),
                mk(.user, "Round two: explain the mood of this poem", 2),
                mk(.assistant,
                   "Through the autumn wind, falling leaves, returning geese and the setting sun, the poem builds a mood that is both desolate and far-reaching. The first line marks the harvest, the second finds beauty in decay, the third sends longing after the geese, and the last closes with mist and slanting light so the feeling lingers.",
                   3),
            ]
        }
        let conv = Conversation(
            id: id,
            title: "Mock Test",
            providerID: UUID(),
            providerKind: .openAI,
            modelID: "mock-model-id",
            previewText: "",
            estimatedCost: 0,
            isDraft: false,
            messages: messages,
            draftText: ""
        )
        appState.upsertConversationProjection(conv)
        return id
    }

    /// Mocks one user message plus a streamed assistant reply for the given conversation (no network).
    /// It goes through the full chat streaming subject + sessions state machine.
    func mockStreamingForTesting(
        in conversationID: UUID,
        userText: String,
        assistantTokens: [String],
        reasoningTokens: [String] = [],
        tokenIntervalMs: Int = 200
    ) async {
        guard let index = appState.conversations.firstIndex(where: { $0.id == conversationID }) else {
            return
        }
        let provider = appState.provider(for: appState.conversations[index].providerID)
        let providerKind = provider?.kind ?? .openAI
        let providerName = provider?.displayName ?? "Mock"
        let modelName = provider?.defaultModel?.name ?? "mock-model"
        let modelID = provider?.defaultModel?.id ?? "mock-model-id"

        let userCreatedAt = Date()
        let assistantCreatedAt = userCreatedAt.addingTimeInterval(0.001)

        let userMessage = ChatMessage(
            id: UUID(),
            role: .user,
            text: userText,
            providerID: provider?.id,
            providerKind: providerKind,
            providerName: providerName,
            modelID: modelID,
            modelName: modelName,
            state: .delivered,
            createdAt: userCreatedAt
        )
        let assistantID = UUID()
        let assistantMessage = ChatMessage(
            id: assistantID,
            role: .assistant,
            text: "",
            providerID: provider?.id,
            providerKind: providerKind,
            providerName: providerName,
            modelID: modelID,
            modelName: modelName,
            state: .generating,
            createdAt: assistantCreatedAt
        )

        var updated = appState.conversations[index]
        updated.messages.append(userMessage)
        updated.messages.append(assistantMessage)
        updated.updatedAt = Date()
        // The mock also takes the pin-to-top path (same as a real send): stage the anchor before the projection is published,
        // otherwise a simulator smoke test cannot exercise the top pin + spacer (the core path of the on-device gate).
        appState.stagePendingChatAnchorUserMessageID(userMessage.id, in: conversationID)
        appState.upsertConversationProjection(updated)

        // Start the mock streaming session (no sendTask)
        let session = StreamingSession(
            messageID: assistantID,
            text: "",
            attachments: [],
            pendingImageData: [:],
            sendTask: nil,
            sendTaskID: UUID()
        )
        addSession(session, for: conversationID)

        // Mock reasoning phase (reproduces the real DeepSeek "thought" scenario):
        // push reasoning chunks first so the cell shows the collapsed reasoning block, then push the body, after which the reasoning settles.
        if !reasoningTokens.isEmpty {
            sessions[conversationID]?.reasoningStartedAt = Date()
            for chunk in reasoningTokens {
                try? await Task.sleep(nanoseconds: UInt64(tokenIntervalMs) * 1_000_000)
                sessions[conversationID]?.reasoningText.append(chunk)
                subject(for: conversationID).send()
            }
        }

        // Tokens arrive one by one to simulate streaming
        for token in assistantTokens {
            try? await Task.sleep(nanoseconds: UInt64(tokenIntervalMs) * 1_000_000)
            sessions[conversationID]?.text.append(token)
            subject(for: conversationID).send()
        }

        // End the stream after a short delay
        try? await Task.sleep(nanoseconds: 300_000_000)
        let finalText = sessions[conversationID]?.text ?? ""

        // Land the final .delivered state first, then removeSession: otherwise at the moment the session is removed textProvider() returns "",
        // the pacer applySnapshot("") resets visible to 0, and the final full text is then enqueued again and re-typed from the start
        // (a timing bug of the mock scaffold; production completeStreamingMessage already moves the data first and removes afterwards, so it has no such problem).
        if let convIdx = appState.conversations.firstIndex(where: { $0.id == conversationID }),
           let msgIdx = appState.conversations[convIdx].messages.firstIndex(where: { $0.id == assistantID }) {
            var finalConv = appState.conversations[convIdx]
            finalConv.messages[msgIdx].text = finalText
            finalConv.messages[msgIdx].state = .delivered
            appState.upsertConversationProjection(finalConv)
        }
        removeSession(for: conversationID)
        subject(for: conversationID).send()
    }
    #endif

    // MARK: - Sending

    /// Callers that only need the result id use this one; callers that must tell "blocked while sending" from "refused" use `sendMessageOutcome`.
    func sendMessage(
        _ text: String,
        attachments: [Attachment] = [],
        quoteContext: QuoteContext? = nil,
        in conversationID: UUID,
        capabilitySelection: ChatCapabilitySelection = ChatCapabilitySelection(),
        /// mode=tool fresh send: attach propose_memory and run its calls.
        proposeMemory: ProposeMemoryTurnContext? = nil
    ) async -> UUID? {
        await sendMessageOutcome(
            text,
            attachments: attachments,
            quoteContext: quoteContext,
            in: conversationID,
            capabilitySelection: capabilitySelection,
            proposeMemory: proposeMemory
        ).sentID
    }

    func sendMessageOutcome(
        _ text: String,
        attachments: [Attachment] = [],
        quoteContext: QuoteContext? = nil,
        in conversationID: UUID,
        capabilitySelection: ChatCapabilitySelection = ChatCapabilitySelection(),
        /// mode=tool fresh send: attach propose_memory and run its calls.
        proposeMemory: ProposeMemoryTurnContext? = nil
    ) async -> ChatSendOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return .refused }
        guard conversations.contains(where: { $0.id == conversationID }) else {
            return .refused
        }
        guard hydrateConversationMessagesIfNeeded(id: conversationID) else {
            // The local thread is not available (the database read failed, or the stored thread has fewer messages than its count says): sending on an empty thread would silently drop context.
            ToastManager.shared.show(L10n.tr("Loading conversation…", table: .chat))
            return .refused
        }
        guard var index = conversations.firstIndex(where: { $0.id == conversationID }) else {
            return .refused
        }
        guard let provider = appState.provider(for: conversations[index].providerID) else {
            ToastManager.shared.show(L10n.tr("The selected provider is no longer available."))
            return .refused
        }

        let model = appState.sendableModel(for: conversations[index], provider: provider)
        guard let model else {
            return .refused
        }
        let modelName = model.name
        let storedModelID = ModelResolver.preferredStoredModelIdentifier(for: model, providerKind: provider.kind)
        let requestedCapabilitySelection = requestedCapabilitySelection(
            capabilitySelection,
            provider: provider,
            model: model,
            conversationID: conversationID,
            skillID: conversations[index].skillId
        )
        // Only the user's intent is kept here. The capability and current scope of reasoning/web/tools are decided one by one by CapabilityEvidenceFacade
        // after the final URL/transport is known; if the intent were cleared first from the persisted model.capabilities/profile,
        // the service-layer facade could not restore it even when it later receives fresh evidence.
        var resolvedCapabilitySelection = initialCapabilitySelection(requestedCapabilitySelection)
        resolvedCapabilitySelection.libraryResearchEnabled = false

        // Rejection: the skill + instructions, or this message itself, do not fit the model context. No request is sent and no message is created;
        // returning .refused makes the composer put the content back.
        // The pre-check yields the main thread: while it is suspended another send in the same conversation is blocked outright, so rapid taps cannot append two rounds.
        guard !contextPreflightInFlight.contains(conversationID) else {
            return .blockedWhileSending
        }
        contextPreflightInFlight.insert(conversationID)
        defer { contextPreflightInFlight.remove(conversationID) }
        if let reject = await contextRejectReason(
            conversation: conversations[index],
            text: trimmed,
            attachments: attachments,
            quoteContext: quoteContext,
            provider: provider,
            model: model,
            capabilitySelection: resolvedCapabilitySelection
        ) {
            ToastManager.shared.show(Self.contextRejectMessage(reject))
            // A rejected send does not count as an edit resend: clear the flag so the next ordinary send is not recorded as edit.
            pendingEditResendConversationIDs.remove(conversationID)
            return .refused
        }
        // The pre-check yielded the main thread while assembling in the background; the conversation may have been deleted or reordered, so the index must be re-resolved before it is used again.
        guard let rejectChecked = conversations.firstIndex(where: { $0.id == conversationID }) else {
            return .refused
        }
        index = rejectChecked

        // Keep user and assistant createdAt 1 ms apart explicitly, so a millisecond collision cannot make cross-platform ordering
        // fall back to UUID lexical order and become unstable
        let userCreatedAt = Date()
        let assistantCreatedAt = userCreatedAt.addingTimeInterval(0.001)

        let userMessage = ChatMessage(
            id: UUID(),
            role: .user,
            text: trimmed,
            providerID: provider.id,
            providerKind: provider.kind,
            providerName: provider.displayName,
            modelID: storedModelID,
            modelName: modelName,
            state: .delivered,
            attachments: attachments.isEmpty ? nil : attachments,
            quoteContext: quoteContext?.isValid == true ? quoteContext : nil,
            createdAt: userCreatedAt
        )

        let assistantMessageID = UUID()
        let assistantMessage = ChatMessage(
            id: assistantMessageID,
            role: .assistant,
            text: "",
            providerID: provider.id,
            providerKind: provider.kind,
            providerName: provider.displayName,
            modelID: storedModelID,
            modelName: modelName,
            state: .generating,
            createdAt: assistantCreatedAt
        )

        // Merge every conversation change into a single didSet, so persistSessionIfNeeded is not triggered several times
        let isFirstMessage = conversations[index].displayMessageCount == 0
            && conversations[index].messages.isEmpty
        var updatedConv = conversations[index]
        updatedConv.modelID = storedModelID
        updatedConv.messages.append(userMessage)
        updatedConv.messages.append(assistantMessage)
        updatedConv.updatedAt = ConversationListMetadata.computeActivityAt(for: updatedConv)
        updatedConv.isDraft = false
        updatedConv.draftText = ""
        ConversationListMetadata.apply(to: &updatedConv)
        appState.stagePendingChatAnchorUserMessageID(userMessage.id, in: conversationID)
        appState.upsertConversationProjection(updatedConv)

        let attemptKind: ChatAttemptKind = pendingEditResendConversationIDs.remove(conversationID) != nil ? .edit : .send
        let requestSnapshot = prepareRequestSnapshot(
            conversation: updatedConv,
            messages: updatedConv.messages,
            sendPath: .send(excludingMessageID: assistantMessageID)
        )

        queueAssistantResponse(
            conversationID: conversationID,
            assistantMessageID: assistantMessageID,
            requestSnapshot: requestSnapshot,
            provider: provider,
            model: model,
            capabilitySelection: resolvedCapabilitySelection,
            latestUserText: trimmed,
            appendsToExistingText: false,
            attemptKind: attemptKind,
            proposeTurn: proposeMemory.map { ProposeMemoryTurn(context: $0, userMessageID: userMessage.id) }
        )
        return .sent(userMessage.id)
    }

    /// `userInitiated` defaults to true (the user tapped stop); pass false for non-user stops such as deleting a conversation, which do not report chat_message_stopped.
    func cancelGeneration(in conversationID: UUID, userInitiated: Bool = true) {
        cancelGeneration(in: conversationID, messageID: nil, userInitiated: userInitiated)
    }

    /// `userInitiated == false` (a system interruption such as a partition switch): the stopReason is recorded as a transport error, not interrupted.
    private func cancelGeneration(in conversationID: UUID, messageID: UUID?, userInitiated: Bool = true) {
        // Tapping stop while parked on the pre-send confirmation gate means cancel: roll back (no interrupted is persisted and no stopped is sent).
        if let pending = appState.contextCapConfirmCoordinator.pending(for: conversationID),
           let held = sessions[conversationID], held.messageID == pending.messageID,
           messageID == nil || messageID == pending.messageID {
            held.sendTask?.cancel()
            appState.contextCapConfirmCoordinator.resolve(id: pending.id, choice: .cancel)
            rollbackUnconfirmedSend(assistantMessageID: pending.messageID, in: conversationID)
            return
        }
        let session = sessions[conversationID]

        guard let convIndex = conversations.firstIndex(where: { $0.id == conversationID }) else {
            session?.sendTask?.cancel()
            removeSession(for: conversationID)
            return
        }
        let messageIndex: Int?
        if let messageID {
            messageIndex = conversations[convIndex].messages.firstIndex(where: {
                $0.id == messageID && $0.role == .assistant && $0.state == .generating
            })
        } else if let s = session {
            // With multiple conversations, session.messageID is the target ChatManager tracks exactly.
            // Look it up by session.messageID first (so lastIndex cannot hit another .generating message).
            messageIndex = conversations[convIndex].messages.firstIndex(where: {
                $0.id == s.messageID && $0.role == .assistant && $0.state == .generating
            })
        } else {
            // Fallback when no session exists: use lastIndex (compatible with the old path; with no active stream the latest .generating message is used)
            messageIndex = conversations[convIndex].messages.lastIndex(where: {
                $0.role == .assistant && $0.state == .generating
            })
        }
        guard let msgIndex = messageIndex else {
            removeSession(for: conversationID)
            return
        }

        var updated = conversations[convIndex]
        // Sync the streaming buffer text to the message
        if let s = session, s.messageID == updated.messages[msgIndex].id {
            updated.messages[msgIndex].text = s.text
            // User-initiated stop: keep the reasoning generated so far, so the thinking is not lost when the stream is cut midway
            let trimmedReasoning = s.reasoningText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedReasoning.isEmpty {
                updated.messages[msgIndex].reasoningText = s.reasoningText
                if let start = s.reasoningStartedAt {
                    let end = s.reasoningEndedAt ?? Date()
                    let elapsedMs = Int64((end.timeIntervalSince(start) * 1000).rounded())
                    if elapsedMs > 0 {
                        updated.messages[msgIndex].reasoningDurationMs = elapsedMs
                    }
                }
            }
        }
        updated.messages[msgIndex].state = .interrupted
        updated.messages[msgIndex].stopReason = userInitiated
            ? .interrupted
            : failureStopReason(in: conversationID, messageID: updated.messages[msgIndex].id)
        updated.messages[msgIndex].errorTitle = nil
        updated.messages[msgIndex].errorDetail = nil
        // Stopped midway by the user: the memory items injected into the request already sent are still recorded, taken from this attempt's contextAttempt.
        if userInitiated, let s = session, s.messageID == updated.messages[msgIndex].id, let attempt = s.contextAttempt {
            Self.recordMemoryItemIds(attempt.memoryIds, purpose: attempt.purpose, into: &updated.messages[msgIndex])
        }
        updated.updatedAt = ConversationListMetadata.computeActivityAt(for: updated)
        ConversationListMetadata.apply(to: &updated)
        appState.upsertConversationProjection(updated)

        session?.sendTask?.cancel()

        // A user cancel also records a manifest; the finishing path no longer writes once the session is removed.
        if userInitiated, let s = session, s.messageID == updated.messages[msgIndex].id {
            settleContextLedger(s.contextAttempt, stopReason: .interrupted, observedInput: nil, recordsSample: false)
        }
        removeSession(for: conversationID)
    }

    /// Called when entering the background: requests ~30s of grace through `UIApplication.beginBackgroundTask`,
    /// so a streaming SSE can read as much as possible before the system suspends the socket. Before it expires the system calls expirationHandler ->
    /// `gracefullyInterruptAllStreaming`, which marks the current text of every active stream `.interrupted` and persists it.
    ///
    /// All streams share one BG task (a hard iOS limit: an app can hold only one BG task at a time).
    /// It does not cancel any sendTask: a stream that finishes naturally within 30s takes the normal complete path.
    func prepareForSessionBoundary() {
        guard isAnyStreaming, backgroundTaskID == .invalid else { return }
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "oriveo.chatStreaming") { [weak self] in
            // expirationHandler fires on the main thread (guaranteed by Apple's documentation) and must call
            // endBackgroundTask synchronously before returning, otherwise the system treats the task as not released and may kill it.
            // The streaming-state cleanup is finished synchronously through assumeIsolated after endBackgroundTask.
            MainActor.assumeIsolated {
                guard let self else { return }
                let id = self.backgroundTaskID
                self.backgroundTaskID = .invalid
                if id != .invalid {
                    UIApplication.shared.endBackgroundTask(id)
                }
                self.gracefullyInterruptAllStreaming()
            }
        }
        backgroundTaskID = taskID
        #if DEBUG
        print("[ChatManager] prepareForSessionBoundary: BG task started id=\(taskID.rawValue), sessions=\(sessions.count)")
        #endif
    }

    /// Called on returning to the foreground / when all streams finish naturally: releases the background time budget. Idempotent.
    /// It really releases only when sessions is empty, so one stream finishing does not release early while others are still running.
    func endSessionBoundary() {
        guard backgroundTaskID != .invalid, sessions.isEmpty else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    /// Writes the `streamingText` of every active stream back to its message.text, leaving the state `.generating`.
    /// A safety net for key lifecycle moments (scenePhase=.background / willTerminate),
    /// so the partial text is not lost entirely if the process is killed by the system later. **It cancels no task**.
    func flushStreamingTextToMessage() {
        for (convID, session) in sessions {
            guard !session.text.isEmpty,
                  let ci = conversations.firstIndex(where: { $0.id == convID }),
                  let mi = conversations[ci].messages.firstIndex(where: { $0.id == session.messageID }),
                  conversations[ci].messages[mi].text != session.text
            else { continue }
            var updated = conversations[ci]
            updated.messages[mi].text = session.text
            // Keep state .generating; leave updatedAt alone so the list does not jitter from a reorder
            appState.upsertConversationProjection(updated)
        }
    }

    /// Writes the current `streamingText` of the given conversation back to message.text and marks it `.interrupted`.
    /// Used when a new stream starts in "overwrite" fashion (the entry of queueAssistantResponse) to keep the previous partial,
    /// and by paths that must persist .interrupted, such as expirationHandler and a user cancel.
    /// - Parameter userInitiated: how stopReason is recorded. true = the user gave up (an overwriting send) -> interrupted;
    ///   false = a system interruption (background expiry) -> finish as an abnormal end; nil = leave unchanged.
    private func persistPartialStreamingAsInterrupted(in conversationID: UUID, userInitiated: Bool? = nil) {
        guard let session = sessions[conversationID],
              let ci = conversations.firstIndex(where: { $0.id == conversationID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == session.messageID })
        else { return }
        var updated = conversations[ci]
        if let userInitiated {
            updated.messages[mi].stopReason = userInitiated
                ? .interrupted
                : failureStopReason(in: conversationID, messageID: session.messageID)
        }
        updated.messages[mi].text = session.text
        // Likewise keep the reasoning generated so far on interruption (same behaviour as cancelGeneration / failStreamingMessage)
        let trimmedReasoning = session.reasoningText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedReasoning.isEmpty {
            updated.messages[mi].reasoningText = session.reasoningText
            if let start = session.reasoningStartedAt {
                let end = session.reasoningEndedAt ?? Date()
                let elapsedMs = Int64((end.timeIntervalSince(start) * 1000).rounded())
                if elapsedMs > 0 {
                    updated.messages[mi].reasoningDurationMs = elapsedMs
                }
            }
        }
        updated.messages[mi].state = .interrupted
        updated.messages[mi].errorTitle = nil
        updated.messages[mi].errorDetail = nil
        // Background / screen lock only marks the tool legs that already completed; a call that never finished was never written to the sidecar, so neither a restart nor an explicit
        // new send recovers it automatically. No tool effect is interpreted or reported here.
        try? RecipeContinuationRuntime.markInterrupted(messageID: session.messageID)
        updated.updatedAt = ConversationListMetadata.computeActivityAt(for: updated)
        ConversationListMetadata.apply(to: &updated)
        appState.upsertConversationProjection(updated)
    }

    /// expirationHandler path: the system is about to suspend the socket, so the content already streamed by every active stream is written to the database as
    /// `.interrupted`, which makes the inline "Continue" button visible on the chat page.
    /// It differs from `cancelGeneration` only in that it does not count as a user-initiated cancel.
    private func gracefullyInterruptAllStreaming() {
        guard isAnyStreaming else {
            endSessionBoundary()
            return
        }
        // Copy the keys so the dictionary is not mutated while iterating
        let convIDs = Array(sessions.keys)
        for convID in convIDs {
            persistPartialStreamingAsInterrupted(in: convID, userInitiated: false)
            sessions[convID]?.sendTask?.cancel()
            removeSession(for: convID)    // ends the background task when the last session is removed
        }
    }

    /// Force-cancels every active stream, used for partition switches, sign-out and similar cases.
    func forceStopStreaming() {
        appState.mcpConfirmationCoordinator.cancelAll()
        appState.mcpReauthorizationCoordinator.cancelAll()
        guard isAnyStreaming else { return }
        let convIDs = Array(sessions.keys)
        for convID in convIDs {
            cancelGeneration(in: convID, messageID: nil, userInitiated: false)
        }
    }

    func editUserMessage(messageID: UUID, in conversationID: UUID) -> String? {
        beginEditingUserMessage(messageID: messageID, in: conversationID)?.text
    }

    func editPromptingMessage(for assistantMessageID: UUID, in conversationID: UUID) -> String? {
        beginEditingPromptingMessage(for: assistantMessageID, in: conversationID)?.text
    }

    /// Edit a user message: truncates the conversation to before it and returns the text to put back in the composer plus the original attachments.
    func beginEditingUserMessage(messageID: UUID, in conversationID: UUID) -> ComposerEditDraft? {
        guard hydrateConversationMessagesIfNeeded(id: conversationID) else { return nil }
        guard let convIndex = conversations.firstIndex(where: { $0.id == conversationID }) else { return nil }
        guard let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageID }),
              conversations[convIndex].messages[msgIndex].role == .user else { return nil }

        return beginEditingUserMessage(at: msgIndex, in: conversationID)
    }

    func beginEditingPromptingMessage(for assistantMessageID: UUID, in conversationID: UUID) -> ComposerEditDraft? {
        guard hydrateConversationMessagesIfNeeded(id: conversationID) else { return nil }
        guard let convIndex = conversations.firstIndex(where: { $0.id == conversationID }) else { return nil }
        guard let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == assistantMessageID }),
              conversations[convIndex].messages[msgIndex].role == .assistant else { return nil }

        let precedingMessages = conversations[convIndex].messages[..<msgIndex]
        guard let userIndex = precedingMessages.lastIndex(where: { $0.role == .user }) else { return nil }

        return beginEditingUserMessage(at: userIndex, in: conversationID)
    }

    func continueMessage(
        messageID: UUID,
        in conversationID: UUID,
        capabilitySelection: ChatCapabilitySelection = ChatCapabilitySelection()
    ) async {
        hydrateConversationMessagesIfNeeded(id: conversationID)
        guard let convIndex = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        guard let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageID }),
              conversations[convIndex].messages[msgIndex].role == .assistant else { return }
        // An empty interrupted message has no partial content to continue, so it degrades to a regeneration (answering the original question again). Otherwise the empty assistant would be dropped by the
        // ChatRequestBuilder empty-content guard, the continue instruction would merge with the adjacent leading user message, and the original question would become context inside the unanswered envelope.
        if conversations[convIndex].messages[msgIndex].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await regenerateMessage(messageID: messageID, in: conversationID, capabilitySelection: capabilitySelection)
            return
        }
        guard let provider = appState.provider(for: conversations[convIndex].providerID) else { return }

        let continuingMessage = conversations[convIndex].messages[msgIndex]

        let model = appState.sendableModel(for: conversations[convIndex], provider: provider)
        guard let model else { return }
        let storedModelID = ModelResolver.preferredStoredModelIdentifier(for: model, providerKind: provider.kind)
        guard let resolvedCapabilitySelection = await gatedRecoveryCapabilitySelection(
            capabilitySelection,
            preservingLibraryModeFrom: continuingMessage,
            model: model,
            provider: provider,
            conversationID: conversationID
        ) else { return }
        // The gate may have force-refreshed metadata (the await yields the main thread), so the conversation / message indexes must be re-resolved
        guard let convIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageID })
        else { return }

        // Rejection (the same decision as sending, purpose continue): if it does not fit, no request is sent and the original message is untouched; the same Toast is shown.
        if let reject = await contextRejectReason(
            conversation: conversations[convIndex],
            messages: Array(conversations[convIndex].messages[...msgIndex]),
            provider: provider,
            model: model,
            capabilitySelection: resolvedCapabilitySelection,
            sendPath: .continueResponse(assistantMessageID: messageID)
        ) {
            ToastManager.shared.show(Self.contextRejectMessage(reject))
            return
        }
        // The pre-check yielded the main thread while assembling in the background, so the conversation / message indexes must be re-resolved
        guard let convIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageID })
        else { return }

        var updatedForContinue = conversations[convIndex]
        updatedForContinue.modelID = storedModelID
        // Data safety net: a continuation only completes the target assistant in place and never deletes the messages after it (matching the correct web implementation),
        // so "stop A, send B, then continue A overwrites B" cannot happen. The UI already guarantees the continue button shows only on the last message of the conversation.
        updatedForContinue.messages[msgIndex].providerID = provider.id
        updatedForContinue.messages[msgIndex].providerKind = provider.kind
        updatedForContinue.messages[msgIndex].providerName = provider.displayName
        updatedForContinue.messages[msgIndex].modelID = storedModelID
        updatedForContinue.messages[msgIndex].modelName = model.name
        updatedForContinue.messages[msgIndex].servedModelID = nil
        updatedForContinue.messages[msgIndex].state = .generating
        updatedForContinue.messages[msgIndex].errorTitle = nil
        updatedForContinue.messages[msgIndex].errorDetail = nil

        updatedForContinue.updatedAt = ConversationListMetadata.computeActivityAt(for: updatedForContinue)
        let precedingMessages = conversations[convIndex].messages[..<msgIndex]
        let latestUserText = precedingMessages.last(where: { $0.role == .user })?.text ?? ""
        appState.upsertConversationProjection(updatedForContinue)

        // The request history stops at the target assistant and does not treat later messages as continuation context.
        let messagesThroughAssistant = Array(updatedForContinue.messages[...msgIndex])
        let requestSnapshot = prepareRequestSnapshot(
            conversation: updatedForContinue,
            messages: messagesThroughAssistant,
            sendPath: .continueResponse(assistantMessageID: messageID)
        )

        queueAssistantResponse(
            conversationID: conversationID,
            assistantMessageID: messageID,
            requestSnapshot: requestSnapshot,
            provider: provider,
            model: model,
            capabilitySelection: resolvedCapabilitySelection,
            latestUserText: latestUserText,
            appendsToExistingText: true,
            // Sidecar consumption is an explicit continue/retry-only affordance. A new user send
            // keeps this nil, preventing opaque previous-turn state from contaminating its wire.
            explicitContinuationMessageID: [.moonshot, .openAI, .anthropic, .gemini, .deepseek, .openRouter, .grok].contains(provider.kind) ? messageID : nil,
            attemptKind: .continueResponse
        )
    }

    func regenerateMessage(
        messageID: UUID,
        in conversationID: UUID,
        capabilitySelection: ChatCapabilitySelection = ChatCapabilitySelection()
    ) async {
        hydrateConversationMessagesIfNeeded(id: conversationID)
        guard let convIndex = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        guard let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageID }),
              conversations[convIndex].messages[msgIndex].role == .assistant else { return }
        guard let provider = appState.provider(for: conversations[convIndex].providerID) else { return }
        let model = appState.sendableModel(for: conversations[convIndex], provider: provider)
        guard let model else { return }
        let storedModelID = ModelResolver.preferredStoredModelIdentifier(for: model, providerKind: provider.kind)
        let originalMessage = conversations[convIndex].messages[msgIndex]
        guard let resolvedCapabilitySelection = await gatedRecoveryCapabilitySelection(
            capabilitySelection,
            preservingLibraryModeFrom: originalMessage,
            model: model,
            provider: provider,
            conversationID: conversationID
        ) else { return }
        // The gate may have force-refreshed metadata (the await yields the main thread), so the conversation / message indexes must be re-resolved
        guard let convIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageID })
        else { return }

        let precedingMessages = conversations[convIndex].messages[..<msgIndex]
        guard let lastUserMessage = precedingMessages.last(where: { $0.role == .user }) else { return }
        // Rejection (the same decision as sending): the skill + instructions, or the user message to resend, do not fit the model context.
        // No request is sent and the original message is untouched; the same Toast is shown.
        if let reject = await contextRejectReason(
            conversation: conversations[convIndex],
            messages: Array(precedingMessages),
            provider: provider,
            model: model,
            capabilitySelection: resolvedCapabilitySelection
        ) {
            ToastManager.shared.show(Self.contextRejectMessage(reject))
            return
        }
        // The pre-check yielded the main thread while assembling in the background, so the conversation / message indexes must be re-resolved
        guard let convIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageID })
        else { return }

        let assistantMessageID = UUID()
        let newAssistantMessage = ChatMessage(
            id: assistantMessageID,
            role: .assistant,
            text: "",
            providerID: provider.id,
            providerKind: provider.kind,
            providerName: provider.displayName,
            modelID: storedModelID,
            modelName: model.name,
            state: .generating,
            createdAt: Date()
        )

        var updatedForRegen = conversations[convIndex]
        updatedForRegen.modelID = storedModelID
        // Record the ids of the removed .delivered messages
        let removedMessages = Array(updatedForRegen.messages[msgIndex...])
        let removedDeliveredIDs = removedMessages
            .filter { $0.state == .delivered }
            .map(\.id)
        updatedForRegen.messages.removeSubrange(msgIndex...)
        ReadAloudController.shared.stopIfSpeaking(messageIDs: removedMessages.map(\.id), .newGeneration)
        updatedForRegen.messages.append(newAssistantMessage)
        updatedForRegen.updatedAt = ConversationListMetadata.computeActivityAt(for: updatedForRegen)
        updatedForRegen.draftText = ""
        updatedForRegen.isDraft = false
        ConversationListMetadata.apply(to: &updatedForRegen)
        appState.upsertConversationProjection(
            updatedForRegen,
            deletingMessageIDs: Set(removedMessages.map(\.id))
        )
        // Truncation is a destructive change: refresh the recovery snapshot right away, so after a crash a cold-start merge does not add the deleted segment back by message count
        appState.persistRecoverySnapshotAfterDestructiveChange()

        let requestSnapshot = prepareRequestSnapshot(
            conversation: updatedForRegen,
            messages: updatedForRegen.messages,
            sendPath: .send(excludingMessageID: assistantMessageID)
        )


        queueAssistantResponse(
            conversationID: conversationID,
            assistantMessageID: assistantMessageID,
            requestSnapshot: requestSnapshot,
            provider: provider,
            model: model,
            capabilitySelection: resolvedCapabilitySelection,
            latestUserText: lastUserMessage.text,
            appendsToExistingText: false,
            explicitContinuationMessageID: [.moonshot, .openAI, .anthropic, .gemini, .deepseek, .openRouter, .grok].contains(provider.kind) ? assistantMessageID : nil,
            attemptKind: .regenerate
        )
    }

    func retryMessage(
        messageID: UUID,
        in conversationID: UUID,
        capabilitySelection: ChatCapabilitySelection = ChatCapabilitySelection(),
        localCustomFragmentDisposition: LocalCustomFragmentDisposition = .include
    ) async {
        _ = hydrateConversationMessagesIfNeeded(id: conversationID)
        guard let convIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageID }),
              conversations[convIndex].messages[msgIndex].role == .assistant,
              conversations[convIndex].messages[msgIndex].state == .failed
        else {
            await regenerateMessage(
                messageID: messageID,
                in: conversationID,
                capabilitySelection: capabilitySelection
            )
            return
        }
        guard let provider = appState.provider(for: conversations[convIndex].providerID) else { return }
        let model = appState.sendableModel(for: conversations[convIndex], provider: provider)
        guard let model else { return }
        let storedModelID = ModelResolver.preferredStoredModelIdentifier(for: model, providerKind: provider.kind)
        let originalMessage = conversations[convIndex].messages[msgIndex]
        let storedRecoveryDescriptor: CapabilityRecoveryDescriptor? = {
            guard let values = originalMessage.capabilityExecution?.recoveryDescriptors,
                  values.count == 1 else { return nil }
            return values[0]
        }()
        guard let resolvedCapabilitySelection = await gatedRecoveryCapabilitySelection(
            capabilitySelection,
            preservingLibraryModeFrom: originalMessage,
            model: model,
            provider: provider,
            conversationID: conversationID
        ) else { return }
        // The gate may have force-refreshed metadata (the await yields the main thread), so the conversation / message indexes must be re-resolved
        guard let convIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageID })
        else { return }

        let currentProvider = appState.provider(for: conversations[convIndex].providerID)
        let currentModel = currentProvider.flatMap {
            appState.sendableModel(for: conversations[convIndex], provider: $0)
        }

        // A persisted descriptor belongs to the failed message's exact runtime identity, not to
        // whichever connection/model is current when the CTA is tapped. Validate again after the
        // async recovery gate (metadata may have refreshed) and before any message state rewrite.
        let currentRecoveryIdentity: CapabilityEvidenceRequestIdentity? = {
            guard let currentProvider, let currentModel,
                  let runtime = CapabilityPreferenceRuntimeIdentity.make(
                    provider: currentProvider, model: currentModel
                  ) else {
                return nil
            }
            let base = CapabilityEvidenceRequestIdentity.make(
                provider: currentProvider,
                model: currentModel,
                partitionID: appState.sessionPartitionUID,
                hasExplicitValue: true,
                effectiveTransport: runtime.finalTransport
            )
            guard base.query.effectiveModelID == runtime.canonicalModelID else { return nil }
            return base.resolvingCapabilityRuntimeTransport(runtime.finalTransport)?
                .resolvingRuntimeRevision(runtime.runtimeRevision)
        }()
        let recoveryDescriptor: CapabilityRecoveryDescriptor? = {
            guard let currentProvider, let currentModel,
                  originalMessage.providerID == currentProvider.id,
                  originalMessage.modelID == ModelResolver.preferredStoredModelIdentifier(
                    for: currentModel, providerKind: currentProvider.kind
                  ) else { return nil }
            return CapabilityRecoveryDescriptorValidation.validated(
                storedRecoveryDescriptor,
                providerKind: currentProvider.kind,
                identity: currentRecoveryIdentity,
                cache: .shared
            )
        }()
        // The visible CTA promises "without this setting". If its stored descriptor no longer
        // belongs to the current exact identity, doing an ordinary retry here could silently send
        // the current preference. Fail closed without changing the message; generic retry/regenerate
        // remains a separate action path.
        if storedRecoveryDescriptor != nil, recoveryDescriptor == nil { return }
        let preservesFailedContent = recoveryDescriptor != nil

        let precedingMessages = conversations[convIndex].messages[..<msgIndex]
        guard let lastUserMessage = precedingMessages.last(where: { $0.role == .user }) else { return }
        // Rejection (the same decision as sending): the skill + instructions, or the user message to resend, do not fit the model context.
        // No request is sent and the original message is untouched; the same Toast is shown.
        if let reject = await contextRejectReason(
            conversation: conversations[convIndex],
            messages: Array(precedingMessages),
            provider: provider,
            model: model,
            capabilitySelection: resolvedCapabilitySelection
        ) {
            ToastManager.shared.show(Self.contextRejectMessage(reject))
            return
        }
        // The pre-check yielded the main thread while assembling in the background, so the conversation / message indexes must be re-resolved
        guard let convIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageID })
        else { return }

        var updatedForRetry = conversations[convIndex]
        updatedForRetry.modelID = storedModelID
        if !preservesFailedContent {
            updatedForRetry.messages[msgIndex].text = ""
            updatedForRetry.messages[msgIndex].reasoningText = nil
            updatedForRetry.messages[msgIndex].reasoningDurationMs = nil
            updatedForRetry.messages[msgIndex].citations = nil
            updatedForRetry.messages[msgIndex].attachments = nil
        }
        updatedForRetry.messages[msgIndex].toolSteps = nil
        // The cap notice is cleared together with the steps (it is the same local field as the fallback notice below).
        updatedForRetry.messages[msgIndex].estimatedCost = 0
        updatedForRetry.messages[msgIndex].providerID = provider.id
        updatedForRetry.messages[msgIndex].providerKind = provider.kind
        updatedForRetry.messages[msgIndex].providerName = provider.displayName
        updatedForRetry.messages[msgIndex].modelID = storedModelID
        updatedForRetry.messages[msgIndex].modelName = model.name
        updatedForRetry.messages[msgIndex].servedModelID = nil
        updatedForRetry.messages[msgIndex].state = .generating
        updatedForRetry.messages[msgIndex].errorTitle = nil
        updatedForRetry.messages[msgIndex].errorDetail = nil
        updatedForRetry.messages[msgIndex].capabilityExecution = nil
        updatedForRetry.messages[msgIndex].memoryItemIds = []
        updatedForRetry.messages[msgIndex].unhandledToolCalls = nil
        updatedForRetry.messages[msgIndex].toolFallbackNotice = nil
        updatedForRetry.messages[msgIndex].inputTokens = nil
        updatedForRetry.messages[msgIndex].outputTokens = nil
        updatedForRetry.messages[msgIndex].cachedInputTokens = nil
        updatedForRetry.messages[msgIndex].cacheCreationInputTokens = nil
        updatedForRetry.messages[msgIndex].cacheCreation5mTokens = nil
        updatedForRetry.messages[msgIndex].cacheCreation1hTokens = nil
        updatedForRetry.messages[msgIndex].costSource = nil
        updatedForRetry.updatedAt = ConversationListMetadata.computeActivityAt(for: updatedForRetry)
        // A resend owns only the failed assistant turn. Draft text composed while the error was
        // visible is independent user content and must survive explicit omit-setting recovery.
        ConversationListMetadata.apply(to: &updatedForRetry)
        appState.upsertConversationProjection(updatedForRetry)

        let requestSnapshot = prepareRequestSnapshot(
            conversation: updatedForRetry,
            messages: updatedForRetry.messages,
            sendPath: .send(excludingMessageID: messageID)
        )


        queueAssistantResponse(
            conversationID: conversationID,
            assistantMessageID: messageID,
            requestSnapshot: requestSnapshot,
            provider: provider,
            model: model,
            capabilitySelection: resolvedCapabilitySelection,
            latestUserText: lastUserMessage.text,
            appendsToExistingText: preservesFailedContent,
            explicitContinuationMessageID: [.moonshot, .openAI, .anthropic, .gemini, .deepseek, .openRouter, .grok].contains(provider.kind) ? messageID : nil,
            localCustomFragmentDisposition: localCustomFragmentDisposition,
            capabilityRecoveryDescriptor: recoveryDescriptor,
            attemptKind: .retry
        )
    }

    /// The relay's web intent this turn: the switch (preference store + default layer) is on and not overridden off by the user. A rejected current record does not count:
    /// whether each attempt carries a fragment is decided by that attempt's protocol (`RelayWebProbe.chatFragments`), and when none is carried the reply gets a notice.
    /// False when out of scope (local engine / undecided protocol).
    static func relayWebIsOn(
        provider: Provider, model: AIModel, conversationID: UUID?, skillID: UUID?
    ) -> Bool {
        guard RelayWebProbe.inScope(provider: provider, model: model) else { return false }
        let preference = RelayWebSwitch.isOn(provider: provider, model: model, conversationID: conversationID, skillID: skillID)
        return RelayWebProbe.fact(provider: provider, model: model, preference: preference)?.isOn ?? false
    }

    /// The entry of the three recovery paths (retry / regenerate / continue): resolves the capability selection before any state is rewritten.
    private func gatedRecoveryCapabilitySelection(
        _ requested: ChatCapabilitySelection,
        preservingLibraryModeFrom message: ChatMessage,
        model: AIModel,
        provider: Provider,
        conversationID: UUID? = nil
    ) async -> ChatCapabilitySelection? {
        // Relay web search: the recovery path resolves it from the switch (default layer included) the same as the first send.
        var requested = requested
        if ProviderForm.of(provider) == .relay {
            requested.webSearchEnabled = Self.relayWebIsOn(
                provider: provider, model: model, conversationID: conversationID,
                skillID: conversationID.flatMap { id in conversations.first(where: { $0.id == id })?.skillId }
            )
        }
        return recoveryCapabilitySelection(
            requested,
            preservingLibraryModeFrom: message,
            model: model
        )
    }

    private func recoveryCapabilitySelection(
        _ requested: ChatCapabilitySelection,
        preservingLibraryModeFrom message: ChatMessage,
        model: AIModel
    ) -> ChatCapabilitySelection {
        var resolved = requested
        // Composer state belongs to the next new send. Recovery keeps the requested
        // reasoning/web intent and never re-enables cloud Library research.
        resolved.libraryResearchEnabled = false
        return resolved
    }

    /// The capability selection actually in effect this turn (web / reasoning level / Library), decided from the preferences of the conversation, skill and connection layers.
    /// Sending and the attachment check before the composer sends read this same function, so both sides see the same web switch.
    private func requestedCapabilitySelection(
        _ capabilitySelection: ChatCapabilitySelection,
        provider: Provider,
        model: AIModel,
        conversationID: UUID,
        skillID: UUID?,
    ) -> ChatCapabilitySelection {
        var requestedCapabilitySelection = capabilitySelection
        let form = ProviderForm.of(provider)
        do {
            let runtimeIdentity = CapabilityPreferenceRuntimeIdentity.make(provider: provider, model: model)
            let transportIdentity = runtimeIdentity?.wireValue ?? ""
            let capabilityModelID = runtimeIdentity?.canonicalModelID ?? ""
            let store = GenerationParameterSettingsStore.shared
            let conversationValues = store.capabilityPreferences(
                providerID: provider.id, modelID: capabilityModelID, conversationID: conversationID,
                transportIdentity: transportIdentity
            )
            let skillValues = skillID.flatMap { skillID in
                store.capabilityPreferences(
                    providerID: provider.id, modelID: capabilityModelID, conversationID: nil,
                    skillID: skillID, transportIdentity: transportIdentity
                )
            }
            let connectionValues = store.capabilityPreferences(
                providerID: provider.id, modelID: capabilityModelID, conversationID: nil,
                transportIdentity: transportIdentity
            )
            let connectionScopeValues = store.connectionCapabilityPreferences(
                providerID: provider.id, modelID: capabilityModelID, transportIdentity: transportIdentity
            )
            let typed = CapabilityPreferenceValueResolver.resolve(
                singleSend: capabilitySelection.typedPreferences,
                conversation: conversationValues,
                skill: skillValues,
                connectionModel: connectionValues,
                connection: connectionScopeValues
            )
            // The web intent follows the store **only when the store can really be addressed**.
            //
            // - Identity available (most connections, including the subscription path): preferences are stored per connection x model x transport,
            //   the panel writes and this reads, so the store is the only source of truth and overriding the value passed by the UI is correct.
            // - Identity unavailable (the relay protocol is still on "auto", the model is not in the catalog, the runtime snapshot is not ready):
            //   the queries above used an empty identity and returned **defaults**, not what the user expressed. Overriding unconditionally with those
            //   would silently discard the intent the UI passed in, which is the last gate behind "web turned on yet the request never has a web tool"
            //   on the subscription path. In that case keep the UI's decision, which already passed the availability gate once in ChatView (`ChatCapabilityOutboundDecision`).
            if runtimeIdentity != nil {
                requestedCapabilitySelection.webSearchEnabled = typed.web != .off
            }
            // Relay web: this turn's web intent = the fact of the web row isOn (the switch including the default layer, and not overridden off by the user);
            // whether each attempt carries a fragment is decided by that attempt's protocol. The Library / custom takeover below still turns this turn off as usual.
            if form == .relay {
                requestedCapabilitySelection.webSearchEnabled = Self.relayWebIsOn(
                    provider: provider, model: model, conversationID: conversationID, skillID: skillID
                )
            }
            // The local `ReasoningMode` mirror is overwritten only when **the store really holds a level**.
            //
            // The criterion cannot be `typed.reasoningIntent`: `resolve` is a projection for the outbound compiler, where
            // "never set", "chose automatic" and "chose off" are equivalent and all fold into `"off"`. Overriding unconditionally with it
            // would reset the level a relay user just chose (the store has no complete identity and the level only relies on the chip's local mapping) to
            // automatic. `displaySelection` walks the same ladder without folding, and nil is the real "no layer ever stored it".
            //
            // When there is a value it must go through `ReasoningMode.fromIntent`: the v2 vocabulary differs from the local enum (`low` <-> `fast`),
            // `ReasoningMode(rawValue: "low")` returns nil and would silently swallow "fast" into an empty send; while `off`
            // and retired old levels must explicitly fall back to automatic, otherwise the previous round's level keeps taking part in the yield decision.
            let displayedIntent = CapabilityPreferenceValueResolver.displaySelection(
                conversation: conversationValues,
                skill: skillValues,
                connectionModel: connectionValues,
                connection: connectionScopeValues
            ).reasoningIntent
            if let intent = capabilitySelection.typedPreferences?.reasoningIntent ?? displayedIntent {
                requestedCapabilitySelection.reasoningMode = ReasoningMode.fromIntent(intent) ?? .automatic
            }
            requestedCapabilitySelection.typedPreferences = typed
            // The developer master switch is retired; the takeover criterion is only `mode == .custom` (the same source as outbound).
            // When the conversation layer has no record it falls back to the model default scope, the same reading as `activeLocalCustomFragments`;
            // `forwardPort` carries fields written under an old recipe version across the version line and validates them once more with the new recipe.
            let localCustomForwardPort = CapabilityLocalCustomForwardPortContext(
                providerKind: provider.kind, schemaModelID: model.id
            )
            let webCustom = store.effectiveLocalCustomConfiguration(
                providerID: provider.id, modelID: capabilityModelID, conversationID: conversationID,
                transportIdentity: transportIdentity, namespace: "webPatch",
                forwardPort: localCustomForwardPort
            ).mode == .custom
            let reasoningCustom = store.effectiveLocalCustomConfiguration(
                providerID: provider.id, modelID: capabilityModelID, conversationID: conversationID,
                transportIdentity: transportIdentity, namespace: "reasoningPatch",
                forwardPort: localCustomForwardPort
            ).mode == .custom
            if webCustom {
                requestedCapabilitySelection.webSearchEnabled = false
                requestedCapabilitySelection.typedPreferences?.web = .off
            }
            if reasoningCustom {
                requestedCapabilitySelection.reasoningMode = .automatic
                requestedCapabilitySelection.typedPreferences?.reasoningIntent = nil
            }
        }
        requestedCapabilitySelection.libraryResearchEnabled = false
        return requestedCapabilitySelection
    }

    /// The pre-check when the composer's send is tapped: whether this turn's attachments fit on the route the send is about to take.
    ///
    /// A non-nil return means they do not fit: the caller does not send, keeps the composer content and shows a hint. The route, the model resolution
    /// and the over-limit decision use the same functions and the same inputs as a real send; when the route cannot be decided right now
    /// (catalog not loaded, image generation, etc.) it returns nil and the failure card at send time catches it.
    func composerAttachmentOverLimit(
        text: String,
        attachments: [Attachment],
        conversationID: UUID?,
        draftSessionID: UUID?,
        capabilitySelection: ChatCapabilitySelection
    ) -> ProviderServiceError? {
        guard attachments.contains(where: { $0.kind == .file }) else { return nil }
        let conversation = conversationID.flatMap { id in conversations.first(where: { $0.id == id }) }
        let provider: Provider
        let model: AIModel
        if let conversation {
            guard let resolvedProvider = appState.provider(for: conversation.providerID),
                  let resolvedModel = appState.sendableModel(for: conversation, provider: resolvedProvider) else {
                return nil
            }
            provider = resolvedProvider
            model = resolvedModel
        } else {
            // There is no conversation yet: the send will create one with the currently selected model.
            guard conversationID == nil, let active = appState.activeModel else { return nil }
            provider = active.provider
            model = active.model
        }
        // For a new chat, preferences and tool switches are moved as they are from the draft id to the conversation id at send time, so reading by the draft id here gets that same copy.
        guard let scopeID = conversationID ?? draftSessionID else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let selection = initialCapabilitySelection(requestedCapabilitySelection(
            capabilitySelection,
            provider: provider,
            model: model,
            conversationID: scopeID,
            skillID: conversation?.skillId
        ))

        let usesToolLoop = !prepareMcpToolPlan(conversationID: scopeID, provider: provider, model: model).isEmpty

        guard let transport = AttachmentTransportResolver.resolve(
            provider: provider,
            model: model,
            request: .init(
                webSearchEnabled: selection.webSearchEnabled,
                webPreferenceIsAutomatic: selection.typedPreferences?.web == .automatic,
                usesToolLoop: usesToolLoop,
                historyHasVideo: Self.preflightHistoryHasVideo(
                    history: conversation?.messages ?? [], pendingText: trimmed, pendingAttachments: attachments
                )
            )
        ) else { return nil }
        let deliveryModel = AttachmentTransportResolver.deliveryModel(provider: provider, model: model, transport: transport)
        // When this connection has already been remembered as not accepting file blocks, the send goes out as text directly; the check uses the same premise.
        // A relay's "does not accept file blocks" is recorded in the negative cache per connection x model x protocol.
        let relayScope: NativeFileFallback.Scope? = provider.kind == .relay
            ? .relayScope(
                RelayEndpointResolver.effectiveTransport(provider: provider, model: model),
                connectionID: provider.id, modelID: model.id,
                fileOverride: model.relayCapabilityOverrides?.file
            )
            : nil
        let plan = NativeFileFallback.withKnownConnectionState(
            connectionID: provider.id, transport: transport, relay: relayScope
        ) {
            AttachmentDelivery.plan(
                userText: trimmed,
                attachments: attachments,
                transport: transport.profile,
                model: deliveryModel
            )
        }
        return AttachmentDelivery.overLimitError(for: plan, model: deliveryModel)
    }

    /// Pre-send check: whether the outbound history of the next send (conversation history plus this turn, normalized the
    /// same way as for sending) contains a video attachment.
    /// The outbound history uses the same projection as a real send (ChatRequestBuilder.outboundAttachmentHistory).
    /// When this turn has no text and no attachments yet (the model panel's pre-check), placeholder text stands for "the next turn always has content". Otherwise normalization would drop it as an empty message,
    nonisolated static func preflightHistoryHasVideo(
        history: [ChatMessage], pendingText: String, pendingAttachments: [Attachment],
        outboundHistory: ([ChatMessage]) -> [ChatMessage] = {
            ChatRequestBuilder.outboundAttachmentHistory($0, sendPath: .send(excludingMessageID: nil))
        }
    ) -> Bool {
        // Normalization only drops videos and never adds one: when neither side has one, skip normalization and the attachment budget (the panel calls this on every evaluation).
        guard pendingAttachments.contains(where: { $0.kind == .video }) || GeminiService.historyHasVideo(history) else {
            return false
        }
        let trimmed = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        var pending = ChatMessage(
            id: UUID(), role: .user, text: trimmed.isEmpty && pendingAttachments.isEmpty ? "_" : pendingText,
            providerKind: .gemini, providerName: "", modelName: "", state: .delivered
        )
        pending.attachments = pendingAttachments.isEmpty ? nil : pendingAttachments
        return GeminiService.historyHasVideo(outboundHistory(history + [pending]))
    }

    /// Route pre-check for the file card of the model panel: judges video by the outbound history of this conversation's next send (the draft attachments of this turn are not available to the panel and are not counted).
    func preflightHistoryHasVideo(conversationID: UUID?) -> Bool {
        let history = conversationID.flatMap { id in conversations.first(where: { $0.id == id }) }?.messages ?? []
        return Self.preflightHistoryHasVideo(history: history, pendingText: "", pendingAttachments: [])
    }

    /// The first send only records the user's intent. The raw capability/profile on the persisted model
    /// neither authorizes nor vetoes it; the real UI/request availability is decided item by item by the final facade
    /// once the actual endpoint/transport is known.
    private func initialCapabilitySelection(
        _ requested: ChatCapabilitySelection
    ) -> ChatCapabilitySelection {
        requested
    }

    // MARK: - Streaming response

    // MARK: Context compaction

    /// The connection used for the summary call: this conversation's provider / model (each connection type has its own one-shot channel).
    private struct PendingCompactionConnection {
        var provider: Provider
        var model: AIModel
        /// The wire model id (written to the database model column).
        var modelID: String
        var window: ContextWindowInput
        /// The prototype of the summary request message fields (provider / model markers).
        var prototype: ChatMessage?
    }

    private func compactionCoordinator(uid: String) -> ContextCompactionCoordinator? {
        if let existing = compactionCoordinators[uid] { return existing }
        guard let store = ContextCompactionStore.forPartition(uid) else { return nil }
        let coordinator = ContextCompactionCoordinator(
            store: store,
            upload: nil
        )
        coordinator.summaryActivityChanged = { [weak self] conversationId, active in
            guard let self, let id = UUID(uuidString: conversationId) else { return }
            // Do not write the current UI state once the partition has switched away (sign-out / account switch).
            guard self.appState.sessionPartitionUID == uid else { return }
            if active {
                self.appState.aiCompactingConversationIDs.insert(id)
            } else {
                self.appState.aiCompactingConversationIDs.remove(id)
            }
        }
        compactionCoordinators[uid] = coordinator
        return coordinator
    }

    /// Before chat assembly, read latestValid; nil when it cannot be read or errors.
    private func latestValidCheckpoint(
        conversationID: UUID,
        uid: String,
        snapshot: ChatRequestSnapshot
    ) -> ContextCheckpointRecord? {
        guard let store = ContextCompactionStore.forPartition(uid) else { return nil }
        do {
            return try store.latestValid(
                conversationId: conversationID.uuidString,
                history: ChatRequestBuilder.checkpointHistory(from: snapshot)
            )
        } catch {
            print("[ChatManager] checkpoint latestValid failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// The deterministic fallback's oldSummary = the non-empty summary of the latestValid winner, or nil if there is none.
    private func fallbackOldSummary(
        conversationID: UUID,
        uid: String,
        snapshot: ChatRequestSnapshot
    ) -> String? {
        guard let summary = latestValidCheckpoint(conversationID: conversationID, uid: uid, snapshot: snapshot)?.summary,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return summary
    }

    /// Conversations with an AI summary in progress (only counting the summary call itself; the instantaneous fallback does not count).
    var aiCompactingConversationIDs: Set<UUID> { appState.aiCompactingConversationIDs }

    /// Cancels the AI summary in progress for this conversation. preSend / overflow switch to the fallback and carry on sending this message; a manual compaction persists nothing and shows no hint.
    func cancelCompaction(conversationId conversationID: UUID) {
        compactionCoordinator(uid: appState.sessionPartitionUID)?
            .cancelSummary(conversationId: conversationID.uuidString)
    }

    /// Compacts when still required after applying (preSend) or on overflow (overflow); the snapshot is supplied by this plan. Returns the persisted new row, nil for noop.
    private func compactBeforeSend(
        conversationID: UUID,
        uid: String,
        trigger: ContextCompactionCoordinator.Trigger,
        inputs: ChatCompactionInputs,
        connection: PendingCompactionConnection
    ) async -> ContextCheckpointRecord? {
        await runCompaction(
            conversationID: conversationID, uid: uid, trigger: trigger, inputs: inputs, connection: connection
        ).row
    }

    private func runCompaction(
        conversationID: UUID,
        uid: String,
        trigger: ContextCompactionCoordinator.Trigger,
        inputs: ChatCompactionInputs,
        connection: PendingCompactionConnection,
        fallbackOnAIFailure: Bool = true
    ) async -> ContextCompactionCoordinator.Result {
        let noop = ContextCompactionCoordinator.Result(outcome: .noop, row: nil, failures: [])
        guard let coordinator = compactionCoordinator(uid: uid) else { return noop }
        // The snapshot, connection and system prompt are handed to the coordinator with this call: concurrent compactions of one conversation each use their own, without a per-conversation shared scratch.
        let snapshot = ContextCompactionSnapshot(
            messages: inputs.messages,
            attachments: inputs.attachments,
            B: inputs.B,
            U: inputs.U,
            rhoHi: inputs.rhoHi,
            prefixTokens: inputs.prefixTokens,
            fixedTokens: inputs.fixedTokens,
            model: connection.modelID
        )
        let system = inputs.system
        let instructions = conversations.first(where: { $0.id == conversationID })?.instructions
        let result = await coordinator.compact(
            conversationId: conversationID.uuidString,
            trigger: trigger,
            snapshot: snapshot,
            fallbackOnAIFailure: fallbackOnAIFailure,
            summarize: { [weak self] request in
                guard let self else { return nil }
                return await self.compactionSummary(
                    request: request, connection: connection, system: system, instructions: instructions
                )
            }
        )
        if result.row != nil {
            noteCompactionLanded(conversationID: conversationID, uid: uid)
        }
        return result
    }

    /// Manual compaction entry (called from the UI): always an AI summary (ignoring the preference and the circuit breaker), falling back only when the remote switch is off.
    /// The last message of the conversation is the current message (not in the span, counted in fixedTokens) and the rest is history; the system prompt / applied library row use the same rule as a chat send.
    /// A noop (no throw) when there is no conversation, the conversation is empty, no model is available or the budget is unknown.
    func compactConversationNow(conversationId conversationID: UUID) async -> ContextCompactionCoordinator.Result {
        let noop = ContextCompactionCoordinator.Result(outcome: .noop, row: nil, failures: [])
        guard let plan = await conversationCompactionPlan(conversationID: conversationID) else { return noop }
        return await runCompaction(
            conversationID: conversationID,
            uid: plan.uid,
            trigger: .manual,
            inputs: plan.inputs,
            connection: plan.connection
        )
    }

    /// Called by the UI when the composer gains focus or receives its first input. Only in AI mode with no compaction in progress for this conversation,
    /// and when P-hat = fixedTokens (already including the prefix and the current message) + the library-row estimate + the estimate of the history after coversTo >= 0.75*B,
    /// it starts an AI summary as preSend; failure or cancel returns noop, writes no fallback row and shows no hint (the 0.90*B check before sending handles it per mode).
    @discardableResult
    func precompactIfNeeded(conversationId conversationID: UUID) async -> ContextCompactionCoordinator.Result {
        let noop = ContextCompactionCoordinator.Result(outcome: .noop, row: nil, failures: [])
        let key = conversationID.uuidString
        guard !precompactingConversationIDs.contains(conversationID),
              let coordinator = compactionCoordinator(uid: appState.sessionPartitionUID),
              !coordinator.isSummarizing(conversationId: key),
              coordinator.isAIMode(conversationId: key),
              let conversation = conversations.first(where: { $0.id == conversationID }),
              appState.provider(for: conversation.providerID) != nil
        else { return noop }
        precompactingConversationIDs.insert(conversationID)
        defer { precompactingConversationIDs.remove(conversationID) }
        guard let plan = await conversationCompactionPlan(conversationID: conversationID),
              coordinator.isAIMode(conversationId: key),
              !coordinator.isSummarizing(conversationId: key)
        else { return noop }
        let inputs = plan.inputs
        var history = inputs.messages
        if let coversTo = plan.checkpoint?.coversTo,
           let index = history.firstIndex(where: { $0.id == coversTo }) {
            history = Array(history[(index + 1)...])
        }
        let checkpointTokens = plan.checkpoint.map {
            ContextBudget.estimateMessage($0.text, rhoHi: inputs.rhoHi)
        } ?? 0
        let pHat = inputs.fixedTokens + checkpointTokens + history.reduce(0) { $0 + $1.estTokens }
        guard Double(pHat) >= 0.75 * Double(inputs.B) else { return noop }
        return await runCompaction(
            conversationID: conversationID,
            uid: plan.uid,
            trigger: .preSend,
            inputs: inputs,
            connection: plan.connection,
            fallbackOnAIFailure: false
        )
    }

    private struct ConversationCompactionPlan {
        var uid: String
        var inputs: ChatCompactionInputs
        var connection: PendingCompactionConnection
        var checkpoint: ContextCheckpointRecord?
    }

    /// The snapshot shared by manual compaction and pre-compaction: the last message of the conversation is the current message (not in the span, counted in fixedTokens), the rest is history;
    /// the system prompt / applied library row use the same rule as a chat send. nil when there is no conversation, the conversation is empty, no model is available or the budget is unknown.
    private func conversationCompactionPlan(conversationID: UUID) async -> ConversationCompactionPlan? {
        guard conversations.contains(where: { $0.id == conversationID }),
              hydrateConversationMessagesIfNeeded(id: conversationID),
              let conversation = conversations.first(where: { $0.id == conversationID }),
              let last = conversation.messages.last,
              let provider = appState.provider(for: conversation.providerID),
              let model = appState.sendableModel(for: conversation, provider: provider)
        else { return nil }
        // When the last message is a user message, assembly naturally takes it as the current message; otherwise exclude it from assembly and count it in the fixed overhead.
        let lastIsUser = last.role == .user
        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(
                id: conversation.id,
                useMemory: conversation.useMemory,
                skillID: conversation.skillId,
                instructions: conversation.instructions,
                folderID: conversation.folderID
            ),
            messages: conversation.messages,
            preferences: ChatRequestPreferencesSnapshot(memoryItems: appState.memoryItemsCache.items),
            skill: conversation.skillId
                .flatMap { appState.skillManager.skill(by: $0) }
                .map(ChatRequestSkillSnapshot.init),
            sendPath: .send(excludingMessageID: lastIsUser ? nil : last.id)
        )
        let (_, generationParameters) = resolveGenerationParameters(
            provider: provider,
            model: model,
            conversationID: conversationID,
            capabilitySelection: ChatCapabilitySelection()
        )
        let window = ChatRequestBuilder.contextWindowInput(
            providerKind: provider.kind,
            model: model,
            userMaxOutput: ChatRequestBuilder.userMaxOutputTokens(from: generationParameters),
            budgetCap: effectiveContextCap(conversationID: conversationID)
        )
        let rhoKey = Self.rhoKey(provider: provider, model: model)
        let partitionUID = appState.sessionPartitionUID
        // rho and the write-back both obtain the store through the resolver (the store is obtained on the main actor, and reading the table is left to the background assembly).
        let rhoLedger = contextLedgerResolver(partitionUID)
        let checkpoint = latestValidCheckpoint(conversationID: conversationID, uid: partitionUID, snapshot: snapshot)
        let build = await Task.detached(priority: .userInitiated) {
            ChatRequestBuilder.build(
                from: snapshot,
                assembly: ChatRequestAssemblyContext(
                    window: window,
                    rhoHi: ContextLedgerStore.currentRhoHi(for: rhoKey, in: rhoLedger),
                    checkpoint: checkpoint,
                    memoryFallback: false,
                    overflowCompactionInputs: true
                )
            )
        }.value
        guard var inputs = build.compactionInputs, !inputs.messages.isEmpty else { return nil }
        debugLastCompactionBudgetForTesting = inputs.B
        if !lastIsUser {
            inputs.fixedTokens += ContextBudget.estimateMessage(last.text, rhoHi: inputs.rhoHi)
        }
        return ConversationCompactionPlan(
            uid: partitionUID,
            inputs: inputs,
            connection: PendingCompactionConnection(
                provider: provider,
                model: model,
                modelID: ModelResolver.resolvedProviderModelIdentifier(model.id, providerKind: provider.kind),
                window: window,
                prototype: last
            ),
            checkpoint: checkpoint
        )
    }

    // MARK: - Compaction actions (called by the UI layer, they draw no UI)

    /// The hint after a compaction action; a successful summary shows none.
    enum ContextCompactionToast: Hashable, Sendable {
        case cleared
        case fallback
        case noop

        /// A summary shows no hint; fallback and noop each have one.
        static func forManual(_ outcome: ContextCompactor.Outcome) -> Self? {
            switch outcome {
            case .summary: nil
            case .fallback: .fallback
            case .noop: .noop
            }
        }
    }

    /// The conversation that should show the "third compaction" hint; kept on AppState so the UI can observe it.
    var pendingCompactionHint: UUID? {
        get { appState.pendingCompactionHint }
        set { appState.pendingCompactionHint = newValue }
    }

    func dismissCompactionHint() {
        pendingCompactionHint = nil
    }

    /// After a local write, if this conversation now holds exactly 3 and this process has not shown the hint for it, show it once.
    /// internal: the context page sample shots use it to stage the third-compaction hint (ContextShots.open).
    func noteCompactionLanded(conversationID: UUID, uid: String) {
        guard !compactionHintShownConversationIDs.contains(conversationID),
              let store = ContextCompactionStore.forPartition(uid)
        else { return }
        let count: Int
        do {
            count = try store.list(conversationId: conversationID.uuidString).count
        } catch {
            print("[ChatManager] checkpoint list failed: \(error.localizedDescription)")
            return
        }
        guard count == 3 else { return }
        compactionHintShownConversationIDs.insert(conversationID)
        pendingCompactionHint = conversationID
    }

    /// Deletes all checkpoints of this conversation. nil when the store cannot be opened or the deletion fails.
    @discardableResult
    func clearCompaction(conversationId conversationID: UUID) -> ContextCompactionToast? {
        guard let store = ContextCompactionStore.forPartition(appState.sessionPartitionUID) else { return nil }
        do {
            _ = try store.deleteAll(conversationId: conversationID.uuidString)
            return .cleared
        } catch {
            print("[ChatManager] checkpoint deleteAll failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Deletes the latestValid row and then runs a manual compaction.
    func recompact(conversationId conversationID: UUID) async -> ContextCompactionToast? {
        if hydrateConversationMessagesIfNeeded(id: conversationID),
           let conversation = conversations.first(where: { $0.id == conversationID }),
           let store = ContextCompactionStore.forPartition(appState.sessionPartitionUID) {
            let history = conversation.messages.map {
                ContextCheckpoint.CoveredMessage(id: $0.id.uuidString, text: $0.text)
            }
            do {
                if let latest = try store.latestValid(conversationId: conversationID.uuidString, history: history) {
                    _ = try store.delete(
                        conversationId: conversationID.uuidString,
                        checkpointId: latest.checkpointId
                    )
                }
            } catch {
                print("[ChatManager] recompact delete failed: \(error.localizedDescription)")
            }
        }
        return await manualCompact(conversationId: conversationID)
    }

    /// Manual compaction, returning the hint to show.
    /// A cancelled run shows no hint.
    func manualCompact(conversationId conversationID: UUID) async -> ContextCompactionToast? {
        let result = await compactConversationNow(conversationId: conversationID)
        if result.cancelled { return nil }
        return ContextCompactionToast.forManual(result.outcome)
    }

    /// Whether this conversation's circuit breaker is in fallback-only mode (the panel shows [Retry]).
    func compactionBreakerIsFallbackOnly(conversationId conversationID: UUID) -> Bool {
        guard let coordinator = compactionCoordinator(uid: appState.sessionPartitionUID) else { return false }
        return coordinator.breakerState(conversationId: conversationID.uuidString).mode == .fallbackOnly
    }

    /// Panel [Retry]: forwards to the coordinator's breaker retry.
    func retryCompaction(conversationId conversationID: UUID) {
        compactionCoordinator(uid: appState.sessionPartitionUID)?.retry(conversationId: conversationID.uuidString)
    }

    /// Test seam: the production compaction coordinator instance of this partition.
    func debugCompactionCoordinatorForTesting(uid: String) -> ContextCompactionCoordinator? {
        compactionCoordinator(uid: uid)
    }

    /// The summary goes through a one-shot call channel with purpose compaction; system = req.system ?? the system of this chat plan,
    /// messages = req.messages, max output = req.maxOutputTokens, with no tools, no [D] and no extra memory. nil on error.
    private func compactionSummary(
        request: ContextCompactor.SummaryRequest,
        connection: PendingCompactionConnection,
        system: String,
        instructions: String?
    ) async -> String? {
        let prototype = connection.prototype
        let messages = request.messages.map { message in
            ChatMessage(
                id: UUID(),
                role: message.role == .user ? .user : .assistant,
                text: message.text,
                providerID: prototype?.providerID,
                providerKind: prototype?.providerKind ?? connection.provider.kind,
                providerName: prototype?.providerName ?? "",
                modelID: prototype?.modelID ?? connection.model.id,
                modelName: prototype?.modelName ?? connection.model.id,
                state: .delivered
            )
        }
        let planned = PlannedChatRequest.compactionSummary(
            system: request.system ?? system,
            messages: messages,
            window: connection.window,
            instructions: instructions
        )
        var options = ChatRequestOptions()
        options.maxOutputTokens = request.maxOutputTokens
        let transport = planned.transportInput(options)
        do {
            let providerManager = appState.providerManager
            let stream = try NoteAIManager.crosscheckEventStream(
                provider: connection.provider,
                model: connection.model,
                transport: transport,
                services: ProviderServiceRouter.Services(session: providerSession),
                nativeService: { providerManager.service(for: $0) }
            )
            var text = ""
            var streamed = false
            for try await event in stream {
                switch event {
                case .delta(let chunk):
                    if !chunk.isEmpty { streamed = true; text += chunk }
                case .done(let result):
                    if !streamed { text = result.text }
                case let .toolCallDeltas(calls):
                    if !calls.isEmpty { return nil }
                default:
                    break
                }
            }
            return text
        } catch {
            print("[ChatManager] compaction summary failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// For the divider row: reads rhoHi from the partition Ledger by this conversation's (provider, model), from the same source as assembly at send time (same rule as Android / Web);
    /// calibrated with the default when the provider or model cannot be resolved.
    func contextRhoHi(for conversation: Conversation) -> Double {
        guard let provider = appState.provider(for: conversation.providerID),
              let model = appState.sendableModel(for: conversation, provider: provider)
        else { return RhoCalibration().rhoHi }
        return ContextLedgerStore.currentRhoHi(
            for: Self.rhoKey(provider: provider, model: model),
            in: contextLedgerResolver(appState.sessionPartitionUID)
        )
    }

    /// The Ledger key of rho: (connection instance id, wire model id). It is the app's provider instance id (relay connection / BYOK configuration).
    /// Reads and writes share this one function.
    private static func rhoKey(provider: Provider, model: AIModel) -> RhoCalibrationKey {
        let transportInstanceId = provider.id.uuidString
        return RhoCalibrationKey(
            transportInstanceId: transportInstanceId,
            modelId: ModelResolver.resolvedProviderModelIdentifier(model.id, providerKind: provider.kind)
        )
    }

    /// The protocol family of this request (for overflow detection). When the stream handed over a finish, finish.family wins; when it failed at the HTTP layer it is inferred from the connection and protocol.
    private static func requestStopFamily(provider: Provider, relayTransport: RelayTransport?) -> StopFamily {
        switch provider.kind {
        case .anthropic: return .anthropic
        case .gemini: return .gemini
        case .relay:
            switch relayTransport {
            case .anthropicMessages: return .anthropic
            case .geminiGenerateContent: return .gemini
            case .openaiResponses: return .openaiResponses
            case .llamacppNative: return .llamaCpp
            default: return .openaiChat
            }
        default: return .openaiChat
        }
    }

    /// Whether this failure is a context overflow: classify(family, httpStatus, rawBody) with empty extraPatterns.
    /// In-stream window overflow: the upstream hands over finish first and then throws; a finish resolved to context_window_exceeded counts as an overflow when this attempt produced no body text.
    private static func isContextOverflow(
        error: Error,
        diagnostics: ChatFailureDiagnostics.Snapshot,
        family: StopFamily,
        streamFinish: StreamFinish?,
        answerStarted: Bool
    ) -> Bool {
        if let streamFinish, !answerStarted,
           StopReasonResolver.resolve(
               family: streamFinish.family, ended: streamFinish.ended,
               finishRaw: streamFinish.finishRaw, hadContent: false
           ) == .contextWindowExceeded {
            return true
        }
        let status: Int
        let body: String
        if let rawBody = diagnostics.rawBody {
            status = diagnostics.httpStatus ?? 200
            body = rawBody
        } else if let status = diagnostics.httpStatus {
            return status == 413
        } else {
            return false
        }
        return ContextOverflowClassifier.classify(family: overflowFamily(family), status: status, body: body).overflow
    }

    /// StopFamily -> overflow classification family: an explicit mapping per family, with no rawValue fallback.
    private static func overflowFamily(_ family: StopFamily) -> OverflowFamily {
        switch family {
        case .openaiChat: return .openaiChat
        case .openaiResponses: return .openaiResponses
        case .anthropic: return .anthropic
        case .gemini, .geminiInteractions: return .gemini
        case .managed: return .managed
        case .free: return .free
        case .llamaCpp: return .openaiCompatible
        }
    }

    /// Settle the Ledger at the end: append the manifest; record a rho sample when it ends successfully, is plain text and has usage. A write failure does not affect finishing the message.
    private func settleContextLedger(
        _ attempt: ContextLedgerAttempt?,
        stopReason: StopReason?,
        observedInput: Int?,
        recordsSample: Bool
    ) {
        guard let attempt, let ledger = contextLedgerResolver(attempt.partitionUID) else { return }
        let observed = observedInput
        try? ledger.appendManifest(attempt.manifest(observedInput: observed, stopReason: stopReason))
        // Only recorded on a single-leg chat; the usage of a context_window_exceeded ending does not represent the full input, so it is not recorded.
        if recordsSample, attempt.singleChatLeg, !attempt.hasAttachments,
           stopReason != .contextWindowExceeded, let observed, observed > 0 {
            try? ledger.recordRhoSample(attempt.rhoKey, observedInput: observed, textBytes: attempt.textBytes)
        }
    }

    /// Denominator of the rho sample: the UTF-8 byte count of the system prompt plus each message body.
    private static func contextTextBytes(systemPrompt: String, messages: [ChatMessage]) -> Int {
        systemPrompt.utf8.count + messages.reduce(0) { $0 + $1.text.utf8.count }
    }

    /// Pre-send rejection decision: assemble once with this message appended to the end of the conversation as the current user, using the same window parameters as outbound.
    /// It does not commit pending pinned notes and adds no retrieval: rejection only looks at the skill + instructions and the current message.
    private func contextRejectReason(
        conversation: Conversation,
        text: String,
        attachments: [Attachment],
        quoteContext: QuoteContext?,
        provider: Provider,
        model: AIModel,
        capabilitySelection: ChatCapabilitySelection
    ) async -> ContextRejectReason? {
        let candidate = ChatMessage(
            id: UUID(),
            role: .user,
            text: text,
            providerID: provider.id,
            providerKind: provider.kind,
            providerName: provider.displayName,
            modelName: model.name,
            state: .delivered,
            attachments: attachments.isEmpty ? nil : attachments,
            quoteContext: quoteContext?.isValid == true ? quoteContext : nil
        )
        return await contextRejectReason(
            conversation: conversation,
            messages: conversation.messages + [candidate],
            provider: provider,
            model: model,
            capabilitySelection: capabilitySelection
        )
    }

    /// Core of the rejection decision: messages end with the one that is about to be the current user (a send is a new message; a retry / regeneration uses the history before the target assistant message);
    /// a continuation passes the history cut through the target assistant (inclusive) and the continue send path.
    private func contextRejectReason(
        conversation: Conversation,
        messages: [ChatMessage],
        provider: Provider,
        model: AIModel,
        capabilitySelection: ChatCapabilitySelection,
        sendPath: ChatRequestSendPath = .send(excludingMessageID: nil)
    ) async -> ContextRejectReason? {
        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(
                id: conversation.id,
                useMemory: conversation.useMemory,
                skillID: conversation.skillId,
                instructions: conversation.instructions,
                folderID: conversation.folderID
            ),
            messages: messages,
            preferences: ChatRequestPreferencesSnapshot(memoryItems: appState.memoryItemsCache.items),
            skill: conversation.skillId
                .flatMap { appState.skillManager.skill(by: $0) }
                .map(ChatRequestSkillSnapshot.init),
            sendPath: sendPath
        )
        let (_, generationParameters) = resolveGenerationParameters(
            provider: provider,
            model: model,
            conversationID: conversation.id,
            capabilitySelection: capabilitySelection
        )
        let window = ChatRequestBuilder.contextWindowInput(
            providerKind: provider.kind,
            model: model,
            userMaxOutput: ChatRequestBuilder.userMaxOutputTokens(from: generationParameters),
            budgetCap: effectiveContextCap(conversationID: conversation.id)
        )
        let rhoKey = Self.rhoKey(provider: provider, model: model)
        let partitionUID = appState.sessionPartitionUID
        // rho and the write-back both obtain the store through the resolver (the store is obtained on the main actor, and reading the table is left to the background assembly).
        let rhoLedger = contextLedgerResolver(partitionUID)
        // Main-actor state is fully read before this point; neither the rho store read nor the assembly runs on the main thread.
        let precheck = await Task.detached(priority: .userInitiated) {
            ChatRequestBuilder.rejectPrecheck(
                for: snapshot,
                assembly: ChatRequestAssemblyContext(
                    window: window,
                    rhoHi: ContextLedgerStore.currentRhoHi(for: rhoKey, in: rhoLedger)
                )
            )
        }.value
        debugLastContextRejectPrecheckBudgetForTesting = precheck.budget
        return precheck.reject
    }

    /// The current B for the usage summary: from the same source as sending (contextWindowInput + the effective cap + the output cap after evaluation),
    /// so after the cap is changed it is computed against the new denominator right away instead of waiting for the next send. When the conversation, connection or model cannot be resolved it returns the outer nil (not passed, and the summary falls back to the ledger B);
    /// when resolved but the window is unknown and there is no custom cap it returns .some(nil) (window_unknown).
    func currentContextBudget(conversationID: UUID) -> Int?? {
        guard let conversation = conversations.first(where: { $0.id == conversationID }),
              let provider = appState.provider(for: conversation.providerID),
              let model = appState.sendableModel(for: conversation, provider: provider)
        else { return .none }
        let (_, generationParameters) = resolveGenerationParameters(
            provider: provider,
            model: model,
            conversationID: conversationID,
            capabilitySelection: ChatCapabilitySelection()
        )
        let window = ChatRequestBuilder.contextWindowInput(
            providerKind: provider.kind,
            model: model,
            userMaxOutput: ChatRequestBuilder.userMaxOutputTokens(from: generationParameters),
            budgetCap: effectiveContextCap(conversationID: conversationID)
        )
        return .some(ContextBudget.window(window).B)
    }

    /// The effective cap: the conversation's contextCap, or the global contextDefaultCap when nil.
    /// Sending, continue, tool legs, overflow resends, the ledger, the rejection pre-check and compaction all take the same value from here.
    private func effectiveContextCap(conversationID: UUID) -> ContextBudgetCap {
        conversations.first(where: { $0.id == conversationID })?.contextCap
            ?? appState.preferences.contextDefaultCap
    }

    private static func contextRejectMessage(_ reason: ContextRejectReason) -> String {
        switch reason {
        case .instructionsTooLong: L10n.tr("context_reject_instructions_too_long", table: .chat)
        case .messageTooLong: L10n.tr("context_reject_message_too_long", table: .chat)
        }
    }

    /// Evaluates the generation parameters of this turn (relay / BYOK). The pre-send rejection decision and the outbound assembly share it,
    /// so both see the same user output cap (maxOutput.user).
    private func resolveGenerationParameters(
        provider: Provider,
        model: AIModel,
        conversationID: UUID,
        capabilitySelection: ChatCapabilitySelection
    ) -> (GenerationProfileRef?, GenerationParameterOverrides?) {
        // The dormant decision of a saved value only looks at "whether the current profile still declares it and has a wire name". Capability
        // support/requestPolicy must wait for the final writer, after the actual URL + transport are known;
        // the UI projection of a relay has no final endpoint here, and filtering early with it would swallow every legitimate explicit
        // intent, leaving the later facade no chance to restore it.
        let generationProfile = GenerationParameterAvailability.profile(provider: provider, model: model)
        let declaredGenerationParameterIDs = Set(
            generationProfile?.parameters?.compactMap { parameter -> String? in
                guard let id = parameter.id,
                      let wire = generationProfile?.wire?[id],
                      !wire.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return id
            } ?? []
        )
        let resolved = GenerationParameterSettingsStore.shared.resolve(
            // The request options are not built yet, so the single-send layer is always empty (the requestOptions.generationParameters read before was nil too).
            transient: nil,
            providerID: provider.id,
            // A relay goes through the parameter-key entry point: the literal key, plus the legacy canonical keys registered as read-compat aliases
            modelID: provider.kind == .relay
                ? CapabilityPreferenceRuntimeIdentity.canonicalModelID(provider: provider, model: model)
                : ModelResolver.preferredStoredModelIdentifier(for: model, providerKind: provider.kind),
            conversationID: conversationID,
            profileFingerprint: GenerationParameterProfileFingerprint.make(provider: provider, model: model),
            // When the chip explicitly picks a level, the connection-level reasoning defaults yield as a whole group (see the comment of resolve).
            reasoningMode: capabilitySelection.reasoningMode,
            // Dormant values (old values the current profile no longer declares / no longer lets through) are blocked on the evaluation side,
            // not left for applyGenerationParameters to drop along the way: the conflict assertion runs before the drop.
            activeParameterIDs: declaredGenerationParameterIDs
        )
        return (generationProfile, resolved)
    }

    /// Whether structured output (json_schema) is in effect for this request: in the generation-parameter contract it conflicts with tools and is dropped when the memory tools are attached,
    /// so it is treated as "this path cannot send tools" and memory takes the fallback this turn.
    func structuredOutputActive(provider: Provider, model: AIModel, conversationID: UUID) -> Bool {
        let (_, parameters) = resolveGenerationParameters(
            provider: provider, model: model, conversationID: conversationID, capabilitySelection: ChatCapabilitySelection()
        )
        return parameters?.values["json_schema"]?.state == .value
    }

    private func queueAssistantResponse(
        conversationID: UUID,
        assistantMessageID: UUID,
        requestSnapshot: ChatRequestSnapshot,
        provider: Provider,
        model: AIModel,
        capabilitySelection: ChatCapabilitySelection,
        latestUserText: String,
        appendsToExistingText: Bool,
        explicitContinuationMessageID: UUID? = nil,
        localCustomFragmentDisposition: LocalCustomFragmentDisposition = .include,
        capabilityRecoveryDescriptor: CapabilityRecoveryDescriptor? = nil,
        /// The sent event of send / edit is emitted by sendMessage with the full properties; the other ways of starting emit it here, exactly one per attempt.
        attemptKind: ChatAttemptKind = .send,
        /// Automatic resend after a context overflow: when non-nil it forces the deterministic fallback, and when the window is unknown it serves as B; a second overflow in this resend is not resent again.
        overflowFallbackB: Int? = nil,
        /// The new row the coordinator compacted and persisted after an overflow: when non-nil this resend assembles from it and no longer runs the in-memory fallback (it still counts as already resent).
        overflowRetryCheckpoint: ContextCheckpointRecord? = nil,
        /// propose_memory state of a mode=tool fresh send.
        proposeTurn: ProposeMemoryTurn? = nil,
        /// Resend without tools after the propose-carrying first leg was rejected:
        /// the send-confirm gate and the compaction turn count already ran for this turn.
        isProposeDegradeResend: Bool = false,
        /// Thinking resend: the first leg's held delivery; its usage / cost add to this attempt's (billing is the sum).
        proposeCarriedDelivery: ProposeMemoryDeferredDelivery? = nil,
        /// Thinking resend: entries search_memory returned on the first leg, placed after the automatic
        /// [D] recall entries (same recallMax fitting).
        carriedSearchRecall: [ContextRecallEntry] = []
    ) {
        let providerKind = provider.kind
        let apiKey = ProviderCredentialResolver.apiKey(provider: provider, modelID: model.id)
        let resolvedModelID = ModelResolver.resolvedProviderModelIdentifier(model.id, providerKind: providerKind)
        let providerID = provider.id
        // Official providers are computed from endpointSource; a relay and the like use the literal address as is.
        let baseURLText = provider.requestBaseURLText()

        // A new stream that overwrites an existing one in the same conversation: persist the previous partial as `.interrupted` first, then cancel the old task.
        // Different conversations never overwrite each other (the core of multi-conversation support).
        // Otherwise, when the old task cancelled below notices isCancelled on the next tick and goes through
        // completeStreamingMessage(state: .interrupted), sessions[convID].messageID has already been
        // overwritten with the new ID, the guard `session.messageID == messageID` does not match
        // -> the partial text of the old message is never written back -> what the user had generated is lost completely.
        if let oldSession = sessions[conversationID], oldSession.messageID != assistantMessageID {
            persistPartialStreamingAsInterrupted(in: conversationID, userInitiated: true)
            oldSession.sendTask?.cancel()
        }

        // Initialize the streaming buffer: text changes notify the view through the per-conversation Combine subject,
        // not through @Published conversations
        let initialText = appendsToExistingText
            ? currentAssistantText(conversationID: conversationID, messageID: assistantMessageID)
            : ""
        let sendTaskID = UUID()
        addSession(
            StreamingSession(
                messageID: assistantMessageID,
                text: initialText,
                attachments: [],
                pendingImageData: [:],
                sendTask: nil,    // filled in after the sendTask is built
                sendTaskID: sendTaskID
            ),
            for: conversationID
        )
        sessions[conversationID]?.attemptKind = attemptKind
        sessions[conversationID]?.baselineText = initialText
        sessions[conversationID]?.proposeTurn = proposeTurn
        sessions[conversationID]?.proposeCarriedDelivery = proposeCarriedDelivery
        if providerKind == .relay {
            sessions[conversationID]?.relayDeliveryRoute = RelayDeliveryRoute(
                providerID: providerID,
                modelID: model.id,
                transport: RelayEndpointResolver.effectiveTransport(provider: provider, model: model),
                keyID: RelayKeyBinding.effectiveKeyID(provider: provider, modelID: model.id),
                keyWriteIdentity: ProviderManager.relayKeyWriteIdentity(provider, modelID: model.id)
            )
        }
        subject(for: conversationID).send()    // triggers the first cell sync
        // Use a structured Task to keep Swift 6 concurrency semantics correct; the network stream read yields the main thread between await points.
        // Hold a strong reference to AppState until the sendTask finishes, so the unowned appState is not read after release in the streaming finishing phase
        // (mainly in unit tests, where AppState is a local variable released after the test case returns)
        let sendTask = Task(priority: .userInitiated) { [weak self, appStateRetainer = appState as AppState?] in
            guard let self else { return }
            _ = appStateRetainer // only holds a strong reference, keeping appState alive for the lifetime of the closure
            let services = ProviderServiceRouter.Services(session: self.providerSession)
            let openRouterService = services.openRouter
            let openAIService = services.openAI
            let deepSeekService = services.deepSeek
            let grokService = services.grok
            let geminiService = services.gemini
            let anthropicService = services.anthropic
            let groqService = services.groq
            let togetherService = services.together
            let fireworksService = services.fireworks
            let miniMaxService = services.miniMax
            let zhipuService = services.zhipu
            let qwenService = services.qwen
            let moonshotService = services.moonshot
            let mistralService = services.mistral
            let siliconFlowService = services.siliconFlow
            let officialImageDispatcher = BaseAPIService(session: self.providerSession)
            var bufferedDelta = ""
            var lastFlushTime = Date().timeIntervalSince1970
            let retrievalSnapshot = await self.prepareEnrichedRequestSnapshot(
                requestSnapshot,
                latestUserText: latestUserText
            )
            // The overflow-fallback reassembly also reads this one.
            var enrichedRequestSnapshot = retrievalSnapshot
            if !carriedSearchRecall.isEmpty {
                let automaticIds = Set(enrichedRequestSnapshot.recall.map(\.id))
                enrichedRequestSnapshot = enrichedRequestSnapshot.withRecall(
                    enrichedRequestSnapshot.recall + carriedSearchRecall.filter { !automaticIds.contains($0.id) }
                )
            }
            // The generation parameters are evaluated before the window parameters are built: the user's output cap goes into maxOutput.user,
            // and the evaluated whole group is still attached to the request options as before (see the generationParameters assignment below).
            let (generationProfile, resolvedGenerationParameters) = self.resolveGenerationParameters(
                provider: provider,
                model: model,
                conversationID: conversationID,
                capabilitySelection: capabilitySelection
            )
            // The chat main path hands over to ContextAssembler: the window comes from the model, and rho is read from the Ledger by (connection, model);
            // the output cap is taken as user > recipe > model, and when the user value exceeds the window the budget caps it (oWire = min(O, R)).
            // The ledger B (contextAttempt) and the raw material of the compaction snapshot both read this one set of window parameters, so the cap is the same.
            let assemblyWindow = ChatRequestBuilder.contextWindowInput(
                providerKind: providerKind,
                model: model,
                userMaxOutput: ChatRequestBuilder.userMaxOutputTokens(from: resolvedGenerationParameters),
                budgetCap: self.effectiveContextCap(conversationID: conversationID)
            )
            let rhoKey = Self.rhoKey(provider: provider, model: model)
            let partitionUID = self.appState.sessionPartitionUID
            let rhoLedger = self.contextLedgerResolver(partitionUID)
            // After the Library evidence is read back it is assembled again with the same window parameters, so assembly is collected into one function.
            // A chat send reads the library row (latestValid) and applies it; if it is still over the 0.90 line it goes to the coordinator for compaction first.
            // When no library row is usable and the coordinator returns noop, it falls back to the in-memory fallback; overflow resends and non-chat requests keep the plain behaviour.
            var chatCheckpoint: ContextCheckpointRecord?
            var chatMemoryFallback = true
            func assembleRequest(_ snapshot: ChatRequestSnapshot) async -> ChatRequestBuildResult {
                let checkpoint = chatCheckpoint
                let memoryFallback = chatMemoryFallback
                let oldSummary = await self.fallbackOldSummary(
                    conversationID: conversationID, uid: partitionUID, snapshot: snapshot
                )
                return await Task.detached(priority: .userInitiated) {
                    ChatRequestBuilder.build(
                        from: snapshot,
                        assembly: ChatRequestAssemblyContext(
                            window: assemblyWindow,
                            rhoHi: ContextLedgerStore.currentRhoHi(for: rhoKey, in: rhoLedger),
                            overflowFallbackB: overflowRetryCheckpoint == nil ? overflowFallbackB : nil,
                            checkpoint: checkpoint,
                            memoryFallback: memoryFallback,
                            fallbackOldSummary: oldSummary
                        )
                    )
                }.value
            }
            // MCP / Library Agent tool loop: the same snapshot is assembled with purpose toolLoopLeg, and the host safety note is the last
            // segment of plan.system; every leg of the loop uses this one system prompt, and the leg runner no longer builds its own.
            func assembleToolLoopRequest(_ snapshot: ChatRequestSnapshot, toolSafety: String) async -> ChatRequestBuildResult {
                let oldSummary = await self.fallbackOldSummary(
                    conversationID: conversationID, uid: partitionUID, snapshot: snapshot
                )
                return await Task.detached(priority: .userInitiated) {
                    ChatRequestBuilder.build(
                        from: snapshot,
                        assembly: ChatRequestAssemblyContext(
                            window: assemblyWindow,
                            rhoHi: ContextLedgerStore.currentRhoHi(for: rhoKey, in: rhoLedger),
                            overflowFallbackB: overflowFallbackB,
                            fallbackOldSummary: oldSummary
                        ),
                        toolSafety: toolSafety
                    )
                }.value
            }
            var isChatSend = false
            if case .send = requestSnapshot.sendPath, overflowFallbackB == nil { isChatSend = true }
            if isChatSend {
                chatMemoryFallback = false
                chatCheckpoint = self.latestValidCheckpoint(
                    conversationID: conversationID, uid: partitionUID, snapshot: enrichedRequestSnapshot
                )
            }
            if let overflowRetryCheckpoint {
                chatCheckpoint = overflowRetryCheckpoint
                chatMemoryFallback = false
            }
            var requestBuild = await assembleRequest(enrichedRequestSnapshot)
            if isChatSend, !isProposeDegradeResend, requestBuild.planned.plan.purpose == .chat {
                self.compactionCoordinator(uid: partitionUID)?.recordTurn(conversationId: conversationID.uuidString)
                if requestBuild.compactionRequired {
                    var compactedRow: ContextCheckpointRecord?
                    if let inputs = requestBuild.compactionInputs {
                        compactedRow = await self.compactBeforeSend(
                            conversationID: conversationID,
                            uid: partitionUID,
                            trigger: .preSend,
                            inputs: inputs,
                            connection: PendingCompactionConnection(
                                provider: provider,
                                model: model,
                                modelID: resolvedModelID,
                                window: assemblyWindow,
                                prototype: requestSnapshot.messages.last
                            )
                        )
                    }
                    if let compactedRow {
                        chatCheckpoint = compactedRow
                        requestBuild = await assembleRequest(enrichedRequestSnapshot)
                    } else if chatCheckpoint == nil {
                        chatMemoryFallback = true
                        requestBuild = await assembleRequest(enrichedRequestSnapshot)
                    }
                }
            }
            // Stop tapped during compaction: the whole send is cancelled and no chat request goes out (the coordinator no longer persists).
            if Task.isCancelled { return }
            // Pre-send confirmation gate: after compaction and before going out, it asks the user only about the message just sent / resent after an edit (an ordinary / Library / MCP
            // first leg all pass here); overflow resends and tool legs do not. P-hat takes the plan estimate at this moment, and later growth of the Library evidence is not asked about again.
            if attemptKind == .send || attemptKind == .edit, overflowFallbackB == nil, !isProposeDegradeResend,
               let estimatedInput = requestBuild.budget?.estimatedInput,
               let prompt = self.contextCapConfirmPrompt(
                   conversationID: conversationID,
                   attemptKind: attemptKind,
                   providerKind: providerKind,
                   model: model,
                   resolvedModelID: resolvedModelID,
                   window: assemblyWindow,
                   estimatedInput: estimatedInput
               ) {
                let choice = await self.appState.contextCapConfirmCoordinator.request(
                    prompt, conversationID: conversationID, messageID: assistantMessageID
                )
                switch choice {
                case let .send(dontAsk):
                    ContextPriceLineConfirmStore().confirm(prompt.decision, dontAsk: dontAsk, conversationID: conversationID)
                case .cancel:
                    self.rollbackUnconfirmedSend(assistantMessageID: assistantMessageID, in: conversationID)
                    return
                }
                if Task.isCancelled { return }
            }
            // When no library row is usable, later reassembly (Library evidence) runs the in-memory fallback as before.
            if chatCheckpoint == nil { chatMemoryFallback = true }
            await MainActor.run {
                self.debugLastContextWindowForTesting = assemblyWindow
                self.debugLastContextBudgetForTesting = requestBuild.budget
            }
            var planned = requestBuild.planned
            var requestOptions = requestBuild.requestOptions
            // Context accounting: only the chat main path (which has a plan) records the manifest / rho.
            let relayRequestTransport: RelayTransport? = providerKind == .relay
                ? RelayEndpointResolver.effectiveTransport(provider: provider, model: model)
                : nil
            @MainActor func contextAttempt(for build: ChatRequestBuildResult) -> ContextLedgerAttempt {
                let plan = build.planned.plan
                let windowBudget = ContextBudget.window(assemblyWindow)
                var attempt = ContextLedgerAttempt(
                    requestId: UUID().uuidString,
                    conversationId: conversationID.uuidString,
                    partitionUID: partitionUID,
                    rhoKey: rhoKey,
                    // transport records this attempt's StopFamily string, from the same source as family.
                    transport: Self.requestStopFamily(provider: provider, relayTransport: relayRequestTransport).rawValue,
                    model: resolvedModelID,
                    family: Self.requestStopFamily(provider: provider, relayTransport: relayRequestTransport),
                    W: windowBudget.W,
                    O: windowBudget.O,
                    B: plan.budget.B,
                    U: windowBudget.U,
                    estimatedInput: plan.budget.estimatedInput,
                    segments: plan.segments.map {
                        ContextManifestSegment(kind: $0.kind, tokens: $0.tokens, items: $0.items, omitted: $0.omitted)
                    },
                    unansweredMerged: plan.unansweredMerged,
                    reminder: plan.reminder,
                    tailFrom: build.tailFrom,
                    checkpointId: build.checkpointId,
                    textBytes: Self.contextTextBytes(systemPrompt: build.planned.system, messages: build.planned.messages),
                    hasAttachments: build.planned.messages.contains { !($0.attachments ?? []).isEmpty }
                )
                attempt.purpose = plan.purpose
                attempt.memoryIds = plan.memoryIds
                return attempt
            }
            self.sessions[conversationID]?.contextAttempt = contextAttempt(for: requestBuild)
            // search_memory: judged once for any chat request (new send / retry / regenerate);
            // a resend without tools (degrade / thinking with empty text) does not attach it again. It shares one host-tool state and tail leg for this turn with propose.
            if !isProposeDegradeResend, requestBuild.planned.plan.purpose == .chat {
                await self.installMemorySearch(
                    conversationID: conversationID,
                    sendTaskID: sendTaskID,
                    snapshot: requestSnapshot,
                    provider: provider,
                    model: model,
                    capabilitySelection: capabilitySelection,
                    recallMax: ContextBudget.window(assemblyWindow).derived?.recallMax,
                    rhoHi: ContextLedgerStore.currentRhoHi(for: rhoKey, in: rhoLedger),
                    recallIds: requestBuild.planned.plan.memoryIds
                )
            }
            requestOptions.capabilityPreferences = capabilitySelection.typedPreferences
            requestOptions.localContinuationMessageID = assistantMessageID
            requestOptions.localExplicitContinuationMessageID = explicitContinuationMessageID
            // Stateful continuation fingerprint: compare with the one stored when the target answer completed, then register this attempt's (it is promoted when this answer is saved).
            let continuationFingerprint = RecipeContinuationRuntime.Fingerprint(
                system: requestBuild.planned.plan.system,
                modelID: resolvedModelID,
                checkpointText: requestBuild.checkpointText
            )
            requestOptions.continuationFingerprintMatches = RecipeContinuationRuntime.fingerprintMatches(
                continuationFingerprint, messageID: explicitContinuationMessageID
            )
            RecipeContinuationRuntime.stageFingerprint(continuationFingerprint, messageID: assistantMessageID)
            // Grok subscription mode: fetch a token right before going out (renewed automatically 5 minutes before expiry) and attach the
            // CLI proxy endpoint and the required request headers delivered by the server.
            //
            // The Keychain, not `provider.apiKey`, is the only source of truth for the credential - the latter is written once at the first authorization
            // only as a "connected" marker and renewals update only the Keychain. Fetching on every send leaves no question of which of two tokens is newer.

            var effectiveAPIKey = apiKey
            if providerKind == .grok, provider.authMode == .subscription {
                switch await self.grokSubscriptionPreparer(providerID) {
                case let .success(prepared):
                    effectiveAPIKey = prepared.accessToken
                    // The protocol is decided by the model-level source of truth (`api_backend` of `/models` > seed > chat),
                    // the same function as the capability decision / preference identity / Library legs.
                    requestOptions.grokSubscription = prepared.context.withTransport(
                        CapabilityControlResolution.subscriptionFinalTransport(for: provider, model: model)
                            ?? prepared.context.transport
                    )
                case let .failure(error):
                    // It must stop here. Without the subscription context the request would go to the default endpoint of API Key mode,
                    // and the user would get an error unrelated to the real cause.
                    if error.requiresConfigRefresh {
                        // 426: the delivered client version is below the upstream floor. The snapshot TTL is 24h and on a cache hit it only refreshes
                        // in the background; without an active pull, after the operator fixes the configuration users would wait up to a day to recover.
                        await MetadataClient.shared.forceRefresh()
                    }
                    await MainActor.run {
                        self.failStreamingMessage(
                            conversationID: conversationID,
                            messageID: assistantMessageID,
                            expectedSendTaskID: sendTaskID,
                            userFacingText: error.userFacingMessage,
                            estimatedCost: 0,
                            // Store the title key and translate it at display time (same as a subscription failure in the streaming phase; the failure card recognises a subscription failure by it).
                            title: ProviderServiceError.SubscriptionLane.grok.titleKey,
                            detail: error.userFacingMessage
                        )
                    }
                    return
                }
            } else if providerKind == .openAI, provider.authMode == .subscription {
                // Codex subscription: the same discipline as Grok - fetch a token right before going out (renewed automatically 5 minutes before expiry),
                // attaching the Codex responses endpoint, chatgpt-account-id and the required request headers delivered by the server. A failure must stop here,
                // otherwise the request would go to the default endpoint of API Key mode and the user would get an error unrelated to the real cause.
                switch await OpenAISubscriptionRuntime.prepare(providerID: providerID) {
                case let .success(prepared):
                    effectiveAPIKey = prepared.accessToken
                    requestOptions.openAISubscription = prepared.context
                case let .failure(error):
                    if error.requiresConfigRefresh {
                        await MetadataClient.shared.forceRefresh()
                    }
                    await MainActor.run {
                        self.failStreamingMessage(
                            conversationID: conversationID,
                            messageID: assistantMessageID,
                            expectedSendTaskID: sendTaskID,
                            userFacingText: error.userFacingMessage,
                            estimatedCost: 0,
                            title: ProviderServiceError.SubscriptionLane.openAI.titleKey,
                            detail: error.userFacingMessage
                        )
                    }
                    return
                }
            }
            if let token = RecipeContinuationRuntime.explicitConsumptionToken(
                explicitMessageID: explicitContinuationMessageID
            ) {
                await MainActor.run {
                    self.pendingRecipeContinuationAcknowledgements[sendTaskID] = token
                }
            }
            // A normal new user send must never replay a previous assistant's opaque state: placing a
            // role=tool after the new user message would create an orphan tool_call_id. Only a future
            // explicit continue/retry entry may opt in after reconstructing assistant tool_calls +
            // matching tool results in protocol order.
            do {
                // The user's explicit output cap is applied after the builder, and the value sent = min(user value, oWire).
                requestOptions.generationParameters = ChatRequestBuilder.cappingUserMaxOutputTokens(
                    resolvedGenerationParameters, to: requestOptions.maxOutputTokens
                )
                requestOptions.generationProfile = generationProfile
            }
            // Raw JSON is local-only and never enters the typed envelope. Read it only
            // on the real send path and require the same complete connection/model/transport key
            // as the editor. Do not preflight-and-drop here: a stored fragment that has become
            // invalid after a metadata revision must reach the final production builder, which
            // rejects it before networking. Silently omitting it would turn a normal send into an
            // unrequested “retry without custom fields”.
            requestOptions.localCustomFragmentDisposition = localCustomFragmentDisposition
            if requestOptions.localCustomFragmentDisposition != .omitForExplicitRetry {
                let runtimeIdentity = CapabilityPreferenceRuntimeIdentity.make(provider: provider, model: model)
                let customFragments = GenerationParameterSettingsStore.shared.activeLocalCustomFragments(
                    providerID: provider.id, modelID: runtimeIdentity?.canonicalModelID ?? "",
                    conversationID: conversationID, transportIdentity: runtimeIdentity?.wireValue ?? "",
                    // The outbound side and the UI read the same forward path. Missing this one place would show the user "in use" on the panel
                    // while the request lacks that field - the forward happens only when the panel is opened.
                    forwardPort: .init(providerKind: provider.kind, schemaModelID: model.id)
                )
                requestOptions.selectLocalCustomBodyFragments(customFragments)
            }
            // Additional request body: read by every connection. It coexists with the panel parameters,
            // so only the raw text is attached here and generationParameters is untouched. The send where the user tapped "Retry without the additional request body"
            // does not attach it; the stored content and the switch are both left unchanged.
            requestOptions.localAdditionalRequestBody = nil
            if requestOptions.localCustomFragmentDisposition != .omitAdditionalBodyForExplicitRetry {
                requestOptions.localAdditionalRequestBody = GenerationParameterSettingsStore.shared
                    .activeAdditionalRequestBody(
                        providerID: provider.id,
                        modelID: CapabilityPreferenceRuntimeIdentity.canonicalModelID(provider: provider, model: model),
                        conversationID: conversationID
                    )
            }
            requestOptions.capabilityEvidenceModel = AttachmentTransportResolver.evidenceModel(provider: provider, model: model)
            requestOptions.attachmentConnectionID = provider.id
            // Relay web: when the switch is on, each protocol gets its own effective fragment (stored ?? that protocol's template), and a protocol whose current record is
            // rejected (not counted while the user override is on) gets none; the constructors of the first send, a first-send reroute and a protocol fallback each take the fragment of their own protocol.
            // This turn's web intent was already resolved from the switch in requestedCapabilitySelection; Library / helper sends turn it off.
            let relayWebOn = capabilitySelection.webSearchEnabled
            requestOptions.relayWebFragments = RelayWebProbe.chatFragments(provider: provider, model: model, webOn: relayWebOn)
            if self.sessions[conversationID]?.relayDeliveryRoute != nil {
                self.sessions[conversationID]?.relayDeliveryRoute?.webOn = relayWebOn
                    && RelayWebProbe.inScope(provider: provider, model: model)
                var hashes: [RelayTransport: String] = [:]
                for transport in RelayWebProbe.fragmentTransports {
                    if let fragment = requestOptions.relayWebFragments?.object(for: transport) {
                        hashes[transport] = RelayWebProbe.fragmentHash(fragment)
                    }
                }
                self.sessions[conversationID]?.relayDeliveryRoute?.webFragmentHashes = hashes
            }
            // Inject the full local identity only inside the real send task; the adapter itself does not read Keychain/metadata.
            let capabilityEvidenceIdentity = CapabilityEvidenceRequestIdentity.make(
                provider: provider,
                model: model,
                partitionID: appState.sessionPartitionUID,
                hasExplicitValue: requestOptions.generationParameters?.values.values.contains(where: { $0.state == .value }) == true,
                // Relay dispatch is selected solely from requested transport below; a profile is parameter
                // schema, not runtime route, so it must not partition self-heal as a different transport.
                // The relay transport can only be written by the actual request builder after the final URL is formed.
                // requested/auto is only an intent and must not pre-authorize a capability or the self-heal cache.
                effectiveTransport: nil
            )

            // Streaming flush: writes into sessions[convID].text by convID and notifies subscribers through the per-conversation subject;
            // it does not modify the conversations array.
            //
            // Thresholds aligned with the UI cadence:
            // - 40ms period: an integer multiple of the pacer frameDelay of 33-40ms, aligned with the new stepSize=1 normal-speed tier;
            //   the former 50ms + pacer 22ms + cell throttle 50ms gave three clocks with +-40ms jitter,
            //   and with the cell throttle removed this 40ms is the only throttling point.
            // - 32 character cap: keeps the backlog of one flush into the paced streaming within a sensible range
            // - flush immediately on \n: keeps paragraph-level responsiveness
            func flushBufferedDelta(force: Bool = false) async {
                guard !bufferedDelta.isEmpty else { return }

                // Every buffered body delta came from a real StreamEvent. Record it before
                // throttling so an immediate transport failure cannot look pre-token.
                CapabilityExecutionRuntime.recordUpstreamResponse()

                let now = Date().timeIntervalSince1970
                let shouldFlush = force ||
                    now - lastFlushTime >= 0.04 ||
                    bufferedDelta.contains("\n") ||
                    bufferedDelta.count >= 32

                guard shouldFlush else { return }

                let delta = bufferedDelta
                bufferedDelta.removeAll(keepingCapacity: true)
                lastFlushTime = now
                await MainActor.run {
                    // Write only if the current sessions[convID] is still this task;
                    // this prevents a task that was already cancelled by an overwriting new stream (a second send in the same conversation) from writing
                    guard self.sessions[conversationID]?.sendTaskID == sendTaskID else { return }
                    // Strip leading whitespace from the first visible delta, the same rule as the trimmingCharacters each service applies to result.text in `.done`. Otherwise
                    // the streamed accumulated text starts with whitespace while the finalized text is trimmed, their prefixes mismatch -> the cell skips the deferred smooth ending and the frozen
                    // segment is rebuilt from prefix=0 (the reproducible root cause of "the whole page flashes + the content drops" after MiniMax cn think-in-content
                    // strips </think> and the body always starts with \n\n).
                    guard let sanitized = Self.sanitizedStreamingDelta(
                        delta,
                        accumulatedIsEmpty: self.sessions[conversationID]?.text.isEmpty != false
                    ) else { return }
                    self.commitStreamingBodyDelta(sanitized, in: conversationID)
                }
            }

            #if DEBUG
            print("[ImageGen] Routing decision: provider=\(providerKind), model=\(model.id), caps=\(model.capabilities), imageGenProfile=\(model.imageGenProfile ?? "nil")")
            #endif

            // Failure handling is in the catch below, which is already outside the TaskLocal scope of the tracker,
            // so reading `CapabilityExecutionRuntime.current` there only yields nil; hence a reference to this send's tracker is kept.
            var sendExecutionTracker: CapabilityExecutionTracker?
            // The scene for attributing a chat failure (status code, upstream error type, relay guidance, content block): likewise a reference is kept for the catch to read.
            let failureDiagnostics = ChatFailureDiagnostics()
            // Relay rejection loop: the failure path reads the protocol of the last attempt, the rejection before output, and whether the protocol was switched.
            var relayAttempt: (transport: RelayTransport, rejection: RelayPreOutputRejection?, switched: Bool)?
            // The file-rejection notice card only looks at the first attempt of this message: whether a native file block was carried and what the first rejection was.
            let relayFileProbe = NativeFileFallback.FirstAttemptProbe()
            var relayFirstRejection: RelayPreOutputRejection?
            // Judged before output as "this key has no access to the model": the failure path no longer enters the capability rejection loop.
            var relayKeyAccessDenied = false
            do {
                // Remote MCP: tools are assembled only when this conversation has servers turned on and the
                // connection can carry tools. Otherwise the plan is empty and the send takes the plain path
                // below, with no MCP tool in the request. When the Library agent is also on, it joins the same loop. A continuation is text-only: it enters neither the MCP nor the Library Agent tool loop (Library evidence still goes into [D]).
                let textContinuationOnly = attemptKind == .continueResponse
                let mcpPlan = textContinuationOnly
                    ? .empty
                    : self.prepareMcpToolPlan(conversationID: conversationID, provider: provider, model: model)

                if !mcpPlan.isEmpty {
                    self.sessions[conversationID]?.contextAttempt?.singleChatLeg = false
                    let toolLoopBuild = await assembleToolLoopRequest(
                        enrichedRequestSnapshot,
                        toolSafety: McpSafetyPrompt.text
                    )
                    let transport = toolLoopBuild.planned.transportInput(requestOptions)
                    try await self.runMcpToolLoop(
                        conversationID: conversationID,
                        assistantMessageID: assistantMessageID,
                        sendTaskID: sendTaskID,
                        initialText: initialText,
                        provider: provider,
                        model: model,
                        accessToken: effectiveAPIKey,
                        resolvedModelID: resolvedModelID,
                        transport: transport,
                        reasoningMode: capabilitySelection.reasoningMode,
                        plan: mcpPlan
                    )
                    self.appState.conversationManager.refreshConversationCost(for: conversationID)
                    return
                }

                // propose_memory: attached only on the plain path as the last item of tools with tool_choice auto;
                // the MCP / Library loops already returned above and are not covered here.
                // search_memory is ordered after propose_memory.
                if let turn = self.proposeTurn(in: conversationID, sendTaskID: sendTaskID) {
                    let hostTools = Self.hostToolDefinitions(turn)
                    if !hostTools.isEmpty {
                        requestOptions.clientTools = hostTools
                        requestOptions.clientToolChoice = .auto
                    }
                }
                // The chat entry takes only the plan projection: the Library evidence and options are settled, and each route below passes transport.*.
                let transport = planned.transportInput(requestOptions)
                // textBytes measures the message text finally sent (after the Library additions).
                self.sessions[conversationID]?.contextAttempt?.textBytes = Self.contextTextBytes(
                    systemPrompt: transport.options.systemPrompt, messages: transport.messages
                )
                // One tracker is scoped to exactly this send task.  It cannot leak to a later
                // retry, continuation or another conversation.
                let capabilityExecutionTracker = CapabilityExecutionTracker { [weak self] execution in
                    // Requested is a transient, visible fact only after the actual URLSession
                    // dispatch boundary.  It replaces no persisted terminal result on refresh.
                    Task { @MainActor [weak self] in
                        self?.recordRequestedCapabilityExecution(
                            execution,
                            conversationID: conversationID,
                            messageID: assistantMessageID,
                            expectedSendTaskID: sendTaskID
                        )
                    }
                }
                sendExecutionTracker = capabilityExecutionTracker
                try await ChatFailureDiagnostics.$current.withValue(failureDiagnostics) {
                try await CapabilityRecipeResendContext.$recoveryDescriptor.withValue(
                    capabilityRecoveryDescriptor
                ) {
                try await CapabilityExecutionRuntime.$current.withValue(capabilityExecutionTracker) {
                try await CapabilityEvidenceDispatchContext.$onWebSearchDispatched.withValue({}) {
                try await CapabilityEvidenceRequestContext.$current.withValue(capabilityEvidenceIdentity) {
                // Dedicated image generation: a single user = plan.imagePrompt + the attachments of the last user message, with no system / memory / [D].
                // images_api, dashscope_multimodal and minimax_image_generation all use it; chat_api still sends chat messages.
                let imageGeneration = await Task.detached(priority: .userInitiated) {
                    ChatRequestBuilder.imageGenerationRequest(
                        from: enrichedRequestSnapshot, window: assemblyWindow
                    )
                }.value
                let officialImageDispatch: OfficialImageGenerationDispatch
                switch providerKind {
                case .relay:
                    // A relay has its own independent transport; the official metadata route must not intercept it.
                    officialImageDispatch = .notApplicable
                default:
                    officialImageDispatch = try await officialImageDispatcher.dispatchOfficialImageGeneration(
                        providerKind: providerKind,
                        userBaseURL: baseURLText,
                        apiKey: apiKey,
                        modelID: resolvedModelID,
                        messages: imageGeneration.messages,
                        selectedModelSupportsImageGeneration: model.capabilities.contains(.imageGen)
                    )
                }
                let providerSpecificImageRoute: ImageGenRoute?
                switch officialImageDispatch {
                case .notApplicable:
                    providerSpecificImageRoute = nil
                case let .providerSpecific(route):
                    providerSpecificImageRoute = route
                case let .handled(result):
                    await self.preDownloadImageAttachments(result.attachments, in: conversationID)
                    await MainActor.run {
                        self.applyNonStreamingCompletionIfCurrent(
                            taskID: sendTaskID,
                            conversationID: conversationID,
                            messageID: assistantMessageID,
                            result: result,
                            estimatedCost: self.resolvedDeliveredCost(
                                from: result,
                                model: model,
                                providerKind: providerKind
                            ),
                            usageMetrics: ChatDeliveredUsageMetrics(result: result)
                        )
                    }
                    return
                }

                // Pick the route by (provider, model): a relay is always dispatched by protocol; an official provider is dispatched by protocol only when a
                // non-native apiProtocol is delivered, and the official-only image routes take priority, with the native service unchanged.
                let protocolRoute: ProviderServiceRouter.ProtocolRoute?
                switch ProviderServiceRouter.route(provider: provider, model: model) {
                case .byProtocol(let route) where providerKind == .relay || providerSpecificImageRoute == nil:
                    protocolRoute = route
                default:
                    protocolRoute = nil
                }
                let dispatchKind: ProviderKind = protocolRoute != nil ? .relay : providerKind

                switch dispatchKind {
                case .openRouter:
                    if providerSpecificImageRoute == .chatAPI {
                        let result = try await openRouterService.sendMessage(
                            apiKey: apiKey,
                            modelID: resolvedModelID,
                            messages: transport.messages,
                            reasoningMode: capabilitySelection.reasoningMode,
                            webSearchEnabled: capabilitySelection.webSearchEnabled,
                            supportsImageGen: true,
                            requestOptions: transport.options
                        )
                        let deliveredCost = self.resolvedDeliveredCost(from: result, model: model, providerKind: providerKind)
                        #if DEBUG
                        print("[ImageGen] OpenRouter non-streaming result: text=\(result.text.prefix(100)), attachments=\(result.attachments?.count ?? 0)")
                        #endif
                        await MainActor.run {
                            self.applyNonStreamingCompletionIfCurrent(
                                taskID: sendTaskID,
                                conversationID: conversationID,
                                messageID: assistantMessageID,
                                result: result,
                                estimatedCost: deliveredCost,
                                servedModelID: result.servedModelID,
                                usageMetrics: ChatDeliveredUsageMetrics(result: result)
                            )
                        }
                    } else {
                        let stream = openRouterService.sendMessageStream(
                            apiKey: apiKey,
                            modelID: resolvedModelID,
                            messages: transport.messages,
                            reasoningMode: capabilitySelection.reasoningMode,
                            webSearchEnabled: capabilitySelection.webSearchEnabled,
                            requestOptions: transport.options
                        )

                        self.clearStreamFinish(in: conversationID, sendTaskID: sendTaskID)
                        for try await event in stream {
                            if Task.isCancelled { break }

                            switch event {
                            case let .delta(text):
                                self.markReasoningEndedIfNeeded(in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                                bufferedDelta += text
                                await flushBufferedDelta()
                            case let .reasoning(chunk):
                                self.appendReasoning(chunk, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                            case let .citations(citations):
                            self.recordCitations(citations, in: conversationID)
                            case let .imagePart(attachment):
                                await self.handleStreamingImagePart(attachment, in: conversationID)
                            case let .toolCallDeltas(calls):
                                self.recordUnhandledToolCalls(calls, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID, provider: provider, model: model)
                            case let .activity(activity):
                                // Land the preamble tail in the buffer into the session first: otherwise it waits for the next event to flush, leaving half a sentence missing on screen during the search,
                                // and a late flush would clear the just-set activity as if it were "the next body segment".
                                await flushBufferedDelta(force: true)
                                self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                            case let .finish(finish):
                                self.recordStreamFinish(finish, in: conversationID, sendTaskID: sendTaskID)
                            case let .done(result):
                                await flushBufferedDelta(force: true)
                                let deliveredCost = self.resolvedDeliveredCost(from: result, model: model, providerKind: providerKind)
                                await MainActor.run {
                                    self.reconcileStreamingText(
                                        with: result.text,
                                        in: conversationID,
                                        messageID: assistantMessageID,
                                        expectedSendTaskID: sendTaskID
                                    )
                                    self.completeStreamingMessage(
                                        conversationID: conversationID,
                                        messageID: assistantMessageID,
                                        expectedSendTaskID: sendTaskID,
                                        estimatedCost: deliveredCost,
                                        state: .delivered,
                                        attachments: result.attachments,
                                        servedModelID: result.servedModelID,
                                        usageMetrics: ChatDeliveredUsageMetrics(result: result),
                                        streamFinish: result.finish
                                    )
                                }
                            }
                        }

                        if Task.isCancelled {
                            await flushBufferedDelta(force: true)
                            await MainActor.run {
                                self.completeStreamingMessage(
                                    conversationID: conversationID,
                                    messageID: assistantMessageID,
                                    expectedSendTaskID: sendTaskID,
                                    state: .interrupted
                                )
                            }
                        }
                    }

                case .openAI:
                    let stream = openAIService.sendMessageStream(
                            apiKey: apiKey,
                            modelID: resolvedModelID,
                            messages: transport.messages,
                            reasoningMode: capabilitySelection.reasoningMode,
                            webSearchEnabled: capabilitySelection.webSearchEnabled,
                            requestOptions: transport.options
                        )

                        self.clearStreamFinish(in: conversationID, sendTaskID: sendTaskID)
                        for try await event in stream {
                            if Task.isCancelled { break }

                            switch event {
                            case let .delta(text):
                                self.markReasoningEndedIfNeeded(in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                                bufferedDelta += text
                                await flushBufferedDelta()
                            case let .reasoning(chunk):
                                self.appendReasoning(chunk, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                            case let .citations(citations):
                            self.recordCitations(citations, in: conversationID)
                            case let .imagePart(attachment):
                                await self.handleStreamingImagePart(attachment, in: conversationID)
                            case let .toolCallDeltas(calls):
                                self.recordUnhandledToolCalls(calls, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID, provider: provider, model: model)
                            case let .activity(activity):
                                // Land the preamble tail in the buffer into the session first: otherwise it waits for the next event to flush, leaving half a sentence missing on screen during the search,
                                // and a late flush would clear the just-set activity as if it were "the next body segment".
                                await flushBufferedDelta(force: true)
                                self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                            case let .finish(finish):
                                self.recordStreamFinish(finish, in: conversationID, sendTaskID: sendTaskID)
                            case let .done(result):
                                await flushBufferedDelta(force: true)
                                await MainActor.run {
                                    self.reconcileStreamingText(
                                        with: result.text,
                                        in: conversationID,
                                        messageID: assistantMessageID,
                                        expectedSendTaskID: sendTaskID
                                    )
                                    self.completeStreamingMessage(
                                        conversationID: conversationID,
                                        messageID: assistantMessageID,
                                        expectedSendTaskID: sendTaskID,
                                        estimatedCost: self.resolvedDeliveredCost(from: result, model: model, providerKind: providerKind),
                                        state: .delivered,
                                        attachments: result.attachments,
                                        usageMetrics: ChatDeliveredUsageMetrics(result: result),
                                        streamFinish: result.finish
                                    )
                                }
                            }
                        }

                        if Task.isCancelled {
                            await flushBufferedDelta(force: true)
                            await MainActor.run {
                                self.completeStreamingMessage(
                                    conversationID: conversationID,
                                    messageID: assistantMessageID,
                                    expectedSendTaskID: sendTaskID,
                                    state: .interrupted
                                )
                            }
                        }

                case .deepseek:
                    let stream = deepSeekService.sendMessageStream(
                        apiKey: apiKey,
                        modelID: resolvedModelID,
                        messages: transport.messages,
                        reasoningMode: capabilitySelection.reasoningMode,
                        requestOptions: transport.options
                    )

                    self.clearStreamFinish(in: conversationID, sendTaskID: sendTaskID)
                    for try await event in stream {
                        if Task.isCancelled { break }

                        switch event {
                        case let .delta(text):
                            self.markReasoningEndedIfNeeded(in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                            bufferedDelta += text
                            await flushBufferedDelta()
                        case let .reasoning(chunk):
                            self.appendReasoning(chunk, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                        case let .citations(citations):
                            self.recordCitations(citations, in: conversationID)
                        case .imagePart:
                            break
                        case let .toolCallDeltas(calls):
                            self.recordUnhandledToolCalls(calls, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID, provider: provider, model: model)
                        case let .activity(activity):
                            // Land the preamble tail in the buffer into the session first: otherwise it waits for the next event to flush, leaving half a sentence missing on screen during the search,
                            // and a late flush would clear the just-set activity as if it were "the next body segment".
                            await flushBufferedDelta(force: true)
                            self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                        case let .finish(finish):
                            self.recordStreamFinish(finish, in: conversationID, sendTaskID: sendTaskID)
                        case let .done(result):
                            await flushBufferedDelta(force: true)
                            await MainActor.run {
                                self.reconcileStreamingText(
                                    with: result.text,
                                    in: conversationID,
                                    messageID: assistantMessageID,
                                    expectedSendTaskID: sendTaskID
                                )
                                self.completeStreamingMessage(
                                    conversationID: conversationID,
                                    messageID: assistantMessageID,
                                    expectedSendTaskID: sendTaskID,
                                    estimatedCost: self.resolvedDeliveredCost(from: result, model: model, providerKind: providerKind),
                                    state: .delivered,
                                    attachments: result.attachments,
                                    usageMetrics: ChatDeliveredUsageMetrics(result: result),
                                    streamFinish: result.finish
                                )
                            }
                        }
                    }

                    if Task.isCancelled {
                        await flushBufferedDelta(force: true)
                        await MainActor.run {
                            self.completeStreamingMessage(
                                conversationID: conversationID,
                                messageID: assistantMessageID,
                                expectedSendTaskID: sendTaskID,
                                state: .interrupted
                            )
                        }
                    }

                case .mistral:
                    // A pure stream with no image-generation fork (Mistral has no webSearch/imageGen), structured like .deepseek
                    let mistralStream = mistralService.sendMessageStream(
                        apiKey: apiKey,
                        modelID: resolvedModelID,
                        messages: transport.messages,
                        reasoningMode: capabilitySelection.reasoningMode,
                        requestOptions: transport.options
                    )

                    self.clearStreamFinish(in: conversationID, sendTaskID: sendTaskID)
                    for try await event in mistralStream {
                        if Task.isCancelled { break }

                        switch event {
                        case let .delta(text):
                            self.markReasoningEndedIfNeeded(in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                            bufferedDelta += text
                            await flushBufferedDelta()
                        case let .reasoning(chunk):
                            self.appendReasoning(chunk, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                        case let .citations(citations):
                            self.recordCitations(citations, in: conversationID)
                        case .imagePart:
                            break
                        case let .toolCallDeltas(calls):
                            self.recordUnhandledToolCalls(calls, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID, provider: provider, model: model)
                        case let .activity(activity):
                            // Land the preamble tail in the buffer into the session first: otherwise it waits for the next event to flush, leaving half a sentence missing on screen during the search,
                            // and a late flush would clear the just-set activity as if it were "the next body segment".
                            await flushBufferedDelta(force: true)
                            self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                        case let .finish(finish):
                            self.recordStreamFinish(finish, in: conversationID, sendTaskID: sendTaskID)
                        case let .done(result):
                            await flushBufferedDelta(force: true)
                            await MainActor.run {
                                self.reconcileStreamingText(
                                    with: result.text,
                                    in: conversationID,
                                    messageID: assistantMessageID,
                                    expectedSendTaskID: sendTaskID
                                )
                                self.completeStreamingMessage(
                                    conversationID: conversationID,
                                    messageID: assistantMessageID,
                                    expectedSendTaskID: sendTaskID,
                                    estimatedCost: self.resolvedDeliveredCost(from: result, model: model, providerKind: providerKind),
                                    state: .delivered,
                                    attachments: result.attachments,
                                    usageMetrics: ChatDeliveredUsageMetrics(result: result),
                                    streamFinish: result.finish
                                )
                            }
                        }
                    }

                    if Task.isCancelled {
                        await flushBufferedDelta(force: true)
                        await MainActor.run {
                            self.completeStreamingMessage(
                                conversationID: conversationID,
                                messageID: assistantMessageID,
                                expectedSendTaskID: sendTaskID,
                                state: .interrupted
                            )
                        }
                    }

                case .grok:
                    let stream = grokService.sendMessageStream(
                            apiKey: effectiveAPIKey,
                            modelID: resolvedModelID,
                            messages: transport.messages,
                            reasoningMode: capabilitySelection.reasoningMode,
                            webSearchEnabled: capabilitySelection.webSearchEnabled,
                            requestOptions: transport.options
                        )

                        self.clearStreamFinish(in: conversationID, sendTaskID: sendTaskID)
                        for try await event in stream {
                            if Task.isCancelled { break }

                            switch event {
                            case let .delta(text):
                                self.markReasoningEndedIfNeeded(in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                                bufferedDelta += text
                                await flushBufferedDelta()
                            case let .reasoning(chunk):
                                self.appendReasoning(chunk, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                            case let .citations(citations):
                                self.recordCitations(citations, in: conversationID)
                            case .imagePart:
                                break
                            case let .toolCallDeltas(calls):
                                self.recordUnhandledToolCalls(calls, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID, provider: provider, model: model)
                            case let .activity(activity):
                                // Land the preamble tail in the buffer into the session first: otherwise it waits for the next event to flush, leaving half a sentence missing on screen during the search,
                                // and a late flush would clear the just-set activity as if it were "the next body segment".
                                await flushBufferedDelta(force: true)
                                self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                            case let .finish(finish):
                                self.recordStreamFinish(finish, in: conversationID, sendTaskID: sendTaskID)
                            case let .done(result):
                                await flushBufferedDelta(force: true)
                                await MainActor.run {
                                    self.reconcileStreamingText(
                                        with: result.text,
                                        in: conversationID,
                                        messageID: assistantMessageID,
                                        expectedSendTaskID: sendTaskID
                                    )
                                    self.completeStreamingMessage(
                                        conversationID: conversationID,
                                        messageID: assistantMessageID,
                                        expectedSendTaskID: sendTaskID,
                                        estimatedCost: self.resolvedDeliveredCost(from: result, model: model, providerKind: providerKind),
                                        state: .delivered,
                                        attachments: result.attachments,
                                        usageMetrics: ChatDeliveredUsageMetrics(result: result),
                                        streamFinish: result.finish
                                    )
                                }
                            }
                        }

                        if Task.isCancelled {
                            await flushBufferedDelta(force: true)
                            await MainActor.run {
                                self.completeStreamingMessage(
                                    conversationID: conversationID,
                                    messageID: assistantMessageID,
                                    expectedSendTaskID: sendTaskID,
                                    state: .interrupted
                                )
                            }
                        }

                case .gemini:
                    if providerSpecificImageRoute == .chatAPI {
                        let result = try await geminiService.sendMessage(
                            apiKey: apiKey,
                            modelID: resolvedModelID,
                            messages: transport.messages,
                            reasoningMode: capabilitySelection.reasoningMode,
                            webSearchEnabled: capabilitySelection.webSearchEnabled,
                            supportsImageGen: true,
                            requestOptions: transport.options
                        )
                        #if DEBUG
                        print("[ImageGen] Gemini non-streaming result: text=\(result.text.prefix(100)), attachments=\(result.attachments?.count ?? 0)")
                        #endif
                        await MainActor.run {
                            self.applyNonStreamingCompletionIfCurrent(
                                taskID: sendTaskID,
                                conversationID: conversationID,
                                messageID: assistantMessageID,
                                result: result,
                                estimatedCost: self.resolvedDeliveredCost(from: result, model: model, providerKind: providerKind),
                                usageMetrics: ChatDeliveredUsageMetrics(result: result)
                            )
                        }
                    } else {
                        let stream = geminiService.sendMessageStream(
                            apiKey: apiKey,
                            modelID: resolvedModelID,
                            messages: transport.messages,
                            reasoningMode: capabilitySelection.reasoningMode,
                            webSearchEnabled: capabilitySelection.webSearchEnabled,
                            requestOptions: transport.options
                        )

                        self.clearStreamFinish(in: conversationID, sendTaskID: sendTaskID)
                        for try await event in stream {
                            if Task.isCancelled { break }

                            switch event {
                            case let .delta(text):
                                self.markReasoningEndedIfNeeded(in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                                bufferedDelta += text
                                await flushBufferedDelta()
                            case let .reasoning(chunk):
                                self.appendReasoning(chunk, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                            case let .citations(citations):
                            self.recordCitations(citations, in: conversationID)
                            case let .imagePart(attachment):
                                await self.handleStreamingImagePart(attachment, in: conversationID)
                            case let .toolCallDeltas(calls):
                                self.recordUnhandledToolCalls(calls, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID, provider: provider, model: model)
                            case let .activity(activity):
                                // Land the preamble tail in the buffer into the session first: otherwise it waits for the next event to flush, leaving half a sentence missing on screen during the search,
                                // and a late flush would clear the just-set activity as if it were "the next body segment".
                                await flushBufferedDelta(force: true)
                                self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                            case let .finish(finish):
                                self.recordStreamFinish(finish, in: conversationID, sendTaskID: sendTaskID)
                            case let .done(result):
                                await flushBufferedDelta(force: true)
                                await MainActor.run {
                                    self.reconcileStreamingText(
                                        with: result.text,
                                        in: conversationID,
                                        messageID: assistantMessageID,
                                        expectedSendTaskID: sendTaskID
                                    )
                                    self.completeStreamingMessage(
                                        conversationID: conversationID,
                                        messageID: assistantMessageID,
                                        expectedSendTaskID: sendTaskID,
                                        estimatedCost: self.resolvedDeliveredCost(from: result, model: model, providerKind: providerKind),
                                        state: .delivered,
                                        attachments: result.attachments,
                                        usageMetrics: ChatDeliveredUsageMetrics(result: result),
                                        streamFinish: result.finish
                                    )
                                }
                            }
                        }

                        if Task.isCancelled {
                            await flushBufferedDelta(force: true)
                            await MainActor.run {
                                self.completeStreamingMessage(
                                    conversationID: conversationID,
                                    messageID: assistantMessageID,
                                    expectedSendTaskID: sendTaskID,
                                    state: .interrupted
                                )
                            }
                        }
                    }

                case .anthropic:
                    let stream = anthropicService.sendMessageStream(
                        apiKey: apiKey,
                        modelID: resolvedModelID,
                        messages: transport.messages,
                        reasoningMode: capabilitySelection.reasoningMode,
                        webSearchEnabled: capabilitySelection.webSearchEnabled,
                        requestOptions: transport.options
                    )

                    self.clearStreamFinish(in: conversationID, sendTaskID: sendTaskID)
                    for try await event in stream {
                        if Task.isCancelled { break }

                        switch event {
                        case let .delta(text):
                            self.markReasoningEndedIfNeeded(in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                            bufferedDelta += text
                            await flushBufferedDelta()
                        case let .reasoning(chunk):
                            self.appendReasoning(chunk, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                        case let .citations(citations):
                            self.recordCitations(citations, in: conversationID)
                        case let .imagePart(attachment):
                            // The current Anthropic stream implementation never yields this case (StreamEvent is a shared enum);
                            // it goes through handleStreamingImagePart here to stay consistent with the other providers:
                            // if Claude supports image output in the future, the URL download / base64 decode / pendingImageData write paths are already aligned
                            await self.handleStreamingImagePart(attachment, in: conversationID)
                        case let .toolCallDeltas(calls):
                            self.recordUnhandledToolCalls(calls, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID, provider: provider, model: model)
                        case let .activity(activity):
                            // Land the preamble tail in the buffer into the session first: otherwise it waits for the next event to flush, leaving half a sentence missing on screen during the search,
                            // and a late flush would clear the just-set activity as if it were "the next body segment".
                            await flushBufferedDelta(force: true)
                            self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                        case let .finish(finish):
                            self.recordStreamFinish(finish, in: conversationID, sendTaskID: sendTaskID)
                        case let .done(result):
                            await flushBufferedDelta(force: true)
                            let deliveredCost = self.resolvedDeliveredCost(from: result, model: model, providerKind: providerKind)
                            await MainActor.run {
                                self.reconcileStreamingText(
                                    with: result.text,
                                    in: conversationID,
                                    messageID: assistantMessageID,
                                    expectedSendTaskID: sendTaskID
                                )
                                self.completeStreamingMessage(
                                    conversationID: conversationID,
                                    messageID: assistantMessageID,
                                    expectedSendTaskID: sendTaskID,
                                    estimatedCost: deliveredCost,
                                    state: .delivered,
                                    attachments: result.attachments,
                                    usageMetrics: ChatDeliveredUsageMetrics(result: result),
                                    streamFinish: result.finish
                                )
                            }
                        }
                    }

                    if Task.isCancelled {
                        await flushBufferedDelta(force: true)
                        await MainActor.run {
                            self.completeStreamingMessage(
                                conversationID: conversationID,
                                messageID: assistantMessageID,
                                expectedSendTaskID: sendTaskID,
                                state: .interrupted
                            )
                        }
                    }

                case .groq:
                    let stream = groqService.sendMessageStream(
                        apiKey: apiKey,
                        modelID: resolvedModelID,
                        messages: transport.messages,
                        reasoningMode: capabilitySelection.reasoningMode,
                        requestOptions: transport.options
                    )

                    self.clearStreamFinish(in: conversationID, sendTaskID: sendTaskID)
                    for try await event in stream {
                        if Task.isCancelled { break }

                        switch event {
                        case let .delta(text):
                            self.markReasoningEndedIfNeeded(in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                            bufferedDelta += text
                            await flushBufferedDelta()
                        case let .reasoning(chunk):
                            self.appendReasoning(chunk, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                        case let .citations(citations):
                            self.recordCitations(citations, in: conversationID)
                        case .imagePart:
                            break
                        case let .toolCallDeltas(calls):
                            self.recordUnhandledToolCalls(calls, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID, provider: provider, model: model)
                        case let .activity(activity):
                            // Land the preamble tail in the buffer into the session first: otherwise it waits for the next event to flush, leaving half a sentence missing on screen during the search,
                            // and a late flush would clear the just-set activity as if it were "the next body segment".
                            await flushBufferedDelta(force: true)
                            self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                        case let .finish(finish):
                            self.recordStreamFinish(finish, in: conversationID, sendTaskID: sendTaskID)
                        case let .done(result):
                            await flushBufferedDelta(force: true)
                            await MainActor.run {
                                self.reconcileStreamingText(
                                    with: result.text,
                                    in: conversationID,
                                    messageID: assistantMessageID,
                                    expectedSendTaskID: sendTaskID
                                )
                                self.completeStreamingMessage(
                                    conversationID: conversationID,
                                    messageID: assistantMessageID,
                                    expectedSendTaskID: sendTaskID,
                                    estimatedCost: self.resolvedDeliveredCost(from: result, model: model, providerKind: providerKind),
                                    state: .delivered,
                                    attachments: result.attachments,
                                    usageMetrics: ChatDeliveredUsageMetrics(result: result),
                                    streamFinish: result.finish
                                )
                            }
                        }
                    }

                    if Task.isCancelled {
                        await flushBufferedDelta(force: true)
                        await MainActor.run {
                            self.completeStreamingMessage(
                                conversationID: conversationID,
                                messageID: assistantMessageID,
                                expectedSendTaskID: sendTaskID,
                                state: .interrupted
                            )
                        }
                    }

                case .together:
                    let stream = togetherService.sendMessageStream(
                            apiKey: apiKey,
                            modelID: resolvedModelID,
                            messages: transport.messages,
                            baseURL: baseURLText,
                            reasoningMode: capabilitySelection.reasoningMode,
                            requestOptions: transport.options
                        )

                        self.clearStreamFinish(in: conversationID, sendTaskID: sendTaskID)
                        for try await event in stream {
                            if Task.isCancelled { break }

                            switch event {
                            case let .delta(text):
                                self.markReasoningEndedIfNeeded(in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                                bufferedDelta += text
                                await flushBufferedDelta()
                            case let .reasoning(chunk):
                                self.appendReasoning(chunk, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                            case let .citations(citations):
                                self.recordCitations(citations, in: conversationID)
                            case .imagePart:
                                break
                            case let .toolCallDeltas(calls):
                                self.recordUnhandledToolCalls(calls, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID, provider: provider, model: model)
                            case let .activity(activity):
                                // Land the preamble tail in the buffer into the session first: otherwise it waits for the next event to flush, leaving half a sentence missing on screen during the search,
                                // and a late flush would clear the just-set activity as if it were "the next body segment".
                                await flushBufferedDelta(force: true)
                                self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                            case let .finish(finish):
                                self.recordStreamFinish(finish, in: conversationID, sendTaskID: sendTaskID)
                            case let .done(result):
                                await flushBufferedDelta(force: true)
                                await MainActor.run {
                                    self.reconcileStreamingText(
                                        with: result.text,
                                        in: conversationID,
                                        messageID: assistantMessageID,
                                        expectedSendTaskID: sendTaskID
                                    )
                                    self.completeStreamingMessage(
                                        conversationID: conversationID,
                                        messageID: assistantMessageID,
                                        expectedSendTaskID: sendTaskID,
                                        estimatedCost: self.resolvedDeliveredCost(from: result, model: model, providerKind: providerKind),
                                        state: .delivered,
                                        attachments: result.attachments,
                                        usageMetrics: ChatDeliveredUsageMetrics(result: result),
                                        streamFinish: result.finish
                                    )
                                }
                            }
                        }

                        if Task.isCancelled {
                            await flushBufferedDelta(force: true)
                            await MainActor.run {
                                self.completeStreamingMessage(
                                    conversationID: conversationID,
                                    messageID: assistantMessageID,
                                    expectedSendTaskID: sendTaskID,
                                    state: .interrupted
                                )
                            }
                        }

                case .fireworks:
                    let stream = fireworksService.sendMessageStream(
                        apiKey: apiKey,
                        modelID: resolvedModelID,
                        messages: transport.messages,
                        reasoningMode: capabilitySelection.reasoningMode,
                        requestOptions: transport.options
                    )

                    self.clearStreamFinish(in: conversationID, sendTaskID: sendTaskID)
                    for try await event in stream {
                        if Task.isCancelled { break }

                        switch event {
                        case let .delta(text):
                            self.markReasoningEndedIfNeeded(in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                            bufferedDelta += text
                            await flushBufferedDelta()
                        case let .reasoning(chunk):
                            self.appendReasoning(chunk, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                        case let .citations(citations):
                            self.recordCitations(citations, in: conversationID)
                        case .imagePart:
                            break
                        case let .toolCallDeltas(calls):
                            self.recordUnhandledToolCalls(calls, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID, provider: provider, model: model)
                        case let .activity(activity):
                            // Land the preamble tail in the buffer into the session first: otherwise it waits for the next event to flush, leaving half a sentence missing on screen during the search,
                            // and a late flush would clear the just-set activity as if it were "the next body segment".
                            await flushBufferedDelta(force: true)
                            self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                        case let .finish(finish):
                            self.recordStreamFinish(finish, in: conversationID, sendTaskID: sendTaskID)
                        case let .done(result):
                            await flushBufferedDelta(force: true)
                            await MainActor.run {
                                self.reconcileStreamingText(
                                    with: result.text,
                                    in: conversationID,
                                    messageID: assistantMessageID,
                                    expectedSendTaskID: sendTaskID
                                )
                                self.completeStreamingMessage(
                                    conversationID: conversationID,
                                    messageID: assistantMessageID,
                                    expectedSendTaskID: sendTaskID,
                                    estimatedCost: self.resolvedDeliveredCost(from: result, model: model, providerKind: providerKind),
                                    state: .delivered,
                                    attachments: result.attachments,
                                    usageMetrics: ChatDeliveredUsageMetrics(result: result),
                                    streamFinish: result.finish
                                )
                            }
                        }
                    }

                    if Task.isCancelled {
                        await flushBufferedDelta(force: true)
                        await MainActor.run {
                            self.completeStreamingMessage(
                                conversationID: conversationID,
                                messageID: assistantMessageID,
                                expectedSendTaskID: sendTaskID,
                                state: .interrupted
                            )
                        }
                    }

                case .miniMax:
                    if providerSpecificImageRoute == .minimaxImageGeneration {
                        let transport = imageGeneration.transportInput(requestOptions)
                        let result = try await miniMaxService.sendMessage(
                            apiKey: apiKey,
                            modelID: resolvedModelID,
                            messages: transport.messages,
                            baseURL: baseURLText,
                            requestOptions: transport.options
                        )
                        await self.preDownloadImageAttachments(result.attachments, in: conversationID)
                        await MainActor.run {
                            self.applyNonStreamingCompletionIfCurrent(
                                taskID: sendTaskID,
                                conversationID: conversationID,
                                messageID: assistantMessageID,
                                result: result,
                                estimatedCost: self.resolvedDeliveredCost(from: result, model: model, providerKind: providerKind),
                                usageMetrics: ChatDeliveredUsageMetrics(result: result)
                            )
                        }
                    } else {
                        let stream = miniMaxService.sendMessageStream(
                            apiKey: apiKey,
                            modelID: resolvedModelID,
                            messages: transport.messages,
                            baseURL: baseURLText,
                            reasoningMode: capabilitySelection.reasoningMode,
                            requestOptions: transport.options
                        )

                        self.clearStreamFinish(in: conversationID, sendTaskID: sendTaskID)
                        for try await event in stream {
                            if Task.isCancelled { break }

                            switch event {
                            case let .delta(text):
                                self.markReasoningEndedIfNeeded(in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                                bufferedDelta += text
                                await flushBufferedDelta()
                            case let .reasoning(chunk):
                                self.appendReasoning(chunk, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                            case let .citations(citations):
                            self.recordCitations(citations, in: conversationID)
                            case .imagePart:
                                break
                            case let .toolCallDeltas(calls):
                                self.recordUnhandledToolCalls(calls, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID, provider: provider, model: model)
                            case let .activity(activity):
                                // Land the preamble tail in the buffer into the session first: otherwise it waits for the next event to flush, leaving half a sentence missing on screen during the search,
                                // and a late flush would clear the just-set activity as if it were "the next body segment".
                                await flushBufferedDelta(force: true)
                                self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                            case let .finish(finish):
                                self.recordStreamFinish(finish, in: conversationID, sendTaskID: sendTaskID)
                            case let .done(result):
                                await flushBufferedDelta(force: true)
                                await MainActor.run {
                                    self.reconcileStreamingText(
                                        with: result.text,
                                        in: conversationID,
                                        messageID: assistantMessageID,
                                        expectedSendTaskID: sendTaskID
                                    )
                                    self.completeStreamingMessage(
                                        conversationID: conversationID,
                                        messageID: assistantMessageID,
                                        expectedSendTaskID: sendTaskID,
                                        estimatedCost: self.resolvedDeliveredCost(from: result, model: model, providerKind: providerKind),
                                        state: .delivered,
                                        attachments: result.attachments,
                                        usageMetrics: ChatDeliveredUsageMetrics(result: result),
                                        streamFinish: result.finish
                                    )
                                }
                            }
                        }

                        if Task.isCancelled {
                            await flushBufferedDelta(force: true)
                            await MainActor.run {
                                self.completeStreamingMessage(
                                    conversationID: conversationID,
                                    messageID: assistantMessageID,
                                    expectedSendTaskID: sendTaskID,
                                    state: .interrupted
                                )
                            }
                        }
                    }

                case .zhipu:
                    let stream = zhipuService.sendMessageStream(
                            apiKey: apiKey,
                            modelID: resolvedModelID,
                            messages: transport.messages,
                            baseURL: baseURLText,
                            reasoningMode: capabilitySelection.reasoningMode,
                            webSearchEnabled: capabilitySelection.webSearchEnabled,
                            requestOptions: transport.options
                        )

                        self.clearStreamFinish(in: conversationID, sendTaskID: sendTaskID)
                        for try await event in stream {
                            if Task.isCancelled { break }

                            switch event {
                            case let .delta(text):
                                self.markReasoningEndedIfNeeded(in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                                bufferedDelta += text
                                await flushBufferedDelta()
                            case let .reasoning(chunk):
                                self.appendReasoning(chunk, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                            case let .citations(citations):
                            self.recordCitations(citations, in: conversationID)
                            case .imagePart:
                                break
                            case let .toolCallDeltas(calls):
                                self.recordUnhandledToolCalls(calls, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID, provider: provider, model: model)
                            case let .activity(activity):
                                // Land the preamble tail in the buffer into the session first: otherwise it waits for the next event to flush, leaving half a sentence missing on screen during the search,
                                // and a late flush would clear the just-set activity as if it were "the next body segment".
                                await flushBufferedDelta(force: true)
                                self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                            case let .finish(finish):
                                self.recordStreamFinish(finish, in: conversationID, sendTaskID: sendTaskID)
                            case let .done(result):
                                await flushBufferedDelta(force: true)
                                await MainActor.run {
                                    self.reconcileStreamingText(
                                        with: result.text,
                                        in: conversationID,
                                        messageID: assistantMessageID,
                                        expectedSendTaskID: sendTaskID
                                    )
                                    self.completeStreamingMessage(
                                        conversationID: conversationID,
                                        messageID: assistantMessageID,
                                        expectedSendTaskID: sendTaskID,
                                        estimatedCost: self.resolvedDeliveredCost(from: result, model: model, providerKind: providerKind),
                                        state: .delivered,
                                        attachments: result.attachments,
                                        usageMetrics: ChatDeliveredUsageMetrics(result: result),
                                        streamFinish: result.finish
                                    )
                                }
                            }
                        }

                        if Task.isCancelled {
                            await flushBufferedDelta(force: true)
                            await MainActor.run {
                                self.completeStreamingMessage(
                                    conversationID: conversationID,
                                    messageID: assistantMessageID,
                                    expectedSendTaskID: sendTaskID,
                                    state: .interrupted
                                )
                            }
                        }

                case .qwen:
                    if providerSpecificImageRoute == .dashscopeMultimodal {
                        let transport = imageGeneration.transportInput(requestOptions)
                        let result = try await qwenService.sendMessage(
                            apiKey: apiKey,
                            modelID: resolvedModelID,
                            messages: transport.messages,
                            baseURL: baseURLText,
                            requestOptions: transport.options
                        )
                        await self.preDownloadImageAttachments(result.attachments, in: conversationID)
                        await MainActor.run {
                            self.applyNonStreamingCompletionIfCurrent(
                                taskID: sendTaskID,
                                conversationID: conversationID,
                                messageID: assistantMessageID,
                                result: result,
                                estimatedCost: self.resolvedDeliveredCost(from: result, model: model, providerKind: providerKind),
                                usageMetrics: ChatDeliveredUsageMetrics(result: result)
                            )
                        }
                    } else {
                        let stream = qwenService.sendMessageStream(
                            apiKey: apiKey,
                            modelID: resolvedModelID,
                            messages: transport.messages,
                            baseURL: baseURLText,
                            reasoningMode: capabilitySelection.reasoningMode,
                            webSearchEnabled: capabilitySelection.webSearchEnabled,
                            requestOptions: transport.options
                        )

                        self.clearStreamFinish(in: conversationID, sendTaskID: sendTaskID)
                        for try await event in stream {
                            if Task.isCancelled { break }

                            switch event {
                            case let .delta(text):
                                self.markReasoningEndedIfNeeded(in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                                bufferedDelta += text
                                await flushBufferedDelta()
                            case let .reasoning(chunk):
                                self.appendReasoning(chunk, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                            case let .citations(citations):
                            self.recordCitations(citations, in: conversationID)
                            case .imagePart:
                                break
                            case let .toolCallDeltas(calls):
                                self.recordUnhandledToolCalls(calls, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID, provider: provider, model: model)
                            case let .activity(activity):
                                // Land the preamble tail in the buffer into the session first: otherwise it waits for the next event to flush, leaving half a sentence missing on screen during the search,
                                // and a late flush would clear the just-set activity as if it were "the next body segment".
                                await flushBufferedDelta(force: true)
                                self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                            case let .finish(finish):
                                self.recordStreamFinish(finish, in: conversationID, sendTaskID: sendTaskID)
                            case let .done(result):
                                await flushBufferedDelta(force: true)
                                await MainActor.run {
                                    self.reconcileStreamingText(
                                        with: result.text,
                                        in: conversationID,
                                        messageID: assistantMessageID,
                                        expectedSendTaskID: sendTaskID
                                    )
                                    self.completeStreamingMessage(
                                        conversationID: conversationID,
                                        messageID: assistantMessageID,
                                        expectedSendTaskID: sendTaskID,
                                        estimatedCost: self.resolvedDeliveredCost(from: result, model: model, providerKind: providerKind),
                                        state: .delivered,
                                        attachments: result.attachments,
                                        usageMetrics: ChatDeliveredUsageMetrics(result: result),
                                        streamFinish: result.finish
                                    )
                                }
                            }
                        }

                        if Task.isCancelled {
                            await flushBufferedDelta(force: true)
                            await MainActor.run {
                                self.completeStreamingMessage(
                                    conversationID: conversationID,
                                    messageID: assistantMessageID,
                                    expectedSendTaskID: sendTaskID,
                                    state: .interrupted
                                )
                            }
                        }
                    }

                case .moonshot:
                    let stream = moonshotService.sendMessageStream(
                        apiKey: apiKey,
                        modelID: resolvedModelID,
                        messages: transport.messages,
                        baseURL: baseURLText,
                        reasoningMode: capabilitySelection.reasoningMode,
                        webSearchEnabled: capabilitySelection.webSearchEnabled,
                        requestOptions: transport.options
                    )

                    self.clearStreamFinish(in: conversationID, sendTaskID: sendTaskID)
                    for try await event in stream {
                        if Task.isCancelled { break }

                        switch event {
                        case let .delta(text):
                            self.markReasoningEndedIfNeeded(in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                            bufferedDelta += text
                            await flushBufferedDelta()
                        case let .reasoning(chunk):
                            self.appendReasoning(chunk, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                        case let .citations(citations):
                            self.recordCitations(citations, in: conversationID)
                        case .imagePart:
                            break
                        case let .toolCallDeltas(calls):
                            self.recordUnhandledToolCalls(calls, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID, provider: provider, model: model)
                        case let .activity(activity):
                            // Land the preamble tail in the buffer into the session first: otherwise it waits for the next event to flush, leaving half a sentence missing on screen during the search,
                            // and a late flush would clear the just-set activity as if it were "the next body segment".
                            await flushBufferedDelta(force: true)
                            self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                        case let .finish(finish):
                            self.recordStreamFinish(finish, in: conversationID, sendTaskID: sendTaskID)
                        case let .done(result):
                            await flushBufferedDelta(force: true)
                            await MainActor.run {
                                self.reconcileStreamingText(
                                    with: result.text,
                                    in: conversationID,
                                    messageID: assistantMessageID,
                                    expectedSendTaskID: sendTaskID
                                )
                                self.completeStreamingMessage(
                                    conversationID: conversationID,
                                    messageID: assistantMessageID,
                                    expectedSendTaskID: sendTaskID,
                                    estimatedCost: self.resolvedDeliveredCost(from: result, model: model, providerKind: providerKind),
                                    state: .delivered,
                                    attachments: result.attachments,
                                    servedModelID: result.servedModelID,
                                    reasoningText: result.reasoningText,
                                    usageMetrics: ChatDeliveredUsageMetrics(result: result),
                                    streamFinish: result.finish
                                )
                            }
                        }
                    }

                    if Task.isCancelled {
                        await flushBufferedDelta(force: true)
                        await MainActor.run {
                            self.completeStreamingMessage(
                                conversationID: conversationID,
                                messageID: assistantMessageID,
                                expectedSendTaskID: sendTaskID,
                                state: .interrupted
                            )
                        }
                    }

                case .siliconFlow:
                    let stream = siliconFlowService.sendMessageStream(
                            apiKey: apiKey,
                            modelID: resolvedModelID,
                            messages: transport.messages,
                            baseURL: baseURLText,
                            reasoningMode: capabilitySelection.reasoningMode,
                            requestOptions: transport.options
                        )

                        self.clearStreamFinish(in: conversationID, sendTaskID: sendTaskID)
                        for try await event in stream {
                            if Task.isCancelled { break }

                            switch event {
                            case let .delta(text):
                                self.markReasoningEndedIfNeeded(in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                                bufferedDelta += text
                                await flushBufferedDelta()
                            case let .reasoning(chunk):
                                self.appendReasoning(chunk, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                            case let .citations(citations):
                            self.recordCitations(citations, in: conversationID)
                            case .imagePart:
                                break
                            case let .toolCallDeltas(calls):
                                self.recordUnhandledToolCalls(calls, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID, provider: provider, model: model)
                            case let .activity(activity):
                                // Land the preamble tail in the buffer into the session first: otherwise it waits for the next event to flush, leaving half a sentence missing on screen during the search,
                                // and a late flush would clear the just-set activity as if it were "the next body segment".
                                await flushBufferedDelta(force: true)
                                self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                            case let .finish(finish):
                                self.recordStreamFinish(finish, in: conversationID, sendTaskID: sendTaskID)
                            case let .done(result):
                                await flushBufferedDelta(force: true)
                                await MainActor.run {
                                    self.reconcileStreamingText(
                                        with: result.text,
                                        in: conversationID,
                                        messageID: assistantMessageID,
                                        expectedSendTaskID: sendTaskID
                                    )
                                    self.completeStreamingMessage(
                                        conversationID: conversationID,
                                        messageID: assistantMessageID,
                                        expectedSendTaskID: sendTaskID,
                                        estimatedCost: self.resolvedDeliveredCost(from: result, model: model, providerKind: providerKind),
                                        state: .delivered,
                                        attachments: result.attachments,
                                        usageMetrics: ChatDeliveredUsageMetrics(result: result),
                                        streamFinish: result.finish
                                    )
                                }
                            }
                        }

                        if Task.isCancelled {
                            await flushBufferedDelta(force: true)
                            await MainActor.run {
                                self.completeStreamingMessage(
                                    conversationID: conversationID,
                                    messageID: assistantMessageID,
                                    expectedSendTaskID: sendTaskID,
                                    state: .interrupted
                                )
                            }
                        }

                case .relay:
                    guard var initialRelayRoute = protocolRoute else {
                        throw ProviderServiceError.invalidConfiguration(detail: "Relay provider missing base URL.")
                    }
                    // For a model not yet verified, the first send picks the protocol in the same candidate order as the lazy verification: when the connection is auto, effectiveTransport always lands on Chat,
                    // and a Claude-family model going through Chat to a group that only accepts Messages is rejected with "max_tokens required" (400 is not a route-level rejection and does not fall back).
                    if let first = await self.relayFirstSendTransport(
                        provider: provider, model: model, current: initialRelayRoute.transport,
                        attachments: transport.messages.flatMap { $0.attachments ?? [] }
                    ) {
                        var firstModel = model
                        firstModel.relayTransport = first
                        if case let .byProtocol(rerouted) = ProviderServiceRouter.route(provider: provider, model: firstModel) {
                            initialRelayRoute = rerouted
                            // On a successful ending it is written back the same way as a protocol fallback: the first-send protocol is remembered as observed ("remember after sending").
                            self.sessions[conversationID]?.relayDeliveryRoute?.switchedTo = first
                        }
                    }
                    // Before going out, the level is settled to the nearest tier by the relay negative cache; if the tier is rejected within this send, it is changed and resent once.
                    var relayReasoningMode = RelayReasoningTier.outboundMode(
                        provider: provider, model: model, transport: initialRelayRoute.transport,
                        selected: capabilitySelection.reasoningMode
                    )
                    var relayTierRetryError: (any Error)?
                    // Protocols whose fragment was rejected with 400 / 422 and resent without it; if the resend fails again, this original error is reported.
                    var relayWebStripped: Set<RelayTransport> = []
                    var relayWebRetryError: (any Error)?
                    // One relay send attempt. The outer protocol fallback may switch protocol and call it once more;
                    // the inner native-file fallback (NativeFileFallback) goes by the original protocol first in each attempt.
                    @MainActor func sendRelayAttempt(_ route: ProviderServiceRouter.ProtocolRoute) async throws {
                        let relayBaseURL = route.baseURL
                        // Injection point: the protocol and root address are resolved per model, and the service only reads this copy.
                        let relayTransport = route.transport
                        let relayRequested = route.requested
                        var relayRequestOptions = requestOptions
                        relayRequestOptions.relayRequested = relayRequested
                        // The image prompt of a relay image generation uses the user's original text without [D] / checkpoint.
                        // The images endpoint follows the same rule as official image generation: a single user = plan.imagePrompt + the attachments of the last user message;
                        // the Responses inline image tool and the Gemini image modality are still chat requests, with only the last user message swapped back to the original text.
                        let relayDispatchesImage = RelayRuntimeSupport.dispatchesImageGeneration(model: model)
                        let relayPlanned: PlannedChatRequest
                        if relayDispatchesImage, RelayRuntimeSupport.imageRoute(for: relayTransport) == .imagesEndpoint {
                            relayPlanned = imageGeneration
                        } else if relayDispatchesImage {
                            relayPlanned = planned.replacingLatestUserText(with: latestUserText)
                        } else {
                            relayPlanned = planned
                        }
                        if relayWebStripped.contains(relayTransport) {
                            relayRequestOptions.relayWebFragments?.raw[relayTransport.rawValue] = nil
                        }
                        let transport = relayPlanned.transportInput(relayRequestOptions)
                        if relayDispatchesImage {
                            self.sessions[conversationID]?.contextAttempt?.textBytes = Self.contextTextBytes(
                                systemPrompt: transport.options.systemPrompt, messages: transport.messages
                            )
                        }
                        // generationProfile is not assigned a second time here: it was already computed above by
                        // `GenerationParameterAvailability.profile(provider:model:)`,
                        // and the relay's `model.generationProfile` is always nil (the model is built from engineProfile without a transport),
                        // so overwriting would knock a correctly computed profile back to nil and lose every value set on the panel.

                        // Image generation is routed statically by transport (derived from `RelayRuntimeSupport.imageRoute`)
                        // - inlineResponsesTool (Codex style, such as ylsagi/packy-codex/code-for)
                        //   -> goes through /responses with an image_generation tool attached and stream=true forced;
                        //   if the current model is a dedicated image model (gpt-image-*), a chat driver is picked automatically as the main model and the current model becomes tool.model
                        // - imagesEndpoint (New API style, chat_completions transport) -> goes through the standalone /images/generations
                        // - geminiModality (Gemini transport) -> falls into the transport dispatch below, so Gemini uses responseModalities
                        // - unsupported (Anthropic transport) -> a friendly error that guides the user to switch transport
                        if providerKind == .relay, RelayRuntimeSupport.dispatchesImageGeneration(model: model) {
                            let imageRoute = RelayRuntimeSupport.imageRoute(for: relayTransport)
                            switch imageRoute {
                            case .unsupported:
                                throw ProviderServiceError.invalidConfiguration(
                                    detail: L10n.tr("Image generation is not available on this protocol. Open Providers → this connection → this model → Advanced and set Protocol to OpenAI Responses or Chat Completions.", table: .providers)
                                )

                            case .imagesEndpoint:
                                #if DEBUG
                                print("[ImageGen][Relay] route=imagesEndpoint provider=\(provider.id) model=\(resolvedModelID)")
                                #endif
                                let result = try await openAIService.sendMessageViaImagesAPIForRelay(
                                    apiKey: apiKey,
                                    modelID: resolvedModelID,
                                    messages: transport.messages,
                                    baseURL: relayBaseURL,
                                    relayRequested: relayRequested
                                )
                                // Completes the Usage Insights statistics chain (aligned with the image paths of OpenRouter / direct OpenAI)
                                await MainActor.run {
                                    self.applyNonStreamingCompletionIfCurrent(
                                        taskID: sendTaskID,
                                        conversationID: conversationID,
                                        messageID: assistantMessageID,
                                        result: result,
                                        estimatedCost: self.resolvedDeliveredCost(from: result, model: model, providerKind: providerKind),
                                        servedModelID: result.servedModelID,
                                        usageMetrics: ChatDeliveredUsageMetrics(result: result)
                                    )
                                }
                                break

                            case .inlineResponsesTool:
                                // Deriving the main model / tool.model:
                                //  - current is a chat model: main model = current, tool.model = nil (the upstream default image model)
                                //  - current is gpt-image-*: pickChatDriverModelID picks a chat driver as the main model, and the current model becomes tool.model
                                //  - no chat driver found: throw a friendly error asking the user to add a chat model first
                                // The request is sent with the effective key of the image model; with two or more keys, the driver model prefers one bound to the same key.
                                let driverKeyIDs = RelayKeyBinding.keyIDs(provider)
                                let driverResult = driverKeyIDs.count >= 2
                                    ? RelayRuntimeSupport.pickChatDriverModelID(
                                        in: provider,
                                        currentModel: model,
                                        currentKeyID: RelayKeyBinding.effectiveKeyID(provider: provider, modelID: model.id),
                                        keyID: { RelayKeyBinding.effectiveKeyID(provider: provider, modelID: $0.id) }
                                    )
                                    : RelayRuntimeSupport.pickChatDriverModelID(
                                        in: provider,
                                        currentModel: model
                                    )
                                let driverModelID: String
                                switch driverResult {
                                case let .success(id):
                                    driverModelID = id
                                case .failure(.missingChatDriverModel):
                                    throw ProviderServiceError.invalidConfiguration(
                                        detail: L10n.tr("Please add a chat model to this relay before using image generation.", table: .providers)
                                    )
                                }
                                let imageToolID: String? = (driverModelID == resolvedModelID)
                                    ? nil
                                    : resolvedModelID
                                #if DEBUG
                                print("[ImageGen][Relay] route=inlineResponsesTool driver=\(driverModelID) tool=\(imageToolID ?? "<default>")")
                                #endif
                                let stream = openAIService.sendMessageStream(
                                    apiKey: apiKey,
                                    modelID: driverModelID,
                                    messages: transport.messages,
                                    baseURL: relayBaseURL,
                                    reasoningMode: relayReasoningMode,
                                    requestOptions: transport.options,
                                    relayRequested: relayRequested,
                                    webSearchEnabled: capabilitySelection.webSearchEnabled,
                                    supportsImageGeneration: true,
                                    imageToolModelID: imageToolID
                                )
                                self.clearStreamFinish(in: conversationID, sendTaskID: sendTaskID)
                                for try await event in stream {
                                    if Task.isCancelled { break }
                                    switch event {
                                    case let .delta(text):
                                        self.markReasoningEndedIfNeeded(in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                                        bufferedDelta += text
                                        await flushBufferedDelta()
                                    case let .reasoning(chunk):
                                        self.appendReasoning(chunk, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                                    case let .citations(citations):
                                self.recordCitations(citations, in: conversationID)
                                    case let .imagePart(attachment):
                                        await self.handleStreamingImagePart(attachment, in: conversationID)
                                    case let .toolCallDeltas(calls):
                                        self.recordUnhandledToolCalls(calls, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID, provider: provider, model: model)
                                    case let .activity(activity):
                                        // Land the preamble tail in the buffer into the session first: otherwise it waits for the next event to flush, leaving half a sentence missing on screen during the search,
                                        // and a late flush would clear the just-set activity as if it were "the next body segment".
                                        await flushBufferedDelta(force: true)
                                        self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                                    case let .finish(finish):
                                        self.recordStreamFinish(finish, in: conversationID, sendTaskID: sendTaskID)
                                    case let .done(result):
                                        await flushBufferedDelta(force: true)
                                        let deliveredCost = self.resolvedDeliveredCost(from: result, model: model, providerKind: providerKind)
                                        await MainActor.run {
                                            self.reconcileStreamingText(
                                                with: result.text,
                                                in: conversationID,
                                                messageID: assistantMessageID,
                                                expectedSendTaskID: sendTaskID
                                            )
                                            self.completeStreamingMessage(
                                                conversationID: conversationID,
                                                messageID: assistantMessageID,
                                                expectedSendTaskID: sendTaskID,
                                                estimatedCost: deliveredCost,
                                                state: .delivered,
                                                attachments: result.attachments,
                                                servedModelID: result.servedModelID,
                                                usageMetrics: ChatDeliveredUsageMetrics(result: result),
                                                streamFinish: result.finish
                                            )
                                        }
                                    }
                                }
                                if Task.isCancelled {
                                    await flushBufferedDelta(force: true)
                                    await MainActor.run {
                                        self.completeStreamingMessage(
                                            conversationID: conversationID,
                                            messageID: assistantMessageID,
                                            expectedSendTaskID: sendTaskID,
                                            state: .interrupted
                                        )
                                    }
                                }
                                break

                            case .geminiModality:
                                // No pre-processing: let Gemini take the transport dispatch path below (supportsImageGen is passed along)
                                break
                            }

                            // Only inlineResponsesTool / imagesEndpoint need to end this attempt after entering this branch;
                            // geminiModality has to fall through to the dispatch below
                            if imageRoute != .geminiModality {
                                return
                            }
                        }

                        let useNonStreamingRelayRuntime =
                            relayRequested.stream == false

                        if useNonStreamingRelayRuntime {
                            let result = try await services.protocolSend(
                                route,
                                apiKey: apiKey,
                                modelID: resolvedModelID,
                                messages: transport.messages,
                                reasoningMode: relayReasoningMode,
                                webSearchEnabled: capabilitySelection.webSearchEnabled,
                                supportsImageGen: RelayRuntimeSupport.dispatchesImageGeneration(model: model),
                                requestOptions: transport.options
                            )

                            let deliveredCost = self.resolvedDeliveredCost(from: result, model: model, providerKind: providerKind)
                            await MainActor.run {
                                self.applyNonStreamingCompletionIfCurrent(
                                    taskID: sendTaskID,
                                    conversationID: conversationID,
                                    messageID: assistantMessageID,
                                    result: result,
                                    estimatedCost: deliveredCost,
                                    servedModelID: result.servedModelID,
                                    usageMetrics: ChatDeliveredUsageMetrics(result: result),
                                    provider: provider,
                                    model: model
                                )
                            }
                        } else {
                            let stream = services.protocolStream(
                                route,
                                apiKey: apiKey,
                                modelID: resolvedModelID,
                                messages: transport.messages,
                                reasoningMode: relayReasoningMode,
                                webSearchEnabled: capabilitySelection.webSearchEnabled,
                                supportsImageGen: RelayRuntimeSupport.dispatchesImageGeneration(model: model),
                                requestOptions: transport.options
                            )

                            self.clearStreamFinish(in: conversationID, sendTaskID: sendTaskID)
                            for try await event in stream {
                                if Task.isCancelled { break }

                                switch event {
                                case let .delta(text):
                                    self.markReasoningEndedIfNeeded(in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                                    bufferedDelta += text
                                    await flushBufferedDelta()
                                case let .reasoning(chunk):
                                    self.appendReasoning(chunk, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                                case let .citations(citations):
                                self.recordCitations(citations, in: conversationID)
                                case let .imagePart(attachment):
                                    await self.handleStreamingImagePart(attachment, in: conversationID)
                                case let .toolCallDeltas(calls):
                                    self.recordUnhandledToolCalls(calls, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID, provider: provider, model: model)
                                case let .activity(activity):
                                    // Land the preamble tail in the buffer into the session first: otherwise it waits for the next event to flush, leaving half a sentence missing on screen during the search,
                                    // and a late flush would clear the just-set activity as if it were "the next body segment".
                                    await flushBufferedDelta(force: true)
                                    self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                                case let .finish(finish):
                                    self.recordStreamFinish(finish, in: conversationID, sendTaskID: sendTaskID)
                                case let .done(result):
                                    await flushBufferedDelta(force: true)
                                    let deliveredCost = self.resolvedDeliveredCost(from: result, model: model, providerKind: providerKind)
                                    await MainActor.run {
                                        self.reconcileStreamingText(
                                            with: result.text,
                                            in: conversationID,
                                            messageID: assistantMessageID,
                                            expectedSendTaskID: sendTaskID
                                        )
                                        self.completeStreamingMessage(
                                            conversationID: conversationID,
                                            messageID: assistantMessageID,
                                            expectedSendTaskID: sendTaskID,
                                            estimatedCost: deliveredCost,
                                            state: .delivered,
                                            attachments: result.attachments,
                                            servedModelID: result.servedModelID,
                                            usageMetrics: ChatDeliveredUsageMetrics(result: result),
                                            streamFinish: result.finish
                                        )
                                    }
                                }
                            }

                            if Task.isCancelled {
                                await flushBufferedDelta(force: true)
                                await MainActor.run {
                                    self.completeStreamingMessage(
                                        conversationID: conversationID,
                                        messageID: assistantMessageID,
                                        expectedSendTaskID: sendTaskID,
                                        state: .interrupted
                                    )
                                }
                            }
                        }
                    }

                    var relayRoute = initialRelayRoute
                    var relaySwitched = false
                    while true {
                        let recorder = RelayPreOutputRejection.Recorder()
                        do {
                            try await RelayPreOutputRejection.$current.withValue(recorder) {
                                try await NativeFileFallback.$firstAttemptProbe.withValue(relayFileProbe) {
                                    try await sendRelayAttempt(relayRoute)
                                }
                            }
                            relayAttempt = (relayRoute.transport, recorder.rejection, relaySwitched)
                            break
                        } catch {
                            relayAttempt = (relayRoute.transport, recorder.rejection, relaySwitched)
                            if !relaySwitched { relayFirstRejection = recorder.rejection }
                            // A route-level rejection before output, whose source is not the user and where this message has not switched yet: switch to the next protocol in the candidates and resend once.
                            // After a switch, a failure reports the second error and records no negative cache (the failure path looks at relayAttempt.switched).
                            let outputStarted = !bufferedDelta.isEmpty || self.relayOutputStarted(
                                conversationID: conversationID, messageID: assistantMessageID, initialText: initialText
                            )
                            // Judge this key first, then enter the capability rejection loop: no-access is recorded on the model, no negative cache is written,
                            // the protocol is not switched and the key is not swapped for a resend; an invalid / restricted key writes that key's state, and the rest proceed as before.
                            if !outputStarted, let rejection = recorder.rejection {
                                let access = RelayKeyAccess.classify(rejection)
                                if access != .none {
                                    self.appState.providerManager.recordRelayKeyAccessFailure(
                                        providerID: providerID, modelID: model.id,
                                        keyID: RelayKeyBinding.effectiveKeyID(provider: provider, modelID: model.id),
                                        outcome: access, httpStatus: rejection.status,
                                        sentIdentity: ProviderManager.relayKeyWriteIdentity(provider, modelID: model.id)
                                    )
                                }
                                if access == .modelAccessDenied {
                                    relayKeyAccessDenied = true
                                    throw relayTierRetryError ?? relayWebRetryError ?? error
                                }
                            }
                            // Tier rejected: record the negative cache and resend once at the nearest tier; if the resend also fails, report the original error.
                            if relayTierRetryError == nil, !Task.isCancelled,
                               let fallback = RelayReasoningTier.recordRejection(
                                   provider: provider, model: model, transport: relayRoute.transport,
                                   sent: relayReasoningMode, rejection: recorder.rejection, outputStarted: outputStarted
                               ) {
                                relayTierRetryError = error
                                relayReasoningMode = fallback ?? .automatic
                                continue
                            }
                            // Web fragment rejected: a fragment was carried, 400 / 422 before any output, and not a route-level rejection (no-access already failed directly above)
                            // -> resend once on the same protocol without the fragment; on delivery that protocol is recorded rejected / tested, and if it fails again the original error is reported and nothing is written.
                            if relayWebRetryError == nil, !Task.isCancelled, !outputStarted,
                               let rejection = recorder.rejection, [400, 422].contains(rejection.status),
                               !RelayProtocolFallback.isRouteRejection(rejection),
                               !relayWebStripped.contains(relayRoute.transport),
                               requestOptions.relayWebFragments?.object(for: relayRoute.transport) != nil {
                                relayWebRetryError = error
                                relayWebStripped.insert(relayRoute.transport)
                                self.sessions[conversationID]?.relayDeliveryRoute?.webStripped.insert(relayRoute.transport)
                                continue
                            }
                            guard !Task.isCancelled,
                                  let rejection = recorder.rejection,
                                  let next = await self.relayProtocolFallbackTarget(
                                      provider: provider, model: model, current: relayRoute.transport,
                                      rejection: rejection, outputStarted: outputStarted, alreadySwitched: relaySwitched,
                                      attachments: transport.messages.flatMap { $0.attachments ?? [] }
                                  ) else { throw relayTierRetryError ?? relayWebRetryError ?? error }
                            var switchedModel = model
                            switchedModel.relayTransport = next
                            guard case let .byProtocol(rerouted) = ProviderServiceRouter.route(
                                provider: provider, model: switchedModel
                            ) else { throw relayTierRetryError ?? relayWebRetryError ?? error }
                            relaySwitched = true
                            relayRoute = rerouted
                            // On a successful ending it is written back as observed with the switched protocol (the same write-back path as the "already used" upgrade).
                            self.sessions[conversationID]?.relayDeliveryRoute?.switchedTo = next
                            self.sessions[conversationID]?.relayDeliveryRoute?.protocolFallback = true
                        }
                    }

                }
                }
                }

                // First-leg ending of propose_memory: execute the calls, add a tail leg when needed, then land the successful ending.
                let proposeOutcome = try await self.finishProposeMemoryTurn(
                    conversationID: conversationID,
                    assistantMessageID: assistantMessageID,
                    sendTaskID: sendTaskID,
                    initialText: initialText,
                    provider: provider,
                    model: model,
                    accessToken: effectiveAPIKey,
                    resolvedModelID: resolvedModelID,
                    transport: transport,
                    reasoningMode: capabilitySelection.reasoningMode
                )
                if case let .plainResend(carried, searchRecall) = proposeOutcome {
                    // Thinking with an empty first-leg body: resend the original request once through the ordinary send pipeline without tools (keeping the web recipe and so on),
                    // reusing the same assistant message; no degradation is recorded and no fallback runs, and the candidate and suggestion strip built by the first leg are kept.
                    if let attempt = self.sessions[conversationID]?.contextAttempt {
                        self.settleContextLedger(attempt, stopReason: .stop, observedInput: nil, recordsSample: false)
                    }
                    self.sessions[conversationID]?.contextAttempt = nil
                    self.sessions[conversationID]?.proposeTurn = nil
                    self.queueAssistantResponse(
                        conversationID: conversationID,
                        assistantMessageID: assistantMessageID,
                        requestSnapshot: requestSnapshot,
                        provider: provider,
                        model: model,
                        capabilitySelection: capabilitySelection,
                        latestUserText: latestUserText,
                        appendsToExistingText: appendsToExistingText,
                        explicitContinuationMessageID: explicitContinuationMessageID,
                        localCustomFragmentDisposition: localCustomFragmentDisposition,
                        capabilityRecoveryDescriptor: capabilityRecoveryDescriptor,
                        attemptKind: attemptKind,
                        overflowFallbackB: overflowFallbackB,
                        overflowRetryCheckpoint: overflowRetryCheckpoint,
                        isProposeDegradeResend: true,
                        proposeCarriedDelivery: carried,
                        carriedSearchRecall: searchRecall
                    )
                    return
                }
                await MainActor.run {
                    self.appState.conversationManager.refreshConversationCost(for: conversationID)
                }
                }
                }
                }
            } catch {
                await flushBufferedDelta(force: true)
                // Capability execution facts and custom requests are privacy-sensitive once they cross the actual
                // dispatch boundary. Never attach provider/model/error/body-derived diagnostics
                // to the error report for that request.
                // This is already outside the TaskLocal scope of the tracker: `CapabilityExecutionRuntime.current` is nil,
                // and reading through it only yields "not sent, not rejected". The facts of this send are always read from the reference kept.
                let canRetryWithoutAdditionalBody = sendExecutionTracker?.canOfferRetryWithoutAdditionalBody ?? false
                let customSourceRejected = sendExecutionTracker?.hasRejectedSource(.custom) ?? false
                let terminalExecution = sendExecutionTracker?.terminalResult()
                let streamProviderError = error as? ProviderServiceError
                // propose_memory degradation: when the first leg carrying tools is deterministically rejected (before any text, no structured tool_calls seen)
                // -> record the degraded set and the tool capability memory, run the fallback this turn, and resend once without tools on the same assistant message. A no-access error is rethrown as is.
                if !Task.isCancelled,
                   let turn = self.proposeTurn(in: conversationID, sendTaskID: sendTaskID),
                   let session = self.sessions[conversationID],
                   MemoryPropose.degrade(
                       rejectionMatches: ToolUnsupportedErrorMatcher.matches(error),
                       legIndex: turn.pastFirstLeg ? 1 : 0,
                       streamStarted: Self.hasStreamedOutput(session),
                       receivedStructuredToolCalls: !turn.pendingCalls.isEmpty
                   ),
                   !self.recordRelayToolsRejectionKeyDenial(error, provider: provider, model: model) {
                    ProposeMemoryRuntime.shared.markDegraded(connectionID: provider.id, modelID: model.id)
                    self.rememberToolCallCapability(
                        provider: provider, model: model, toolCall: false, reason: .toolsRejected4xx,
                        statusCode: Self.toolRejectionStatusCode(error), sentTransport: relayAttempt?.transport
                    )
                    if let attempt = session.contextAttempt {
                        self.settleContextLedger(attempt, stopReason: .error, observedInput: nil, recordsSample: false)
                    }
                    self.sessions[conversationID]?.contextAttempt = nil
                    self.sessions[conversationID]?.proposeTurn = nil
                    turn.context?.onDegraded(turn.userMessageID, assistantMessageID)
                    self.queueAssistantResponse(
                        conversationID: conversationID,
                        assistantMessageID: assistantMessageID,
                        requestSnapshot: requestSnapshot,
                        provider: provider,
                        model: model,
                        capabilitySelection: capabilitySelection,
                        latestUserText: latestUserText,
                        appendsToExistingText: appendsToExistingText,
                        explicitContinuationMessageID: explicitContinuationMessageID,
                        localCustomFragmentDisposition: localCustomFragmentDisposition,
                        capabilityRecoveryDescriptor: capabilityRecoveryDescriptor,
                        attemptKind: attemptKind,
                        overflowFallbackB: overflowFallbackB,
                        overflowRetryCheckpoint: overflowRetryCheckpoint,
                        isProposeDegradeResend: true
                    )
                    return
                }
                // Context overflow: classify(this attempt's family, httpStatus, rawBody). Predicted P-hat < U yet overflowed -> raise rho and write it back;
                // no body text yet and this message has not been resent with the fallback -> record a manifest for this failure, then after the deterministic fallback resend automatically once on the same assistant message.
                // 401 / 429 / 5xx are judged by the classifier as not an overflow.
                var contextOverflowed = false
                if !Task.isCancelled,
                   self.sessions[conversationID]?.sendTaskID == sendTaskID,
                   let session = self.sessions[conversationID] {
                    let family = session.lastStreamFinish?.family
                        ?? Self.requestStopFamily(provider: provider, relayTransport: relayAttempt?.transport)
                    contextOverflowed = Self.isContextOverflow(
                        error: error,
                        diagnostics: failureDiagnostics.snapshot,
                        family: family,
                        streamFinish: session.lastStreamFinish,
                        answerStarted: Self.hasAnswerContent(session.text) && session.text != session.baselineText
                    )
                    if contextOverflowed, let attempt = session.contextAttempt {
                        if attempt.singleChatLeg, let pHat = attempt.estimatedInput, let U = attempt.U, pHat < U {
                            try? self.contextLedgerResolver(attempt.partitionUID)?
                                .recordRhoOverflowMiss(attempt.rhoKey)
                        }
                        // Output started = this attempt received a body, reasoning or image delta.
                        let outputStarted = (Self.hasAnswerContent(session.text) && session.text != session.baselineText)
                            || (Self.hasAnswerContent(session.reasoningText) && session.reasoningText != session.baselineReasoning)
                            || !session.pendingImageData.isEmpty
                            || !session.attachments.isEmpty
                        // If the fallback cannot produce a checkpoint (the tail start is empty), do not resend: sending it unchanged would only overflow again.
                        var fallbackProducesCheckpoint = false
                        // A chat send (not a continue / tool loop) is first compacted and persisted by the coordinator, and a resend reads that row if there is one;
                        // on noop it falls back to the in-memory fallback.
                        var overflowRow: ContextCheckpointRecord?
                        if overflowFallbackB == nil && !outputStarted {
                            let fallbackB = attempt.estimatedInput ?? 0
                            let oldSummary = self.fallbackOldSummary(
                                conversationID: conversationID, uid: partitionUID, snapshot: enrichedRequestSnapshot
                            )
                            // The trial assembly likewise does not run on the main thread.
                            let trial = await Task.detached(priority: .userInitiated) {
                                ChatRequestBuilder.build(
                                    from: enrichedRequestSnapshot,
                                    assembly: ChatRequestAssemblyContext(
                                        window: assemblyWindow,
                                        rhoHi: ContextLedgerStore.currentRhoHi(for: rhoKey, in: rhoLedger),
                                        overflowFallbackB: fallbackB,
                                        overflowCompactionInputs: true,
                                        fallbackOldSummary: oldSummary
                                    )
                                )
                            }.value
                            fallbackProducesCheckpoint = trial.tailFrom != nil
                            var isChatSendPath = false
                            if case .send = requestSnapshot.sendPath { isChatSendPath = true }
                            if isChatSendPath, attempt.purpose == .chat, let inputs = trial.compactionInputs {
                                overflowRow = await self.compactBeforeSend(
                                    conversationID: conversationID,
                                    uid: partitionUID,
                                    trigger: .overflow,
                                    inputs: inputs,
                                    connection: PendingCompactionConnection(
                                        provider: provider,
                                        model: model,
                                        modelID: resolvedModelID,
                                        window: assemblyWindow,
                                        prototype: requestSnapshot.messages.last
                                    )
                                )
                            }
                        }
                        if overflowRow != nil || fallbackProducesCheckpoint {
                            self.settleContextLedger(
                                attempt, stopReason: .contextWindowExceeded, observedInput: nil, recordsSample: false
                            )
                            self.sessions[conversationID]?.contextAttempt = nil
                            self.queueAssistantResponse(
                                conversationID: conversationID,
                                assistantMessageID: assistantMessageID,
                                requestSnapshot: requestSnapshot,
                                provider: provider,
                                model: model,
                                capabilitySelection: capabilitySelection,
                                latestUserText: latestUserText,
                                appendsToExistingText: appendsToExistingText,
                                explicitContinuationMessageID: explicitContinuationMessageID,
                                localCustomFragmentDisposition: localCustomFragmentDisposition,
                                capabilityRecoveryDescriptor: capabilityRecoveryDescriptor,
                                attemptKind: attemptKind,
                                overflowFallbackB: attempt.estimatedInput ?? 0,
                                overflowRetryCheckpoint: overflowRow
                            )
                            return
                        }
                    }
                }
                let overflowStopReason: StopReason? = contextOverflowed ? .contextWindowExceeded : nil
                // Subscription 426: the client version headers in the local metadata snapshot are below what
                // the provider accepts. The snapshot is only refreshed in the background once a day, so wait
                // for a refresh before the failure card lands; one tap on Retry then sends the current values.
                if !Task.isCancelled,
                   streamProviderError?.subscriptionClientVersionRejectionLane != nil {
                    await self.subscriptionConfigurationRefresher()
                }

                await MainActor.run {
                    if Task.isCancelled {
                        self.completeStreamingMessage(
                            conversationID: conversationID,
                            messageID: assistantMessageID,
                            expectedSendTaskID: sendTaskID,
                            state: .interrupted
                        )
                    } else {
                        let providerError = self.appState.providerManager.providerServiceError(from: error)
                        var recoveryPrimaryAction: String?
                        // A relay image send rejected before any output, image recognition unknown at send time, and the protocol not switched for this message:
                        // record the image negative cache (the entry is hidden accordingly), and the recovery card of the failed message shows "images not supported" + Switch Model.
                        // Images get no text fallback and no automatic resend.
                        if providerKind == .relay, !relayKeyAccessDenied, let attempt = relayAttempt,
                           planned.messages.contains(where: { $0.attachments?.contains(where: { $0.kind == .image }) == true }),
                           RelayRejectionRecording.recordImageRejection(
                               provider: provider, model: model,
                               transport: attempt.transport, rejection: attempt.rejection,
                               outputStarted: self.relayOutputStarted(
                                   conversationID: conversationID, messageID: assistantMessageID, initialText: initialText
                               ),
                               protocolSwitched: attempt.switched
                           ) {
                            recoveryPrimaryAction = relayImageUnsupportedRecoveryAction
                        }
                        // A relay request carrying native file blocks that is rejected the first time counts as a rejection signal; if the fallback chain (text resend / protocol fallback) still fails in the end
                        // or all files are scans that cannot fall back: the recovery card body becomes "these files are not supported" + Switch Model.
                        // The displayed error is unchanged; when the same message has already been judged as not accepting images, the image card takes precedence.
                        // If the attempt after a fallback or protocol switch had already started output and failed afterwards, the problem is not the files, so it is not applied.
                        if providerKind == .relay, !relayKeyAccessDenied,
                           recoveryPrimaryAction != relayImageUnsupportedRecoveryAction,
                           !self.relayOutputStarted(
                               conversationID: conversationID, messageID: assistantMessageID, initialText: initialText
                           ),
                           NativeFileFallback.marksRelayFileUnsupported(
                               isRelay: true,
                               firstAttemptCarriedNativeFiles: relayFileProbe.firstAttemptCarriedNativeFiles,
                               firstRejection: relayFirstRejection
                           ) {
                            recoveryPrimaryAction = relayFileUnsupportedRecoveryAction
                        }
                        // Only an invalid Key or a configuration error is a fatal problem that marks the provider as an issue;
                        // transient errors such as network jitter, rate limits and upstream faults must not change the provider status
                        let isFatalError = providerError.marksConnectionFailed
                        if isFatalError, var erroredProvider = self.appState.provider(for: providerID) {
                            erroredProvider.status = ProviderConnectionState.issue(providerError.messageKey)
                            erroredProvider.lastError = providerError.messageKey
                            self.appState.providerManager.updateProvider(erroredProvider)
                        }

                        let isCustomFieldError: Bool = {
                            if case .customFieldsRejected = providerError { return true }
                            // The remaining two internal invariants (duplicate owner, missing request context) are still configuration errors.
                            if case let .invalidConfiguration(detail) = providerError,
                               detail.hasPrefix("Rejected safe custom fragment:") {
                                return true
                            }
                            // Upstream custom recovery is never inferred from status/text. The
                            // production tracker exposes it only after a structured exact locator
                            // matched an actually applied custom pointer before any event/effect.
                            guard localCustomFragmentDisposition != .omitForExplicitRetry,
                                  customSourceRejected
                            else { return false }
                            return true
                        }()
                        let customFieldsRejection: CustomFieldsRejection? = {
                            if case let .customFieldsRejected(rejection) = providerError { return rejection }
                            return nil
                        }()
                        let isLocatedSettingRejection = terminalExecution?.states.values.contains(.rejected) == true
                        // Neither failure of the additional request body is a problem of the connection:
                        // a local rejection (the request was not sent) and "rejected by the upstream with 400 while carrying it". The latter offers
                        // "Retry without the additional request body" only under the recovery conditions, and a rejection already pinned to a specific setting takes the existing path first.
                        let additionalBodyRejection: AdditionalRequestBodyRejection? = {
                            if case let .additionalRequestBodyRejected(rejection) = providerError { return rejection }
                            return nil
                        }()
                        let offersRetryWithoutAdditionalBody = additionalBodyRejection == nil
                            && !isCustomFieldError && !isLocatedSettingRejection
                            && canRetryWithoutAdditionalBody
                        self.failStreamingMessage(
                            conversationID: conversationID,
                            messageID: assistantMessageID,
                            expectedSendTaskID: sendTaskID,
                            userFacingText: isLocatedSettingRejection
                                ? ""
                                : providerError.message,
                            estimatedCost: self.currentAssistantCost(
                                conversationID: conversationID,
                                messageID: assistantMessageID
                            ),
                            title: isCustomFieldError
                                ? "Custom request fields error"
                                : (isLocatedSettingRejection
                                    ? L10n.tr("Model control setting rejected", table: .chat)
                                    : (offersRetryWithoutAdditionalBody
                                        ? AdditionalRequestBody.upstreamRejectionTitleKey
                                        : providerError.titleKey)),
                            // The raw JSON or upstream response must never enter the error card,
                            // persistence, telemetry or diagnostics.  Keep only a stable safe code.
                            detail: isCustomFieldError
                                ? (customSourceRejected
                                    ? "model_control_setting_rejected"
                                    : customFieldsRejection?.safeCode ?? "custom_request_fields_rejected")
                                : (isLocatedSettingRejection
                                    ? "model_control_setting_rejected"
                                    : ChatFailurePresentation.persistedDetail(for: providerError)),
                            recoveryPrimaryAction: recoveryPrimaryAction,
                            terminalExecution: terminalExecution,
                            // Still overflowed after the fallback resend, or overflowed after body text started: overrides the error stopReason, the failure style is unchanged.
                            stopReason: overflowStopReason
                        )
                    }

                    self.appState.conversationManager.refreshConversationCost(for: conversationID)
                }
            }

            await MainActor.run {
                self.finishSendTaskIfCurrent(sendTaskID, conversationID: conversationID)
            }
        }

        // Fill the sendTask reference back into the matching session (serialized on the @MainActor)
        sessions[conversationID]?.sendTask = sendTask
    }

    // MARK: - Remote MCP

    /// The MCP tools available for this send. Empty when the connection cannot carry tools (known not to support them), the conversation has no server turned on,
    /// or reading the local store fails - all fall back to an ordinary send without tools, so an unreadable MCP configuration does not fail the whole message.
    private func prepareMcpToolPlan(conversationID: UUID, provider: Provider, model: AIModel) -> McpToolPlan {
        guard mcpToolAvailability(provider: provider, model: model).isAvailable else {
            return .empty
        }
        let uid = appState.sessionPartitionUID
        do {
            return try McpToolBridge.plan(
                conversationId: conversationID,
                store: try appState.mcpServerDirectory.store(for: uid),
                credentialStore: appState.mcpServerDirectory.credentialStore,
                uid: uid,
                runtimeConfig: mcpRuntimeConfigProvider()
            )
        } catch {
            return .empty
        }
    }

    private func makeMcpExecutor(
        conversationID: UUID,
        assistantMessageID: UUID,
        sendTaskID: UUID
    ) -> McpToolExecutor {
        let uid = appState.sessionPartitionUID
        // The loop only refreshes the token and does not sign in again (that would open a browser, which belongs to the UI flow). The authorizer is shared by the add flow and the management page
        // with this account's single authorizer: concurrent refreshes are serialized by it.
        let directory = appState.mcpServerDirectory
        let authorizer = directory.authorizer(for: uid)
        let credentialStore = directory.credentialStore
        let runtimeConfig = mcpRuntimeConfigProvider()
        let store = try? directory.store(for: uid)
        return McpToolExecutor(
            conversationId: conversationID,
            runtimeConfig: runtimeConfig,
            gate: mcpConfirmationGate ?? appState.mcpConfirmationCoordinator,
            reauthGate: mcpReauthorizationGate ?? appState.mcpReauthorizationCoordinator,
            tokenProvider: { serverId in
                try await authorizer.validAccessToken(serverId: serverId, uid: uid)
            },
            liveState: { tool in
                // If the store cannot be opened the re-check is impossible: treat it as unavailable rather than send a request on the stale state from assembly time.
                guard let store else { return .unavailable }
                return McpToolBridge.liveState(
                    of: tool, store: store, credentialStore: credentialStore, uid: uid, runtimeConfig: runtimeConfig
                )
            },
            makeClient: mcpClientFactory,
            onStep: { [weak self] update in
                await self?.recordMcpToolStep(
                    update, conversationID: conversationID, messageID: assistantMessageID,
                    sendTaskID: sendTaskID, uid: uid
                )
            }
        )
    }

    /// One status callback from the executor -> the message's `toolSteps` (persisted with the message, summary only) + the local per-step payload
    /// (raw arguments and results; they do not enter the message model).
    func recordMcpToolStep(
        _ update: McpToolStepUpdate,
        conversationID: UUID,
        messageID: UUID,
        sendTaskID: UUID,
        uid: String
    ) async {
        if let payload = update.payload, let store = try? appState.mcpServerDirectory.store(for: uid) {
            // A failure to store only affects the "step detail" (shown as detail not on this device); it does not affect the execution or the answer of this step.
            await Task.detached(priority: .userInitiated) {
                try? store.saveStepPayload(
                    messageID: messageID, stepID: update.id, serverId: update.serverId,
                    arguments: payload.arguments, resultPrefix: payload.resultPrefix
                )
            }.value
        }
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == messageID })
        else { return }
        let existing = conversations[conversationIndex].messages[messageIndex].toolSteps ?? []
        let ownsSession = sessions[conversationID]?.messageID == messageID
            && sessions[conversationID]?.sendTaskID == sendTaskID
        if !ownsSession {
            // This send has already wrapped up (the user tapped stop): only accept a callback that moves its own step from running to a terminal state,
            // and add no steps - a retry of the same message is another send, and a late callback from the old task must not write into it.
            guard update.status != .running,
                  existing.contains(where: { $0.id == update.id && $0.status == .running }) else { return }
        }
        if update.status == .needsAuth {
            markMcpServerNeedsAuth(update.serverId, uid: uid)
        }
        let merged = McpToolStep.merging(update, into: existing)
        if merged != existing {
            var updated = conversations[conversationIndex]
            updated.messages[messageIndex].toolSteps = merged
            appState.upsertConversationProjection(updated)
        }
        // Activity status line: set while any step is running and cleared once all have left running.
        // Write the message first and then publish the activity: the cell's text is read from that step in the message.
        guard ownsSession else { return }
        if merged.contains(where: { $0.status == .running }) {
            recordStreamActivity(.mcpTool, in: conversationID, messageID: messageID, sendTaskID: sendTaskID)
        } else if sessions[conversationID]?.activity == .mcpTool {
            clearStreamActivity(in: conversationID)
        }
    }

    private func recordMcpToolLimitReached(conversationID: UUID, messageID: UUID) {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == messageID })
        else { return }
        var updated = conversations[conversationIndex]
        updated.messages[messageIndex].toolFallbackNotice = ToolFallbackNotice.mcpToolLimitReached.rawValue
        appState.upsertConversationProjection(updated)
    }

    /// The loop found that this server needs to sign in again: record the local connection state as needsAuth, from which the tool panel offers "Re-authorize",
    /// and later sends leave its tools out until a sign-in succeeds.
    private func markMcpServerNeedsAuth(_ serverId: UUID, uid: String) {
        guard let store = try? appState.mcpServerDirectory.store(for: uid) else { return }
        var state = (try? store.fetchConnectionState(serverId: serverId)) ?? McpConnectionState(serverId: serverId)
        guard state.status != .needsAuth else { return }
        state.status = .needsAuth
        try? store.saveConnectionState(state)
    }

    /// Shows the text a tool loop leg has produced so far.
    private func applyToolLoopText(
        _ generatedText: String,
        initialText: String,
        conversationID: UUID,
        assistantMessageID: UUID,
        sendTaskID: UUID
    ) {
        guard sessions[conversationID]?.messageID == assistantMessageID,
              sessions[conversationID]?.sendTaskID == sendTaskID else { return }
        sessions[conversationID]?.text = initialText + generatedText
        streamingSubjects[conversationID]?.send()
    }

    /// The text of the leg currently streaming; reset when the next leg starts.
    private actor ToolLoopLegText {
        private var text = ""
        func reset() { text = "" }
        func append(_ delta: String) -> String {
            text += delta
            return text
        }
    }

    /// The tool loop when only MCP is on (the Library agent is off). The leg runner and the adapter that feeds results back are chosen as a pair from the connection's outbound protocol,
    /// with the same factory as the Library (four wire protocols).
    private func runMcpToolLoop(
        conversationID: UUID,
        assistantMessageID: UUID,
        sendTaskID: UUID,
        initialText: String,
        provider: Provider,
        model: AIModel,
        accessToken: String,
        resolvedModelID: String,
        transport: TransportInput,
        reasoningMode: ReasoningMode,
        plan: McpToolPlan
    ) async throws {
        let legPair = try ToolLoopLegRunnerFactory.make(
            provider: provider,
            model: model,
            modelID: resolvedModelID,
            reasoningMode: reasoningMode,
            requestOptions: transport.options,
            accessToken: provider.authMode == .subscription ? accessToken : nil,
            toolCallMemory: toolCallMemory,
            session: providerSession
        )
        let messages = transport.toolLoopMessages(history: try OpenAIChatToolLoopLegRunner.messages(
            from: transport.messages,
            providerKind: provider.kind,
            model: model,
            isChatSend: true,
            dynamicText: transport.options.dynamicText
        ))
        // The protocol this relay leg actually goes out on (the same source as the wire choice); the tool-rejection
        // negative cache is keyed by it. nil for a non-relay connection.
        let relaySentTransport: RelayTransport? = provider.kind == .relay
            ? (RelayEndpointResolver.explicitTransport(provider: provider, model: model) ?? .openaiChatCompletions)
            : nil
        let manager = self
        let loop = McpToolBridge.makeLoop(
            plan: plan,
            executor: makeMcpExecutor(
                conversationID: conversationID, assistantMessageID: assistantMessageID, sendTaskID: sendTaskID
            ),
            legRunner: legPair.runner,
            adapter: legPair.adapter,
            runtimeConfig: mcpRuntimeConfigProvider(),
            onUnhandledToolCalls: { calls in
                // A name outside the lookup table is not executed; it goes to the existing hint card.
                await manager.recordUnhandledToolCalls(
                    calls, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID,
                    provider: provider, model: model
                )
            },
            proposeEntry: proposeMemoryLoopEntry(
                conversationID: conversationID, assistantMessageID: assistantMessageID, sendTaskID: sendTaskID
            ),
            searchEntry: searchMemoryLoopEntry(conversationID: conversationID, sendTaskID: sendTaskID)
        )
        let legText = ToolLoopLegText()
        let result: ToolCallLoop.Result
        do {
            result = try await loop.run(messages: messages) { event in
                switch event {
                case let .legStarted(index):
                    await legText.reset()
                    // After a leg with tool_calls passes, the body is cleared and the next leg renders from the start (same semantics as the Library loop).
                    if index > 0 {
                        await manager.applyToolLoopText(
                            "", initialText: initialText, conversationID: conversationID,
                            assistantMessageID: assistantMessageID, sendTaskID: sendTaskID
                        )
                    }
                case let .textDelta(delta):
                    let text = await legText.append(delta)
                    await manager.applyToolLoopText(
                        text, initialText: initialText, conversationID: conversationID,
                        assistantMessageID: assistantMessageID, sendTaskID: sendTaskID
                    )
                case let .reasoningDelta(delta):
                    await manager.appendReasoning(
                        delta, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID
                    )
                case .usage, .toolCallsAccepted:
                    break
                }
            }
        } catch let rejected as ToolsRejectedByUpstreamError {
            // Only a deterministic 4xx on the first leg where no structured tool_calls were seen means "this connection does not support tools" (the same criterion as the Library):
            // resend once without tools this time; a connection eligible for the tool-capability memory records false, and the next entry no longer carries MCP tools.
            // A rejection on leg N>0 or after tool_calls were seen is not a capability fact and goes to the error card as an ordinary failure.
            guard rejected.qualifiesAsConnectionUnsupported else { throw rejected.underlying }
            try Task.checkCancellation()
            if recordRelayToolsRejectionKeyDenial(rejected, provider: provider, model: model) {
                throw rejected.underlying
            }
            rememberToolCallCapability(
                provider: provider, model: model, toolCall: false, reason: .toolsRejected4xx,
                statusCode: rejected.statusCode, sentTransport: relaySentTransport
            )
            guard sessions[conversationID]?.messageID == assistantMessageID,
                  sessions[conversationID]?.sendTaskID == sendTaskID else { throw CancellationError() }
            // propose_memory degradation: when the first leg carrying propose is deterministically rejected before any text -> the in-process degraded set records
            // "connection + model" and the fallback runs this turn; below it resends once without tools as before.
            if let turn = proposeTurn(in: conversationID, sendTaskID: sendTaskID),
               let session = sessions[conversationID],
               MemoryPropose.degrade(
                   rejectionMatches: true,
                   legIndex: rejected.legIndex ?? 0,
                   streamStarted: Self.hasStreamedOutput(session),
                   receivedStructuredToolCalls: rejected.receivedStructuredToolCalls
               ) {
                ProposeMemoryRuntime.shared.markDegraded(connectionID: provider.id, modelID: model.id)
                sessions[conversationID]?.proposeTurn = nil
                turn.context?.onDegraded(turn.userMessageID, assistantMessageID)
            }
            let resent = try await resendToolLoopLegWithoutTools(
                runner: legPair.runner, messages: messages,
                conversationID: conversationID, assistantMessageID: assistantMessageID,
                sendTaskID: sendTaskID, initialText: initialText,
                provider: provider, model: model
            )
            result = ToolCallLoop.Result(
                text: resent.text, legTexts: [resent.text], usage: resent.usage,
                endedWithoutToolCall: true, stepLimitReached: false,
                receivedStructuredToolCalls: false, executedToolSteps: 0
            )
        }
        try Task.checkCancellation()
        guard sessions[conversationID]?.messageID == assistantMessageID,
              sessions[conversationID]?.sendTaskID == sendTaskID else { throw CancellationError() }
        if result.receivedStructuredToolCalls {
            rememberToolCallCapability(provider: provider, model: model, toolCall: true, reason: .structuredToolCalls)
        }
        if result.stepLimitReached {
            // The step cap was reached: the loop has already run the synthesis leg without tools, and the trailer row of the step block says so.
            recordMcpToolLimitReached(conversationID: conversationID, messageID: assistantMessageID)
        }

        applyToolLoopText(
            result.text,
            initialText: initialText,
            conversationID: conversationID,
            assistantMessageID: assistantMessageID,
            sendTaskID: sendTaskID
        )
        let promptTokens = result.usage?.promptTokens ?? 0
        let completionTokens = result.usage?.completionTokens ?? 0
        let providerResult = ProviderChatResult(
            text: result.text,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            estimatedCost: 0,
            usageBreakdown: UsageBreakdown(promptTokens: promptTokens, completionTokens: completionTokens)
        )
        completeStreamingMessage(
            conversationID: conversationID,
            messageID: assistantMessageID,
            expectedSendTaskID: sendTaskID,
            estimatedCost: resolvedDeliveredCost(from: providerResult, model: model, providerKind: provider.kind),
            state: .delivered,
            usageMetrics: ChatDeliveredUsageMetrics(promptTokens: promptTokens, completionTokens: completionTokens),
            // The tool loop records stopReason from the stream-finish info of the last leg; paths with no single-leg finish, such as a resend without tools, record unknown.
            streamFinish: result.finish
        )
    }

    /// The upstream returned a structured tool call but this connection has no executor.
    /// It does just three things: merges into the message's hint-card data (persisted locally), emits per-tool telemetry (without arguments),
    /// and emits a mismatch reconciliation event when the catalog says false yet tool_calls arrive. It does not resend, mark a failure or change the fact layer.
    private func recordUnhandledToolCalls(
        _ incoming: [ProviderToolCall],
        in conversationID: UUID,
        messageID: UUID,
        sendTaskID: UUID,
        provider: Provider,
        model: AIModel
    ) {
        var calls = incoming
        // propose_memory / search_memory have an executor:
        // they do not go into the hint card and are left, in order of appearance, for the end of this turn to execute.
        if sessions[conversationID]?.messageID == messageID, sessions[conversationID]?.sendTaskID == sendTaskID,
           var turn = sessions[conversationID]?.proposeTurn {
            let hostNames = Self.hostToolNames(turn)
            let proposeCalls = calls.filter { hostNames.contains($0.name) }
            calls.removeAll { hostNames.contains($0.name) }
            for call in proposeCalls {
                turn.pendingCalls.removeAll { $0.providerCallID == call.providerCallID }
                turn.pendingCalls.append(call)
            }
            if !calls.isEmpty, !turn.pastFirstLeg { turn.firstLegHadOtherCalls = true }
            sessions[conversationID]?.proposeTurn = turn
            if !proposeCalls.isEmpty {
                rememberToolCallCapability(provider: provider, model: model, toolCall: true, reason: .structuredToolCalls)
            }
        }
        guard !calls.isEmpty,
              sessions[conversationID]?.messageID == messageID,
              sessions[conversationID]?.sendTaskID == sendTaskID,
              let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == messageID })
        else { return }

        // A structured tool_calls is the response evidence that "this connection does send tools", and memory true is written within the scope of the tool-capability memory.
        rememberToolCallCapability(provider: provider, model: model, toolCall: true, reason: .structuredToolCalls)

        var updated = conversations[conversationIndex]
        var merged = updated.messages[messageIndex].unhandledToolCalls ?? []
        merged.append(contentsOf: calls.map {
            UnhandledToolCall(id: $0.providerCallID, name: $0.name, arguments: $0.rawArguments)
        })
        updated.messages[messageIndex].unhandledToolCalls = merged
        appState.upsertConversationProjection(updated)
    }

    // MARK: - propose_memory

    /// The tool definition of propose_memory (a fixture tool in openai_chat shape); each protocol is projected by ClientToolsInjector / the leg runner.
    static let proposeMemoryToolDefinition: ToolLoopToolDefinition? = try? JSONDecoder().decode(
        ToolLoopToolDefinition.self, from: Data(MemoryPropose.toolJSON.utf8)
    )

    private func proposeTurn(in conversationID: UUID, sendTaskID: UUID) -> ProposeMemoryTurn? {
        guard sessions[conversationID]?.sendTaskID == sendTaskID else { return nil }
        return sessions[conversationID]?.proposeTurn
    }

    /// The last item of the MCP / Library loop registry when mode=tool; nil when not in tool mode.
    private func proposeMemoryLoopEntry(conversationID: UUID, assistantMessageID: UUID, sendTaskID: UUID) -> ProposeMemoryEntry? {
        guard let turn = proposeTurn(in: conversationID, sendTaskID: sendTaskID), let context = turn.context else { return nil }
        return ProposeMemoryEntry(sink: ProposeMemoryLoopSink(
            context: context,
            userMessageID: turn.userMessageID,
            assistantMessageID: assistantMessageID,
            conversationID: conversationID
        ))
    }

    /// search_memory comes after propose in the MCP / Library loop registry; nil when not in tool mode.
    private func searchMemoryLoopEntry(conversationID: UUID, sendTaskID: UUID) -> SearchMemoryEntry? {
        guard let session = proposeTurn(in: conversationID, sendTaskID: sendTaskID)?.search else { return nil }
        return SearchMemoryEntry(session: session)
    }

    /// The host tool definitions of this turn: propose_memory first, search_memory after.
    static func hostToolDefinitions(_ turn: ProposeMemoryTurn) -> [ToolLoopToolDefinition] {
        var tools: [ToolLoopToolDefinition] = []
        if turn.context != nil, let propose = proposeMemoryToolDefinition { tools.append(propose) }
        if turn.search != nil, let search = SearchMemoryEntry.toolDefinition { tools.append(search) }
        return tools
    }

    static func hostToolNames(_ turn: ProposeMemoryTurn) -> Set<String> {
        var names: Set<String> = []
        if turn.context != nil { names.insert(MemoryPropose.toolName) }
        if turn.search != nil { names.insert(MemorySearch.toolName) }
        return names
    }

    /// When the search_memory mode is judged as tool, the retrieval state of this turn is attached to the host tool state
    /// (a turn without propose gets a new one carrying only search); the ids returned to the model are merged into this request's memoryIds.
    private func installMemorySearch(
        conversationID: UUID,
        sendTaskID: UUID,
        snapshot: ChatRequestSnapshot,
        provider: Provider,
        model: AIModel,
        capabilitySelection: ChatCapabilitySelection,
        recallMax: Int?,
        rhoHi: Double,
        recallIds: [String]
    ) async {
        guard sessions[conversationID]?.sendTaskID == sendTaskID, let conversation = snapshot.conversation else { return }
        let useMemory = snapshot.effectiveUseMemory
        let items = snapshot.preferences.memoryItems
        let context = MemoryRecallContext(
            conversationId: conversation.id.uuidString,
            folderId: conversation.folderID?.uuidString,
            nowMs: Int64((Date().timeIntervalSince1970 * 1000).rounded())
        )
        let recallable = useMemory ? await MemoryRecallIndexCache.shared.visibleCount(items: items, context: context) : 0
        var webSearchEnabled = capabilitySelection.webSearchEnabled
        if ProviderForm.of(provider) == .relay {
            webSearchEnabled = Self.relayWebIsOn(
                provider: provider, model: model, conversationID: conversation.id, skillID: conversation.skillID
            )
        }
        let mode = ProposeMemoryRuntime.shared.searchMode(
            purpose: .chat,
            memoryEnabled: useMemory,
            recallableItems: recallable,
            provider: provider,
            model: model,
            webSearchEnabled: webSearchEnabled,
            structuredOutputActive: structuredOutputActive(provider: provider, model: model, conversationID: conversation.id),
            toolCallMemory: toolCallMemory
        )
        guard mode == .tool, sessions[conversationID]?.sendTaskID == sendTaskID else { return }
        let search = MemorySearchSession(
            items: items, context: context, recallMax: recallMax, rhoHi: rhoHi, recallIds: recallIds
        )
        search.onReturnedIds = { [weak self] ids in
            guard let self, self.sessions[conversationID]?.sendTaskID == sendTaskID else { return }
            self.sessions[conversationID]?.contextAttempt?.memoryIds.append(contentsOf: ids)
        }
        let userMessageID = snapshot.messages.last(where: { $0.role == .user })?.id ?? UUID()
        var turn = sessions[conversationID]?.proposeTurn ?? ProposeMemoryTurn(context: nil, userMessageID: userMessageID)
        turn.search = search
        sessions[conversationID]?.proposeTurn = turn
    }

    /// Executes propose in call order: each counts toward priorInTurn, and only an outcome of create writes a candidate; what was created goes to the suggestion strip (the first strip of this turn).
    /// Other names (search_memory) are not executed here.
    private func runProposeCalls(_ calls: [ProviderToolCall], turn: inout ProposeMemoryTurn, assistantMessageID: UUID, conversationID: UUID) async {
        guard let context = turn.context else { return }
        for call in calls where call.name == MemoryPropose.toolName {
            let prior = turn.callCount
            turn.callCount += 1
            do {
                let candidate = try await context.repository.propose(
                    argumentsJSON: call.rawArguments,
                    priorInTurn: prior,
                    userText: context.userText,
                    messageId: turn.userMessageID.uuidString,
                    conversationId: conversationID.uuidString,
                    folderId: context.folderID,
                    nowMs: Int64(Date().timeIntervalSince1970 * 1000)
                )
                if let candidate { context.onCandidate(candidate, assistantMessageID) }
            } catch {
                #if DEBUG
                print("[ProposeMemory] propose failed: \(error)")
                #endif
            }
        }
    }

    /// After the first leg of the ordinary path finishes streaming: executes the propose calls of this leg; when the first leg ends with calls that are all propose, adds one more leg
    /// (original history + assistant tool_calls + a fixed tool_result per call, tools kept, tool_choice none).
    /// With thinking, this side cannot get the resume state: if the first leg has body text it is used to finish, otherwise `.plainResend` is returned,
    /// and the caller resends the original request once through the ordinary send pipeline without tools.
    /// Usage of the two legs is added, stopReason comes from the later leg, the body is first leg + a blank line + tail leg; a turn with an added leg records no rho. A tail-leg failure is thrown up to the error card and the candidate is kept.
    private func finishProposeMemoryTurn(
        conversationID: UUID,
        assistantMessageID: UUID,
        sendTaskID: UUID,
        initialText: String,
        provider: Provider,
        model: AIModel,
        accessToken: String,
        resolvedModelID: String,
        transport: TransportInput,
        reasoningMode: ReasoningMode
    ) async throws -> ProposeMemoryTurnOutcome {
        guard !Task.isCancelled,
              sessions[conversationID]?.messageID == assistantMessageID,
              var turn = proposeTurn(in: conversationID, sendTaskID: sendTaskID) else { return .finished }
        turn.pastFirstLeg = true
        let firstCalls = turn.pendingCalls
        turn.pendingCalls = []
        sessions[conversationID]?.proposeTurn = turn
        await runProposeCalls(firstCalls, turn: &turn, assistantMessageID: assistantMessageID, conversationID: conversationID)
        sessions[conversationID]?.proposeTurn = turn
        guard let delivery = turn.deferredDelivery,
              let session = sessions[conversationID],
              session.messageID == assistantMessageID, session.sendTaskID == sendTaskID else { return .finished }

        let firstText = String(session.text.dropFirst(initialText.count))
        let truncated = [StopReason.length, .contextWindowExceeded].contains(
            turn.firstLegFinish.map {
                StopReasonResolver.resolve(family: $0.family, ended: $0.ended, finishRaw: $0.finishRaw, hadContent: true)
            } ?? .stop
        )
        let thinking = Self.hasAnswerContent(session.reasoningText) && session.reasoningText != session.baselineReasoning
        let tailEligible = !firstCalls.isEmpty && !turn.firstLegHadOtherCalls && !truncated
        let hasFirstText = !firstText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard tailEligible, !(thinking && hasFirstText) else {
            completeProposeDelivery(delivery, tail: nil, conversationID: conversationID, assistantMessageID: assistantMessageID, sendTaskID: sendTaskID, provider: provider, model: model)
            return .finished
        }
        // search_memory is executed only when a tail leg is added or a resend happens (a turn that finishes on a first leg with body text does not use the retrieval result).
        var searchResults: [Int: String] = [:]
        var searchIds: [String] = []
        if let search = turn.search {
            for (offset, call) in firstCalls.enumerated() where call.name == MemorySearch.toolName {
                let result = await search.run(argumentsJSON: call.rawArguments)
                searchResults[offset] = result.text
                searchIds.append(contentsOf: result.ids)
            }
        }
        // With thinking and an empty first-leg body: hand back to the caller to resend through the ordinary send pipeline (not the Library leg runner), and the retrieved entries follow the [D] recall;
        // these ids follow the memoryIds of the resend plan itself and are not recorded for this attempt.
        if thinking { return .plainResend(carried: delivery, searchRecall: turn.search?.returned ?? []) }

        var legOptions = transport.options
        legOptions.clientTools = []
        let legPair = try ToolLoopLegRunnerFactory.make(
            provider: provider,
            model: model,
            modelID: resolvedModelID,
            reasoningMode: reasoningMode,
            requestOptions: legOptions,
            accessToken: provider.authMode == .subscription ? accessToken : nil,
            toolCallMemory: toolCallMemory,
            session: providerSession
        )
        let history = transport.toolLoopMessages(history: try OpenAIChatToolLoopLegRunner.messages(
            from: transport.messages,
            providerKind: provider.kind,
            model: model,
            isChatSend: true,
            dynamicText: transport.options.dynamicText
        ))
        var messages = history
        // A compatible endpoint may not give a call id: fill one by position, and the assistant tool_calls and the tool_result use the same one on both sides.
        let toolCalls = firstCalls.enumerated().map { offset, call in
            ToolLoopToolCall(
                id: call.providerCallID ?? "call_\(call.name)_\(offset)",
                function: .init(name: call.name, arguments: call.rawArguments),
                providerSignature: call.providerSignature
            )
        }
        messages.append(legPair.adapter.encodeAssistantToolCalls(
            text: firstText, reasoning: nil, toolCalls: toolCalls, replayBlocks: [], assistantReplay: nil
        ))
        for (offset, call) in toolCalls.enumerated() {
            messages.append(legPair.adapter.encodeToolResult(
                callID: call.id, toolName: call.function.name,
                content: searchResults[offset] ?? MemoryPropose.toolResult
            ))
        }
        let request = ToolLoopLegRequest(
            messages: messages,
            tools: Self.hostToolDefinitions(turn),
            toolChoice: .none
        )
        let prefix = hasFirstText ? firstText : ""
        sessions[conversationID]?.contextAttempt?.singleChatLeg = false
        // The tail leg delivers the search tool_result to the model: the ids returned are merged into this turn's memoryIds.
        sessions[conversationID]?.contextAttempt?.memoryIds.append(contentsOf: searchIds)

        var tailText = ""
        var usage: ToolLoopUsage?
        var finish: StreamFinish?
        var deltas: [Int: ToolLoopToolCallDelta] = [:]
        do {
            for try await event in legPair.runner.run(request: request) {
                try Task.checkCancellation()
                switch event {
                case let .textDelta(delta):
                    tailText += delta
                    applyToolLoopText(
                        Self.joinProposeLegTexts(prefix, tailText), initialText: initialText,
                        conversationID: conversationID, assistantMessageID: assistantMessageID, sendTaskID: sendTaskID
                    )
                case let .reasoningDelta(delta):
                    appendReasoning(delta, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
                case let .usage(value):
                    usage = value
                case let .finish(value):
                    finish = value
                case let .toolCallDeltas(parts):
                    for part in parts {
                        var merged = deltas[part.index] ?? ToolLoopToolCallDelta(index: part.index)
                        merged.id = merged.id ?? part.id
                        merged.name = (merged.name ?? "") + (part.name ?? "")
                        merged.arguments = (merged.arguments ?? "") + (part.arguments ?? "")
                        deltas[part.index] = merged
                    }
                case .providerReplayBlocks, .providerAssistantReplay:
                    break
                }
            }
        } catch let rejected as ToolsRejectedByUpstreamError {
            // A rejection on a non-first leg is not a capability fact and goes to the error card as an ordinary failure.
            throw rejected.underlying
        }
        try Task.checkCancellation()
        guard sessions[conversationID]?.messageID == assistantMessageID,
              sessions[conversationID]?.sendTaskID == sendTaskID else { throw CancellationError() }
        applyToolLoopText(
            Self.joinProposeLegTexts(prefix, tailText), initialText: initialText,
            conversationID: conversationID, assistantMessageID: assistantMessageID, sendTaskID: sendTaskID
        )
        // The calls of the tail leg: propose only creates candidates and adds no further leg; search is not executed; other names go to the hint card as before.
        let tailCalls = deltas.keys.sorted().compactMap { deltas[$0] }.map {
            ProviderToolCall(providerCallID: $0.id, name: $0.name ?? "", rawArguments: $0.arguments ?? "")
        }
        recordUnhandledToolCalls(
            tailCalls, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID,
            provider: provider, model: model
        )
        if var current = sessions[conversationID]?.proposeTurn {
            let calls = current.pendingCalls
            current.pendingCalls = []
            await runProposeCalls(calls, turn: &current, assistantMessageID: assistantMessageID, conversationID: conversationID)
            if sessions[conversationID]?.sendTaskID == sendTaskID { sessions[conversationID]?.proposeTurn = current }
        }
        completeProposeDelivery(
            delivery, tail: (usage, finish), conversationID: conversationID, assistantMessageID: assistantMessageID,
            sendTaskID: sendTaskID, provider: provider, model: model
        )
        return .finished
    }

    /// Body of the two legs: separated by a blank line when both are non-empty, and either one when the other is empty.
    nonisolated static func joinProposeLegTexts(_ first: String, _ tail: String) -> String {
        if first.isEmpty { return tail }
        if tail.isEmpty { return first }
        return first + "\n\n" + tail
    }

    /// Lands the successful ending recorded by the first leg; with a later leg, usage and cost are added and stopReason comes from the later leg.
    private func completeProposeDelivery(
        _ delivery: ProposeMemoryDeferredDelivery,
        tail: (usage: ToolLoopUsage?, finish: StreamFinish?)?,
        conversationID: UUID,
        assistantMessageID: UUID,
        sendTaskID: UUID,
        provider: Provider,
        model: AIModel
    ) {
        var estimatedCost = delivery.estimatedCost
        var usageMetrics = delivery.usageMetrics
        var streamFinish = delivery.streamFinish
        var stopReason = delivery.stopReason
        if let tail {
            let tailPrompt = tail.usage?.promptTokens ?? 0
            let tailCompletion = tail.usage?.completionTokens ?? 0
            let tailResult = ProviderChatResult(
                text: "",
                promptTokens: tailPrompt,
                completionTokens: tailCompletion,
                estimatedCost: 0,
                usageBreakdown: UsageBreakdown(promptTokens: tailPrompt, completionTokens: tailCompletion)
            )
            let tailCost = resolvedDeliveredCost(from: tailResult, model: model, providerKind: provider.kind)
            estimatedCost = (estimatedCost ?? 0) + tailCost
            usageMetrics = ChatDeliveredUsageMetrics(
                promptTokens: (delivery.usageMetrics?.promptTokens ?? 0) + tailPrompt,
                completionTokens: (delivery.usageMetrics?.completionTokens ?? 0) + tailCompletion
            )
            streamFinish = tail.finish ?? streamFinish
            stopReason = tail.finish == nil ? stopReason : nil
        }
        completeStreamingMessage(
            conversationID: conversationID,
            messageID: assistantMessageID,
            expectedSendTaskID: sendTaskID,
            estimatedCost: estimatedCost,
            state: .delivered,
            attachments: delivery.attachments,
            servedModelID: delivery.servedModelID,
            reasoningText: delivery.reasoningText,
            usageMetrics: usageMetrics,
            streamFinish: streamFinish,
            stopReason: stopReason,
            clearsCitations: delivery.clearsCitations
        )
    }

    /// Connection-level memory write. For a relay, a false result is recorded in the `toolCall` negative cache
    /// instead (the signal counts only when classify judges it rejected) and no longer written here; the cache key
    /// is the protocol this leg actually sent on (`sentTransport`), not the first-send protocol.
    /// Written only for connections the catalog does not cover (Relay / subscription / hand-entered id); a catalog model is not written - its truth belongs to the server and this device only emits the `tool_call_capability_mismatch` reconciliation.
    private func rememberToolCallCapability(
        provider: Provider,
        model: AIModel,
        toolCall: Bool,
        reason: ToolCallMemoryReason,
        statusCode: Int? = nil,
        sentTransport: RelayTransport? = nil
    ) {
        RelayRejectionRecording.rememberToolCall(
            provider: provider, model: model, toolCall: toolCall, reason: reason,
            statusCode: statusCode, sentTransport: sentTransport, memory: toolCallMemory
        )
    }

    /// Whether this assistant message already has output (body or reasoning). When the conversation is gone it is treated as "output started": no protocol switch and no negative cache.
    private func relayOutputStarted(conversationID: UUID, messageID: UUID, initialText: String) -> Bool {
        guard let session = sessions[conversationID], session.messageID == messageID else { return true }
        return session.text != initialText || !session.reasoningText.isEmpty
    }

    /// The protocol for the first send of an unverified model: the criterion lives in `RelayFirstSendTransport` (the negative-cache reads and writes give the same answer as "Auto =" on the advanced page),
    /// and when it equals the current route it returns nil and goes on as before. The family only reads the table already fetched in this conversation and sends no request for the first send.
    /// The criterion for a same-protocol fallback when attachments cannot be delivered belongs to sending only and stays here.
    private func relayFirstSendTransport(
        provider: Provider,
        model: AIModel,
        current: RelayTransport,
        attachments: [Attachment]
    ) async -> RelayTransport? {
        // A Chat request body carries no max_tokens, and a relay that converts a Claude-family model to Anthropic answers 400 "max_tokens required",
        // and a 400 is not a route-level rejection and does not fall back, so the first send of a Claude family goes through Messages.
        let first = RelayFirstSendTransport.current(provider: provider, model: model)
        guard first == .anthropicMessages, first != current else { return nil }
        let files = attachments.filter { $0.kind == .file }
        if !files.isEmpty, !files.contains(where: NativeFileFallback.hasExtractedText),
           !AttachmentTransportResolver.relay(first).profile.sendsNativeFiles {
            return nil
        }
        return first
    }

    /// The target of a protocol-level fallback: the candidates are the same set as the per-model probe (`RelayProbeCandidates.candidates`), and the decision goes through a pure function.
    private func relayProtocolFallbackTarget(
        provider: Provider,
        model: AIModel,
        current: RelayTransport,
        rejection: RelayPreOutputRejection,
        outputStarted: Bool,
        alreadySwitched: Bool,
        attachments: [Attachment]
    ) async -> RelayTransport? {
        // Block first with the conditions that do not need candidates, to avoid looking up the family table on every failure.
        guard RelayProtocolFallback.isEligible(
            source: model.relayTransportSource, rejection: rejection,
            outputStarted: outputStarted, alreadySwitched: alreadySwitched
        ) else { return nil }
        // The user picked the connection protocol and the model follows it: there is no other candidate, so the protocol is not switched.
        guard !RelayProbeCandidates.followsUserChosenConnection(provider: provider, model: model) else { return nil }
        let modelID = model.id
        let candidates = await RelayProbeCandidates.candidates(
            supportedEndpointTypes: RelayCatalogEndpointTypesCache.shared.endpointTypes(
                endpoint: provider.baseURLText,
                modelID: modelID
            ),
            family: { await MetadataClient.shared.relayModelFamily(for: modelID) }
        )
        guard let next = RelayProtocolFallback.next(
            current: current, source: model.relayTransportSource, candidates: candidates,
            rejection: rejection, outputStarted: outputStarted, alreadySwitched: alreadySwitched
        ) else { return nil }
        // After switching protocol the request body is rebuilt by the new protocol's builder and native files are re-decided for delivery under the new protocol; if the new protocol does not accept native files
        // and none of the files yields extractable text (scans), there is no text-fallback version to send, so it does not switch and reports the original error.
        let files = attachments.filter { $0.kind == .file }
        if !files.isEmpty, !files.contains(where: NativeFileFallback.hasExtractedText),
           !AttachmentTransportResolver.relay(next).profile.sendsNativeFiles {
            return nil
        }
        return next
    }

    /// When a relay's "tools rejected" is actually this key having no access to the model, returns the status code: no resend without tools and no tool negative cache written.
    /// The decision uses the raw response body, or the message / code fragments left by `mapHTTPError` when it is not available.
    nonisolated static func relayToolsRejectionKeyDeniedStatus(_ error: any Error, providerKind: ProviderKind) -> Int? {
        guard providerKind == .relay, let status = toolRejectionStatusCode(error) else { return nil }
        let body: String
        if let rejected = error as? ToolsRejectedByUpstreamError {
            if let rawBody = rejected.rawBody {
                body = rawBody
            } else if case let .upstream(_, detail) = rejected.underlying {
                body = detail
            } else {
                body = ""
            }
        } else if case let ProviderServiceError.upstream(_, detail) = error {
            body = detail
        } else {
            return nil
        }
        return RelayKeyAccess.classify(status: status, body: body) == .modelAccessDenied ? status : nil
    }

    /// When judged as no access, records the effective key on the model and returns true (the caller then fails with the original error).
    private func recordRelayToolsRejectionKeyDenial(_ error: any Error, provider: Provider, model: AIModel) -> Bool {
        guard let status = Self.relayToolsRejectionKeyDeniedStatus(error, providerKind: provider.kind) else { return false }
        appState.providerManager.recordRelayKeyAccessFailure(
            providerID: provider.id, modelID: model.id,
            keyID: RelayKeyBinding.effectiveKeyID(provider: provider, modelID: model.id),
            outcome: .modelAccessDenied, httpStatus: status,
            sentIdentity: ProviderManager.relayKeyWriteIdentity(provider, modelID: model.id)
        )
        return true
    }

    /// The upstream status code carried by a "tools not supported" error (an annotated rejection or a bare `.upstream`).
    nonisolated static func toolRejectionStatusCode(_ error: any Error) -> Int? {
        if let rejected = error as? ToolsRejectedByUpstreamError { return rejected.statusCode }
        if case let ProviderServiceError.upstream(statusCode, _) = error { return statusCode }
        return nil
    }

    /// The "server-side retrieval is also unavailable" branch: the same leg resends once bare without tools (depth=1).
    private func resendToolLoopLegWithoutTools(
        runner: any ToolLoopLegRunning,
        messages: [ToolLoopMessage],
        conversationID: UUID,
        assistantMessageID: UUID,
        sendTaskID: UUID,
        initialText: String,
        provider: Provider,
        model: AIModel
    ) async throws -> (text: String, usage: ToolLoopUsage?) {
        let request = ToolLoopLegRequest(messages: messages, tools: [], toolChoice: .none)
        var text = ""
        var usage: ToolLoopUsage?
        for try await event in runner.run(request: request) {
            try Task.checkCancellation()
            switch event {
            case let .textDelta(delta):
                text += delta
                applyToolLoopText(
                    text, initialText: initialText, conversationID: conversationID,
                    assistantMessageID: assistantMessageID, sendTaskID: sendTaskID
                )
            case let .reasoningDelta(delta):
                appendReasoning(delta, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
            case let .usage(value):
                usage = value
            case let .toolCallDeltas(deltas):
                recordUnhandledToolCalls(
                    deltas.map { ProviderToolCall(providerCallID: $0.id, name: $0.name ?? "", rawArguments: $0.arguments ?? "") },
                    in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID,
                    provider: provider, model: model
                )
            case .providerReplayBlocks, .providerAssistantReplay, .finish:
                break
            }
        }
        return (text, usage)
    }

    // MARK: - Request snapshot

    private func prepareRequestSnapshot(
        conversation: Conversation,
        messages: [ChatMessage],
        sendPath: ChatRequestSendPath
    ) -> ChatRequestSnapshot {
        let skillSnapshot = conversation.skillId
            .flatMap { appState.skillManager.skill(by: $0) }
            .map(ChatRequestSkillSnapshot.init)
        // Notes pinned as context: on the first turn the compose-state pending is landed on the conversation, then the content snapshot is resolved for injection (done on the MainActor side).
        appState.commitPendingPinsIfNeeded(to: conversation.id)
        let pinnedNotes = appState.resolvePinnedNoteSnapshots(for: conversation.id)
        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(
                id: conversation.id,
                useMemory: conversation.useMemory,
                skillID: conversation.skillId,
                instructions: conversation.instructions,
                folderID: conversation.folderID
            ),
            messages: messages,
            preferences: ChatRequestPreferencesSnapshot(memoryItems: appState.memoryItemsCache.items),
            skill: skillSnapshot,
            pinnedNotes: pinnedNotes,
            sendPath: sendPath
        )
        return snapshot
    }

    private func prepareEnrichedRequestSnapshot(
        _ requestSnapshot: ChatRequestSnapshot,
        latestUserText: String
    ) async -> ChatRequestSnapshot {
        // L3 recall: retrieved with the original text of the user message this answer is for; the index is cached by entry fingerprint inside an actor and does not occupy the main thread.
        let recall = await Self.recallEntries(for: requestSnapshot, query: latestUserText)

        return requestSnapshot.withRecall(recall)
    }

    /// Retrieves L3 when the effective useMemory is on (L3 lives only on this device); no retrieval when it is off.
    nonisolated static func recallEntries(
        for snapshot: ChatRequestSnapshot,
        query: String,
        now: Date = Date()
    ) async -> [ContextRecallEntry] {
        guard snapshot.effectiveUseMemory, let conversation = snapshot.conversation else { return [] }
        let context = MemoryRecallContext(
            conversationId: conversation.id.uuidString,
            folderId: conversation.folderID?.uuidString,
            nowMs: Int64((now.timeIntervalSince1970 * 1000).rounded())
        )
        return await MemoryRecallIndexCache.shared
            .recall(items: snapshot.preferences.memoryItems, query: query, context: context)
            .map(\.entry)
    }

    private func beginEditingUserMessage(at messageIndex: Int, in conversationID: UUID) -> ComposerEditDraft? {
        guard let convIndex = conversations.firstIndex(where: { $0.id == conversationID }) else { return nil }
        guard conversations[convIndex].messages.indices.contains(messageIndex),
              conversations[convIndex].messages[messageIndex].role == .user else {
            return nil
        }

        let messageText = conversations[convIndex].messages[messageIndex].text
        // The original attachments go back into the composer together with the text. They must be taken before truncating: truncation deletes the file payloads of this message.
        let restoredAttachments = ComposerAttachmentRestoration.restoredForComposer(
            appState.attachmentsWithFilePayloads(
                of: conversations[convIndex].messages[messageIndex], in: conversationID
            ),
            partitionUID: appState.sessionPartitionUID
        )
        var updated = conversations[convIndex]
        // Record the ids of the removed messages (.delivered only)
        let removedIDs = Array(updated.messages[messageIndex...])
            .filter { $0.state == .delivered }
            .map(\.id)
        // Snapshot the provider/model of the truncated segment for telemetry - taken before the deletion
        let truncatedSegment = Array(updated.messages[messageIndex...])
        updated.messages.removeSubrange(messageIndex...)
        ReadAloudController.shared.stopIfSpeaking(messageIDs: truncatedSegment.map(\.id), .navigated)
        // The displayed count is lowered with the truncation: a stale count would make the summary projection after a restart believe there is history that was never loaded.
        updated.messageCountOverride = updated.messageCountOverride.map {
            max(updated.messages.count, $0 - truncatedSegment.count)
        }
        updated.draftText = messageText
        updated.previewText = messageText

        updated.updatedAt = ConversationListMetadata.computeActivityAt(for: updated)
        updated.isDraft = updated.messages.isEmpty
        // When truncated to 0 messages, messages is empty and the storage layer does not delete rows because of that, so the deleted ids must be passed explicitly.
        appState.upsertConversationProjection(
            updated,
            deletingMessageIDs: Set(truncatedSegment.map(\.id))
        )
        // Truncation is a destructive change: refresh the recovery snapshot right away, so after a crash a cold-start merge does not add the deleted segment back by message count
        appState.persistRecoverySnapshotAfterDestructiveChange()

        // Aligned with web `editAndResend`: a rollback triggered by the user editing a user message counts as an after_edit regeneration,
        // with the same semantics on every platform.
        pendingEditResendConversationIDs.insert(conversationID)
        return ComposerEditDraft(text: messageText, attachments: restoredAttachments)
    }

    /// Cancelling the pre-send confirmation = rolling this round back. This user + assistant placeholder pair has not gone out yet,
    /// so only a local deletion is done (no tombstone left); the checkpoint is kept; the streaming state is released, no stopped /
    /// failed is recorded and no telemetry is added; a refill event is sent (the chat page puts the content back when the composer is empty).
    /// Idempotent: if the placeholder is no longer generating (already rolled back, or displaced by a new send in the same conversation and settled as interrupted), nothing is done.
    private func rollbackUnconfirmedSend(assistantMessageID: UUID, in conversationID: UUID) {
        if sessions[conversationID]?.messageID == assistantMessageID {
            removeSession(for: conversationID)
        }
        guard let convIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let assistantIndex = conversations[convIndex].messages.firstIndex(where: {
                  $0.id == assistantMessageID && $0.role == .assistant && $0.state == .generating
              }),
              assistantIndex > 0,
              conversations[convIndex].messages[assistantIndex - 1].role == .user
        else { return }

        var updated = conversations[convIndex]
        let userMessage = updated.messages[assistantIndex - 1]
        let assistantMessage = updated.messages[assistantIndex]
        // The attachments must be taken before the deletion: deleting takes the file payloads of this message with it.
        let restoredAttachments = ComposerAttachmentRestoration.restoredForComposer(
            appState.attachmentsWithFilePayloads(of: userMessage, in: conversationID),
            partitionUID: appState.sessionPartitionUID
        )
        let removedRange = (assistantIndex - 1)...assistantIndex
        let removed = Array(updated.messages[removedRange])
        updated.messages.removeSubrange(removedRange)
        updated.messageCountOverride = updated.messageCountOverride.map {
            max(updated.messages.count, $0 - removed.count)
        }
        updated.updatedAt = ConversationListMetadata.computeActivityAt(for: updated)
        updated.isDraft = updated.messages.isEmpty
        ConversationListMetadata.apply(to: &updated)
        appState.upsertConversationProjection(updated, deletingMessageIDs: Set(removed.map(\.id)))
        appState.persistRecoverySnapshotAfterDestructiveChange()
        // The "Set as instruction" / "Save as memory?" bars this send put up go with it.
        appState.directiveSuggestions.withdraw(messageID: userMessage.id, conversationID: conversationID)
        appState.memorySuggestions.withdraw(messageID: assistantMessage.id, conversationID: conversationID)

        contextCapRollbacks.send(ContextCapSendRollback(
            conversationID: conversationID,
            text: userMessage.text,
            attachments: restoredAttachments,
            quoteContext: userMessage.quoteContext,
        ))
    }

    /// The confirmation input at the gate point: B / limitedBy take the window actually assembled this time, T = window.priceLineTokens,
    /// the price is looked up in the metadata for this model; model records the id the request actually used. nil = do not ask.
    private func contextCapConfirmPrompt(
        conversationID: UUID,
        attemptKind: ChatAttemptKind,
        providerKind: ProviderKind,
        model: AIModel,
        resolvedModelID: String,
        window: ContextWindowInput,
        estimatedInput: Int
    ) -> ContextCapConfirmPresentation.Prompt? {
        let attempt: ContextCapConfirmPresentation.Attempt
        switch attemptKind {
        case .send: attempt = .send
        case .edit: attempt = .edit
        default: return nil
        }
        let budget = ContextBudget.window(window)
        let input = ContextCapConfirmPresentation.Input(
            attempt: attempt,
            model: resolvedModelID,
            reminderEnabled: appState.preferences.contextPriceLineReminderEnabled,
            conversationState: ContextPriceLineConfirmStore().state(for: conversationID),
            pricing: window.priceLineTokens == nil
                ? nil
                : ContextCapPresentation.pricing(providerKind: providerKind, modelID: model.id),
            estimatedInput: estimatedInput,
            B: budget.B,
            limitedBy: budget.limitedBy,
            priceLineTokens: window.priceLineTokens
        )
        let decision = ContextCapConfirmPresentation.decide(input)
        guard let text = ContextCapConfirmPresentation.text(decision, input: input, modelName: model.name) else {
            return nil
        }
        return ContextCapConfirmPresentation.Prompt(input: input, decision: decision, text: text)
    }

    // MARK: - Internal helpers

    private struct ImageAttachmentDiskWrite: Sendable {
        let imageID: String
        let data: Data
    }

    private static func prepareImageAttachmentsForDisk(
        _ attachments: [Attachment],
        imageDataByAttachmentID: [UUID: Data],
        makeImageID: () -> String = { UUID().uuidString }
    ) -> (attachments: [Attachment], writes: [ImageAttachmentDiskWrite]) {
        var resolvedAttachments = attachments
        var pendingWrites: [ImageAttachmentDiskWrite] = []
        var availableImageData = imageDataByAttachmentID

        for i in resolvedAttachments.indices
        where resolvedAttachments[i].kind == .image && resolvedAttachments[i].localImageID == nil {
            let imageData: Data?
            if let pending = availableImageData.removeValue(forKey: resolvedAttachments[i].id) {
                imageData = pending
                #if DEBUG
                print("[ImageGen] took availableImageData attID=\(resolvedAttachments[i].id), bytes=\(pending.count)")
                #endif
            } else if let b64 = resolvedAttachments[i].base64Data, !b64.isEmpty {
                imageData = Self.decodeImageBase64(b64)
                #if DEBUG
                if imageData == nil {
                    print("[ImageGen] completeStreaming: non-streaming attachment base64 decode failed, prefix=\(b64.prefix(40))")
                } else {
                    print("[ImageGen] completeStreaming fallback decoded from base64, bytes=\(imageData?.count ?? 0)")
                }
                #endif
            } else {
                imageData = nil
                #if DEBUG
                print("[ImageGen] completeStreaming: attID=\(resolvedAttachments[i].id) has neither pendingImageData nor base64, landing failed")
                #endif
            }

            if let imageData {
                let imageID = makeImageID()
                resolvedAttachments[i].localImageID = imageID
                resolvedAttachments[i].base64Data = nil
                resolvedAttachments[i].thumbnailBase64 = ImageStore.makeThumbnailBase64(from: imageData)
                pendingWrites.append(ImageAttachmentDiskWrite(imageID: imageID, data: imageData))
            }
        }

        return (resolvedAttachments, pendingWrites)
    }

    private nonisolated static func writeImageAttachmentsToDisk(
        _ writes: [ImageAttachmentDiskWrite],
        partitionUID: String
    ) {
        for write in writes {
            ImageStore.save(imageData: write.data, for: write.imageID, partitionUID: partitionUID)
            ImageStore.generateAndSaveThumbnail(from: write.data, for: write.imageID, partitionUID: partitionUID)
            #if DEBUG
            let verified = ImageStore.loadImageData(for: write.imageID, partitionUID: partitionUID)
            print("[ImageGen] ImageStore.save done imageID=\(write.imageID), writtenBytes=\(write.data.count), readback=\(verified?.count ?? -1)")
            #endif
        }
    }

    private func updateAssistantMessage(
        conversationID: UUID,
        messageID: UUID,
        text: String,
        estimatedCost: Double,
        state: ChatMessageState
    ) {
        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }

        var updated = conversations[ci]
        updated.messages[mi].text = text
        updated.messages[mi].estimatedCost = estimatedCost
        updated.messages[mi].state = state
        updated.messages[mi].errorTitle = nil
        updated.messages[mi].errorDetail = nil
        updated.updatedAt = ConversationListMetadata.computeActivityAt(for: updated)
        ConversationListMetadata.apply(to: &updated)
        appState.upsertConversationProjection(updated)
    }

    private func appendToAssistantMessage(
        conversationID: UUID,
        messageID: UUID,
        delta: String
    ) {
        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }

        // Only for one-shot non-streaming appends (such as the continue case of the demo provider)
        var updated = conversations[ci]
        updated.messages[mi].text += delta
        updated.updatedAt = ConversationListMetadata.computeActivityAt(for: updated)
        ConversationListMetadata.apply(to: &updated)
        appState.upsertConversationProjection(updated)
    }

    private func ownsInFlightResponse(
        taskID: UUID,
        conversationID: UUID,
        messageID: UUID
    ) -> Bool {
        guard sessions[conversationID]?.sendTaskID == taskID,
              let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == messageID })
        else {
            return false
        }

        return conversations[conversationIndex].messages[messageIndex].state == .generating
    }

    private func applyNonStreamingCompletionIfCurrent(
        taskID: UUID,
        conversationID: UUID,
        messageID: UUID,
        result: ProviderChatResult,
        estimatedCost: Double,
        servedModelID: String? = nil,
        usageMetrics: ChatDeliveredUsageMetrics? = nil,
        provider: Provider? = nil,
        model: AIModel? = nil
    ) {
        guard ownsInFlightResponse(
            taskID: taskID,
            conversationID: conversationID,
            messageID: messageID
        ) else {
            return
        }
        // Tool calls in a non-streaming response go through the same handler as streaming - hint card + telemetry,
        // an empty body does not count as a failure either (the service side no longer throws emptyResponse for "empty body but with tool_calls").
        if let toolCalls = result.toolCalls, !toolCalls.isEmpty, let provider, let model {
            recordUnhandledToolCalls(
                toolCalls, in: conversationID, messageID: messageID, sendTaskID: taskID,
                provider: provider, model: model
            )
        }

        // Write result.text into sessions[convID], then go through completeStreamingMessage (the same behaviour as the streaming path)
        sessions[conversationID]?.text = result.text
        streamingSubjects[conversationID]?.send()
        completeStreamingMessage(
            conversationID: conversationID,
            messageID: messageID,
            expectedSendTaskID: taskID,
            estimatedCost: estimatedCost,
            state: .delivered,
            attachments: result.attachments,
            servedModelID: servedModelID ?? result.servedModelID,
            reasoningText: result.reasoningText,
            usageMetrics: usageMetrics,
            streamFinish: result.finish
        )
    }

    /// On streaming completion: syncs streamingText back to conversations and updates the metadata, triggering @Published only once
    private func completeStreamingMessage(
        conversationID: UUID,
        messageID: UUID,
        expectedSendTaskID: UUID?,
        estimatedCost: Double? = nil,
        state: ChatMessageState,
        errorTitle: String? = nil,
        errorDetail: String? = nil,
        attachments: [Attachment]? = nil,
        servedModelID: String? = nil,
        reasoningText: String? = nil,
        usageMetrics: ChatDeliveredUsageMetrics? = nil,
        /// Stream-finish info: when given, stopReason is recorded from it regardless of state.
        streamFinish: StreamFinish? = nil,
        /// Sets stopReason directly, taking precedence over streamFinish.
        stopReason: StopReason? = nil,
        clearsCitations: Bool = false
    ) {
        var estimatedCost = estimatedCost
        var usageMetrics = usageMetrics
        if let expectedSendTaskID {
            guard let session = sessions[conversationID],
                  session.messageID == messageID,
                  session.sendTaskID == expectedSendTaskID else { return }
            // The first leg of propose_memory carried calls: the successful ending is recorded first, and after this turn executes the calls / adds a tail leg
            // finishProposeMemoryTurn lands it in one place.
            if state == .delivered, let turn = session.proposeTurn, !turn.pastFirstLeg, !turn.pendingCalls.isEmpty {
                sessions[conversationID]?.proposeTurn?.deferredDelivery = ProposeMemoryDeferredDelivery(
                    estimatedCost: estimatedCost,
                    attachments: attachments,
                    servedModelID: servedModelID,
                    reasoningText: reasoningText,
                    usageMetrics: usageMetrics,
                    streamFinish: streamFinish,
                    stopReason: stopReason,
                    clearsCitations: clearsCitations
                )
                return
            }
            // Thinking resend with an empty body: the first leg is already billed, so usage and cost of the two attempts are added.
            if state == .delivered, let carried = session.proposeCarriedDelivery {
                if carried.estimatedCost != nil || estimatedCost != nil {
                    estimatedCost = (carried.estimatedCost ?? 0) + (estimatedCost ?? 0)
                }
                usageMetrics = ChatDeliveredUsageMetrics(
                    promptTokens: (carried.usageMetrics?.promptTokens ?? 0) + (usageMetrics?.promptTokens ?? 0),
                    completionTokens: (carried.usageMetrics?.completionTokens ?? 0) + (usageMetrics?.completionTokens ?? 0)
                )
            }
        }

        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }

        var updated = conversations[ci]
        // Key fix: removeSession() clears sessions[convID].pendingImageData. The image data decoded during streaming must be copied to a local variable first,
        // otherwise availableImageData in the disk-writing loop below is always empty,
        // the attachment gets no localImageID and the UI shows a broken image
        var carriedImageData: [UUID: Data] = [:]
        var streamingAttCount = 0
        var carriedCitations: [Citation] = []
        // The reasoning text and duration accumulated while streaming: snapshot before completeStreamingMessage,
        // so after removeSession releases the session the code below can still write the message back from local variables.
        var carriedReasoningText: String?
        var carriedReasoningDurationMs: Int64?
        var carriedRelayDeliveryRoute: RelayDeliveryRoute?
        let activeSession = sessions[conversationID].flatMap { $0.messageID == messageID ? $0 : nil }
        let contextAttempt = activeSession?.contextAttempt
        if let session = sessions[conversationID], session.messageID == messageID {
            updated.messages[mi].text = session.text
            carriedRelayDeliveryRoute = session.relayDeliveryRoute
            let collected = session.attachments
            streamingAttCount = collected.count
            carriedImageData = session.pendingImageData
            carriedCitations = session.citations
            let trimmedReasoning = session.reasoningText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedReasoning.isEmpty {
                carriedReasoningText = session.reasoningText
                // When endedAt is missing (rare: for example done arrives with no body .delta at all) fall back to the done time.
                if let start = session.reasoningStartedAt {
                    let end = session.reasoningEndedAt ?? Date()
                    let elapsedMs = Int64((end.timeIntervalSince(start) * 1000).rounded())
                    if elapsedMs > 0 {
                        carriedReasoningDurationMs = elapsedMs
                    }
                }
            }
            removeSession(for: conversationID)
            if !collected.isEmpty {
                var existing = updated.messages[mi].attachments ?? []
                existing.append(contentsOf: collected)
                updated.messages[mi].attachments = existing
            }
        }
        // Provider capability spec v2: write the streamed citations into the persisted ChatMessage field.
        // The citations that already arrived are kept even if the stream was interrupted (.interrupted), so the user can look back later.
        if clearsCitations {
            updated.messages[mi].citations = nil
        } else if !carriedCitations.isEmpty {
            updated.messages[mi].citations = carriedCitations
        }
        // Merge the attachments returned by a non-streaming response
        if let attachments, !attachments.isEmpty {
            var existing = updated.messages[mi].attachments ?? []
            existing.append(contentsOf: attachments)
            updated.messages[mi].attachments = existing
        }
        #if DEBUG
        print("[ImageGen] completeStreaming: text=\(updated.messages[mi].text.prefix(80))(\(updated.messages[mi].text.count)chars), streamingAtts=\(streamingAttCount), paramAtts=\(attachments?.count ?? 0), finalAtts=\(updated.messages[mi].attachments?.count ?? 0), state=\(state)")
        #endif
        var imageDiskWrites: [ImageAttachmentDiskWrite] = []
        // Fill localImageID into the image attachments and produce the data to write to disk.
        if var allAtts = updated.messages[mi].attachments {
            // The carriedImageData moved over during streaming is enough (the non-streaming path already wrote sessions[convID].pendingImageData before the call,
            // and the removeSession above moved it into carriedImageData as well)
            #if DEBUG
            let imageAttsCount = allAtts.filter { $0.kind == .image }.count
            print("[ImageGen] completeStreaming loop: imageAtts=\(imageAttsCount), availableImageDataKeys=\(carriedImageData.keys.count)")
            #endif
            let prepared = Self.prepareImageAttachmentsForDisk(allAtts, imageDataByAttachmentID: carriedImageData)
            allAtts = prepared.attachments
            imageDiskWrites = prepared.writes
            updated.messages[mi].attachments = allAtts
            #if DEBUG
            print("[ImageGen] pendingWrites count=\(imageDiskWrites.count), attachments localImageIDs=\(allAtts.compactMap { $0.localImageID })")
            #endif
        }

        if let estimatedCost {
            updated.messages[mi].estimatedCost = estimatedCost
        }
        if let servedModelID, !servedModelID.isEmpty {
            updated.messages[mi].servedModelID = servedModelID
        }
        if let usageMetrics {
            func adding(_ current: Int?, _ next: Int?) -> Int? {
                guard current != nil || next != nil else { return nil }
                return (current ?? 0) + (next ?? 0)
            }
            updated.messages[mi].inputTokens = adding(updated.messages[mi].inputTokens, usageMetrics.inputTokens)
            updated.messages[mi].outputTokens = adding(updated.messages[mi].outputTokens, usageMetrics.outputTokens)
            updated.messages[mi].cachedInputTokens = adding(updated.messages[mi].cachedInputTokens, usageMetrics.cachedInputTokens)
            updated.messages[mi].cacheCreationInputTokens = adding(
                updated.messages[mi].cacheCreationInputTokens,
                usageMetrics.cacheCreationInputTokens
            )
        }
        // Prefer the streamed reasoning (it overrides what the provider reports in done); when the streamed one is empty fall back to the provider's value.
        // This supports streamed reasoning of Anthropic / DeepSeek / Moonshot and the like,
        // and stays compatible with the old path: result.reasoningText comes from the non-streaming applyNonStreamingCompletionIfCurrent.
        if let carriedReasoningText,
           !carriedReasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.messages[mi].reasoningText = carriedReasoningText
            updated.messages[mi].reasoningDurationMs = carriedReasoningDurationMs
        } else if let reasoningText,
                  !reasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.messages[mi].reasoningText = reasoningText
        }
        // No status code can upgrade this result.  Only the current production parser may have
        // recorded a reviewed signal; otherwise the tracker settles each requested owner as
        // unconfirmed when the response completes.
        if state == .delivered,
           let execution = CapabilityExecutionRuntime.current?.terminalResult(),
           !execution.states.isEmpty {
            updated.messages[mi].capabilityExecution = execution
        }
        updated.messages[mi].stopReason = stopReason ?? Self.completionStopReason(
            state: state,
            finish: streamFinish,
            hadContent: Self.hasAnswerContent(updated.messages[mi].text)
        )
        settleContextLedger(
            contextAttempt,
            stopReason: updated.messages[mi].stopReason,
            observedInput: usageMetrics?.inputTokens,
            recordsSample: state == .delivered
        )
        if state != .failed, let contextAttempt {
            Self.recordMemoryItemIds(contextAttempt.memoryIds, purpose: contextAttempt.purpose, into: &updated.messages[mi])
        }
        updated.messages[mi].state = state
        updated.messages[mi].errorTitle = errorTitle
        updated.messages[mi].errorDetail = errorDetail
        // Relay web reply notice: the switch is on and the delivering attempt carried no fragment -> attach it under this assistant message (kept in this process's memory only).
        // Set before the conversation is published below, so the row the list rebuilds from this publish already carries it.
        if state == .delivered, let route = carriedRelayDeliveryRoute, route.webOn {
            let delivered = route.switchedTo ?? route.transport
            if route.webStripped.contains(delivered) || route.webFragmentHashes[delivered] == nil {
                relayWebReplyNotices[messageID] = .webNotUsed
            }
        }
        updated.updatedAt = ConversationListMetadata.computeActivityAt(for: updated)
        ConversationListMetadata.apply(to: &updated)
        appState.upsertConversationProjection(updated)

        if let expectedSendTaskID {
            let acknowledgement = pendingRecipeContinuationAcknowledgements.removeValue(forKey: expectedSendTaskID)
            if state == .delivered, let acknowledgement {
                Task {
                    do {
                        _ = try RecipeContinuationRuntime.acknowledgeExplicitConsumption(acknowledgement)
                    } catch {
                        print("[ChatManager] continuation acknowledgement failed: \(error.localizedDescription)")
                    }
                }
            }
        }

        if state != .delivered, !imageDiskWrites.isEmpty {
            let convID = conversationID
            let stateRetainer: AppState? = appState
            let writes = imageDiskWrites
            // Capture the partition key at launch: encoding images is slow, and the partition may change in the meantime
            let partitionUID = AppSessionStore.activeUID
            Task.detached(priority: .utility) {
                Self.writeImageAttachmentsToDisk(writes, partitionUID: partitionUID)
                await MainActor.run {
                    guard let stateRef = stateRetainer else { return }
                    if let conv = stateRef.conversations.first(where: { $0.id == convID }) {
                        stateRef.upsertConversationProjection(conv, expectedUID: partitionUID)
                    }
                }
            }
        }

        // On delivery:
        if state == .delivered {
            let assistantMsg = updated.messages[mi]
            if let route = carriedRelayDeliveryRoute {
                appState.providerManager.recordRelayDeliveredTransport(
                    providerID: route.providerID,
                    modelID: route.modelID,
                    startedTransport: route.transport,
                    switchedTo: route.switchedTo
                )
                appState.providerManager.recordRelayKeyAccessSuccess(
                    providerID: route.providerID, modelID: route.modelID, keyID: route.keyID,
                    sentIdentity: route.keyWriteIdentity
                )
                // Web: look at the protocol actually delivered on (after a first-send reroute or a protocol fallback too) to see whether this attempt carried a fragment.
                let deliveredTransport = route.switchedTo ?? route.transport
                let stripped = route.webStripped.contains(deliveredTransport)
                let carriedHash = stripped ? nil : route.webFragmentHashes[deliveredTransport]
                // Delivered with a fragment and the production parser produced web citations -> searched / observed; only a local record is written.
                if let carriedHash, !carriedCitations.isEmpty {
                    RelayWebProbeStore.shared.record(
                        connectionID: route.providerID.uuidString, modelID: route.modelID,
                        transport: deliveredTransport.rawValue, result: .searched, source: .observed, fragmentHash: carriedHash
                    )
                }
                // Delivered after a resend without the fragment -> that protocol x current hash rejected / tested.
                if stripped, let hash = route.webFragmentHashes[deliveredTransport] {
                    RelayWebProbeStore.shared.record(
                        connectionID: route.providerID.uuidString, modelID: route.modelID,
                        transport: deliveredTransport.rawValue, result: .rejected, source: .tested, fragmentHash: hash
                    )
                }

            }
            // Land the decoded images on disk off the main thread; the partition key is captured at launch.
            if !imageDiskWrites.isEmpty {
                let convID = conversationID
                let stateRetainer: AppState? = appState
                let writes = imageDiskWrites
                let partitionUID = AppSessionStore.activeUID
                Task.detached(priority: .utility) {
                    Self.writeImageAttachmentsToDisk(writes, partitionUID: partitionUID)
                    await MainActor.run {
                        guard let stateRef = stateRetainer else { return }
                        if let conv = stateRef.conversations.first(where: { $0.id == convID }) {
                            stateRef.upsertConversationProjection(conv, expectedUID: partitionUID)
                        }
                    }
                }
            }
        }
    }

    /// Called only by `CapabilityExecutionTracker.confirmRequestDispatched`. Pre-compilation / JSON encoding and
    /// HTTP success must not come in here, so the user is not told falsely during streaming that a capability was actually requested.
    private func recordRequestedCapabilityExecution(
        _ execution: CapabilityExecutionResult,
        conversationID: UUID,
        messageID: UUID,
        expectedSendTaskID: UUID
    ) {
        guard let session = sessions[conversationID],
              session.messageID == messageID,
              session.sendTaskID == expectedSendTaskID,
              let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == messageID }),
              conversations[conversationIndex].messages[messageIndex].state == .generating
        else { return }
        var updated = conversations[conversationIndex]
        updated.messages[messageIndex].capabilityExecution = execution
        appState.upsertConversationProjection(updated)
    }

    // MARK: - memoryItemIds

    /// Called when the request really went out and the ending is a failure that is not a streaming error: a continue that injected no entries keeps the existing ids, and one that did overwrites them;
    /// a new answer / re-answer (chat, toolLoopLeg) always takes this attempt's value, and an empty array clears the old one.
    nonisolated static func recordMemoryItemIds(_ ids: [String], purpose: RequestPurpose, into message: inout ChatMessage) {
        if purpose == .continue && ids.isEmpty { return }
        message.memoryItemIds = ids
    }

    // MARK: - stopReason

    /// hadContent: the received answer body is non-empty (reasoning excluded).
    private static func hasAnswerContent(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Normal ending: when there is stream-finish info it is resolved from it; otherwise a user stop -> interrupted, done without finish -> unknown,
    /// and the rest follow a transport error (incomplete when there is body text, error otherwise).
    private static func completionStopReason(state: ChatMessageState, finish: StreamFinish?, hadContent: Bool) -> StopReason {
        if let finish {
            return StopReasonResolver.resolve(
                family: finish.family, ended: finish.ended, finishRaw: finish.finishRaw, hadContent: hadContent
            )
        }
        switch state {
        case .interrupted: return .interrupted
        case .delivered: return .unknown
        default: return hadContent ? .incomplete : .error
        }
    }

    /// Abnormal ending not initiated by the user: if the upstream handed over a finish before the error, the last one is used, otherwise it is treated as a transport error.
    private func failureStopReason(in conversationID: UUID, messageID: UUID) -> StopReason {
        let session = sessions[conversationID].flatMap { $0.messageID == messageID ? $0 : nil }
        let text = session?.text
            ?? conversations.first(where: { $0.id == conversationID })?
                .messages.first(where: { $0.id == messageID })?.text
            ?? ""
        let hadContent = Self.hasAnswerContent(text)
        if let finish = session?.lastStreamFinish {
            return StopReasonResolver.resolve(
                family: finish.family, ended: finish.ended, finishRaw: finish.finishRaw, hadContent: hadContent
            )
        }
        return hadContent ? .incomplete : .error
    }

    /// Clears the previous request's stream-finish info before every start / resend, so a failure ending only trusts the finish handed over by this request.
    private func clearStreamFinish(in conversationID: UUID, sendTaskID: UUID) {
        guard sessions[conversationID]?.sendTaskID == sendTaskID else { return }
        sessions[conversationID]?.lastStreamFinish = nil
    }

    /// Records the stream-finish info the upstream handed over before an error (only for this send task).
    private func recordStreamFinish(_ finish: StreamFinish, in conversationID: UUID, sendTaskID: UUID) {
        guard sessions[conversationID]?.sendTaskID == sendTaskID else { return }
        sessions[conversationID]?.lastStreamFinish = finish
        // propose_memory: the end reason of the first leg decides whether a tail leg is added (a truncated ending adds none).
        if sessions[conversationID]?.proposeTurn?.pastFirstLeg == false {
            sessions[conversationID]?.proposeTurn?.firstLegFinish = finish
        }
    }

    /// On a streaming failure: syncs the text and marks the failure
    private func failStreamingMessage(
        conversationID: UUID,
        messageID: UUID,
        expectedSendTaskID: UUID,
        userFacingText: String,
        estimatedCost: Double,
        title: String,
        detail: String,
        recoveryPrimaryAction: String? = nil,
        /// The catch of the send task sits outside the TaskLocal scope of the tracker and cannot read `current`; the caller passes the terminal result in.
        terminalExecution: CapabilityExecutionResult? = nil,
        /// Sets stopReason directly (context overflow -> context_window_exceeded), taking precedence over inference from the stream-finish info.
        stopReason: StopReason? = nil
    ) {
        guard let session = sessions[conversationID],
              session.messageID == messageID,
              session.sendTaskID == expectedSendTaskID else { return }
        let contextAttempt = session.contextAttempt

        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }

        var updated = conversations[ci]
        // stopReason only looks at the answer body (not the reasoning, nor the failure text added below).
        let resolvedStopReason = stopReason ?? failureStopReason(in: conversationID, messageID: messageID)
        settleContextLedger(contextAttempt, stopReason: resolvedStopReason, observedInput: nil, recordsSample: false)
        if let session = sessions[conversationID], session.messageID == messageID {
            updated.messages[mi].text = session.text
            // Provider capability spec v2: Web Search citations accumulated before the failure are persisted too, so already-fetched citations are not hidden from the user
            if !session.citations.isEmpty {
                updated.messages[mi].citations = session.citations
            }
            // The reasoning text accumulated before the failure is persisted too; the duration falls back to endedAt (or the failure time).
            let trimmedReasoning = session.reasoningText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedReasoning.isEmpty {
                updated.messages[mi].reasoningText = session.reasoningText
                if let start = session.reasoningStartedAt {
                    let end = session.reasoningEndedAt ?? Date()
                    let elapsedMs = Int64((end.timeIntervalSince(start) * 1000).rounded())
                    if elapsedMs > 0 {
                        updated.messages[mi].reasoningDurationMs = elapsedMs
                    }
                }
            }
            removeSession(for: conversationID)
        }
        if updated.messages[mi].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.messages[mi].text = userFacingText
        }
        updated.messages[mi].estimatedCost = estimatedCost
        // Generic failures preserve the requested snapshot. Only the production tracker which
        // already matched an exact Server locator may replace it with rejected.
        if let execution = terminalExecution ?? CapabilityExecutionRuntime.current?.terminalResult(),
           execution.states.values.contains(.rejected) {
            updated.messages[mi].capabilityExecution = execution
        }
        updated.messages[mi].stopReason = resolvedStopReason
        updated.messages[mi].state = .failed
        updated.messages[mi].errorTitle = title
        updated.messages[mi].errorDetail = detail
        updated.messages[mi].recoveryPrimaryAction = recoveryPrimaryAction
        updated.updatedAt = ConversationListMetadata.computeActivityAt(for: updated)
        ConversationListMetadata.apply(to: &updated)
        appState.upsertConversationProjection(updated)
    }

    /// Whether this attempt received a new body or reasoning delta (failure_phase). Content that existed before the attempt started does not count.
    private static func hasStreamedOutput(_ session: StreamingSession) -> Bool {
        (hasAnswerContent(session.text) && session.text != session.baselineText)
            || (hasAnswerContent(session.reasoningText) && session.reasoningText != session.baselineReasoning)
    }

    /// Normalization before a streaming delta is written (a pure function, locked by unit tests): when the accumulated text is empty the delta's leading whitespace is stripped,
    /// matching the leading-edge `trimmingCharacters(.whitespacesAndNewlines)` each service applies to result.text in `.done`
    /// - so the streamed accumulated text never starts with whitespace and the finalized text is always its prefix continuation.
    /// A nil return means this delta is empty after stripping and should be skipped entirely (nothing written, no notification).
    nonisolated static func sanitizedStreamingDelta(_ delta: String, accumulatedIsEmpty: Bool) -> String? {
        guard accumulatedIsEmpty else { return delta }
        let stripped = delta.drop { ch in
            ch.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
        }
        guard !stripped.isEmpty else { return nil }
        return String(stripped)
    }

    /// The provider-side accumulatedText is the authoritative full output of this request, while sessions[convID].text may lose content to a flush race.
    /// Called before completeStreamingMessage, falling back on the provider result. For a continuation (appendsToExistingText) the provider
    /// only knows the part added this time, which must be appended after baselineText (the original body of the target assistant), otherwise the original body is overwritten wholesale.
    /// The message + task double guard stops the done of an old stream from overwriting a retry / continue session that reuses the same messageID.
    private func reconcileStreamingText(
        with fullText: String,
        in conversationID: UUID,
        messageID: UUID,
        expectedSendTaskID: UUID
    ) {
        guard !fullText.isEmpty,
              sessions[conversationID]?.messageID == messageID,
              sessions[conversationID]?.sendTaskID == expectedSendTaskID else { return }
        let baseline = sessions[conversationID]?.baselineText ?? ""
        let current = sessions[conversationID]?.text ?? baseline
        sessions[conversationID]?.text = Self.reconciledStreamingText(
            baseline: baseline, current: current, fullText: fullText
        )
    }

    /// Aligns the full text of the completion event to the conversation body: baseline (the body present before the continuation) + fullText.
    /// Some upstreams (Grok) strip the leading whitespace from result.text on completion, so a continuation join would glue the two segments together;
    /// when the streamed delta starts with whitespace and equals fullText after stripping it, that leading whitespace is kept.
    static func reconciledStreamingText(baseline: String, current: String, fullText: String) -> String {
        guard current.hasPrefix(baseline),
              let first = fullText.first, !first.isWhitespace else { return baseline + fullText }
        let streamed = current.dropFirst(baseline.count)
        let leading = streamed.prefix { $0.isWhitespace }
        guard !leading.isEmpty else { return baseline + fullText }
        let rest = streamed.dropFirst(leading.count)
        guard fullText.hasPrefix(rest) || rest.hasPrefix(fullText) else { return baseline + fullText }
        return baseline + leading + fullText
    }

    /// Non-streaming path: pre-processes the URL images in attachments, downloading them and writing into `sessions[convID].pendingImageData`,
    /// for the later `completeStreamingMessage` to write to disk. Isolated per conversation.
    private func preDownloadImageAttachments(_ attachments: [Attachment]?, in conversationID: UUID) async {
        guard let attachments else { return }
        for att in attachments where att.kind == .image {
            if let b64 = att.base64Data, b64.hasPrefix("http"), let url = URL(string: b64) {
                if let data = await downloadGeneratedImage(from: url) {
                    sessions[conversationID]?.pendingImageData[att.id] = data
                }
            }
        }
    }

    /// Handles an AI image during streaming: decodes base64 -> holds the Data and clears base64Data.
    /// Compatible with three upstream sources:
    /// - HTTP URL (DALL-E via OpenRouter) -> downloaded as binary
    /// - plain base64 (OpenAI / most relays)
    /// - a `data:image/png;base64,XXXX` prefixed data URL (some relays such as ylsagi return this)
    ///
    /// Isolated per conversation: written into `sessions[conversationID]?.pendingImageData` / `attachments`,
    /// so decode results of different conversations never pollute each other.
    private func handleStreamingImagePart(_ attachment: Attachment, in conversationID: UUID) async {
        var att = attachment
        if let b64 = att.base64Data, b64.hasPrefix("http"), let url = URL(string: b64) {
            if let data = await downloadGeneratedImage(from: url) {
                sessions[conversationID]?.pendingImageData[att.id] = data
                #if DEBUG
                print("[ImageGen] streaming URL fetched, bytes=\(data.count), attID=\(att.id)")
                #endif
            }
        } else if let b64 = att.base64Data, !b64.isEmpty,
                  let data = Self.decodeImageBase64(b64) {
            sessions[conversationID]?.pendingImageData[att.id] = data
            #if DEBUG
            let img = UIImage(data: data)
            print("[ImageGen] streaming decoded OK, bytes=\(data.count), UIImageValid=\(img != nil), UIImageSize=\(img?.size ?? .zero), attID=\(att.id)")
            #endif
        } else if let b64 = att.base64Data, !b64.isEmpty {
            #if DEBUG
            print("[ImageGen] decode base64 failed, length=\(b64.count), prefix=\(b64.prefix(40))")
            #endif
        }
        att.base64Data = nil
        sessions[conversationID]?.attachments.append(att)

    }

    /// Accumulates one reasoning chunk into the current session and triggers a partial cell refresh.
    /// Records startedAt on the first reasoning received; it shares the same streamingSubject with the body delta, so a single cell subscription refreshes both the text and the reasoning.
    /// The `messageID` guard stops the reasoning of an old stream from leaking into a new message across a message boundary (the same conversation switched to a new messageID).
    /// The `sendTaskID` guard follows the same pattern as `flushBufferedDelta`: when the user taps stop and immediately "Continue" reusing the same messageID,
    /// a reasoning chunk of the old task, cancelled but still yielded at an await point, must not pollute the new task's reasoningText.
    private func appendReasoning(_ chunk: String, in conversationID: UUID, messageID: UUID, sendTaskID: UUID) {
        // An empty string is **not dropped**: during a long thinking phase upstreams such as DeepSeek only send a
        // `reasoning_content: ""` heartbeat, and the real content comes out in one piece after the whole thinking ends (the first non-empty
        // reasoning was observed at 279s). The carrier here is **the event itself**, not the text - `reasoningText.append("")`
        // is a no-op and an empty string never becomes a character on screen; the downstream `UIKitReasoningBlock` shows
        // "Thinking..." + a pulsing dot as soon as it receives the event. Dropping the heartbeat would leave the UI with zero feedback for the whole thinking window, and the user could not tell thinking from stuck.
        // No side effect on the persistence side: `completeStreamingMessage` / interruption / failure all use
        // `trimmedReasoning.isEmpty` as the gate, so a pure heartbeat never writes an empty reasoningText or a phantom duration.
        // Mutate in place through the modify accessor (zero copy): taking the struct out and writing it back would memcpy the whole reasoningText on every chunk,
        // see the comment of `StreamingSession.appendReasoning`.
        guard let revision = sessions[conversationID]?
            .appendReasoning(chunk, messageID: messageID, sendTaskID: sendTaskID) else { return }
        // A nonempty normalized parser event is evidence only when the TaskLocal tracker has an
        // exact Server binding for this owner/protocol/parser.  A display-only heartbeat remains
        // useful UI feedback but is never execution evidence.
        CapabilityExecutionRuntime.recordParserEvent(.reasoning, nonEmpty: !chunk.isEmpty)
        // A non-empty reasoning delta = the model spoke again, so the activity ends here; an empty heartbeat does not clear it (the reasoning block moves by itself during a search).
        if !chunk.isEmpty {
            clearStreamActivity(in: conversationID)
        }
        reasoningSubjects[conversationID]?.send(ReasoningStreamDelta(
            messageID: messageID,
            sendTaskID: sendTaskID,
            revision: revision,
            delta: chunk
        ))
    }

    // MARK: - Stream activity

    /// The only entry that sets the activity. The `messageID` / `sendTaskID` guard follows the same pattern as `appendReasoning`:
    /// an old task that was cancelled but still emits events at an await point must not attach an activity to the new task's session.
    private func recordStreamActivity(
        _ activity: StreamActivity,
        in conversationID: UUID,
        messageID: UUID,
        sendTaskID: UUID
    ) {
        guard sessions[conversationID]?.messageID == messageID,
              sessions[conversationID]?.sendTaskID == sendTaskID,
              sessions[conversationID]?.activity != activity else { return }
        sessions[conversationID]?.activity = activity
        activitySubjects[conversationID]?.send(StreamActivityState(messageID: messageID, activity: activity))
    }

    private func clearStreamActivity(in conversationID: UUID) {
        guard let messageID = sessions[conversationID]?.messageID,
              sessions[conversationID]?.activity != nil else { return }
        sessions[conversationID]?.activity = nil
        activitySubjects[conversationID]?.send(StreamActivityState(messageID: messageID, activity: nil))
    }

    /// The session was removed / overwritten: tells subscribers this message's stream ends here (the activity is cleared and the waiting feedback collapses as a whole).
    /// Sent only once per session, not per token.
    private func publishStreamEnded(for session: StreamingSession?, in conversationID: UUID) {
        guard let session else { return }
        activitySubjects[conversationID]?.send(
            StreamActivityState(messageID: session.messageID, activity: nil, isStreaming: false)
        )
    }

    /// The landing point where a live body delta enters `session.text` (called after the `flushBufferedDelta` throttle).
    /// The activity is cleared before the body signal is sent: by the time the cell receives this body the status line has already given way and will not share the screen with the new characters.
    private func commitStreamingBodyDelta(_ sanitized: String, in conversationID: UUID) {
        sessions[conversationID]?.text.append(sanitized)
        clearStreamActivity(in: conversationID)
        streamingSubjects[conversationID]?.send()
    }

    /// Records reasoningEndedAt when the first body .delta (or done) arrives.
    /// The caller invokes it the first time it enters the case .delta / done branch; repeated calls are idempotent (an existing endedAt is not overwritten).
    /// The `sendTaskID` guard is the same as `appendReasoning`: it stops a chunk of an old task at an await point from overwriting the new task's endedAt.
    private func markReasoningEndedIfNeeded(in conversationID: UUID, messageID: UUID, sendTaskID: UUID) {
        guard var session = sessions[conversationID],
              session.messageID == messageID,
              session.sendTaskID == sendTaskID else { return }
        guard session.reasoningStartedAt != nil, session.reasoningEndedAt == nil else { return }
        session.reasoningEndedAt = Date()
        sessions[conversationID] = session
    }

    /// Provider capability spec v2: accumulates Web Search citations while streaming.
    /// TransportStrategy already dedupes / merges by URL key internally, so this method only overwrites.
    /// The citations are also written to the ChatMessage so the chat cell can see them (while streaming the cell
    /// re-renders through PassthroughSubject and reads `model.message.citations`).
    /// When a stream is interrupted, the citations accumulated so far are persisted to the database through `completeStreamingMessage`.
    private func recordCitations(_ citations: [Citation], in conversationID: UUID) {
        guard !citations.isEmpty else { return }
        // This is called by the real TransportStrategy → StreamEvent path.  The tracker still
        // requires a current recipe signal, so arbitrary citations cannot promote an owner.
        CapabilityExecutionRuntime.recordParserEvent(.citations, nonEmpty: true)
        let resolvedCitations = citations
        sessions[conversationID]?.citations = resolvedCitations

        // Write the citation delta to the ChatMessage so the UI shows it live.
        // updatedAt is not modified during streaming (to avoid list reorder jitter), the same idea as reconcileStreamingText.
        guard let session = sessions[conversationID],
              let ci = conversations.firstIndex(where: { $0.id == conversationID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == session.messageID })
        else { return }
        // Reduce needless @Observable triggers: publish only when the citations really changed.
        if conversations[ci].messages[mi].citations != resolvedCitations {
            var updated = conversations[ci]
            updated.messages[mi].citations = resolvedCitations
            appState.upsertConversationProjection(updated)
            streamingSubjects[conversationID]?.send()
        }
    }

    /// Lenient base64 decoding: strips the data URL prefix, ignores line breaks/whitespace, and tolerates base64url variants
    nonisolated static func decodeImageBase64(_ raw: String) -> Data? {
        let maxDecodedBytes = ChatAttachmentImportPolicy.maxAttachmentBytes
        let maxEncodedBytes = ((maxDecodedBytes + 2) / 3) * 4
        guard raw.utf8.count <= maxEncodedBytes + 256 else {
            reportGeneratedImageRejection(reason: "base64_input_too_large")
            return nil
        }

        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip the data URL prefix
        if s.hasPrefix("data:") {
            if let comma = s.firstIndex(of: ",") {
                s = String(s[s.index(after: comma)...])
            }
        }
        // Try the lenient option first (ignoring line breaks, spaces and the like)
        if let data = Data(base64Encoded: s, options: [.ignoreUnknownCharacters]) {
            guard data.count <= maxDecodedBytes else {
                reportGeneratedImageRejection(reason: "base64_output_too_large")
                return nil
            }
            return data
        }
        // base64url -> standard base64 (replace - and _)
        var normalized = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Fill in the padding
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: normalized, options: [.ignoreUnknownCharacters]) else {
            reportGeneratedImageRejection(reason: "invalid_base64")
            return nil
        }
        guard data.count <= maxDecodedBytes else {
            reportGeneratedImageRejection(reason: "base64_output_too_large")
            return nil
        }
        return data
    }

    private func downloadGeneratedImage(from url: URL) async -> Data? {
        do {
            return try await BoundedNetworkDataLoader(
                maxBytes: ChatAttachmentImportPolicy.maxAttachmentBytes
            ).data(from: url)
        } catch {
            let rejection = error is BoundedNetworkDataError ? "too_large" : "download_failed"
            print("[ImageGen] generated image download rejected: \(rejection)")
            return nil
        }
    }

    nonisolated private static func reportGeneratedImageRejection(reason: String) {
        print("[ImageGen] Generated image payload was rejected before persistence: \(reason)")
    }

    private func updateAssistantMessageMetadata(
        conversationID: UUID,
        messageID: UUID,
        estimatedCost: Double,
        state: ChatMessageState,
        errorTitle: String? = nil,
        errorDetail: String? = nil
    ) {
        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }

        var updated = conversations[ci]
        updated.messages[mi].estimatedCost = estimatedCost
        updated.messages[mi].state = state
        updated.messages[mi].errorTitle = errorTitle
        updated.messages[mi].errorDetail = errorDetail
        updated.updatedAt = ConversationListMetadata.computeActivityAt(for: updated)
        ConversationListMetadata.apply(to: &updated)
        appState.upsertConversationProjection(updated)
    }

    private func finishSendTaskIfCurrent(_ taskID: UUID, conversationID: UUID) {
        guard sessions[conversationID]?.sendTaskID == taskID else { return }
        // Normally completeStreamingMessage / failStreamingMessage has already cleaned up; this is a defensive cleanup
        if sessions[conversationID] != nil {
            removeSession(for: conversationID)
        }
        // isAnyStreaming suppressed persistence during streaming, so it has to be triggered once now
        appState.triggerPersistSession()
    }

    private func currentAssistantText(conversationID: UUID, messageID: UUID) -> String {
        // During streaming the text is in sessions[conversationID].text
        if let session = sessions[conversationID], session.messageID == messageID {
            return session.text
        }
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == messageID }) else {
            return ""
        }

        return conversations[conversationIndex].messages[messageIndex].text
    }

    private func currentAssistantCost(conversationID: UUID, messageID: UUID) -> Double {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == messageID }) else {
            return 0
        }

        return conversations[conversationIndex].messages[messageIndex].estimatedCost
    }

    private func resolvedDeliveredCost(from result: ProviderChatResult, model: AIModel, providerKind: ProviderKind) -> Double {
        ChatDeliveryAccounting.deliveredCost(result: result, model: model, providerKind: providerKind)
    }

    private func sampleContinuation(for modelName: String) -> String {
        String(
            format: L10n.tr("Continuing with %@, here are the strongest next steps:\n\n- Summarize the key decision in one sentence.\n- Turn the next action into a concrete checklist.\n- Flag any open risks or assumptions before you move on."),
            modelName
        )
    }

    #if DEBUG
    func debugInitialCapabilitySelectionForTesting(
        _ requested: ChatCapabilitySelection
    ) -> ChatCapabilitySelection {
        initialCapabilitySelection(requested)
    }

    func debugRecoveryCapabilitySelectionForTesting(
        _ requested: ChatCapabilitySelection,
        preservingLibraryModeFrom message: ChatMessage,
        model: AIModel
    ) -> ChatCapabilitySelection {
        recoveryCapabilitySelection(
            requested,
            preservingLibraryModeFrom: message,
            model: model
        )
    }

    func debugGatedRecoveryCapabilitySelectionForTesting(
        _ requested: ChatCapabilitySelection,
        preservingLibraryModeFrom message: ChatMessage,
        model: AIModel,
        provider: Provider
    ) async -> ChatCapabilitySelection? {
        await gatedRecoveryCapabilitySelection(
            requested,
            preservingLibraryModeFrom: message,
            model: model,
            provider: provider
        )
    }

    func debugInstallStreamingStateForTesting(
        conversationID: UUID,
        messageID: UUID,
        text: String,
        sendTaskID: UUID = UUID(),
        citations: [Citation] = []
    ) {
        var session = StreamingSession(
            messageID: messageID,
            text: text,
            attachments: [],
            pendingImageData: [:],
            sendTask: nil,
            sendTaskID: sendTaskID
        )
        session.citations = citations
        addSession(
            session,
            for: conversationID
        )
    }

    func debugInstallActiveSendTaskIDForTesting(
        conversationID: UUID,
        messageID: UUID,
        taskID: UUID
    ) {
        addSession(
            StreamingSession(
                messageID: messageID,
                text: "",
                attachments: [],
                pendingImageData: [:],
                sendTask: nil,
                sendTaskID: taskID
            ),
            for: conversationID
        )
    }

    func debugApplyNonStreamingCompletionForTesting(
        taskID: UUID,
        conversationID: UUID,
        messageID: UUID,
        result: ProviderChatResult
    ) {
        applyNonStreamingCompletionIfCurrent(
            taskID: taskID,
            conversationID: conversationID,
            messageID: messageID,
            result: result,
            estimatedCost: result.estimatedCost
        )
    }

    static func debugPrepareImageAttachmentsForDiskForTesting(
        _ attachments: [Attachment],
        imageDataByAttachmentID: [UUID: Data],
        makeImageID: @escaping () -> String = { UUID().uuidString }
    ) -> (attachments: [Attachment], writeImageIDs: [String]) {
        let prepared = prepareImageAttachmentsForDisk(
            attachments,
            imageDataByAttachmentID: imageDataByAttachmentID,
            makeImageID: makeImageID
        )
        return (prepared.attachments, prepared.writes.map(\.imageID))
    }

    /// Directly runs the partial-preservation guard at the entry of `queueAssistantResponse`,
    /// for the regression test: when switching conversations / regenerating, the old streaming must land as .interrupted.
    func debugInvokePartialPreservationGuardForTesting(
        conversationID: UUID,
        newMessageID: UUID
    ) {
        if let oldSession = sessions[conversationID], oldSession.messageID != newMessageID {
            persistPartialStreamingAsInterrupted(in: conversationID, userInitiated: true)
        }
    }

    /// Test helper: exposes the current BG task ID. Requested by `prepareForSessionBoundary` and
    /// released when `endSessionBoundary` / all sessions are cleared. `.invalid` = no active BG task.
    var debugBackgroundTaskID: UIBackgroundTaskIdentifier { backgroundTaskID }

    /// Test helper: simulates a conversation stream finishing naturally (going through the full completeStreamingMessage path);
    /// internally it syncs streamingText -> message.text, sets the final state and removes the session.
    func debugFinishStreamingForTesting(conversationID: UUID, state: ChatMessageState) {
        guard let session = sessions[conversationID] else { return }
        completeStreamingMessage(
            conversationID: conversationID,
            messageID: session.messageID,
            expectedSendTaskID: session.sendTaskID,
            state: state
        )
    }

    /// Simulates the terminal callback of a given send task; used to lock that an old task must not close a new session.
    func debugFinishStreamingForTesting(
        conversationID: UUID,
        messageID: UUID,
        expectedSendTaskID: UUID,
        state: ChatMessageState
    ) {
        completeStreamingMessage(
            conversationID: conversationID,
            messageID: messageID,
            expectedSendTaskID: expectedSendTaskID,
            state: state
        )
    }

    /// Test helper: directly triggers `gracefullyInterruptAllStreaming`.
    /// Simulates the BG task expirationHandler path - all active streams land as .interrupted and the BG task is released.
    func debugTriggerGracefulInterruptForTesting() {
        gracefullyInterruptAllStreaming()
    }

    /// Test helper: manually sends one empty notification to a conversation's streamingSubject.
    /// Used to verify that per-conversation publishers do not interfere with each other.
    func debugSendSubjectForTesting(in conversationID: UUID) {
        subject(for: conversationID).send()
    }

    /// Test helper: simulates a single token append. Directly modifies sessions[convID].text and sends the subject,
    /// without changing the `streamingConversationIDs` set (to verify the set stays stable under the token flow).
    func debugAppendTokenForTesting(delta: String, in conversationID: UUID) {
        sessions[conversationID]?.text.append(delta)
        streamingSubjects[conversationID]?.send()
    }

    func debugApplyLibraryGeneratedTextForTesting(
        _ generatedText: String,
        initialText: String,
        conversationID: UUID,
        messageID: UUID,
        sendTaskID: UUID
    ) {
        applyToolLoopText(
            generatedText,
            initialText: initialText,
            conversationID: conversationID,
            assistantMessageID: messageID,
            sendTaskID: sendTaskID
        )
    }

    /// Test helper: directly drives the passive-interruption path of "background grace expired" (in production the BG task expirationHandler fires it,
    /// and a test cannot get the system callback). A passive interruption only lands .interrupted.
    func debugGracefullyInterruptAllStreamingForTesting() {
        gracefullyInterruptAllStreaming()
    }

    #endif
}
