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

    init(providerSession: URLSession = .shared, toolCallMemory: ToolCallMemoryStore = .shared) {
        self.providerSession = providerSession
        self.toolCallMemory = toolCallMemory
    }

    // MARK: - Streaming session state

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

    private(set) var streamingConversationIDs: Set<UUID> = []

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

    // MARK: - Streaming sessions

    /// Registers a streaming session and publishes the active conversation set.
    private func addSession(_ session: StreamingSession, for conversationID: UUID) {
        sessions[conversationID] = session
        streamingConversationIDs = Set(sessions.keys)
    }

    /// Drops the streaming session. Ends the background task once no sessions remain.
    @discardableResult
    private func removeSession(for conversationID: UUID) -> StreamingSession? {
        let removed = sessions.removeValue(forKey: conversationID)
        streamingConversationIDs = Set(sessions.keys)
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

    func discardStreamingResources(for conversationID: UUID) {
        if sessions[conversationID] != nil {
            cancelGeneration(in: conversationID) // this also removes the session
        }
        streamingSubjects.removeValue(forKey: conversationID)
        reasoningSubjects.removeValue(forKey: conversationID)
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

    func isBusyStreaming(in conversationID: UUID) -> Bool {
        sessions[conversationID] != nil
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
        case .delta, .reasoning, .imagePart, .citations, .done:
            break
        }
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
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return nil }
        guard let provider = appState.provider(for: conversations[index].providerID) else {
            ToastManager.shared.show(L10n.tr("The selected provider is no longer available."))
            return nil
        }

        let model = appState.currentModel(for: conversations[index]) ?? provider.defaultModel
        guard let model else { return nil }
        let modelName = model.name
        let storedModelID = ModelResolver.preferredStoredModelIdentifier(for: model, providerKind: provider.kind)
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
            let skillValues = conversations[index].skillId.flatMap { skillID in
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
        guard isAnyStreaming else { return }
        let convIDs = Array(sessions.keys)
        for convID in convIDs {
            cancelGeneration(in: convID)
        }
    }

    func editUserMessage(messageID: UUID, in conversationID: UUID) -> String? {
        guard let convIndex = conversations.firstIndex(where: { $0.id == conversationID }) else { return nil }
        guard let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageID }),
              conversations[convIndex].messages[msgIndex].role == .user else { return nil }

        return beginEditingUserMessage(at: msgIndex, in: conversationID)
    }

    func editPromptingMessage(for assistantMessageID: UUID, in conversationID: UUID) -> String? {
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
        guard let convIndex = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        guard let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageID }),
              conversations[convIndex].messages[msgIndex].role == .assistant else { return }
        if conversations[convIndex].messages[msgIndex].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await regenerateMessage(messageID: messageID, in: conversationID, capabilitySelection: capabilitySelection)
            return
        }
        guard let provider = appState.provider(for: conversations[convIndex].providerID) else { return }

        let continuingMessage = conversations[convIndex].messages[msgIndex]
        let model = appState.currentModel(for: conversations[convIndex]) ?? provider.defaultModel
        guard let model else { return }
        let storedModelID = ModelResolver.preferredStoredModelIdentifier(for: model, providerKind: provider.kind)
        guard let resolvedCapabilitySelection = await gatedRecoveryCapabilitySelection(
            capabilitySelection,
            preservingLibraryModeFrom: continuingMessage,
            model: model,
            provider: provider
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
        guard let convIndex = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        guard let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageID }),
              conversations[convIndex].messages[msgIndex].role == .assistant else { return }
        guard let provider = appState.provider(for: conversations[convIndex].providerID) else { return }
        let model = appState.currentModel(for: conversations[convIndex]) ?? provider.defaultModel
        guard let model else { return }
        let storedModelID = ModelResolver.preferredStoredModelIdentifier(for: model, providerKind: provider.kind)
        let originalMessage = conversations[convIndex].messages[msgIndex]
        guard let resolvedCapabilitySelection = await gatedRecoveryCapabilitySelection(
            capabilitySelection,
            preservingLibraryModeFrom: originalMessage,
            model: model,
            provider: provider
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
        updatedForRegen.messages.append(newAssistantMessage)
        updatedForRegen.updatedAt = ConversationListMetadata.computeActivityAt(for: updatedForRegen)
        updatedForRegen.draftText = ""
        updatedForRegen.isDraft = false
        ConversationListMetadata.apply(to: &updatedForRegen)
        appState.upsertConversationProjection(updatedForRegen)
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
        let model = appState.currentModel(for: conversations[convIndex]) ?? provider.defaultModel
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
            provider: provider
        ) else { return }
        guard let convIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageID })
        else { return }

        let currentProvider = appState.provider(for: conversations[convIndex].providerID)
        let currentModel = currentProvider.flatMap {
            appState.currentModel(for: conversations[convIndex]) ?? $0.defaultModel
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
        updatedForRetry.messages[msgIndex].capabilityExecution = nil
        updatedForRetry.messages[msgIndex].unhandledToolCalls = nil
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

    private func gatedRecoveryCapabilitySelection(
        _ requested: ChatCapabilitySelection,
        preservingLibraryModeFrom message: ChatMessage,
        model: AIModel,
        provider: Provider
    ) async -> ChatCapabilitySelection? {
        recoveryCapabilitySelection(
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
        let apiKey = provider.apiKey
        let resolvedModelID = ModelResolver.resolvedProviderModelIdentifier(model.id, providerKind: providerKind)
        let providerID = provider.id
        let baseURLText = provider.baseURLText

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
        subject(for: conversationID).send()
        let sendTask = Task(priority: .userInitiated) { [weak self, appStateRetainer = appState as AppState?] in
            guard let self else { return }
            _ = appStateRetainer
            let openRouterService = OpenRouterService(session: self.providerSession)
            let openAIService = OpenAIService(session: self.providerSession)
            let deepSeekService = DeepSeekService(session: self.providerSession)
            let grokService = GrokService(session: self.providerSession)
            let geminiService = GeminiService(session: self.providerSession)
            let anthropicService = AnthropicService(session: self.providerSession)
            let groqService = GroqService(session: self.providerSession)
            let togetherService = TogetherService(session: self.providerSession)
            let fireworksService = FireworksService(session: self.providerSession)
            let miniMaxService = MiniMaxService(session: self.providerSession)
            let zhipuService = ZhipuService(session: self.providerSession)
            let qwenService = QwenService(session: self.providerSession)
            let moonshotService = MoonshotService(session: self.providerSession)
            let mistralService = MistralService(session: self.providerSession)
            let siliconFlowService = SiliconFlowService(session: self.providerSession)
            let officialImageDispatcher = BaseAPIService(session: self.providerSession)
            var bufferedDelta = ""
            var lastFlushTime = Date().timeIntervalSince1970
            let enrichedRequestSnapshot = await self.markMemoryUsedIfRequestInjectsIt(requestSnapshot)
            let requestBuild = await Task.detached(priority: .userInitiated) {
                ChatRequestBuilder.build(from: enrichedRequestSnapshot)
            }.value
            let requestMessages = requestBuild.requestMessages
            var requestOptions = requestBuild.requestOptions
            requestOptions.capabilityPreferences = capabilitySelection.typedPreferences
            requestOptions.localContinuationMessageID = assistantMessageID
            requestOptions.localExplicitContinuationMessageID = explicitContinuationMessageID
            var effectiveAPIKey = apiKey
            if providerKind == .grok, provider.authMode == .subscription {
                switch await GrokSubscriptionRuntime.prepare(providerID: providerID) {
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
                            title: L10n.tr("Grok subscription", table: .providers),
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
                            title: L10n.tr("ChatGPT subscription", table: .providers),
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
                    modelID: ModelResolver.preferredStoredModelIdentifier(for: model, providerKind: provider.kind),
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
            if requestOptions.localCustomFragmentDisposition == .include {
                let runtimeIdentity = CapabilityPreferenceRuntimeIdentity.make(provider: provider, model: model)
                let customFragments = GenerationParameterSettingsStore.shared.activeLocalCustomFragments(
                    providerID: provider.id, modelID: runtimeIdentity?.canonicalModelID ?? "",
                    conversationID: conversationID, transportIdentity: runtimeIdentity?.wireValue ?? "",
                    forwardPort: .init(providerKind: provider.kind, schemaModelID: model.id)
                )
                requestOptions.selectLocalCustomBodyFragments(customFragments)
            }
            requestOptions.capabilityEvidenceModel = provider.kind == .relay
                ? model
                : MetadataClient.shared.syncCurrentCapabilityEvidenceModel(model, providerKind: provider.kind)
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
                    self.sessions[conversationID]?.text.append(sanitized)
                    self.streamingSubjects[conversationID]?.send()
                }
            }

            #if DEBUG
            AppLog.info(
                "Routing a send: provider=\(providerKind) model=\(model.id) "
                + "capabilities=\(model.capabilities) imageGenProfile=\(model.imageGenProfile ?? "none")",
                module: "ImageGen"
            )
            #endif

            do {
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

                switch providerKind {
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
                    guard let relayBaseURL = baseURLText else {
                        throw ProviderServiceError.invalidConfiguration(detail: "Relay provider missing base URL.")
                    }

                    let relayTransport = provider.relayRequested?.transport ?? .openaiChatCompletions
                    var relayRequestOptions = requestOptions
                    relayRequestOptions.relayRequested = provider.relayRequested

                    // Image generation on a relay depends on the transport. Chat Completions posts
                    // to the images endpoint, Responses carries an inline `image_generation` tool on
                    // a streaming chat request, and Gemini asks for an image modality on its normal
                    // generate call. A dedicated image model cannot drive the Responses request
                    // itself, so it moves into the tool while a chat model drives the turn.
                    if model.capabilities.contains(.imageGen) {
                        let imageRoute = RelayRuntimeSupport.imageRoute(for: relayTransport)
                        switch imageRoute {
                        case .unsupported:
                            throw ProviderServiceError.invalidConfiguration(
                                detail: L10n.tr("Image generation is not available on this transport. Open Providers → this Relay → Advanced Settings → Transport and switch it to OpenAI Responses or Chat Completions.", table: .providers)
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
                                relayRequested: provider.relayRequested
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
                            let driverResult = RelayRuntimeSupport.pickChatDriverModelID(
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
                                reasoningMode: capabilitySelection.reasoningMode,
                                requestOptions: relayRequestOptions,
                                relayRequested: provider.relayRequested,
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

                        if imageRoute != .geminiModality {
                            break
                        }
                    }

                    let useNonStreamingRelayRuntime =
                        provider.relayRequested?.stream == false

                    if useNonStreamingRelayRuntime {
                        let result: ProviderChatResult
                        switch relayTransport {
                        case .anthropicMessages:
                            result = try await anthropicService.sendMessage(
                                apiKey: apiKey,
                                modelID: resolvedModelID,
                                messages: requestMessages,
                                baseURL: relayBaseURL,
                                reasoningMode: capabilitySelection.reasoningMode,
                                requestOptions: relayRequestOptions,
                                relayRequested: provider.relayRequested
                            )
                        case .geminiGenerateContent:
                            result = try await geminiService.sendMessage(
                                apiKey: apiKey,
                                modelID: resolvedModelID,
                                messages: requestMessages,
                                baseURL: relayBaseURL,
                                reasoningMode: capabilitySelection.reasoningMode,
                                webSearchEnabled: capabilitySelection.webSearchEnabled,
                                // Gemini has no separate image endpoint: image output is requested
                                // as an extra response modality on the normal generate call.
                                supportsImageGen: model.capabilities.contains(.imageGen),
                                requestOptions: relayRequestOptions,
                                relayRequested: provider.relayRequested
                            )
                        case .openaiResponses, .openaiChatCompletions, .llamacppNative, .auto:
                            result = try await openAIService.sendMessage(
                                apiKey: apiKey,
                                modelID: resolvedModelID,
                                messages: requestMessages,
                                baseURL: relayBaseURL,
                                reasoningMode: capabilitySelection.reasoningMode,
                                requestOptions: relayRequestOptions,
                                relayRequested: provider.relayRequested,
                                webSearchEnabled: capabilitySelection.webSearchEnabled
                            )
                        }

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
                        let stream: AsyncThrowingStream<StreamEvent, Error>
                        switch relayTransport {
                        case .anthropicMessages:
                            stream = anthropicService.sendMessageStream(
                                apiKey: apiKey,
                                modelID: resolvedModelID,
                                messages: requestMessages,
                                baseURL: relayBaseURL,
                                reasoningMode: capabilitySelection.reasoningMode,
                                requestOptions: relayRequestOptions,
                                relayRequested: provider.relayRequested
                            )
                        case .geminiGenerateContent:
                            stream = geminiService.sendMessageStream(
                                apiKey: apiKey,
                                modelID: resolvedModelID,
                                messages: requestMessages,
                                baseURL: relayBaseURL,
                                reasoningMode: capabilitySelection.reasoningMode,
                                webSearchEnabled: capabilitySelection.webSearchEnabled,
                                // Gemini has no separate image endpoint: image output is requested
                                // as an extra response modality on the normal generate call.
                                supportsImageGen: model.capabilities.contains(.imageGen),
                                requestOptions: relayRequestOptions,
                                relayRequested: provider.relayRequested
                            )
                        case .openaiResponses, .openaiChatCompletions, .llamacppNative, .auto:
                            stream = openAIService.sendMessageStream(
                                apiKey: apiKey,
                                modelID: resolvedModelID,
                                messages: requestMessages,
                                baseURL: relayBaseURL,
                                reasoningMode: capabilitySelection.reasoningMode,
                                requestOptions: relayRequestOptions,
                                relayRequested: provider.relayRequested,
                                webSearchEnabled: capabilitySelection.webSearchEnabled
                            )
                        }

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
                let hasDispatchedCustomFacts = CapabilityExecutionRuntime.hasDispatchedFact()

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
                        let isFatalError: Bool = {
                            switch providerError {
                            case .invalidAPIKey, .invalidConfiguration: return true
                            default: return false
                            }
                        }()
                        if isFatalError, var erroredProvider = self.appState.provider(for: providerID) {
                            erroredProvider.status = ProviderConnectionState.issue(providerError.messageKey)
                            erroredProvider.lastError = providerError.messageKey
                            self.appState.providerManager.updateProvider(erroredProvider)
                        }

                        let isCustomFieldError: Bool = {
                            if case let .invalidConfiguration(detail) = providerError,
                               detail.hasPrefix("Rejected safe custom fragment:") {
                                return true
                            }
                            // Upstream custom recovery is never inferred from status/text. The
                            // production tracker exposes it only after a structured exact locator
                            // matched an actually applied custom pointer before any event/effect.
                            guard localCustomFragmentDisposition == .include,
                                  CapabilityExecutionRuntime.hasRejectedSource(.custom)
                            else { return false }
                            return true
                        }()
                        let isLocatedSettingRejection = CapabilityExecutionRuntime.current?
                            .terminalResult().states.values.contains(.rejected) == true
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
                                    : providerError.titleKey),
                            // The raw JSON or upstream response must never reach the error card,
                            // persistence or the log. Keep only a stable, safe code.
                            detail: isCustomFieldError
                                ? (CapabilityExecutionRuntime.hasRejectedSource(.custom)
                                    ? "model_control_setting_rejected"
                                    : "custom_request_fields_rejected")
                                : (isLocatedSettingRejection
                                    ? "model_control_setting_rejected"
                                    : providerError.technicalDetail),
                            errorCode: providerError.diagnosticCode
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

    private func rememberToolCallCapability(
        provider: Provider,
        model: AIModel,
        toolCall: Bool,
        reason: ToolCallMemoryReason
    ) {
        guard ToolCallCapabilityPolicy.memoryEligible(provider: provider, model: model) else { return }
        toolCallMemory.record(connectionID: provider.id, modelID: model.id, toolCall: toolCall, reason: reason)
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

    /// Records that this request consumes memory so the conversation can show it, and hands the
    /// snapshot back unchanged.
    private func markMemoryUsedIfRequestInjectsIt(
        _ requestSnapshot: ChatRequestSnapshot
    ) async -> ChatRequestSnapshot {
        if let conversation = requestSnapshot.conversation,
           ChatRequestBuilder.willInjectMemory(
               skill: requestSnapshot.skill,
               preferences: requestSnapshot.preferences,
               conversation: requestSnapshot.conversation,
               retrievedSnippets: requestSnapshot.retrievedSnippets
           ) {
            appState.markMemoryUsedIfNeeded(in: conversation.id)
        }
        return requestSnapshot
    }

    private func beginEditingUserMessage(at messageIndex: Int, in conversationID: UUID) -> String? {
        guard let convIndex = conversations.firstIndex(where: { $0.id == conversationID }) else { return nil }
        guard conversations[convIndex].messages.indices.contains(messageIndex),
              conversations[convIndex].messages[messageIndex].role == .user else {
            return nil
        }

        let messageText = conversations[convIndex].messages[messageIndex].text
        var updated = conversations[convIndex]
        updated.messages.removeSubrange(messageIndex...)
        updated.draftText = messageText
        updated.previewText = messageText

        updated.updatedAt = ConversationListMetadata.computeActivityAt(for: updated)
        updated.isDraft = updated.messages.isEmpty
        appState.upsertConversationProjection(updated)
        appState.persistRecoverySnapshotAfterDestructiveChange()

        return messageText
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
        if let session = sessions[conversationID], session.messageID == messageID {
            updated.messages[mi].text = session.text
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
        if let execution = CapabilityExecutionRuntime.current?.terminalResult(),
           execution.states.values.contains(.rejected) {
            updated.messages[mi].capabilityExecution = execution
        }
        updated.messages[mi].state = .failed
        updated.messages[mi].errorTitle = title
        updated.messages[mi].errorDetail = detail
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
        reasoningSubjects[conversationID]?.send(ReasoningStreamDelta(
            messageID: messageID,
            sendTaskID: sendTaskID,
            revision: revision,
            delta: chunk
        ))
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
