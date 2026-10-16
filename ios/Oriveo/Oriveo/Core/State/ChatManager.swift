import Combine
import Foundation
import OriveoProviderKit
import UIKit

struct ReasoningStreamDelta: Equatable, Sendable {
    let messageID: UUID
    let sendTaskID: UUID
    let revision: UInt64
    let delta: String
}

struct ReasoningStreamSnapshot: Equatable, Sendable {
    let messageID: UUID
    let sendTaskID: UUID
    let revision: UInt64
    let text: String
}

@MainActor
final class ChatManager {
    nonisolated static let continueInstruction =
        "Continue from where you stopped. Do not repeat what you have already said."

    unowned private(set) var appState: AppState!
    private let providerSession: URLSession
    let toolCallMemory: ToolCallMemoryStore

    /// Refreshes the provider configuration after a subscription request is rejected for its client version.
    /// It is an instance property only so that this step of the send path can be tested: the default goes
    /// straight to the network.
    var subscriptionConfigurationRefresher: () async -> Void = {
        await MetadataClient.shared.forceRefresh()
    }
    /// Prepares the credential of a Grok subscription before a request goes out. The credential lives in the
    /// Keychain, which an unsigned test host cannot use; as an instance property, a test can supply an
    /// already prepared outbound context. The default is the direct call.
    var grokSubscriptionPreparer: (UUID) async -> Result<GrokSubscriptionRuntime.Prepared, GrokSubscriptionError> = {
        providerID in
        await GrokSubscriptionRuntime.prepare(providerID: providerID)
    }
    /// The confirmation gate for remote MCP tools. Nil in production, where `AppState.mcpConfirmationCoordinator`
    /// (the confirmation sheet) is used; tests put a scripted gate here.
    var mcpConfirmationGate: (any McpConfirmationGate)?
    /// The gate for a sign-in that expired mid-answer. Nil in production, where
    /// `AppState.mcpReauthorizationCoordinator` is used.
    var mcpReauthorizationGate: (any McpReauthorizationGate)?
    /// Runtime limits for remote MCP: the catalog's `mcpRuntimeConfig`, or the built-in fallback values when
    /// the snapshot has none.
    private var mcpRuntimeConfigProvider: () -> McpRuntimeConfig = {
        MetadataClient.shared.syncMcpRuntimeConfig()
    }
    /// Test seam: how the MCP protocol client is built (nil in production, which uses a real network session).
    private var mcpClientFactory: (@Sendable (URL) -> McpClient)?

    init(providerSession: URLSession = .shared, toolCallMemory: ToolCallMemoryStore = .shared) {
        self.providerSession = providerSession
        self.toolCallMemory = toolCallMemory
    }

    // MARK: - Streaming session state

    /// The route a relay send actually took, carried on the streaming session so the delivered / failed paths can write back what happened.
    private struct RelayDeliveryRoute {
        let providerID: UUID
        let modelID: String
        let transport: RelayTransport
        /// The key in effect for this model when the send started: after a success it clears the "no access" mark and records the key status as ok.
        let keyID: String
        /// The key value and outbound configuration actually sent: a write-back is dropped if the current state no longer matches them.
        let keyWriteIdentity: RelayCatalogConnectionIdentity
        /// The protocol switched to when this message fell back at protocol level.
        var switchedTo: RelayTransport? = nil
        /// This message fell back at protocol level. Re-routing the first send (`switchedTo` = the first-send protocol) does not count.
        var protocolFallback = false
        /// The relay web switch is on this turn (and in the relay web scope): if the delivering attempt carried no fragment, a notice is attached to the reply.
        var webOn = false
        /// The hash of the fragment carried on each protocol this turn: on delivery it is looked up by the protocol actually used, and with citations searched / observed is written.
        var webFragmentHashes: [RelayTransport: String] = [:]
        /// Protocols whose fragment was rejected with 400 / 422 and resent without it: delivering on one of them writes rejected / tested.
        var webStripped: Set<RelayTransport> = []
    }

    private struct StreamingSession {
        var messageID: UUID
        var text: String
        var attachments: [Attachment]
        var pendingImageData: [UUID: Data]
        var sendTask: Task<Void, Never>?
        var sendTaskID: UUID
        var startedAt: Date = Date()
        /// Citations collected during this send; copied onto the ChatMessage at completion.
        var citations: [Citation] = []
        var reasoningText: String = ""
        var reasoningRevision: UInt64 = 0
        var reasoningStartedAt: Date?
        var reasoningEndedAt: Date?
        /// The protocol this model actually used when the relay send started: on delivery it is used to promote `reachable` to `observed`.
        var relayDeliveryRoute: RelayDeliveryRoute?
        /// The activity currently observed on this stream. Transient: it lives only in the
        /// session and is never persisted or copied onto a `ChatMessage`. `recordStreamActivity`
        /// is the only place that sets it; it is cleared by the next body delta, the next
        /// non-empty reasoning delta, and when the session is removed (finished, failed, stopped).
        var activity: StreamActivity?

        /// Appends a reasoning chunk in place and returns the new revision.
        ///
        /// The obvious `guard var session = sessions[id] … sessions[id] = session` shape takes a
        /// second reference to the session, so every append re-copies the whole accumulated
        /// reasoning text. Called as `sessions[id]?.appendReasoning(…)`, this goes through the
        /// dictionary's in-place `_modify` accessor instead and the buffer keeps its storage.
        ///
        /// Returns `nil` when the session has moved on to another message or send task: a chunk
        /// still in flight from a superseded send must not land on the current one.
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

    private var sessions: [UUID: StreamingSession] = [:]

    /// One subject per conversation, so a token arriving in one conversation only wakes the cells
    /// subscribed to that conversation. They outlive an individual send and are released by
    /// `discardStreamingResources(for:)`.
    private var streamingSubjects: [UUID: PassthroughSubject<Void, Never>] = [:]
    private var reasoningSubjects: [UUID: PassthroughSubject<ReasoningStreamDelta, Never>] = [:]
    /// Activity channel. It fires only at the moment an activity is set or cleared, never per
    /// token. Same lifetime as the two subjects above.
    private var activitySubjects: [UUID: PassthroughSubject<StreamActivityState, Never>] = [:]

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
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    func bind(to appState: AppState) {
        self.appState = appState
    }

    // MARK: - Conversation access

    private var conversations: [Conversation] {
        appState.conversations
    }

    /// Cold-start memory is a summary projection, so the thread must be loaded before its
    /// messages are read or written (see the AppState method of the same name).
    @discardableResult
    private func hydrateConversationMessagesIfNeeded(id: UUID) -> Bool {
        appState.hydrateConversationMessagesIfNeeded(id: id)
    }

    // MARK: - Streaming sessions

    /// Registers a streaming session and publishes the active conversation set.
    private func addSession(_ session: StreamingSession, for conversationID: UUID) {
        // A new send replacing an existing session ends the old stream here, exactly as
        // `removeSession` would.
        publishStreamEnded(for: sessions[conversationID], in: conversationID)
        sessions[conversationID] = session
        streamingConversationIDs = Set(sessions.keys)
    }

    /// Drops the streaming session. Ends the background task once no sessions remain.
    @discardableResult
    private func removeSession(for conversationID: UUID) -> StreamingSession? {
        appState.mcpConfirmationCoordinator.cancel(conversationID: conversationID)
        appState.mcpReauthorizationCoordinator.cancel(conversationID: conversationID)
        let removed = sessions.removeValue(forKey: conversationID)
        streamingConversationIDs = Set(sessions.keys)
        // Finishing, failing and stopping all remove the session here. The activity goes with it
        // and subscribed cells hide the status line right away.
        publishStreamEnded(for: removed, in: conversationID)
        if sessions.isEmpty {
            endSessionBoundary()
        }
        return removed
    }

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

    func discardStreamingResources(for conversationID: UUID) {
        if sessions[conversationID] != nil {
            cancelGeneration(in: conversationID) // this also removes the session
        }
        streamingSubjects.removeValue(forKey: conversationID)
        reasoningSubjects.removeValue(forKey: conversationID)
        activitySubjects.removeValue(forKey: conversationID)
    }

    // MARK: - Streaming queries, by conversation

    /// The assistant message currently streaming in this conversation, or `nil` when it is idle.
    func streamingMessageID(in conversationID: UUID) -> UUID? {
        sessions[conversationID]?.messageID
    }

    func streamingText(in conversationID: UUID) -> String {
        sessions[conversationID]?.text ?? ""
    }

    func streamingReasoning(in conversationID: UUID) -> String {
        sessions[conversationID]?.reasoningText ?? ""
    }

    func streamingReasoningSnapshot(in conversationID: UUID) -> ReasoningStreamSnapshot? {
        guard let session = sessions[conversationID] else { return nil }
        return ReasoningStreamSnapshot(
            messageID: session.messageID,
            sendTaskID: session.sendTaskID,
            revision: session.reasoningRevision,
            text: session.reasoningText
        )
    }

    func streamingTextDidChange(in conversationID: UUID) -> AnyPublisher<Void, Never> {
        subject(for: conversationID).eraseToAnyPublisher()
    }

    func streamingReasoningDidChange(in conversationID: UUID) -> AnyPublisher<ReasoningStreamDelta, Never> {
        reasoningSubject(for: conversationID).eraseToAnyPublisher()
    }

    /// The activity snapshot of the message currently streaming, or `nil` when there is no
    /// session. A cell reads it once when it binds or is rebound, then follows the channel.
    func streamingActivity(in conversationID: UUID) -> StreamActivityState? {
        guard let session = sessions[conversationID] else { return nil }
        return StreamActivityState(messageID: session.messageID, activity: session.activity)
    }

    func streamingActivityDidChange(in conversationID: UUID) -> AnyPublisher<StreamActivityState, Never> {
        activitySubject(for: conversationID).eraseToAnyPublisher()
    }

    func isBusyStreaming(in conversationID: UUID) -> Bool {
        sessions[conversationID] != nil
    }

    /// Whether this connection and model can use MCP tools (for the tool panel and the composer chip; the
    /// same verdict the send path uses).
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

    /// Test seam: exposes the session's `sendTaskID` so a test can satisfy the same guard
    /// `appendReasoning` applies.
    func _testingSendTaskID(in conversationID: UUID) -> UUID? {
        sessions[conversationID]?.sendTaskID
    }

    func _testingAppendReasoning(
        _ chunk: String,
        in conversationID: UUID,
        messageID: UUID,
        sendTaskID: UUID
    ) {
        appendReasoning(chunk, in: conversationID, messageID: messageID, sendTaskID: sendTaskID)
    }

    /// Test seam: routes a real `StreamEvent` through the production dispatch switch rather than
    /// letting a test call `recordUnhandledToolCalls` directly, so the routing itself is covered.
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
        case .delta, .reasoning, .imagePart, .citations, .activity, .done:
            break
        }
    }

    /// Test seam: hands a `StreamEvent` produced by the parsing layer to the activity handler
    /// through the same dispatch the production switch uses. Only `.activity` is handled, and the
    /// handler is the production `recordStreamActivity`.
    func _testingDispatchActivityStreamEvent(
        _ event: StreamEvent,
        in conversationID: UUID,
        messageID: UUID,
        sendTaskID: UUID
    ) {
        switch event {
        case let .activity(activity):
            recordStreamActivity(activity, in: conversationID, messageID: messageID, sendTaskID: sendTaskID)
        case .delta, .reasoning, .imagePart, .citations, .toolCallDeltas, .done:
            break
        }
    }

    /// Test seam: drives the production point where a body delta enters the session, the step
    /// `flushBufferedDelta` performs.
    func _testingCommitStreamingBodyDelta(_ delta: String, in conversationID: UUID) {
        commitStreamingBodyDelta(delta, in: conversationID)
    }

    /// Test seam: completes a streaming message through the production completion path.
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

    func _testingFailStreamingMessage(
        conversationID: UUID,
        messageID: UUID,
        sendTaskID: UUID,
        userFacingText: String = "",
        estimatedCost: Double = 0,
        title: String = "",
        detail: String = "",
        errorCode: String
    ) {
        failStreamingMessage(
            conversationID: conversationID,
            messageID: messageID,
            expectedSendTaskID: sendTaskID,
            userFacingText: userFacingText,
            estimatedCost: estimatedCost,
            title: title,
            detail: detail,
            errorCode: errorCode
        )
    }

    func _testingReasoningStorageIdentity(in conversationID: UUID) -> UInt {
        guard let text = sessions[conversationID]?.reasoningText else { return 0 }
        return text.utf8.withContiguousStorageIfAvailable { buffer in
            UInt(bitPattern: buffer.baseAddress)
        } ?? 0
    }

#endif

    var isAnyStreaming: Bool { !sessions.isEmpty }

    // MARK: - Mock streaming harness

    #if DEBUG
    /// Builds a conversation with canned content so a simulator or UI run has something to render
    /// without contacting a provider.
    @MainActor
    func bootstrapMockConversationForTesting(withHistory: Bool = false) -> UUID {
        let id = UUID()
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

    /// Appends a mock user message and reveals a canned assistant reply token by token, through
    /// the same session and subject plumbing a real send uses.
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
        // Same order as a real send: stage the anchor first, so the list already knows which user
        // message to scroll to by the time the new projection reaches it.
        appState.stagePendingChatAnchorUserMessageID(userMessage.id, in: conversationID)
        appState.upsertConversationProjection(updated)

        // No send task: there is nothing to cancel, the loop below drives the stream.
        let session = StreamingSession(
            messageID: assistantID,
            text: "",
            attachments: [],
            pendingImageData: [:],
            sendTask: nil,
            sendTaskID: UUID()
        )
        addSession(session, for: conversationID)

        // Reasoning first, then body text: the order a reasoning model streams in.
        if !reasoningTokens.isEmpty {
            sessions[conversationID]?.reasoningStartedAt = Date()
            for chunk in reasoningTokens {
                try? await Task.sleep(nanoseconds: UInt64(tokenIntervalMs) * 1_000_000)
                sessions[conversationID]?.reasoningText.append(chunk)
                subject(for: conversationID).send()
            }
        }

        for token in assistantTokens {
            try? await Task.sleep(nanoseconds: UInt64(tokenIntervalMs) * 1_000_000)
            sessions[conversationID]?.text.append(token)
            subject(for: conversationID).send()
        }

        try? await Task.sleep(nanoseconds: 300_000_000)
        let finalText = sessions[conversationID]?.text ?? ""

        // Publish the final text before dropping the session, so the pacer gets a snapshot that
        // still matches what it is revealing instead of an empty one.
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

    func sendMessage(
        _ text: String,
        attachments: [Attachment] = [],
        quoteContext: QuoteContext? = nil,
        in conversationID: UUID,
        capabilitySelection: ChatCapabilitySelection = ChatCapabilitySelection()
    ) async -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return nil }
        guard conversations.contains(where: { $0.id == conversationID }) else { return nil }
        guard hydrateConversationMessagesIfNeeded(id: conversationID) else {
            // The local thread is not available (the database read failed, or the stored thread has
            // fewer messages than its count says): sending on an empty thread would silently drop context.
            ToastManager.shared.show(L10n.tr("Loading conversation…", table: .chat))
            return nil
        }
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return nil }
        guard let provider = appState.provider(for: conversations[index].providerID) else {
            ToastManager.shared.show(L10n.tr("The selected provider is no longer available."))
            return nil
        }

        let model = appState.sendableModel(for: conversations[index], provider: provider)
        guard let model else { return nil }
        let modelName = model.name
        let storedModelID = ModelResolver.preferredStoredModelIdentifier(for: model, providerKind: provider.kind)
        let requestedCapabilitySelection = requestedCapabilitySelection(
            capabilitySelection,
            provider: provider,
            model: model,
            conversationID: conversationID,
            skillID: conversations[index].skillId
        )
        var resolvedCapabilitySelection = initialCapabilitySelection(requestedCapabilitySelection)
        resolvedCapabilitySelection.libraryResearchEnabled = false

        // Keep user/assistant createdAt 1ms apart so UUID sort is not the only order.
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

        // Mutate a local copy and publish once. Every assignment into `appState.conversations`
        // runs its `didSet`, which rebuilds the lookup and persists the session, so editing the
        // stored conversation field by field would pay that cost several times per send.
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
        )
        return userMessage.id
    }

    func cancelGeneration(in conversationID: UUID) {
        cancelGeneration(in: conversationID, messageID: nil)
    }

    private func cancelGeneration(in conversationID: UUID, messageID: UUID?) {
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
            messageIndex = conversations[convIndex].messages.firstIndex(where: {
                $0.id == s.messageID && $0.role == .assistant && $0.state == .generating
            })
        } else {
            messageIndex = conversations[convIndex].messages.lastIndex(where: {
                $0.role == .assistant && $0.state == .generating
            })
        }
        guard let msgIndex = messageIndex else {
            removeSession(for: conversationID)
            return
        }

        var updated = conversations[convIndex]
        if let s = session, s.messageID == updated.messages[msgIndex].id {
            updated.messages[msgIndex].text = s.text
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
        updated.messages[msgIndex].errorTitle = nil
        updated.messages[msgIndex].errorDetail = nil
        updated.messages[msgIndex].recoveryPrimaryAction = nil
        updated.updatedAt = ConversationListMetadata.computeActivityAt(for: updated)
        ConversationListMetadata.apply(to: &updated)
        appState.upsertConversationProjection(updated)

        session?.sendTask?.cancel()

        removeSession(for: conversationID)
    }
    func prepareForSessionBoundary() {
        guard isAnyStreaming, backgroundTaskID == .invalid else { return }
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "oriveo.chatStreaming") { [weak self] in
            // UIKit runs the expiration handler on the main thread, which is what
            // `MainActor.assumeIsolated` relies on. End the task before interrupting the streams:
            // the system kills the app if the handler returns without having ended it.
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
        AppLog.info(
            "Session boundary background task \(taskID.rawValue) started, \(sessions.count) sessions streaming",
            module: "ChatManager"
        )
        #endif
    }

    func endSessionBoundary() {
        guard backgroundTaskID != .invalid, sessions.isEmpty else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    /// Copies each session's accumulated text onto its message while leaving the state at
    /// `.generating`. Used at a lifecycle boundary so partial output survives even if the app is
    /// suspended before the stream finishes.
    func flushStreamingTextToMessage() {
        for (convID, session) in sessions {
            guard !session.text.isEmpty,
                  let ci = conversations.firstIndex(where: { $0.id == convID }),
                  let mi = conversations[ci].messages.firstIndex(where: { $0.id == session.messageID }),
                  conversations[ci].messages[mi].text != session.text
            else { continue }
            var updated = conversations[ci]
            updated.messages[mi].text = session.text
            appState.upsertConversationProjection(updated)
        }
    }

    /// Copies the session's partial text and reasoning onto the message and marks it
    /// `.interrupted`, so a stream that was cut short is kept and shown as stopped, not lost.
    private func persistPartialStreamingAsInterrupted(in conversationID: UUID) {
        guard let session = sessions[conversationID],
              let ci = conversations.firstIndex(where: { $0.id == conversationID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == session.messageID })
        else { return }
        var updated = conversations[ci]
        updated.messages[mi].text = session.text
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
        updated.messages[mi].recoveryPrimaryAction = nil
        try? RecipeContinuationRuntime.markInterrupted(messageID: session.messageID)
        updated.updatedAt = ConversationListMetadata.computeActivityAt(for: updated)
        ConversationListMetadata.apply(to: &updated)
        appState.upsertConversationProjection(updated)
    }

    /// Persists what every live stream has produced so far, then cancels its send task. Dropping
    /// the sockets without this step would throw away everything already streamed.
    private func gracefullyInterruptAllStreaming() {
        guard isAnyStreaming else {
            endSessionBoundary()
            return
        }
        let convIDs = Array(sessions.keys)
        for convID in convIDs {
            persistPartialStreamingAsInterrupted(in: convID)
            sessions[convID]?.sendTask?.cancel()
            removeSession(for: convID) // ends the background task once the last session is gone
        }
    }

    func forceStopStreaming() {
        appState.mcpConfirmationCoordinator.cancelAll()
        appState.mcpReauthorizationCoordinator.cancelAll()
        guard isAnyStreaming else { return }
        let convIDs = Array(sessions.keys)
        for convID in convIDs {
            cancelGeneration(in: convID)
        }
    }

    func editUserMessage(messageID: UUID, in conversationID: UUID) -> String? {
        beginEditingUserMessage(messageID: messageID, in: conversationID)?.text
    }

    func editPromptingMessage(for assistantMessageID: UUID, in conversationID: UUID) -> String? {
        beginEditingPromptingMessage(for: assistantMessageID, in: conversationID)?.text
    }

    /// Edit a user message: truncates the conversation to before it and returns the text and original attachments to put back in the composer.
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
        guard let convIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageID })
        else { return }

        var updatedForContinue = conversations[convIndex]
        updatedForContinue.modelID = storedModelID
        updatedForContinue.messages[msgIndex].providerID = provider.id
        updatedForContinue.messages[msgIndex].providerKind = provider.kind
        updatedForContinue.messages[msgIndex].providerName = provider.displayName
        updatedForContinue.messages[msgIndex].modelID = storedModelID
        updatedForContinue.messages[msgIndex].modelName = model.name
        updatedForContinue.messages[msgIndex].servedModelID = nil
        updatedForContinue.messages[msgIndex].state = .generating
        updatedForContinue.messages[msgIndex].errorTitle = nil
        updatedForContinue.messages[msgIndex].errorDetail = nil
        updatedForContinue.messages[msgIndex].recoveryPrimaryAction = nil

        updatedForContinue.updatedAt = ConversationListMetadata.computeActivityAt(for: updatedForContinue)
        let precedingMessages = conversations[convIndex].messages[..<msgIndex]
        let latestUserText = precedingMessages.last(where: { $0.role == .user })?.text ?? ""
        appState.upsertConversationProjection(updatedForContinue)

        let messagesThroughAssistant = Array(updatedForContinue.messages[...msgIndex])
        let requestSnapshot = prepareRequestSnapshot(
            conversation: updatedForContinue,
            messages: messagesThroughAssistant,
            sendPath: .continueResponse(
                assistantMessageID: messageID,
                instruction: Self.continueInstruction
            )
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
            explicitContinuationMessageID: [.moonshot, .openAI, .anthropic, .gemini, .deepseek, .openRouter, .grok].contains(provider.kind) ? messageID : nil
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
        guard let convIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageID })
        else { return }

        let precedingMessages = conversations[convIndex].messages[..<msgIndex]
        guard let lastUserMessage = precedingMessages.last(where: { $0.role == .user }) else { return }

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
        let removedMessages = Array(updatedForRegen.messages[msgIndex...])
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
            explicitContinuationMessageID: [.moonshot, .openAI, .anthropic, .gemini, .deepseek, .openRouter, .grok].contains(provider.kind) ? assistantMessageID : nil
        )
    }

    func retryMessage(
        messageID: UUID,
        in conversationID: UUID,
        capabilitySelection: ChatCapabilitySelection = ChatCapabilitySelection(),
        localCustomFragmentDisposition: LocalCustomFragmentDisposition = .include
    ) async {
        hydrateConversationMessagesIfNeeded(id: conversationID)
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

        var updatedForRetry = conversations[convIndex]
        updatedForRetry.modelID = storedModelID
        if !preservesFailedContent {
            updatedForRetry.messages[msgIndex].text = ""
            updatedForRetry.messages[msgIndex].reasoningText = nil
            updatedForRetry.messages[msgIndex].reasoningDurationMs = nil
            updatedForRetry.messages[msgIndex].citations = nil
            updatedForRetry.messages[msgIndex].attachments = nil
        }
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
        updatedForRetry.messages[msgIndex].recoveryPrimaryAction = nil
        updatedForRetry.messages[msgIndex].capabilityExecution = nil
        updatedForRetry.messages[msgIndex].unhandledToolCalls = nil
        // The step limit notice goes with the steps it describes.
        updatedForRetry.messages[msgIndex].toolSteps = nil
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
            capabilityRecoveryDescriptor: recoveryDescriptor
        )
    }

    /// The relay's web intent this turn: the switch (preference store + default layer) is on and not overridden off by the user. A rejected current record does not count:
    /// whether each attempt carries a fragment is decided by that attempt's protocol (`RelayWebProbe.chatFragments`), and when none is carried the reply gets a notice.
    /// False when out of scope (local engine / undecided protocol).
    private static func relayWebIsOn(
        provider: Provider, model: AIModel, conversationID: UUID?, skillID: UUID?
    ) -> Bool {
        guard RelayWebProbe.inScope(provider: provider, model: model) else { return false }
        let preference = RelayWebSwitch.isOn(provider: provider, model: model, conversationID: conversationID, skillID: skillID)
        return RelayWebProbe.fact(provider: provider, model: model, preference: preference)?.isOn ?? false
    }

    private func gatedRecoveryCapabilitySelection(
        _ requested: ChatCapabilitySelection,
        preservingLibraryModeFrom message: ChatMessage,
        model: AIModel,
        provider: Provider,
        conversationID: UUID? = nil
    ) async -> ChatCapabilitySelection? {
        // Relay web search: the recovery path resolves it from the switch (default layer included) the same as the first send; library recovery is switched off as usual below.
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

    /// The capability selection actually in effect this turn (web search / reasoning level), resolved from
    /// the conversation, skill and connection preference layers. Sending and the composer's pre-send attachment
    /// check read the same function, so both see the same web search switch.
    private func requestedCapabilitySelection(
        _ capabilitySelection: ChatCapabilitySelection,
        provider: Provider,
        model: AIModel,
        conversationID: UUID,
        skillID: UUID?
    ) -> ChatCapabilitySelection {
        var requestedCapabilitySelection = capabilitySelection
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
            if runtimeIdentity != nil {
                requestedCapabilitySelection.webSearchEnabled = typed.web != .off
            }
            // Relay web search: this turn's web intent = the web row fact isOn (the switch with the default layer, and not overridden off by the user);
            // whether each attempt carries a fragment is decided by that attempt's protocol. The library / custom takeover below still turns it off for this turn.
            if ProviderForm.of(provider) == .relay {
                requestedCapabilitySelection.webSearchEnabled = Self.relayWebIsOn(
                    provider: provider, model: model, conversationID: conversationID, skillID: skillID
                )
            }
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
        return requestedCapabilitySelection
    }

    /// Pre-send check when the composer's send is tapped: whether this turn's attachments fit on the route about to be used.
    ///
    /// Non-nil means they do not fit: the caller does not send, keeps the composer and shows a notice. The route
    /// and model resolution and the over-limit decision use the same functions and inputs as a real send; when
    /// the route cannot be determined yet (the catalog is not loaded, image generation, and so on) it returns
    /// nil and the failure card at send time covers it.
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
            // No conversation yet: sending creates one with the currently selected model.
            guard conversationID == nil, let active = appState.activeModel else { return nil }
            provider = active.provider
            model = active.model
        }
        // Preferences and tool switches of a new chat move from the draft id to the conversation id on send, so reading by draft id gets the same ones.
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
        // When this connection is already remembered as not accepting file blocks, sending goes straight to text; the check uses the same premise.
        // For a relay, "does not accept file blocks" is remembered in the negative cache per connection x model x protocol.
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
    /// When this turn has no text and no attachments yet (the model panel's pre-check), placeholder text stands for "the
    /// next turn always has content". Otherwise normalization would drop it as an empty message, the user message of an
    /// earlier failed turn would not be replaced by the adjacent-same-role merge, and the pre-check would disagree with
    /// the real send. The placeholder is only used for the decision and is never sent.
    nonisolated static func preflightHistoryHasVideo(
        history: [ChatMessage], pendingText: String, pendingAttachments: [Attachment],
        outboundHistory: ([ChatMessage]) -> [ChatMessage] = {
            ChatRequestBuilder.outboundAttachmentHistory($0, sendPath: .send(excludingMessageID: nil))
        }
    ) -> Bool {
        // Normalization can only drop videos, never add them: if neither side has one, skip normalization and the attachment budget (the panel calls this on every evaluation).
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

    /// Route pre-check for the model panel's file card: judges video from the outbound history of this conversation's next
    /// send (the draft attachments of this turn are not available to the panel and are not counted).
    func preflightHistoryHasVideo(conversationID: UUID?) -> Bool {
        let history = conversationID.flatMap { id in conversations.first(where: { $0.id == id }) }?.messages ?? []
        return Self.preflightHistoryHasVideo(history: history, pendingText: "", pendingAttachments: [])
    }

    private func initialCapabilitySelection(
        _ requested: ChatCapabilitySelection
    ) -> ChatCapabilitySelection {
        requested
    }

    // MARK: - Assistant response pipeline

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
        capabilityRecoveryDescriptor: CapabilityRecoveryDescriptor? = nil
    ) {
        let providerKind = provider.kind
        let apiKey = ProviderCredentialResolver.apiKey(provider: provider, modelID: model.id)
        let resolvedModelID = ModelResolver.resolvedProviderModelIdentifier(model.id, providerKind: providerKind)
        let providerID = provider.id
        // Official providers compute the address from endpointSource at request time; a relay uses its literal address as is.
        let baseURLText = provider.requestBaseURLText()

        // A replacement send on the same conversation interrupts the previous stream first.
        if let oldSession = sessions[conversationID], oldSession.messageID != assistantMessageID {
            persistPartialStreamingAsInterrupted(in: conversationID)
            oldSession.sendTask?.cancel()
        }

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
                sendTask: nil,
                sendTaskID: sendTaskID
            ),
            for: conversationID
        )
        if providerKind == .relay {
            sessions[conversationID]?.relayDeliveryRoute = RelayDeliveryRoute(
                providerID: providerID,
                modelID: model.id,
                transport: RelayEndpointResolver.effectiveTransport(provider: provider, model: model),
                keyID: RelayKeyBinding.effectiveKeyID(provider: provider, modelID: model.id),
                keyWriteIdentity: ProviderManager.relayKeyWriteIdentity(provider, modelID: model.id)
            )
        }
        subject(for: conversationID).send()
        let sendTask = Task(priority: .userInitiated) { [weak self, appStateRetainer = appState as AppState?] in
            guard let self else { return }
            _ = appStateRetainer
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
            let requestBuild = await Task.detached(priority: .userInitiated) {
                ChatRequestBuilder.build(from: requestSnapshot)
            }.value
            let requestMessages = requestBuild.requestMessages
            var requestOptions = requestBuild.requestOptions
            requestOptions.capabilityPreferences = capabilitySelection.typedPreferences
            requestOptions.localContinuationMessageID = assistantMessageID
            requestOptions.localExplicitContinuationMessageID = explicitContinuationMessageID
            var effectiveAPIKey = apiKey
            if providerKind == .grok, provider.authMode == .subscription {
                switch await self.grokSubscriptionPreparer(providerID) {
                case let .success(prepared):
                    effectiveAPIKey = prepared.accessToken
                    // Pin the transport the subscription link will actually use. It comes from the
                    // model's declared `api_backend`, falling back to the seeded subscription
                    // config, so it can differ from the one the prepared context arrived with.
                    requestOptions.grokSubscription = prepared.context.withTransport(
                        CapabilityControlResolution.subscriptionFinalTransport(for: provider, model: model)
                            ?? prepared.context.transport
                    )
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
                            // Store the title key and translate on display, like a subscription failure
                            // during streaming; the failure card recognizes subscription failures by it.
                            title: ProviderServiceError.SubscriptionLane.grok.titleKey,
                            detail: error.userFacingMessage,
                            errorCode: "grok_subscription_unavailable"
                        )
                    }
                    return
                }
            } else if providerKind == .openAI, provider.authMode == .subscription {
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
                            detail: error.userFacingMessage,
                            errorCode: "codex_subscription_unavailable"
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
                requestOptions.generationParameters = GenerationParameterSettingsStore.shared.resolve(
                    transient: requestOptions.generationParameters,
                    providerID: provider.id,
                    // A relay goes through the parameter-key entry point: the literal key, plus the legacy canonical keys registered as read-compat aliases
                    modelID: provider.kind == .relay
                        ? CapabilityPreferenceRuntimeIdentity.canonicalModelID(provider: provider, model: model)
                        : ModelResolver.preferredStoredModelIdentifier(for: model, providerKind: provider.kind),
                    conversationID: conversationID,
                    profileFingerprint: GenerationParameterProfileFingerprint.make(provider: provider, model: model),
                    reasoningMode: capabilitySelection.reasoningMode,
                    // Only parameters this profile declares with a wire name survive. A stored
                    // override for a parameter the current model no longer exposes stays dormant
                    // instead of being sent under a name the upstream never accepted.
                    activeParameterIDs: declaredGenerationParameterIDs
                )
                requestOptions.generationProfile = generationProfile
            }
            // raw JSON is local-only and never enters the typed/sync envelope. Read it only
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
                    forwardPort: .init(providerKind: provider.kind, schemaModelID: model.id)
                )
                requestOptions.selectLocalCustomBodyFragments(customFragments)
            }
            // Additional request body: it coexists with the panel parameters, so only the raw text
            // is attached here and `generationParameters` is left alone. The one send where the
            // user chose "retry without the additional request body" skips it; the saved body and
            // its switch are not changed.
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
            // Relay web search: with the switch on, one effective fragment (saved ?? that protocol's template) is prepared per protocol, except the one whose current record is
            // rejected (not counted when the user override is on); the builders for the first send, a re-routed first send and a protocol fallback each take the fragment of their own protocol.
            // This turn's web intent was already resolved from the switch in requestedCapabilitySelection; the library / auxiliary sends turn it off.
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
            // Built before dispatch, so `endpointFingerprint` is still unknown here. The final
            // endpoint is folded in later, once the production builder has chosen a URL.
            let capabilityEvidenceIdentity = CapabilityEvidenceRequestIdentity.make(
                provider: provider,
                model: model,
                partitionID: appState.sessionPartitionUID,
                hasExplicitValue: requestOptions.generationParameters?.values.values.contains(where: { $0.state == .value }) == true,
                // Relay dispatch is selected solely from requested transport below; a profile is parameter
                // schema, not runtime route, so it must not partition self-heal as a different transport.
                effectiveTransport: nil
            )

            // Coalesces deltas into `sessions[convID].text` and pokes only that conversation's
            // subject. Publishing on every token would push updates faster than the pacer and the
            // cell throttle downstream can consume them; the newline and 32-character triggers stop
            // a fast stream from sitting in the buffer between the time-based flushes.
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
                    guard self.sessions[conversationID]?.sendTaskID == sendTaskID else { return }
                    guard let sanitized = Self.sanitizedStreamingDelta(
                        delta,
                        accumulatedIsEmpty: self.sessions[conversationID]?.text.isEmpty != false
                    ) else { return }
                    self.commitStreamingBodyDelta(sanitized, in: conversationID)
                }
            }

            #if DEBUG
            AppLog.info(
                "Routing a send: provider=\(providerKind) model=\(model.id) "
                + "capabilities=\(model.capabilities) imageGenProfile=\(model.imageGenProfile ?? "none")",
                module: "ImageGen"
            )
            #endif

            // Failures are handled in the catch below, which is already outside the tracker's
            // task-local scope: `CapabilityExecutionRuntime.current` is nil there. Keep a reference
            // to this send's tracker.
            var sendExecutionTracker: CapabilityExecutionTracker?
            // Relay rejection loop: the failure path reads the protocol of the last attempt, the rejection before output, and whether the protocol was switched.
            var relayAttempt: (transport: RelayTransport, rejection: RelayPreOutputRejection?, switched: Bool)?
            // The "files rejected" hint card looks only at this message's first attempt: whether it carried native file blocks and what the first rejection was.
            let relayFileProbe = NativeFileFallback.FirstAttemptProbe()
            var relayFirstRejection: RelayPreOutputRejection?
            // Judged before any output as "this key has no access to the model": the failure path does not enter the capability-rejection loop.
            var relayKeyAccessDenied = false
            do {
                // Remote MCP: tools are assembled only when this conversation has servers turned on and the
                // connection can carry tools. Otherwise the plan is empty and the send takes the plain path
                // below, with no MCP tool in the request.
                let mcpPlan = self.prepareMcpToolPlan(conversationID: conversationID, provider: provider, model: model)
                if !mcpPlan.isEmpty {
                    try await self.runMcpToolLoop(
                        conversationID: conversationID,
                        assistantMessageID: assistantMessageID,
                        sendTaskID: sendTaskID,
                        initialText: initialText,
                        provider: provider,
                        model: model,
                        accessToken: effectiveAPIKey,
                        resolvedModelID: resolvedModelID,
                        requestMessages: requestMessages,
                        requestOptions: requestOptions,
                        reasoningMode: capabilitySelection.reasoningMode,
                        plan: mcpPlan
                    )
                    self.appState.conversationManager.refreshConversationCost(for: conversationID)
                    return
                }

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
                try await CapabilityRecipeResendContext.$recoveryDescriptor.withValue(
                    capabilityRecoveryDescriptor
                ) {
                try await CapabilityExecutionRuntime.$current.withValue(capabilityExecutionTracker) {
                try await CapabilityEvidenceRequestContext.$current.withValue(capabilityEvidenceIdentity) {
                let officialImageDispatch: OfficialImageGenerationDispatch
                switch providerKind {
                case .relay:
                    officialImageDispatch = .notApplicable
                default:
                    officialImageDispatch = try await officialImageDispatcher.dispatchOfficialImageGeneration(
                        providerKind: providerKind,
                        userBaseURL: baseURLText,
                        apiKey: apiKey,
                        modelID: resolvedModelID,
                        messages: requestMessages,
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

                // Choose the route by (provider, model): a relay is always dispatched by protocol; an official provider is
                // dispatched by protocol only when it delivers a non-native-family apiProtocol, the official-only image
                // route takes precedence, and the native service is unchanged otherwise.
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
                            messages: requestMessages,
                            reasoningMode: capabilitySelection.reasoningMode,
                            webSearchEnabled: capabilitySelection.webSearchEnabled,
                            supportsImageGen: true,
                            requestOptions: requestOptions
                        )
                        let deliveredCost = self.resolvedDeliveredCost(from: result, model: model, providerKind: providerKind)
                        #if DEBUG
                        AppLog.info(
                            "OpenRouter returned \(result.text.count) characters of text and "
                            + "\(result.attachments?.count ?? 0) attachments",
                            module: "ImageGen"
                        )
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
                            messages: requestMessages,
                            reasoningMode: capabilitySelection.reasoningMode,
                            webSearchEnabled: capabilitySelection.webSearchEnabled,
                            requestOptions: requestOptions
                        )

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
                                // Flush the tail of the preamble into the session first. Otherwise it waits for the
                                // next event, the screen is half a sentence short while the search runs, and the late
                                // flush would clear the activity just set as if it were the next piece of body text.
                                await flushBufferedDelta(force: true)
                                self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
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
                                        usageMetrics: ChatDeliveredUsageMetrics(result: result)
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
                            messages: requestMessages,
                            reasoningMode: capabilitySelection.reasoningMode,
                            webSearchEnabled: capabilitySelection.webSearchEnabled,
                            requestOptions: requestOptions
                        )

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
                                // Flush the tail of the preamble into the session first. Otherwise it waits for the
                                // next event, the screen is half a sentence short while the search runs, and the late
                                // flush would clear the activity just set as if it were the next piece of body text.
                                await flushBufferedDelta(force: true)
                                self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
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
                                        usageMetrics: ChatDeliveredUsageMetrics(result: result)
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
                        messages: requestMessages,
                        reasoningMode: capabilitySelection.reasoningMode,
                        requestOptions: requestOptions
                    )

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
                            // Flush the tail of the preamble into the session first. Otherwise it waits for the
                            // next event, the screen is half a sentence short while the search runs, and the late
                            // flush would clear the activity just set as if it were the next piece of body text.
                            await flushBufferedDelta(force: true)
                            self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
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
                                    usageMetrics: ChatDeliveredUsageMetrics(result: result)
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
                    let mistralStream = mistralService.sendMessageStream(
                        apiKey: apiKey,
                        modelID: resolvedModelID,
                        messages: requestMessages,
                        reasoningMode: capabilitySelection.reasoningMode,
                        requestOptions: requestOptions
                    )

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
                            // Flush the tail of the preamble into the session first. Otherwise it waits for the
                            // next event, the screen is half a sentence short while the search runs, and the late
                            // flush would clear the activity just set as if it were the next piece of body text.
                            await flushBufferedDelta(force: true)
                            self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
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
                                    usageMetrics: ChatDeliveredUsageMetrics(result: result)
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
                            messages: requestMessages,
                            reasoningMode: capabilitySelection.reasoningMode,
                            webSearchEnabled: capabilitySelection.webSearchEnabled,
                            requestOptions: requestOptions
                        )

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
                                // Flush the tail of the preamble into the session first. Otherwise it waits for the
                                // next event, the screen is half a sentence short while the search runs, and the late
                                // flush would clear the activity just set as if it were the next piece of body text.
                                await flushBufferedDelta(force: true)
                                self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
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
                                        usageMetrics: ChatDeliveredUsageMetrics(result: result)
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
                            messages: requestMessages,
                            reasoningMode: capabilitySelection.reasoningMode,
                            webSearchEnabled: capabilitySelection.webSearchEnabled,
                            supportsImageGen: true,
                            requestOptions: requestOptions
                        )
                        #if DEBUG
                        AppLog.info(
                            "Gemini returned \(result.text.count) characters of text and "
                            + "\(result.attachments?.count ?? 0) attachments",
                            module: "ImageGen"
                        )
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
                            messages: requestMessages,
                            reasoningMode: capabilitySelection.reasoningMode,
                            webSearchEnabled: capabilitySelection.webSearchEnabled,
                            requestOptions: requestOptions
                        )

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
                                // Flush the tail of the preamble into the session first. Otherwise it waits for the
                                // next event, the screen is half a sentence short while the search runs, and the late
                                // flush would clear the activity just set as if it were the next piece of body text.
                                await flushBufferedDelta(force: true)
                                self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
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
                                        usageMetrics: ChatDeliveredUsageMetrics(result: result)
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
                        messages: requestMessages,
                        reasoningMode: capabilitySelection.reasoningMode,
                        webSearchEnabled: capabilitySelection.webSearchEnabled,
                        requestOptions: requestOptions
                    )

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
                            // Anthropic never yields this case, but `StreamEvent` is shared across
                            // every provider, so the switch still has to handle it.
                            await self.handleStreamingImagePart(attachment, in: conversationID)
                        case let .toolCallDeltas(calls):
                            self.recordUnhandledToolCalls(calls, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID, provider: provider, model: model)
                        case let .activity(activity):
                            // Flush the tail of the preamble into the session first. Otherwise it waits for the
                            // next event, the screen is half a sentence short while the search runs, and the late
                            // flush would clear the activity just set as if it were the next piece of body text.
                            await flushBufferedDelta(force: true)
                            self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
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
                                    usageMetrics: ChatDeliveredUsageMetrics(result: result)
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
                        messages: requestMessages,
                        reasoningMode: capabilitySelection.reasoningMode,
                        requestOptions: requestOptions
                    )

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
                            // Flush the tail of the preamble into the session first. Otherwise it waits for the
                            // next event, the screen is half a sentence short while the search runs, and the late
                            // flush would clear the activity just set as if it were the next piece of body text.
                            await flushBufferedDelta(force: true)
                            self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
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
                                    usageMetrics: ChatDeliveredUsageMetrics(result: result)
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
                            messages: requestMessages,
                            baseURL: baseURLText,
                            reasoningMode: capabilitySelection.reasoningMode,
                            requestOptions: requestOptions
                        )

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
                                // Flush the tail of the preamble into the session first. Otherwise it waits for the
                                // next event, the screen is half a sentence short while the search runs, and the late
                                // flush would clear the activity just set as if it were the next piece of body text.
                                await flushBufferedDelta(force: true)
                                self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
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
                                        usageMetrics: ChatDeliveredUsageMetrics(result: result)
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
                        messages: requestMessages,
                        reasoningMode: capabilitySelection.reasoningMode,
                        requestOptions: requestOptions
                    )

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
                            // Flush the tail of the preamble into the session first. Otherwise it waits for the
                            // next event, the screen is half a sentence short while the search runs, and the late
                            // flush would clear the activity just set as if it were the next piece of body text.
                            await flushBufferedDelta(force: true)
                            self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
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
                                    usageMetrics: ChatDeliveredUsageMetrics(result: result)
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
                        let result = try await miniMaxService.sendMessage(
                            apiKey: apiKey,
                            modelID: resolvedModelID,
                            messages: requestMessages,
                            baseURL: baseURLText,
                            requestOptions: requestOptions
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
                            messages: requestMessages,
                            baseURL: baseURLText,
                            reasoningMode: capabilitySelection.reasoningMode,
                            requestOptions: requestOptions
                        )

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
                                // Flush the tail of the preamble into the session first. Otherwise it waits for the
                                // next event, the screen is half a sentence short while the search runs, and the late
                                // flush would clear the activity just set as if it were the next piece of body text.
                                await flushBufferedDelta(force: true)
                                self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
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
                                        usageMetrics: ChatDeliveredUsageMetrics(result: result)
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
                            messages: requestMessages,
                            baseURL: baseURLText,
                            reasoningMode: capabilitySelection.reasoningMode,
                            webSearchEnabled: capabilitySelection.webSearchEnabled,
                            requestOptions: requestOptions
                        )

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
                                // Flush the tail of the preamble into the session first. Otherwise it waits for the
                                // next event, the screen is half a sentence short while the search runs, and the late
                                // flush would clear the activity just set as if it were the next piece of body text.
                                await flushBufferedDelta(force: true)
                                self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
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
                                        usageMetrics: ChatDeliveredUsageMetrics(result: result)
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
                        let result = try await qwenService.sendMessage(
                            apiKey: apiKey,
                            modelID: resolvedModelID,
                            messages: requestMessages,
                            baseURL: baseURLText,
                            requestOptions: requestOptions
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
                            messages: requestMessages,
                            baseURL: baseURLText,
                            reasoningMode: capabilitySelection.reasoningMode,
                            webSearchEnabled: capabilitySelection.webSearchEnabled,
                            requestOptions: requestOptions
                        )

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
                                // Flush the tail of the preamble into the session first. Otherwise it waits for the
                                // next event, the screen is half a sentence short while the search runs, and the late
                                // flush would clear the activity just set as if it were the next piece of body text.
                                await flushBufferedDelta(force: true)
                                self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
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
                                        usageMetrics: ChatDeliveredUsageMetrics(result: result)
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
                        messages: requestMessages,
                        baseURL: baseURLText,
                        reasoningMode: capabilitySelection.reasoningMode,
                        webSearchEnabled: capabilitySelection.webSearchEnabled,
                        requestOptions: requestOptions
                    )

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
                            // Flush the tail of the preamble into the session first. Otherwise it waits for the
                            // next event, the screen is half a sentence short while the search runs, and the late
                            // flush would clear the activity just set as if it were the next piece of body text.
                            await flushBufferedDelta(force: true)
                            self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
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
                                    usageMetrics: ChatDeliveredUsageMetrics(result: result)
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
                            messages: requestMessages,
                            baseURL: baseURLText,
                            reasoningMode: capabilitySelection.reasoningMode,
                            requestOptions: requestOptions
                        )

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
                                // Flush the tail of the preamble into the session first. Otherwise it waits for the
                                // next event, the screen is half a sentence short while the search runs, and the late
                                // flush would clear the activity just set as if it were the next piece of body text.
                                await flushBufferedDelta(force: true)
                                self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
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
                                        usageMetrics: ChatDeliveredUsageMetrics(result: result)
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
                    // For a model that has not been verified, pick the first-send protocol with the same candidate order as the lazy
                    // verification: with the connection on auto, effectiveTransport always lands on Chat, and a Claude-family model
                    // sent through Chat to a group that only accepts Messages is rejected with "max_tokens required" (a 400 is not a
                    // route-level rejection, so it does not fall back).
                    if let first = await self.relayFirstSendTransport(
                        provider: provider, model: model, current: initialRelayRoute.transport,
                        attachments: requestMessages.flatMap { $0.attachments ?? [] }
                    ) {
                        var firstModel = model
                        firstModel.relayTransport = first
                        if case let .byProtocol(rerouted) = ProviderServiceRouter.route(provider: provider, model: firstModel) {
                            initialRelayRoute = rerouted
                            // On success this is written back like a protocol fallback: the first-send protocol is remembered as observed ("remembered after sending").
                            self.sessions[conversationID]?.relayDeliveryRoute?.switchedTo = first
                        }
                    }
                    // Before sending, settle the reasoning level from the relay negative cache (nearest supported level);
                    // if the level is rejected during this send, change it and resend once.
                    var relayReasoningMode = RelayReasoningTier.outboundMode(
                        provider: provider, model: model, transport: initialRelayRoute.transport,
                        selected: capabilitySelection.reasoningMode
                    )
                    var relayTierRetryError: (any Error)?
                    // Protocols whose fragment was rejected with 400 / 422 and resent without it; if the resend fails again, this original error is reported.
                    var relayWebStripped: Set<RelayTransport> = []
                    var relayWebRetryError: (any Error)?
                    // One relay send attempt. The outer protocol fallback may switch protocol and call it again;
                    // the inner native-file fallback (NativeFileFallback) first goes out on the original protocol in each attempt.
                    @MainActor func sendRelayAttempt(_ route: ProviderServiceRouter.ProtocolRoute) async throws {
                        let relayBaseURL = route.baseURL
                        // Injection point: the protocol and root address are resolved per model, and the service only reads this copy.
                        let relayTransport = route.transport
                        let relayRequested = route.requested
                        var relayRequestOptions = requestOptions
                        relayRequestOptions.relayRequested = relayRequested
                        if relayWebStripped.contains(relayTransport) {
                            relayRequestOptions.relayWebFragments?.raw[relayTransport.rawValue] = nil
                        }

                        // Image generation on a relay depends on the transport. Chat Completions posts
                        // to the images endpoint, Responses carries an inline `image_generation` tool on
                        // a streaming chat request, and Gemini asks for an image modality on its normal
                        // generate call. A dedicated image model cannot drive the Responses request
                        // itself, so it moves into the tool while a chat model drives the turn.
                        if providerKind == .relay, RelayRuntimeSupport.dispatchesImageGeneration(model: model) {
                            let imageRoute = RelayRuntimeSupport.imageRoute(for: relayTransport)
                            switch imageRoute {
                            case .unsupported:
                                throw ProviderServiceError.invalidConfiguration(
                                    detail: L10n.tr("Image generation is not available on this protocol. Open Providers → this connection → this model → Advanced and set Protocol to OpenAI Responses or Chat Completions.", table: .providers)
                                )

                            case .imagesEndpoint:
                                #if DEBUG
                                AppLog.info(
                                    "Relay image route: imagesEndpoint, provider=\(provider.id) model=\(resolvedModelID)",
                                    module: "ImageGen"
                                )
                                #endif
                                let result = try await openAIService.sendMessageViaImagesAPIForRelay(
                                    apiKey: apiKey,
                                    modelID: resolvedModelID,
                                    messages: requestMessages,
                                    baseURL: relayBaseURL,
                                    relayRequested: relayRequested
                                )
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
                                // A dedicated image model cannot drive the request, so pick a chat
                                // model for the turn and pass the image model to the tool instead.
                                // The request goes out with the image model's effective key; with two or more keys the
                                // driver model prefers one bound to the same key.
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
                                AppLog.info(
                                    "Relay image route: inlineResponsesTool, driver=\(driverModelID) "
                                    + "tool=\(imageToolID ?? "default")",
                                    module: "ImageGen"
                                )
                                #endif
                                let stream = openAIService.sendMessageStream(
                                    apiKey: apiKey,
                                    modelID: driverModelID,
                                    messages: requestMessages,
                                    baseURL: relayBaseURL,
                                    reasoningMode: relayReasoningMode,
                                    requestOptions: relayRequestOptions,
                                    relayRequested: relayRequested,
                                    webSearchEnabled: capabilitySelection.webSearchEnabled,
                                    supportsImageGeneration: true,
                                    imageToolModelID: imageToolID
                                )
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
                                        // Flush the tail of the preamble into the session first. Otherwise it waits for the
                                        // next event, the screen is half a sentence short while the search runs, and the late
                                        // flush would clear the activity just set as if it were the next piece of body text.
                                        await flushBufferedDelta(force: true)
                                        self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
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
                                                usageMetrics: ChatDeliveredUsageMetrics(result: result)
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
                                break
                            }

                            // Only inlineResponsesTool / imagesEndpoint end this attempt here;
                            // geminiModality falls through to the dispatch below.
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
                                messages: requestMessages,
                                reasoningMode: relayReasoningMode,
                                webSearchEnabled: capabilitySelection.webSearchEnabled,
                                supportsImageGen: RelayRuntimeSupport.dispatchesImageGeneration(model: model),
                                requestOptions: relayRequestOptions
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
                                messages: requestMessages,
                                reasoningMode: relayReasoningMode,
                                webSearchEnabled: capabilitySelection.webSearchEnabled,
                                supportsImageGen: RelayRuntimeSupport.dispatchesImageGeneration(model: model),
                                requestOptions: relayRequestOptions
                            )

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
                                    // Flush the tail of the preamble into the session first. Otherwise it waits for the
                                    // next event, the screen is half a sentence short while the search runs, and the late
                                    // flush would clear the activity just set as if it were the next piece of body text.
                                    await flushBufferedDelta(force: true)
                                    self.recordStreamActivity(activity, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID)
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
                                            usageMetrics: ChatDeliveredUsageMetrics(result: result)
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
                            // A route-level rejection before any output, from a source other than the user, on a message that has not switched yet:
                            // switch to the next protocol among the candidates and resend once.
                            // After a switch, a failure reports the second error and writes no negative cache (the failure path reads relayAttempt.switched).
                            let outputStarted = !bufferedDelta.isEmpty || self.relayOutputStarted(
                                conversationID: conversationID, messageID: assistantMessageID, initialText: initialText
                            )
                            // Judge this key first, before entering the capability-rejection loop: "no access" is recorded on the model,
                            // writes no negative cache, does not switch protocol and does not resend with another key.
                            // An invalid or restricted key writes that key's status; everything else is unchanged.
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
                            // Reasoning level rejected: record it in the negative cache and resend once at the nearest level;
                            // if the resend also fails, report the original error.
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
                                      attachments: requestMessages.flatMap { $0.attachments ?? [] }
                                  ) else { throw relayTierRetryError ?? relayWebRetryError ?? error }
                            var switchedModel = model
                            switchedModel.relayTransport = next
                            guard case let .byProtocol(rerouted) = ProviderServiceRouter.route(
                                provider: provider, model: switchedModel
                            ) else { throw relayTierRetryError ?? relayWebRetryError ?? error }
                            relaySwitched = true
                            relayRoute = rerouted
                            // On success this is written back as observed under the switched-to protocol (the same write-back path as the "already used" promotion).
                            self.sessions[conversationID]?.relayDeliveryRoute?.switchedTo = next
                            self.sessions[conversationID]?.relayDeliveryRoute?.protocolFallback = true
                        }
                    }


                }
                }

                await MainActor.run {
                    self.appState.conversationManager.refreshConversationCost(for: conversationID)
                }
                }
                }
            } catch {
                await flushBufferedDelta(force: true)
                // Once a request with custom capability facts has crossed the dispatch
                // boundary its provider, model, error and body are all privacy-sensitive, so a
                // failure on that path is not written to the log at all.
                // This runs outside the tracker's TaskLocal scope, where
                // `CapabilityExecutionRuntime.current` is nil and reading through it always
                // answers "nothing was sent, nothing was rejected". Every fact about this send is
                // read from the reference the send left behind.
                let hasDispatchedCustomFacts = sendExecutionTracker?.hasDispatchedFact ?? false
                let canRetryWithoutAdditionalBody = sendExecutionTracker?.canOfferRetryWithoutAdditionalBody ?? false
                let customSourceRejected = sendExecutionTracker?.hasRejectedSource(.custom) ?? false
                let terminalExecution = sendExecutionTracker?.terminalResult()
                // Subscription 426: the client version headers in the local metadata snapshot are below what
                // the provider accepts. The snapshot is only refreshed in the background once a day, so wait
                // for a refresh before the failure card lands; one tap on Retry then sends the current values.
                if !Task.isCancelled,
                   (error as? ProviderServiceError)?.subscriptionClientVersionRejectionLane != nil {
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
                        // A relay rejected an image before any output, image support was unknown at send time, and this
                        // message did not switch protocol: record the image negative cache (the entry point is then hidden)
                        // and change the failure message's recovery card to "doesn't support images" + Switch Model.
                        // Images get no text fallback and are never resent automatically.
                        if providerKind == .relay, !relayKeyAccessDenied, let attempt = relayAttempt,
                           requestMessages.contains(where: { $0.attachments?.contains(where: { $0.kind == .image }) == true }),
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
                        // A relay request carrying native file blocks was rejected the first time, and the fallback chain
                        // (text resend / protocol fallback) still failed in the end or could not fall back because every file
                        // is a scan: the recovery card body becomes "doesn't support these files" + Switch Model.
                        // The error shown is unchanged; when the same message was already judged as not accepting images, the
                        // image card wins. If the attempt after a fallback or protocol switch had already started output and
                        // failed later, the problem is not the files, so this is not applied.
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
                        let isFatalError = providerError.marksConnectionFailed
                        if isFatalError, var erroredProvider = self.appState.provider(for: providerID) {
                            erroredProvider.status = ProviderConnectionState.issue(providerError.messageKey)
                            erroredProvider.lastError = providerError.messageKey
                            self.appState.providerManager.updateProvider(erroredProvider)
                        }

                        let isCustomFieldError: Bool = {
                            if case .customFieldsRejected = providerError { return true }
                            // The two remaining internal invariants (duplicate owner, missing request context) are still configuration errors.
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
                        // Neither additional-request-body failure is a connection problem: a local
                        // rejection (nothing was sent) and an upstream 400 for a request that
                        // carried it. The latter offers "retry without the additional request body"
                        // only under the contract's recovery conditions; a rejection already
                        // pinned to one specific setting keeps its existing way out.
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
                            userFacingText: isLocatedSettingRejection ? "" : providerError.message,
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
                            // The raw JSON or upstream response must never reach the error card,
                            // persistence or the log. Keep only a stable, safe code.
                            detail: isCustomFieldError
                                ? (customSourceRejected
                                    ? "model_control_setting_rejected"
                                    : customFieldsRejection?.safeCode ?? "custom_request_fields_rejected")
                                : (isLocatedSettingRejection
                                    ? "model_control_setting_rejected"
                                    : ChatFailurePresentation.persistedDetail(for: providerError)),
                            errorCode: providerError.diagnosticCode,
                            recoveryPrimaryAction: recoveryPrimaryAction,
                            terminalExecution: terminalExecution
                        )

                        if !hasDispatchedCustomFacts {
                            AppLog.error(
                                error,
                                module: "chat.stream",
                                context: [
                                    "provider.kind": providerKind.rawValue,
                                    "model.id": model.id
                                ]
                            )
                        }
                    }

                    self.appState.conversationManager.refreshConversationCost(for: conversationID)
                }
            }

            await MainActor.run {
                self.finishSendTaskIfCurrent(sendTaskID, conversationID: conversationID)
            }
        }

        sessions[conversationID]?.sendTask = sendTask
    }

    // MARK: - Remote MCP

    /// Test seam: swaps the MCP protocol client for a replayed session, so a test can run the whole
    /// production path starting at `sendMessage`.
    func debugUseMcpClientFactoryForTesting(_ factory: @escaping @Sendable (URL) -> McpClient) {
        mcpClientFactory = factory
    }

    /// The MCP tools usable for this send. Empty when the connection cannot carry tools, the conversation has
    /// no server turned on, or local storage cannot be read: each of those falls back to a plain send without
    /// tools, so an unreadable MCP configuration never fails the whole message.
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
        // The loop only refreshes tokens; it never signs in again (that opens the browser and belongs to the
        // UI). The authorizer is the one shared with the add flow and the management page, which is what
        // serializes concurrent refreshes.
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
                // Without the database there is nothing to re-check against: treat the tool as unavailable
                // rather than sending a request based on the state seen when the plan was assembled.
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

    /// One status callback from the executor: updates the message's `toolSteps` (summaries only, persisted
    /// with the message) and saves the step payload (raw arguments and result, which never enter the message
    /// model).
    func recordMcpToolStep(
        _ update: McpToolStepUpdate,
        conversationID: UUID,
        messageID: UUID,
        sendTaskID: UUID,
        uid: String
    ) async {
        if let payload = update.payload, let store = try? appState.mcpServerDirectory.store(for: uid) {
            // A failed save only affects the step detail sheet (it shows that the details are not on this
            // device); the step itself and the answer are unaffected.
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
            // This send is already over (the user pressed stop). Only a callback that moves its own step
            // from running to a terminal state is accepted; no step is added. A retry of the same message is
            // a different send, and a late callback from the old task must not write into it.
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
        // The activity line is set while any step is running and cleared once none is. The message is
        // written before the activity is published, because the cell reads its caption from the running step.
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

    /// The loop found that this server needs a new sign-in: record `needsAuth` as its connection state. The
    /// tool panel offers "Re-authorize" from that, and later sends leave its tools out until a sign-in succeeds.
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

    /// The tool loop of a send that carries MCP tools. The leg runner and the adapter that feeds results
    /// back are chosen as a pair from the connection's outbound protocol.
    private func runMcpToolLoop(
        conversationID: UUID,
        assistantMessageID: UUID,
        sendTaskID: UUID,
        initialText: String,
        provider: Provider,
        model: AIModel,
        accessToken: String,
        resolvedModelID: String,
        requestMessages: [ChatMessage],
        requestOptions: ChatRequestOptions,
        reasoningMode: ReasoningMode,
        plan: McpToolPlan
    ) async throws {
        let legPair = try ToolLoopLegRunnerFactory.make(
            provider: provider,
            model: model,
            modelID: resolvedModelID,
            reasoningMode: reasoningMode,
            requestOptions: requestOptions,
            accessToken: provider.authMode == .subscription ? accessToken : nil,
            toolCallMemory: toolCallMemory,
            session: providerSession
        )
        // The protocol this relay leg actually goes out on (the same source as the wire choice); the tool-rejection
        // negative cache is keyed by it. nil for a non-relay connection.
        let relaySentTransport: RelayTransport? = provider.kind == .relay
            ? (RelayEndpointResolver.explicitTransport(provider: provider, model: model) ?? .openaiChatCompletions)
            : nil
        let messages = McpToolBridge.initialMessages(
            history: try OpenAIChatToolLoopLegRunner.messages(
                from: requestMessages,
                providerKind: provider.kind,
                model: model,
                isChatSend: true
            ),
            systemPrompt: requestOptions.systemPrompt
        )
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
                // A name outside the plan's table is never executed; it gets the existing notice card.
                await manager.recordUnhandledToolCalls(
                    calls, in: conversationID, messageID: assistantMessageID, sendTaskID: sendTaskID,
                    provider: provider, model: model
                )
            }
        )
        let legText = ToolLoopLegText()
        let result: ToolCallLoop.Result
        do {
            result = try await loop.run(messages: messages) { event in
                switch event {
                case let .legStarted(index):
                    await legText.reset()
                    // The text of a leg that ended in tool calls is cleared, and the next leg renders from
                    // the start.
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
            // Only a deterministic 4xx on the first leg, before any structured tool call was seen, means "this
            // connection does not support tools": this send resends once without tools, and a connection that
            // qualifies is recorded as false so the next send's entry point no longer carries MCP tools.
            // A rejection on a later leg, or after tool_calls were seen, is not a capability fact and fails
            // like any other request.
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
            // The loop already ran its final synthesis leg without tools; the step block says so in its
            // last row.
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
            usageMetrics: ChatDeliveredUsageMetrics(promptTokens: promptTokens, completionTokens: completionTokens)
        )
    }

    private func recordUnhandledToolCalls(
        _ calls: [ProviderToolCall],
        in conversationID: UUID,
        messageID: UUID,
        sendTaskID: UUID,
        provider: Provider,
        model: AIModel
    ) {
        guard !calls.isEmpty,
              sessions[conversationID]?.messageID == messageID,
              sessions[conversationID]?.sendTaskID == sendTaskID,
              let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == messageID })
        else { return }

        rememberToolCallCapability(provider: provider, model: model, toolCall: true, reason: .structuredToolCalls)

        var updated = conversations[conversationIndex]
        var merged = updated.messages[messageIndex].unhandledToolCalls ?? []
        merged.append(contentsOf: calls.map {
            UnhandledToolCall(id: $0.providerCallID, name: $0.name, arguments: $0.rawArguments)
        })
        updated.messages[messageIndex].unhandledToolCalls = merged
        appState.upsertConversationProjection(updated)
    }

    /// Connection-level memory write. For a relay, a false result is recorded in the `toolCall` negative cache
    /// instead (the signal counts only when classify judges it rejected) and no longer written here; the cache key
    /// is the protocol this leg actually sent on (`sentTransport`), not the first-send protocol.
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

    /// Whether this assistant message already has output (body or reasoning). When the session is gone it counts
    /// as "output started": no protocol switch and no negative-cache write.
    private func relayOutputStarted(conversationID: UUID, messageID: UUID, initialText: String) -> Bool {
        guard let session = sessions[conversationID], session.messageID == messageID else { return true }
        return session.text != initialText || !session.reasoningText.isEmpty
    }

    /// The protocol for the first send of an unverified model. The decision lives in `RelayFirstSendTransport` (the
    /// negative-cache read/write and the "Auto =" line on the advanced page give the same answer); when it equals the
    /// current route this returns nil and the send proceeds as before. The family is read only from the table already
    /// fetched in this session; the first send makes no request for it.
    /// The rule for falling back to the same protocol when attachments cannot be delivered belongs to sending only, so it stays here.
    private func relayFirstSendTransport(
        provider: Provider,
        model: AIModel,
        current: RelayTransport,
        attachments: [Attachment]
    ) async -> RelayTransport? {
        // A Chat request body carries no max_tokens, and a relay that converts a Claude-family model to Anthropic answers
        // 400 "max_tokens required". A 400 is not a route-level rejection and never falls back, so a Claude-family model's
        // first send goes through Messages.
        let first = RelayFirstSendTransport.current(provider: provider, model: model)
        guard first == .anthropicMessages, first != current else { return nil }
        let files = attachments.filter { $0.kind == .file }
        if !files.isEmpty, !files.contains(where: NativeFileFallback.hasExtractedText),
           !AttachmentTransportResolver.relay(first).profile.sendsNativeFiles {
            return nil
        }
        return first
    }

    /// The target of a protocol-level fallback: the candidates are the same set as the per-model probe
    /// (`RelayProbeCandidates.candidates`), and the decision is a pure function.
    private func relayProtocolFallbackTarget(
        provider: Provider,
        model: AIModel,
        current: RelayTransport,
        rejection: RelayPreOutputRejection,
        outputStarted: Bool,
        alreadySwitched: Bool,
        attachments: [Attachment]
    ) async -> RelayTransport? {
        // Rule out first with the conditions that need no candidates, so every failure does not look up the family table.
        guard RelayProtocolFallback.isEligible(
            source: model.relayTransportSource, rejection: rejection,
            outputStarted: outputStarted, alreadySwitched: alreadySwitched
        ) else { return nil }
        // The user chose the connection protocol and the model follows it: there is no other candidate, so do not switch protocol.
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
        // After a switch the request body is rebuilt by the new protocol's builder and native-file delivery is decided again
        // for it. If the new protocol does not accept native files and none of the files has extractable text (scanned
        // documents), there is no text fallback version to send, so do not switch and report the original error.
        let files = attachments.filter { $0.kind == .file }
        if !files.isEmpty, !files.contains(where: NativeFileFallback.hasExtractedText),
           !AttachmentTransportResolver.relay(next).profile.sendsNativeFiles {
            return nil
        }
        return next
    }

    /// When a relay's "tools rejected" is really this key having no access to the model, returns the status code: do not
    /// resend without tools and do not write the tool negative cache. The decision uses the raw response body, falling
    /// back to the message / code fragment `mapHTTPError` leaves behind when the body is unavailable.
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

    /// If judged as no access, records the effective key on the model and returns true (the caller then fails with the original error).
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

    /// The upstream status code carried by a "tools unsupported" error (an annotated rejection or a bare `.upstream`).
    nonisolated static func toolRejectionStatusCode(_ error: any Error) -> Int? {
        if let rejected = error as? ToolsRejectedByUpstreamError { return rejected.statusCode }
        if case let ProviderServiceError.upstream(statusCode, _) = error { return statusCode }
        return nil
    }

    /// The "tool support unavailable" branch: resend the same leg once with the tools removed (depth = 1).
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
            case .providerReplayBlocks, .providerAssistantReplay:
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
        appState.commitPendingPinsIfNeeded(to: conversation.id)
        let pinnedNotes = appState.resolvePinnedNoteSnapshots(for: conversation.id)
        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(
                id: conversation.id,
                useMemory: conversation.useMemory,
                skillID: conversation.skillId
            ),
            messages: messages,
            preferences: ChatRequestPreferencesSnapshot(appState.preferences),
            skill: skillSnapshot,
            pinnedNotes: pinnedNotes,
            sendPath: sendPath
        )
        return snapshot
    }

    private func beginEditingUserMessage(at messageIndex: Int, in conversationID: UUID) -> ComposerEditDraft? {
        guard let convIndex = conversations.firstIndex(where: { $0.id == conversationID }) else { return nil }
        guard conversations[convIndex].messages.indices.contains(messageIndex),
              conversations[convIndex].messages[messageIndex].role == .user else {
            return nil
        }

        let messageText = conversations[convIndex].messages[messageIndex].text
        // Put the original attachments back into the composer along with the text. This must happen before truncation, which deletes this message's file payloads.
        let restoredAttachments = ComposerAttachmentRestoration.restoredForComposer(
            appState.attachmentsWithFilePayloads(
                of: conversations[convIndex].messages[messageIndex], in: conversationID
            ),
            partitionUID: appState.sessionPartitionUID
        )
        var updated = conversations[convIndex]
        let truncatedSegment = Array(updated.messages[messageIndex...])
        updated.messages.removeSubrange(messageIndex...)
        ReadAloudController.shared.stopIfSpeaking(messageIDs: truncatedSegment.map(\.id), .navigated)
        // Lower the display count with the truncation: a stale count would make the summary projection
        // after a restart believe there is history that was never loaded.
        updated.messageCountOverride = updated.messageCountOverride.map {
            max(updated.messages.count, $0 - truncatedSegment.count)
        }
        updated.draftText = messageText
        updated.previewText = messageText

        updated.updatedAt = ConversationListMetadata.computeActivityAt(for: updated)
        updated.isDraft = updated.messages.isEmpty
        // Truncating to zero messages leaves `messages` empty, which the store does not treat as a
        // deletion, so the removed ids are passed explicitly.
        appState.upsertConversationProjection(
            updated,
            deletingMessageIDs: Set(truncatedSegment.map(\.id))
        )
        appState.persistRecoverySnapshotAfterDestructiveChange()

        return ComposerEditDraft(text: messageText, attachments: restoredAttachments)
    }

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
                AppLog.info(
                    "Attachment \(resolvedAttachments[i].id) took \(pending.count) bytes of pending image data",
                    module: "ImageGen"
                )
                #endif
            } else if let b64 = resolvedAttachments[i].base64Data, !b64.isEmpty {
                imageData = Self.decodeImageBase64(b64)
                #if DEBUG
                if imageData == nil {
                    AppLog.warning(
                        "Attachment \(resolvedAttachments[i].id) carried \(b64.count) characters of base64 "
                        + "that could not be decoded as image data",
                        module: "ImageGen"
                    )
                } else {
                    AppLog.info(
                        "Attachment \(resolvedAttachments[i].id) fell back to decoding its inline base64, "
                        + "\(imageData?.count ?? 0) bytes",
                        module: "ImageGen"
                    )
                }
                #endif
            } else {
                imageData = nil
                #if DEBUG
                AppLog.warning(
                    "Attachment \(resolvedAttachments[i].id) has neither pending image data nor inline base64, "
                    + "so nothing will be written to disk",
                    module: "ImageGen"
                )
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
            AppLog.info(
                "Saved image \(write.imageID): wrote \(write.data.count) bytes, "
                + "read back \(verified.map { "\($0.count)" } ?? "nothing")",
                module: "ImageGen"
            )
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
        updated.messages[mi].recoveryPrimaryAction = nil
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
        // A response can carry tool calls and no text at all. Record them before completing,
        // otherwise the turn lands as an empty assistant message with nothing explaining why.
        if let toolCalls = result.toolCalls, !toolCalls.isEmpty, let provider, let model {
            recordUnhandledToolCalls(
                toolCalls, in: conversationID, messageID: messageID, sendTaskID: taskID,
                provider: provider, model: model
            )
        }

        // Route the final text through the session so completion picks it up on exactly the same
        // path a streamed response takes.
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
            usageMetrics: usageMetrics
        )
    }

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
        clearsCitations: Bool = false
    ) {
        if let expectedSendTaskID {
            guard let session = sessions[conversationID],
                  session.messageID == messageID,
                  session.sendTaskID == expectedSendTaskID else { return }
        } else if sessions[conversationID]?.messageID == messageID {
            // A sessionless update must never steal the session owned by an active send task.
            return
        }

        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }

        var updated = conversations[ci]
        // Image bytes stay in memory keyed by attachment id until they are written to disk below.
        var carriedImageData: [UUID: Data] = [:]
        var streamingAttCount = 0
        var carriedCitations: [Citation] = []
        // Everything the session holds has to be read out before `removeSession` drops it.
        var carriedReasoningText: String?
        var carriedReasoningDurationMs: Int64?
        var carriedRelayDeliveryRoute: RelayDeliveryRoute?
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
        if clearsCitations {
            updated.messages[mi].citations = nil
        } else if !carriedCitations.isEmpty {
            updated.messages[mi].citations = carriedCitations
        }
        if let attachments, !attachments.isEmpty {
            var existing = updated.messages[mi].attachments ?? []
            existing.append(contentsOf: attachments)
            updated.messages[mi].attachments = existing
        }
        #if DEBUG
        AppLog.info(
            "Completing a message: \(updated.messages[mi].text.count) characters of text, "
            + "\(streamingAttCount) streamed attachments, \(attachments?.count ?? 0) passed in, "
            + "\(updated.messages[mi].attachments?.count ?? 0) in total, state=\(state)",
            module: "ImageGen"
        )
        #endif
        var imageDiskWrites: [ImageAttachmentDiskWrite] = []
        if var allAtts = updated.messages[mi].attachments {
            // The session is gone by now; the pending bytes survive in `carriedImageData`.
            #if DEBUG
            let imageAttsCount = allAtts.filter { $0.kind == .image }.count
            AppLog.info(
                "Preparing attachments for disk: \(imageAttsCount) images, "
                + "\(carriedImageData.keys.count) carried image payloads",
                module: "ImageGen"
            )
            #endif
            let prepared = Self.prepareImageAttachmentsForDisk(allAtts, imageDataByAttachmentID: carriedImageData)
            allAtts = prepared.attachments
            imageDiskWrites = prepared.writes
            updated.messages[mi].attachments = allAtts
            #if DEBUG
            AppLog.info(
                "\(imageDiskWrites.count) images queued for disk, local ids "
                + "\(allAtts.compactMap { $0.localImageID })",
                module: "ImageGen"
            )
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
        updated.messages[mi].state = state
        updated.messages[mi].errorTitle = errorTitle
        updated.messages[mi].errorDetail = errorDetail
        // Relay web reply notice: the switch is on and the delivering attempt carried no fragment -> attach it under this assistant message (in this process's memory only).
        // This runs before the conversation is published below, so the list rows rebuilt by that publish already include it.
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
                        AppLog.error(error, module: "chat.continuation_ack")
                    }
                }
            }
        }

        if state != .delivered, !imageDiskWrites.isEmpty {
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

        if state == .delivered {
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
                // Web search: look at whether this delivery carried a fragment, by the protocol actually delivered on (a re-routed first send or a protocol fallback counts).
                let deliveredTransport = route.switchedTo ?? route.transport
                let stripped = route.webStripped.contains(deliveredTransport)
                let carriedHash = stripped ? nil : route.webFragmentHashes[deliveredTransport]
                // Delivered with a fragment and the production parser produced web citations -> searched / observed. It writes only the local record and does not upgrade any
                // message-level execution fact.
                if let carriedHash, !carriedCitations.isEmpty {
                    RelayWebProbeStore.shared.record(
                        connectionID: route.providerID.uuidString, modelID: route.modelID,
                        transport: deliveredTransport.rawValue, result: .searched, source: .observed, fragmentHash: carriedHash
                    )
                }
                // Delivered after resending without the fragment -> rejected / tested for that protocol x the current hash.
                if stripped, let hash = route.webFragmentHashes[deliveredTransport] {
                    RelayWebProbeStore.shared.record(
                        connectionID: route.providerID.uuidString, modelID: route.modelID,
                        transport: deliveredTransport.rawValue, result: .rejected, source: .tested, fragmentHash: hash
                    )
                }
            }
            // Persist generated images locally on this device.
            let uid = AppSessionStore.activeUID
            if !imageDiskWrites.isEmpty {
                let convID = conversationID
                let stateRetainer: AppState? = appState
                let writes = imageDiskWrites
                let partitionUID = uid
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

    private func failStreamingMessage(
        conversationID: UUID,
        messageID: UUID,
        expectedSendTaskID: UUID,
        userFacingText: String,
        estimatedCost: Double,
        title: String,
        detail: String,
        errorCode: String = "unknown",
        recoveryPrimaryAction: String? = nil,
        /// The send task's catch runs outside the tracker's TaskLocal scope and cannot read
        /// `current`, so the caller passes the terminal result in.
        terminalExecution: CapabilityExecutionResult? = nil
    ) {
        guard let session = sessions[conversationID],
              session.messageID == messageID,
              session.sendTaskID == expectedSendTaskID else { return }

        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }

        var updated = conversations[ci]
        if let session = sessions[conversationID], session.messageID == messageID {
            updated.messages[mi].text = session.text
            if !session.citations.isEmpty {
                updated.messages[mi].citations = session.citations
            }
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
        // already matched an exact catalog locator may replace it with rejected.
        if let execution = terminalExecution ?? CapabilityExecutionRuntime.current?.terminalResult(),
           execution.states.values.contains(.rejected) {
            updated.messages[mi].capabilityExecution = execution
        }
        updated.messages[mi].state = .failed
        updated.messages[mi].errorTitle = title
        updated.messages[mi].errorDetail = detail
        updated.messages[mi].recoveryPrimaryAction = recoveryPrimaryAction
        updated.updatedAt = ConversationListMetadata.computeActivityAt(for: updated)
        ConversationListMetadata.apply(to: &updated)
        appState.upsertConversationProjection(updated)
    }

    /// Strips leading whitespace from the first visible delta so a reply never opens with a blank
    /// line. Once anything has been accumulated the delta passes through untouched: the final
    /// `.done` text is trimmed as a whole, and trimming mid-stream would eat real spacing.
    nonisolated static func sanitizedStreamingDelta(_ delta: String, accumulatedIsEmpty: Bool) -> String? {
        guard accumulatedIsEmpty else { return delta }
        let stripped = delta.drop { ch in
            ch.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
        }
        guard !stripped.isEmpty else { return nil }
        return String(stripped)
    }

    /// Replaces the accumulated text with the authoritative final text carried by `.done`.
    ///
    /// Guarded on both the message id and the send task id: a late `.done` belonging to a retry or
    /// continue that has since been superseded must not overwrite the session that replaced it.
    private func reconcileStreamingText(
        with fullText: String,
        in conversationID: UUID,
        messageID: UUID,
        expectedSendTaskID: UUID
    ) {
        guard !fullText.isEmpty,
              sessions[conversationID]?.messageID == messageID,
              sessions[conversationID]?.sendTaskID == expectedSendTaskID else { return }
        sessions[conversationID]?.text = fullText
    }

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

    /// Turns a streamed image part into bytes held on the session and clears `base64Data`, so the
    /// payload is not carried a second time inside the attachment.
    ///
    /// Two shapes arrive here: an HTTP URL, which is downloaded, and an inline
    /// `data:image/png;base64,…` URL, which is decoded. Relays commonly send the second form.
    private func handleStreamingImagePart(_ attachment: Attachment, in conversationID: UUID) async {
        var att = attachment
        if let b64 = att.base64Data, b64.hasPrefix("http"), let url = URL(string: b64) {
            if let data = await downloadGeneratedImage(from: url) {
                sessions[conversationID]?.pendingImageData[att.id] = data
                #if DEBUG
                AppLog.info(
                    "Downloaded a streamed image for attachment \(att.id), \(data.count) bytes",
                    module: "ImageGen"
                )
                #endif
            }
        } else if let b64 = att.base64Data, !b64.isEmpty,
                  let data = Self.decodeImageBase64(b64) {
            sessions[conversationID]?.pendingImageData[att.id] = data
            #if DEBUG
            let img = UIImage(data: data)
            AppLog.info(
                "Decoded a streamed image for attachment \(att.id): \(data.count) bytes, "
                + "decodesAsImage=\(img != nil) size=\(img?.size ?? .zero)",
                module: "ImageGen"
            )
            #endif
        } else if let b64 = att.base64Data, !b64.isEmpty {
            #if DEBUG
            AppLog.warning(
                "A streamed image part carried \(b64.count) characters of base64 that could not be "
                + "decoded as image data, attachment \(att.id)",
                module: "ImageGen"
            )
            #endif
        }
        att.base64Data = nil
        sessions[conversationID]?.attachments.append(att)

    }

    /// Appends a reasoning chunk to the session and publishes the delta to its subscribers.
    private func appendReasoning(_ chunk: String, in conversationID: UUID, messageID: UUID, sendTaskID: UUID) {
        // Mutate through the dictionary subscript so the buffer is appended in place. Copying the
        // session out and writing it back would re-copy the whole accumulated reasoning text on
        // every chunk, which turns a long reasoning stream quadratic.
        guard let revision = sessions[conversationID]?
            .appendReasoning(chunk, messageID: messageID, sendTaskID: sendTaskID) else { return }
        // A nonempty normalized parser event is evidence only when the TaskLocal tracker has an
        // exact catalog binding for this owner/protocol/parser.  A display-only heartbeat remains
        // useful UI feedback but is never execution evidence.
        CapabilityExecutionRuntime.recordParserEvent(.reasoning, nonEmpty: !chunk.isEmpty)
        // A non-empty reasoning delta means the model is talking again, so the activity is over.
        // An empty heartbeat does not clear it: the reasoning block keeps itself alive during a
        // search.
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

    /// The only place an activity is set. Guarded on message and send task id for the same reason
    /// `appendReasoning` is: a cancelled task still emitting events at an await point must not
    /// attach an activity to the session of the send that replaced it.
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

    /// The session was removed or replaced: tells subscribers that this message's stream is over,
    /// which clears the activity and hides all waiting feedback. Sent once per session, never per
    /// token.
    private func publishStreamEnded(for session: StreamingSession?, in conversationID: UUID) {
        guard let session else { return }
        activitySubjects[conversationID]?.send(
            StreamActivityState(messageID: session.messageID, activity: nil, isStreaming: false)
        )
    }

    /// Where a live body delta enters `session.text`, called by `flushBufferedDelta` after
    /// throttling. The activity is cleared before the body signal is sent, so by the time the cell
    /// receives the text the status line has already made way and never shares the screen with
    /// newly arrived words.
    private func commitStreamingBodyDelta(_ sanitized: String, in conversationID: UUID) {
        sessions[conversationID]?.text.append(sanitized)
        clearStreamActivity(in: conversationID)
        streamingSubjects[conversationID]?.send()
    }

    /// Stamps the moment reasoning gave way to body text. Guarded on message and send task id for
    /// the same reason `appendReasoning` is: a chunk still in flight from a superseded send must
    /// not close out the current one.
    private func markReasoningEndedIfNeeded(in conversationID: UUID, messageID: UUID, sendTaskID: UUID) {
        guard var session = sessions[conversationID],
              session.messageID == messageID,
              session.sendTaskID == sendTaskID else { return }
        guard session.reasoningStartedAt != nil, session.reasoningEndedAt == nil else { return }
        session.reasoningEndedAt = Date()
        sessions[conversationID] = session
    }

    private func recordCitations(_ citations: [Citation], in conversationID: UUID) {
        guard !citations.isEmpty else { return }
        // This is called by the real TransportStrategy → StreamEvent path.  The tracker still
        // requires a current recipe signal, so arbitrary citations cannot promote an owner.
        CapabilityExecutionRuntime.recordParserEvent(.citations, nonEmpty: true)
        var resolvedCitations = sessions[conversationID]?.citations ?? []
        resolvedCitations.append(contentsOf: citations)
        sessions[conversationID]?.citations = resolvedCitations

        guard let session = sessions[conversationID],
              let ci = conversations.firstIndex(where: { $0.id == conversationID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == session.messageID })
        else { return }
        if conversations[ci].messages[mi].citations != resolvedCitations {
            var updated = conversations[ci]
            updated.messages[mi].citations = resolvedCitations
            appState.upsertConversationProjection(updated)
            streamingSubjects[conversationID]?.send()
        }
    }

    nonisolated static func decodeImageBase64(_ raw: String) -> Data? {
        let maxDecodedBytes = ChatAttachmentImportPolicy.maxAttachmentBytes
        let maxEncodedBytes = ((maxDecodedBytes + 2) / 3) * 4
        guard raw.utf8.count <= maxEncodedBytes + 256 else {
            reportGeneratedImageRejection(reason: "base64_input_too_large")
            return nil
        }

        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("data:") {
            if let comma = s.firstIndex(of: ",") {
                s = String(s[s.index(after: comma)...])
            }
        }
        if let data = Data(base64Encoded: s, options: [.ignoreUnknownCharacters]) {
            guard data.count <= maxDecodedBytes else {
                reportGeneratedImageRejection(reason: "base64_output_too_large")
                return nil
            }
            return data
        }
        var normalized = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
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
            AppLog.error(
                error,
                module: "chat.generated_image",
                context: [
                    "image.source": "url",
                    "image.rejection": error is BoundedNetworkDataError ? "too_large" : "download_failed",
                ]
            )
            return nil
        }
    }

    nonisolated private static func reportGeneratedImageRejection(reason: String) {
        Task { @MainActor in
            AppLog.warning(
                "Generated image payload was rejected before persistence.",
                module: "chat.generated_image",
                context: ["image.rejection": reason]
            )
        }
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
        if sessions[conversationID] != nil {
            removeSession(for: conversationID)
        }
        appState.triggerPersistSession()
    }

    private func currentAssistantText(conversationID: UUID, messageID: UUID) -> String {
        // Prefer the live session: while a send is running it is ahead of the stored message.
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

    func debugInvokePartialPreservationGuardForTesting(
        conversationID: UUID,
        newMessageID: UUID
    ) {
        if let oldSession = sessions[conversationID], oldSession.messageID != newMessageID {
            persistPartialStreamingAsInterrupted(in: conversationID)
        }
    }

    var debugBackgroundTaskID: UIBackgroundTaskIdentifier { backgroundTaskID }

    /// Test helper: completes the active session's message with the given state.
    func debugFinishStreamingForTesting(conversationID: UUID, state: ChatMessageState) {
        guard let session = sessions[conversationID] else { return }
        completeStreamingMessage(
            conversationID: conversationID,
            messageID: session.messageID,
            expectedSendTaskID: session.sendTaskID,
            state: state
        )
    }

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

    func debugTriggerGracefulInterruptForTesting() {
        gracefullyInterruptAllStreaming()
    }

    func debugSendSubjectForTesting(in conversationID: UUID) {
        subject(for: conversationID).send()
    }

    /// Test helper: appends a token to an existing session and pokes its subject. It deliberately
    /// does not create a session, so `streamingConversationIDs` is left unchanged.
    func debugAppendTokenForTesting(delta: String, in conversationID: UUID) {
        sessions[conversationID]?.text.append(delta)
        streamingSubjects[conversationID]?.send()
    }

    func debugGracefullyInterruptAllStreamingForTesting() {
        gracefullyInterruptAllStreaming()
    }

    #endif
}
