import Foundation
import SwiftUI
import Testing
@testable import Oriveo

@Suite("ChatScreenProjection")
struct ChatScreenProjectionTests {

    @Test("message count and sending state come from observed messages")
    func messageCountAndSendingStateComeFromObservedMessages() {
        let summary = makeSummary(messageCount: 42)
        let messages = [
            TestFactories.makeMessage(role: .user, text: "hello"),
            TestFactories.makeMessage(role: .assistant, text: "working", state: .generating)
        ]

        let projection = ChatScreenProjection(
            requestedConversationID: summary.id,
            summary: summary,
            messages: messages,
            hasLoadedSummary: true,
            messageRevision: 7
        )

        #expect(projection.messageCount == 2)
        #expect(projection.messageRevision == 7)
        #expect(projection.isSendingMessage == true)
        #expect(projection.exportsEnabled == true)
    }

    @Test("persisted chat is treated as missing only after summary observation finishes loading")
    func missingConversationRequiresLoadedSummaryObservation() {
        let requestedConversationID = UUID()

        let pendingProjection = ChatScreenProjection(
            requestedConversationID: requestedConversationID,
            summary: nil,
            messages: [],
            hasLoadedSummary: false,
            messageRevision: 0
        )
        let missingProjection = ChatScreenProjection(
            requestedConversationID: requestedConversationID,
            summary: nil,
            messages: [],
            hasLoadedSummary: true,
            messageRevision: 1
        )

        #expect(pendingProjection.isMissingPersistedConversation == false)
        #expect(pendingProjection.isBootstrappingPersistedConversation == true)
        #expect(missingProjection.isMissingPersistedConversation == true)
        #expect(missingProjection.isBootstrappingPersistedConversation == false)
    }

    @Test("persisted chat keeps bootstrapping while summary says history exists but messages have not hydrated")
    func persistedConversationWaitsForMessagesBeforeLeavingBootstrap() {
        let summary = makeSummary(messageCount: 2)

        let preObservation = ChatScreenProjection(
            requestedConversationID: summary.id,
            summary: summary,
            messages: [],
            hasLoadedSummary: true,
            messageRevision: 0
        )
        #expect(preObservation.isBootstrappingPersistedConversation == true)
        #expect(preObservation.isMissingPersistedConversation == false)

        let postObservation = ChatScreenProjection(
            requestedConversationID: summary.id,
            summary: summary,
            messages: [],
            hasLoadedSummary: true,
            messageRevision: 1
        )
        #expect(postObservation.isBootstrappingPersistedConversation == true)
        #expect(postObservation.isMissingPersistedConversation == false)
    }

    @Test("A Persisted Conversation With Nothing To Load Shows The Skeleton Until The Watchdog")
    func emptyPersistedConversationLeavesTheSkeletonOnlyAfterTheWatchdog() {
        // The window loader reports an empty message list both while it is still reading and when
        // the conversation really is empty, so the skeleton stays up until the watchdog decides
        // the read is not going to produce anything.
        let summary = makeSummary(messageCount: 0, previewText: "")

        let stillLoading = ChatScreenProjection(
            requestedConversationID: summary.id,
            summary: summary,
            messages: [],
            hasLoadedSummary: true,
            messageRevision: 1
        )
        #expect(stillLoading.loadState == .bootstrapping)
        #expect(stillLoading.isBootstrappingPersistedConversation == true)

        var expired = stillLoading
        expired.bootstrapWatchdogExpired = true
        #expect(expired.loadState == .stalled)
        #expect(expired.isBootstrappingPersistedConversation == false)
    }

    @Test("Skill Draft Conversation Shows Empty State Not Bootstrap")
    func skillDraftConversationShowsEmptyStateNotBootstrap() {
        let summary = makeSummary(messageCount: 0, previewText: "", skillID: UUID(), isDraft: true)

        let projection = ChatScreenProjection(
            requestedConversationID: summary.id,
            summary: summary,
            messages: [],
            hasLoadedSummary: true,
            messageRevision: 1
        )
        #expect(projection.isBootstrappingPersistedConversation == false)

        let draftWithPreview = makeSummary(
            messageCount: 0,
            previewText: "draft preview",
            draftText: "typing…"
        )
        let draftProjection = ChatScreenProjection(
            requestedConversationID: draftWithPreview.id,
            summary: draftWithPreview,
            messages: [],
            hasLoadedSummary: true,
            messageRevision: 1
        )
        #expect(draftProjection.isBootstrappingPersistedConversation == false)
    }

    @Test("Cloud Restored Conversation Keeps Bootstrap Until Messages Arrive")
    func cloudRestoredConversationKeepsBootstrapUntilMessagesArrive() {
        let summary = makeSummary(messageCount: 0, previewText: "summary of what was discussed last time")

        let projection = ChatScreenProjection(
            requestedConversationID: summary.id,
            summary: summary,
            messages: [],
            hasLoadedSummary: true,
            messageRevision: 1
        )
        #expect(projection.isBootstrappingPersistedConversation == true)

        let hydrated = ChatScreenProjection(
            requestedConversationID: summary.id,
            summary: summary,
            messages: [TestFactories.makeMessage(role: .user, text: "hello")],
            hasLoadedSummary: true,
            messageRevision: 2
        )
        #expect(hydrated.isBootstrappingPersistedConversation == false)
    }

    @Test("A Persisted Message Count Keeps The Skeleton Up Even Without A Preview")
    func persistedMessageCountKeepsBootstrapEvenWithoutPreview() {
        let summary = makeSummary(messageCount: 8, previewText: "")

        let projection = ChatScreenProjection(
            requestedConversationID: summary.id,
            summary: summary,
            messages: [],
            hasLoadedSummary: true,
            messageRevision: 1
        )
        #expect(projection.isBootstrappingPersistedConversation == true)
    }

    @Test("A Draft Conversation Goes Straight To The Empty State")
    func draftConversationGoesStraightToTheEmptyState() {
        // A draft has nothing persisted to wait for, so showing a skeleton would be a lie.
        let draft = makeSummary(messageCount: 0, previewText: "", isDraft: true)
        #expect(
            ChatScreenProjection(
                requestedConversationID: draft.id,
                summary: draft,
                messages: [],
                hasLoadedSummary: true,
                messageRevision: 1
            ).loadState == .empty
        )

        let withUnsentText = makeSummary(messageCount: 0, previewText: "", draftText: "half a question")
        #expect(
            ChatScreenProjection(
                requestedConversationID: withUnsentText.id,
                summary: withUnsentText,
                messages: [],
                hasLoadedSummary: true,
                messageRevision: 1
            ).loadState == .empty
        )
    }

    @Test("summary metadata is exposed for chat chrome")
    func summaryMetadataFeedsChatChrome() {
        let providerID = UUID()
        let skillID = UUID()
        let summary = makeSummary(
            providerID: providerID,
            modelID: "gpt-4.1",
            estimatedCost: 1.25,
            draftText: "draft",
            useMemory: false,
            skillID: skillID
        )

        let projection = ChatScreenProjection(
            requestedConversationID: summary.id,
            summary: summary,
            messages: [],
            hasLoadedSummary: true,
            messageRevision: 3
        )

        #expect(projection.activeConversationID == summary.id)
        #expect(projection.providerID == providerID)
        #expect(projection.modelID == "gpt-4.1")
        #expect(abs(projection.estimatedCost - 1.25) < 0.000_001)
        #expect(projection.draftText == "draft")
        #expect(projection.useMemory == false)
        #expect(projection.skillID == skillID)
        #expect(projection.isBootstrappingPersistedConversation == false)
    }

    @Test("message rows include note references for saved-note badge routing")
    func messageRowsIncludeNoteReferences() {
        let sourceMessageID = UUID()
        let savedNote = NoteSummary(NoteTestFactories.makeNote(
            title: "Saved answer",
            sourceMessageId: sourceMessageID,
            sourceProviderKind: .openAI,
            captureKind: .fullAnswer
        ))
        let messages = [
            TestFactories.makeMessage(id: sourceMessageID, role: .assistant, text: "answer")
        ]

        let rows = ChatCollectionProjectionBuilder.makeRows(
            from: messages,
            metadata: .empty,
            noteReferencesByMessageID: [sourceMessageID: [savedNote]]
        )

        #expect(rows.count == 1)
        #expect(rows[0].noteReferences.map(\.id) == [savedNote.id])
        #expect(rows[0].noteBadgePresentation == .single(savedNote.id))
    }

    @Test("message rows expose multi-note badge presentation when several notes share one source message")
    func messageRowsExposeMultiNoteBadgePresentation() {
        let sourceMessageID = UUID()
        let noteA = NoteSummary(NoteTestFactories.makeNote(title: "A", sourceMessageId: sourceMessageID))
        let noteB = NoteSummary(NoteTestFactories.makeNote(title: "B", sourceMessageId: sourceMessageID))
        let rows = ChatCollectionProjectionBuilder.makeRows(
            from: [TestFactories.makeMessage(id: sourceMessageID, role: .assistant, text: "answer")],
            metadata: .empty,
            noteReferencesByMessageID: [sourceMessageID: [noteA, noteB]]
        )

        #expect(rows[0].noteReferences.map(\.id) == [noteA.id, noteB.id])
        #expect(rows[0].noteBadgePresentation == .multiple([noteA.id, noteB.id]))
    }

    @Test("saved-note references are filtered to the active conversation")
    func savedNoteReferencesFilterActiveConversation() {
        let activeConversationID = UUID()
        let otherConversationID = UUID()
        let sourceMessageID = UUID()
        let activeNote = NoteSummary(NoteTestFactories.makeNote(
            title: "Active",
            sourceConversationId: activeConversationID,
            sourceMessageId: sourceMessageID
        ))
        let otherConversationNote = NoteSummary(NoteTestFactories.makeNote(
            title: "Other",
            sourceConversationId: otherConversationID,
            sourceMessageId: sourceMessageID
        ))

        let references = ChatNoteReferences.groupByMessageID(
            [otherConversationNote, activeNote],
            conversationID: activeConversationID
        )

        #expect(references[sourceMessageID]?.map(\.id) == [activeNote.id])
    }

    @Test("Replace Current Note Action Uses Return Note Or Message Reference")
    func replaceCurrentNoteActionUsesReturnNoteOrMessageReference() {
        let activeNoteID = UUID()
        let activeSummary = NoteSummary(NoteTestFactories.makeNote(id: activeNoteID))
        let sourceMessageID = UUID()
        let olderNoteID = UUID()
        let newerNoteID = UUID()
        let sourceSummary = NoteSummary(NoteTestFactories.makeNote(
            id: newerNoteID,
            sourceMessageId: sourceMessageID,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_200)
        ))
        let olderSourceSummary = NoteSummary(NoteTestFactories.makeNote(
            id: olderNoteID,
            sourceMessageId: sourceMessageID,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        ))

        #expect(ChatNoteReferences.canReplaceCurrentNote(
            returnToNoteID: activeNoteID,
            activeNotes: [activeSummary],
            currentMessageID: nil
        ) == true)
        #expect(ChatNoteReferences.canReplaceCurrentNote(
            returnToNoteID: nil,
            activeNotes: [sourceSummary],
            currentMessageID: sourceMessageID
        ) == true)
        #expect(ChatNoteReferences.canReplaceCurrentNote(
            returnToNoteID: UUID(),
            activeNotes: [activeSummary],
            currentMessageID: nil
        ) == false)
        #expect(ChatNoteReferences.canReplaceCurrentNote(
            returnToNoteID: nil,
            activeNotes: [activeSummary],
            currentMessageID: nil
        ) == false)
        #expect(ChatNoteReferences.replacementNoteID(
            returnToNoteID: nil,
            activeNotes: [olderSourceSummary, sourceSummary],
            currentMessageID: sourceMessageID
        ) == newerNoteID)
        #expect(ChatNoteReferences.canShowReplaceSelection(
            canReplaceCurrentNoteSelection: true,
            noteReferences: []
        ) == true)
        #expect(ChatNoteReferences.canShowReplaceSelection(
            canReplaceCurrentNoteSelection: false,
            noteReferences: [sourceSummary]
        ) == true)
        #expect(ChatNoteReferences.canShowReplaceSelection(
            canReplaceCurrentNoteSelection: false,
            noteReferences: []
        ) == false)
    }

    @Test("Falls Back To Active Model When Conversation Provider Is Missing")
    func fallsBackToActiveModelWhenConversationProviderIsMissing() {
        let fallbackProvider = TestFactories.makeProvider(
            kind: .openAI,
            models: [
                TestFactories.makeModel(
                    id: "gpt-4o",
                    name: "GPT-4o",
                    isDefault: true,
                    canonicalModelId: "gpt-4o"
                )
            ]
        )
        let activeModel = (provider: fallbackProvider, model: fallbackProvider.models[0])

        let missingID = UUID()

        let context = resolveChatScreenContext(
            requestedProviderID: missingID,
            requestedModelID: "missing-model",
            providers: [fallbackProvider],
            activeModel: activeModel,
            primaryProvider: fallbackProvider,
            providersLoaded: true,
            requestedProviderKind: .openAI
        )

        #expect(context?.provider.id == missingID)
        #expect(context?.model == nil)
        #expect(context?.connectionState == .removed)
    }

    @Test("A conversation bound to a provider that is not loaded yet does not fall back and does not show the banner")
    func byokConversationWhileProvidersLoadingDoesNotFallBack() {
        let other = TestFactories.makeProvider(
            kind: .anthropic,
            models: [TestFactories.makeModel(id: "claude-haiku", name: "Claude Haiku", isDefault: true)]
        )
        let byokID = UUID()
        var lookedUp: [(String, ProviderKind)] = []

        let context = resolveChatScreenContext(
            requestedProviderID: byokID,
            requestedModelID: "gpt-5.5",
            providers: [other],
            activeModel: (provider: other, model: other.models[0]),
            primaryProvider: other,
            providersLoaded: false,
            requestedProviderKind: .openAI,
            modelDisplayName: { id, kind in
                lookedUp.append((id, kind))
                return id == "gpt-5.5" ? "GPT-5.5" : nil
            }
        )

        #expect(context?.provider.id == byokID)
        #expect(context?.model == nil)
        #expect(context?.connectionState == .pending)
        #expect(context?.pendingModelName == "GPT-5.5")
        #expect(lookedUp.count == 1 && lookedUp.first?.1 == .openAI)
        #expect(ChatModelRemovedBanner.resolve(context) == nil)
        #expect(ChatModelRemovedBanner.isSendEnabled(
            hasComposerContent: true,
            controlsDisabled: false,
            banner: ChatModelRemovedBanner.resolve(context)
        ))

        // Once the list has loaded, a connection that is still absent counts as removed: the banner shows and no model name is given.
        let removed = resolveChatScreenContext(
            requestedProviderID: byokID,
            requestedModelID: "gpt-5.5",
            providers: [other],
            activeModel: nil,
            primaryProvider: other,
            providersLoaded: true,
            requestedProviderKind: .openAI,
            modelDisplayName: { _, _ in "GPT-5.5" }
        )
        #expect(removed?.connectionState == .removed)
        #expect(removed?.pendingModelName == nil)
        #expect(ChatModelRemovedBanner.resolve(removed)?.connectionRemoved == true)
    }

    @Test("New Conversation Uses Active Model Not Primary Provider Default")
    func newConversationUsesActiveModelNotPrimaryProviderDefault() {
        let primaryProvider = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4o", name: "GPT-4o", isDefault: true)]
        )
        let clickedProvider = TestFactories.makeProvider(
            kind: .anthropic,
            models: [
                TestFactories.makeModel(id: "claude-haiku", name: "Claude Haiku", isDefault: true),
                TestFactories.makeModel(id: "claude-opus", name: "Claude Opus")
            ]
        )

        let context = resolveChatScreenContext(
            requestedProviderID: nil,
            requestedModelID: nil,
            providers: [primaryProvider, clickedProvider],
            activeModel: (provider: clickedProvider, model: clickedProvider.models[1]),
            primaryProvider: primaryProvider,
            providersLoaded: true
        )

        #expect(context?.provider.id == clickedProvider.id)
        #expect(context?.model?.id == "claude-opus")
    }

    private func makeSummary(
        id: UUID = UUID(),
        providerID: UUID = UUID(),
        modelID: String = "gpt-4o",
        messageCount: Int = 0,
        previewText: String = "preview",
        estimatedCost: Double = 0,
        draftText: String = "",
        useMemory: Bool = true,
        skillID: UUID? = nil,
        isDraft: Bool = false
    ) -> ConversationSummary {
        ConversationSummary(
            id: id,
            title: "Observed Title",
            hasCustomTitle: true,
            providerID: providerID,
            providerKind: .openAI,
            modelID: modelID,
            previewText: previewText,
            messageCount: messageCount,
            remoteMessageCount: 0,
            estimatedCost: estimatedCost,
            isDraft: isDraft,
            draftText: draftText,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            folderID: nil,
            useMemory: useMemory,
            skillId: skillID,
            messagesHydratedAt: nil,
            messagesStale: false
        )
    }
}

// MARK: - Realtime selection hides regenerate / retry / edit

extension ChatScreenProjectionTests {

    @Test("Realtime selected: render context has no retry / edit callbacks, recovery card shows no retry / edit; switching back to a text model restores them and callbacks fire as usual")
    @MainActor
    func realtimeSelectionHidesRetryAndEditUntilTextModelIsBack() throws {
        var retried: [UUID] = []
        var edited: [UUID] = []
        let retry: (ChatMessage) -> Void = { retried.append($0.id) }
        let edit: (ChatMessage) -> Void = { edited.append($0.id) }
        let model = Self.failedAssistantModel()

        // Realtime selected: no callbacks exist (not greyed out); no retry / edit on the recovery card.
        let realtimeRetry = ChatListDataSource.RenderContext.realtimeGated(retry, realtimeSelected: true)
        let realtimeEdit = ChatListDataSource.RenderContext.realtimeGated(edit, realtimeSelected: true)
        #expect(realtimeRetry == nil)
        #expect(realtimeEdit == nil)
        let realtimeConfig = try #require(Self.recoveryConfig(
            model,
            onRetry: realtimeRetry.map { action in { action(model.message) } },
            onEditMessage: realtimeEdit.map { action in { action(model.message) } }
        ))
        #expect(realtimeConfig.primaryTitle == localizedMessageRecoveryActionTitle(.switchModel))
        #expect(realtimeConfig.secondaryTitle == nil)
        #expect(realtimeConfig.tertiaryTitle == nil)
        realtimeConfig.primaryAction()
        realtimeConfig.secondaryAction?()
        realtimeConfig.tertiaryAction?()
        #expect(retried.isEmpty)
        #expect(edited.isEmpty)

        // Back to a text model: retry / edit return; taps re-answer through the current text model's callback.
        let textRetry = try #require(ChatListDataSource.RenderContext.realtimeGated(retry, realtimeSelected: false))
        let textEdit = try #require(ChatListDataSource.RenderContext.realtimeGated(edit, realtimeSelected: false))
        let textConfig = try #require(Self.recoveryConfig(
            model,
            onRetry: { textRetry(model.message) },
            onEditMessage: { textEdit(model.message) }
        ))
        #expect(textConfig.primaryTitle == localizedMessageRecoveryActionTitle(.retry))
        #expect(textConfig.secondaryTitle == localizedMessageRecoveryActionTitle(.editMessage))
        textConfig.primaryAction()
        textConfig.secondaryAction?()
        #expect(retried == [model.message.id])
        #expect(edited == [model.message.id])
    }

    @Test("Realtime selected: search error card shows no retry / re-answer with X; switching back to a text model restores it")
    @MainActor
    func realtimeSelectionHidesSearchErrorCardReanswer() throws {
        let retry: (ChatMessage) -> Void = { _ in }
        var message = TestFactories.makeMessage(role: .assistant, text: "Answer")
        message.capabilityExecution = CapabilityExecutionResult(
            states: [:], recoveryDescriptors: nil,
            externalSearch: ExternalSearchMessageRecord(
                facts: .init(state: "failed", searchCount: 1, sourceCount: 0),
                errorCard: ExternalSearchMessageRecord.ErrorCard(
                    errorClass: "service_error", headline: "service_error", primaryAction: "retry",
                    secondaryAction: "switch_to_other_service",
                    serviceId: "s-deepseek", serviceName: "DeepSeek",
                    switchTo: .init(id: "s-tavily", name: "Tavily")
                )
            )
        )

        // Realtime selected: onRetry is gated off; the error card keeps only the error text.
        let realtimeRetry = ChatListDataSource.RenderContext.realtimeGated(retry, realtimeSelected: true)
        let realtimeCard = try #require(ExternalSearchChatPresentation.errorCard(
            message, isLastAssistant: true, realtimeSelected: realtimeRetry == nil
        ))
        #expect(realtimeCard.titleKey == "chatError.serviceError")
        #expect(realtimeCard.primary == nil)
        #expect(realtimeCard.secondary == nil)

        // Back to a text model: retry and "re-answer with Tavily" return.
        let textRetry = ChatListDataSource.RenderContext.realtimeGated(retry, realtimeSelected: false)
        let textCard = try #require(ExternalSearchChatPresentation.errorCard(
            message, isLastAssistant: true, realtimeSelected: textRetry == nil
        ))
        #expect(textCard.primary?.action == .retry)
        #expect(textCard.secondary?.action == .answerWith(serviceID: "s-tavily", name: "Tavily"))
    }

    @Test("Retry-only recovery card switches to a change-model action when realtime is selected; no empty button")
    @MainActor
    func realtimeSelectionRetryOnlyCardOffersSwitchModel() {
        let layout = hidingUnavailableRecoveryActions(
            MessageRecoveryCardActionLayout(primary: .retry, secondary: nil, tertiary: nil),
            retryAvailable: false,
            editAvailable: false
        )
        #expect(layout == MessageRecoveryCardActionLayout(primary: .switchModel, secondary: nil, tertiary: nil))
        let untouched = MessageRecoveryCardActionLayout(primary: .retry, secondary: .editMessage, tertiary: .switchModel)
        #expect(hidingUnavailableRecoveryActions(untouched, retryAvailable: true, editAvailable: true) == untouched)
    }

    private static let liveAttribution = RealtimeVoiceAttribution(
        providerID: UUID(), providerKind: .gemini, providerName: "Gemini", model: "gemini-live"
    )

    private static func livePlan(
        _ messages: [ChatMessage],
        drafts: RealtimeDrafts,
        callMessageIDs: Set<UUID> = []
    ) -> ChatCollectionProjectionBuilder.SnapshotPlan {
        ChatCollectionProjectionBuilder.makeSnapshotPlan(
            from: ChatCollectionProjectionBuilder.makeRows(from: messages, metadata: .empty),
            providerMetadataVersion: 0,
            realtimeLive: .init(drafts: drafts, attribution: liveAttribution, callMessageIDs: callMessageIDs)
        )
    }

    @Test("Realtime session's two temporary bubbles sit at the end of the list; the AI row carries the same persisted byline and model name line; during interruption the reply comes first")
    func realtimeLiveBubblesAppendAtTail() throws {
        let history = TestFactories.makeMessage(role: .assistant, text: "earlier")
        let plan = Self.livePlan([history], drafts: RealtimeDrafts(user: "hello there", assistant: "hi"))
        #expect(plan.items.map(\.presentationKind) == [.assistant, .liveUser, .liveAssistant])
        #expect(plan.items.first?.id == history.id)
        let user = try #require(plan.renderModelsByID[ChatCollectionProjectionBuilder.realtimeLiveUserID])
        let assistant = try #require(plan.renderModelsByID[ChatCollectionProjectionBuilder.realtimeLiveAssistantID])
        #expect(user.message.role == .user && user.message.text == "hello there")
        #expect(assistant.message.role == .assistant && assistant.message.text == "hi")
        #expect(assistant.showMetadata)
        #expect(assistant.resolvedModelName == "gemini-live")
        #expect(assistant.message.providerID == Self.liveAttribution.providerID)
        #expect(!assistant.isLastInConversation && !assistant.isStreaming)
        #expect(plan.liveRows.map(\.id) == [user.messageID, assistant.messageID])

        let bargeIn = Self.livePlan(
            [history], drafts: RealtimeDrafts(user: "wait", assistant: "so", userAfterAssistant: true)
        )
        #expect(bargeIn.items.map(\.presentationKind) == [.assistant, .liveAssistant, .liveUser])
        // Unchanged draft: two projections give the same value; no reconfiguration triggered.
        #expect(plan == Self.livePlan([history], drafts: RealtimeDrafts(user: "hello there", assistant: "hi")))
    }

    @Test("A cleared side keeps its last text until the message persisted in this call enters the list, then the formal message takes over without duplication")
    func realtimeLiveBubbleHandsOverToPersistedMessage() throws {
        let history = TestFactories.makeMessage(role: .user, text: "hello there")
        let drafts = RealtimeDrafts(assistant: "hi", userPersisted: 1, userPersistedText: "hello there")
        // Persisted row not yet in the list: old history with the same text does not count; the user bubble still shows the last text.
        let waiting = Self.livePlan([history], drafts: drafts)
        #expect(waiting.items.map(\.presentationKind) == [.user, .liveUser, .liveAssistant])
        let held = try #require(waiting.renderModelsByID[ChatCollectionProjectionBuilder.realtimeLiveUserID])
        #expect(held.message.text == "hello there")

        // The row persisted in this call enters the list: the temporary user bubble disappears, leaving only the formal message + the temporary AI bubble.
        let stored = TestFactories.makeMessage(role: .user, text: "hello there")
        let handed = Self.livePlan([history, stored], drafts: drafts, callMessageIDs: [stored.id])
        #expect(handed.items.map(\.id) == [history.id, stored.id, ChatCollectionProjectionBuilder.realtimeLiveAssistantID])
        #expect(handed.renderModelsByID[ChatCollectionProjectionBuilder.realtimeLiveUserID] == nil)
    }

    @Test("No user-side text shows no temporary user bubble; when neither side has text the list shows only formal messages")
    func realtimeLiveUserBubbleHiddenWithoutText() {
        let history = TestFactories.makeMessage(role: .assistant, text: "earlier")
        let assistantOnly = Self.livePlan([history], drafts: RealtimeDrafts(user: "  ", assistant: "thinking aloud"))
        #expect(assistantOnly.items.map(\.presentationKind) == [.assistant, .liveAssistant])
        let none = Self.livePlan([history], drafts: RealtimeDrafts())
        #expect(none.items.map(\.id) == [history.id])
        #expect(none.liveRows.isEmpty)
    }

    @Test("Toggling the realtime selection state makes the list equality check differ (triggers redraw); equal when the selection state is unchanged")
    @MainActor
    func realtimeSelectionFlipBreaksListEquality() {
        let summary = makeSummary(messageCount: 1)
        let projection = ChatScreenProjection(
            requestedConversationID: summary.id,
            summary: summary,
            messages: [TestFactories.makeMessage(role: .assistant, text: "hi")],
            hasLoadedSummary: true,
            messageRevision: 3
        )
        let loader = MessageWindowLoader()
        let text = Self.messageList(projection: projection, loader: loader, realtimeSelected: false)
        let textAgain = Self.messageList(projection: projection, loader: loader, realtimeSelected: false)
        let realtime = Self.messageList(projection: projection, loader: loader, realtimeSelected: true)
        #expect(text == textAgain)
        #expect(text != realtime)
        #expect(realtime == Self.messageList(projection: projection, loader: loader, realtimeSelected: true))
    }

    @MainActor
    private static func messageList(
        projection: ChatScreenProjection,
        loader: MessageWindowLoader,
        realtimeSelected: Bool
    ) -> ChatMessageList {
        ChatMessageList(
            projection: projection,
            conversationID: projection.activeConversationID,
            isSendingMessage: false,
            capabilitySelection: ChatCapabilitySelection(reasoningMode: .automatic, webSearchEnabled: false),
            realtimeSelected: realtimeSelected,
            bottomOverlayInset: 0,
            scrollButtonBottomInset: 0,
            windowLoader: loader,
            isAtBottom: .constant(true),
            autoScrollEnabled: .constant(true),
            onRestoreComposerText: { _ in },
            pendingQuoteContext: .constant(nil),
            showModelSwitcher: .constant(false),
            composerFocused: .constant(false)
        )
    }

    private static func failedAssistantModel() -> ChatCollectionProjectionBuilder.MessageRenderModel {
        let message = ChatMessage(
            id: UUID(), role: .assistant, text: "partial reply",
            providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
            state: .failed,
            errorTitle: "Request failed"
        )
        return ChatCollectionProjectionBuilder.MessageRenderModel(
            messageID: message.id, message: message, presentationKind: .assistant,
            showMetadata: true, resolvedProviderName: "OpenAI", resolvedModelName: "GPT-4o",
            relayKind: nil, renderHint: nil, topPadding: 16,
            displayText: nil, textHash: message.text.hashValue, isStreaming: false,
            providerMetadataVersion: 0, isLastInConversation: true
        )
    }

    @MainActor
    private static func recoveryConfig(
        _ model: ChatCollectionProjectionBuilder.MessageRenderModel,
        onRetry: (() -> Void)?,
        onEditMessage: (() -> Void)?
    ) -> UIKitRecoveryCard.Config? {
        AssistantMessageRecoveryBuilder.makeConfig(
            for: model,
            isSendingMessage: false,
            isDismissed: false,
            isTechnicalDetailExpanded: false,
            onRetry: onRetry, onContinue: {}, onRegenerate: {},
            onEditMessage: onEditMessage,
            onSwitchModelRequested: {},
            onDismiss: {},
            onTechnicalDetailVisibilityChanged: { _ in }
        )
    }
}

// MARK: - Realtime model: sessions storing a model from the voice catalog realtime[] are not judged removed

extension ChatScreenProjectionTests {
    /// Voice catalog: openAI / relay realtime both list gpt-realtime (relay listing it does not make it realtime; the connection shape decides).
    private static func realtimeVoiceCatalog() -> VoiceCatalog {
        let entry = VoiceRealtimeEntry(
            model: "gpt-realtime",
            transport: .openaiRealtime,
            path: "/v1/realtime",
            contextWindow: 128_000,
            voices: [VoiceCatalogVoice(id: "marin", isDefault: true)],
            maxSessionSec: nil,
            inputTranscriptionModel: "gpt-4o-mini-transcribe",
            isDefault: true
        )
        return VoiceCatalog(schemaVersion: 2, revision: "e701", providers: [
            .openAI: VoiceProviderEntries(realtime: [entry]),
            .relay: VoiceProviderEntries(realtime: [entry]),
        ])
    }

    private static func officialOpenAIProvider() -> Provider {
        let enabled = TestFactories.makeModel(id: "gpt-5.4", name: "GPT-5.4", isDefault: true, canonicalModelId: "gpt-5.4")
        return TestFactories.makeProvider(kind: .openAI, models: [enabled], catalogModels: [enabled])
    }

    @Test("Official apiKey session stores a realtime model from the voice catalog: no removed banner and no send block even if the text catalog lacks it")
    func realtimeModelConversationShowsNoRetiredBanner() async throws {
        let provider = Self.officialOpenAIProvider()
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: Self.retiredMetadataJSON)

        let state = ProviderSelectionSnapshot.conversationModelState(
            storedModelID: "gpt-realtime", in: provider, voiceCatalog: Self.realtimeVoiceCatalog()
        )
        #expect(state == .resolved)
        #expect(state.blocksSend == false)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Voice catalog not ready yet: official apiKey session's missing is not judged removed")
    func realtimeModelBeforeVoiceCatalogShowsNoRetiredBanner() async throws {
        let provider = Self.officialOpenAIProvider()
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: Self.retiredMetadataJSON)

        let state = ProviderSelectionSnapshot.conversationModelState(
            storedModelID: "gpt-realtime", in: provider, voiceCatalog: nil
        )
        #expect(state == .resolved)
        #expect(state.blocksSend == false)
        // Tombstones are not exempt: with a nil catalog, removal still applies.
        #expect(ProviderSelectionSnapshot.conversationModelState(
            storedModelID: "gpt-4-legacy", in: provider, voiceCatalog: nil
        ) == .retired(displayName: "GPT-4 Legacy", successorId: "gpt-5.4"))
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Server has no voice catalog (404): the stored realtime model and the text catalog both miss it; show the removed banner instead of waiting on the catalog forever")
    @MainActor
    func unavailableVoiceCatalogShowsRetiredBannerForRealtimeModel() async throws {
        let provider = Self.officialOpenAIProvider()
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: Self.retiredMetadataJSON)

        // Uses production default parameters: catalog snapshot set to 404 (.unavailable), voiceCatalog not passed.
        let snapshot = ReadAloudCatalogSnapshot.shared
        let previous = snapshot.state
        snapshot.setStateForTesting(.unavailable)
        defer { snapshot.setStateForTesting(previous) }
        let state = ProviderSelectionSnapshot.conversationModelState(storedModelID: "gpt-realtime", in: provider)
        #expect(state == .missing(displayName: "gpt-realtime"))
        #expect(state.blocksSend)
        #expect(ChatModelRemovedBanner.awaitsVoiceCatalog(
            storedModelID: "gpt-realtime", provider: provider,
            voiceCatalog: AppState.realtimeVoiceCatalog(from: snapshot.state)
        ) == false)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("UI reads the voice catalog uniformly through the 404 mapping: apart from AppState and legacy key migration, state?.catalog is not read directly")
    func voiceCatalogReadsGoThroughUnavailableMapping() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Oriveo")
        let enumerator = try #require(FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" && url.lastPathComponent != "AppState.swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("ReadAloudCatalogSnapshot.shared.state?.catalog") {
                // Legacy key migration with an empty catalog would delete the old realtime selection (persisted write); keep the "no conclusion, no judgment" reading.
                let context = lines[max(0, index - 4)..<index].joined(separator: "\n")
                if context.contains("RealtimeMigration.evaluate(") { continue }
                offenders.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    @Test("Relay session's stored realtime id is not among enabled models: still removed")
    func relayConnectionStoredRealtimeIdStillRemoved() {
        let enabled = TestFactories.makeModel(id: "relay-chat", name: "Relay Chat", isDefault: true)
        let relay = TestFactories.makeProvider(kind: .relay, models: [enabled], catalogModels: [enabled], customName: "My Relay")
        let state = ProviderSelectionSnapshot.conversationModelState(
            storedModelID: "gpt-realtime", in: relay, voiceCatalog: Self.realtimeVoiceCatalog()
        )
        #expect(state == .removed(connectionName: relay.displayName))
        #expect(state.blocksSend)
    }

    @Test("Voice catalog ready but lacks this id: when the text catalog also lacks it, still judged missing and send is blocked")
    func missingTextModelStillRetiredWithVoiceCatalog() async throws {
        let provider = Self.officialOpenAIProvider()
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: Self.retiredMetadataJSON)

        let state = ProviderSelectionSnapshot.conversationModelState(
            storedModelID: "gpt-unknown-9", in: provider, voiceCatalog: Self.realtimeVoiceCatalog()
        )
        #expect(state == .missing(displayName: "gpt-unknown-9"))
        #expect(state.blocksSend)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("send_disabled_while_awaiting_voice_catalog: voice catalog not ready and stored value not in text table disables the send key and reads the loading-model label")
    func send_disabled_while_awaiting_voice_catalog() {
        let provider = Self.officialOpenAIProvider()
        // Catalog not arrived: stored gpt-realtime is not in the text table; wait for the catalog; send key disabled.
        let awaiting = ChatModelRemovedBanner.awaitsVoiceCatalog(storedModelID: "gpt-realtime", provider: provider, voiceCatalog: nil)
        #expect(awaiting)
        #expect(ChatModelRemovedBanner.isSendEnabled(
            hasComposerContent: true, controlsDisabled: false, banner: nil, awaitingVoiceCatalog: awaiting
        ) == false)
        #expect(ChatModelRemovedBanner.voiceCatalogLoadingLabel == L10n.tr("Loading model", table: .voice))
        #expect(!ChatModelRemovedBanner.voiceCatalogLoadingLabel.isEmpty)

        // Catalog arrived: sendable again (realtime judgment takes over, no longer waiting on the catalog).
        let arrived = ChatModelRemovedBanner.awaitsVoiceCatalog(
            storedModelID: "gpt-realtime", provider: provider, voiceCatalog: Self.realtimeVoiceCatalog()
        )
        #expect(arrived == false)
        #expect(ChatModelRemovedBanner.isSendEnabled(
            hasComposerContent: true, controlsDisabled: false, banner: nil, awaitingVoiceCatalog: arrived
        ))

        // Stored value is in the text table: do not wait even if the catalog has not arrived.
        #expect(ChatModelRemovedBanner.awaitsVoiceCatalog(storedModelID: "gpt-5.4", provider: provider, voiceCatalog: nil) == false)
        // Relay does not wait on the catalog.
        let enabled = TestFactories.makeModel(id: "relay-chat", name: "Relay Chat", isDefault: true)
        let relay = TestFactories.makeProvider(kind: .relay, models: [enabled], catalogModels: [enabled], customName: "My Relay")
        #expect(ChatModelRemovedBanner.awaitsVoiceCatalog(storedModelID: "gpt-realtime", provider: relay, voiceCatalog: nil) == false)
    }
}

// MARK: - Realtime model: voice catalog load failure shows a failure row above the input area + retry

extension ChatScreenProjectionTests {
    @Test("realtime_catalog_load_failed_shows_retry_row: waiting on catalog and catalog load failed -> failure row + retry; primary key disabled, no spinner")
    func realtime_catalog_load_failed_shows_retry_row() throws {
        let provider = Self.officialOpenAIProvider()
        let row = try #require(ChatRealtimeCatalogRetryRow.resolve(
            storedModelID: "gpt-realtime", provider: provider, catalogState: .loadFailed
        ))
        #expect(row.message == L10n.tr("Couldn't load realtime voice models", table: .voice))
        #expect(row.actionTitle == L10n.tr("Try Again", table: .voice))
        #expect(!row.message.isEmpty && !row.actionTitle.isEmpty)

        // Failed catalog folded to nil: still waiting on the catalog, primary key disabled; no spinner (spinner belongs only to loading).
        let awaiting = ChatModelRemovedBanner.awaitsVoiceCatalog(
            storedModelID: "gpt-realtime", provider: provider, voiceCatalog: VoiceCatalogState.loadFailed.catalog
        )
        #expect(awaiting)
        #expect(ChatModelRemovedBanner.isSendEnabled(
            hasComposerContent: true, controlsDisabled: false, banner: nil, awaitingVoiceCatalog: awaiting
        ) == false)
        #expect(ChatRealtimeCatalogRetryRow.showsLoadingIndicator(awaitingVoiceCatalog: awaiting, retryRow: row) == false)

        // Loading (no conclusion yet): no failure row; primary key shows spinner.
        let loading = ChatRealtimeCatalogRetryRow.resolve(storedModelID: "gpt-realtime", provider: provider, catalogState: nil)
        #expect(loading == nil)
        #expect(ChatRealtimeCatalogRetryRow.showsLoadingIndicator(awaitingVoiceCatalog: awaiting, retryRow: loading))

        // Stored value in text table / relay: do not wait on the catalog; no row even on failure.
        #expect(ChatRealtimeCatalogRetryRow.resolve(storedModelID: "gpt-5.4", provider: provider, catalogState: .loadFailed) == nil)
        let enabled = TestFactories.makeModel(id: "relay-chat", name: "Relay Chat", isDefault: true)
        let relay = TestFactories.makeProvider(kind: .relay, models: [enabled], catalogModels: [enabled], customName: "My Relay")
        #expect(ChatRealtimeCatalogRetryRow.resolve(storedModelID: "gpt-realtime", provider: relay, catalogState: .loadFailed) == nil)
    }

    @Test("realtime_catalog_arrived_hides_retry_row: catalog arrives after retry -> failure row disappears, primary key restored")
    func realtime_catalog_arrived_hides_retry_row() {
        let provider = Self.officialOpenAIProvider()
        let arrived = VoiceCatalogState.available(Self.realtimeVoiceCatalog())
        let row = ChatRealtimeCatalogRetryRow.resolve(storedModelID: "gpt-realtime", provider: provider, catalogState: arrived)
        #expect(row == nil)
        let awaiting = ChatModelRemovedBanner.awaitsVoiceCatalog(
            storedModelID: "gpt-realtime", provider: provider, voiceCatalog: arrived.catalog
        )
        #expect(awaiting == false)
        #expect(ChatModelRemovedBanner.isSendEnabled(
            hasComposerContent: true, controlsDisabled: false, banner: nil, awaitingVoiceCatalog: awaiting
        ))
        #expect(ChatRealtimeCatalogRetryRow.showsLoadingIndicator(awaitingVoiceCatalog: awaiting, retryRow: row) == false)
    }
}

// MARK: - retired: metadata payload with retired model tombstones

extension ChatScreenProjectionTests {
    static let retiredMetadataJSON = """
    {
      "version": 1,
      "updatedAt": "2026-10-01T00:00:00Z",
      "providers": {
        "openAI": {
          "displayName": "OpenAI",
          "defaultModelId": "gpt-5.4",
          "resolveMap": { "gpt-5.4": "gpt-5.4", "gpt-5.5": "gpt-5.5" },
          "models": {
            "gpt-5.4": { "canonicalModelId": "gpt-5.4", "displayName": "GPT-5.4", "capabilities": ["text"] },
            "gpt-5.5": { "canonicalModelId": "gpt-5.5", "displayName": "GPT-5.5", "capabilities": ["text"] }
          },
          "retiredModels": [
            { "id": "gpt-4-legacy", "displayName": "GPT-4 Legacy", "retiredAt": "2026-07-01T00:00:00Z", "routedTo": "gpt-5.4" },
            { "id": "gpt-4-orphan", "displayName": "GPT-4 Orphan", "retiredAt": "2026-07-01T00:00:00Z", "routedTo": "gpt-5.5" }
          ]
        }
      }
    }
    """
}
