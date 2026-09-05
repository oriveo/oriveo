import Foundation
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

    @Test("Empty Persisted Conversation Shows Empty State Not Bootstrap")
    func emptyPersistedConversationShowsEmptyStateNotBootstrap() {
        // messageCount == 0 with an empty previewText means there is no history to hydrate at all
        // (a brand new or emptied conversation), so the screen must not stay on the skeleton.
        // Starting a conversation from a skill pre-creates an empty draft carrying the skill id
        // (messageCount == 0 with a requested conversation id), and the empty-state gate reads
        // `isDraft`/`draftText`, so the fixture has to model `isDraft` faithfully. An earlier
        // version omitted it and only passed because the old rule fell back to
        // "messageCount == 0 && empty previewText" and never read `isDraft` at all.
        // The fixture also sets `.skipped` because production always carries it on this path:
        // `ChatView.startMessageBackfillIfNeeded` marks the backfill skipped when it does not run.
        // `.idle` means "the backfill has not started yet", and a skeleton is still correct there;
        // what was wrong was staying on the skeleton for twelve seconds with no result, which the
        // `.skipped` branch now ends.
        let summary = makeSummary(messageCount: 0, previewText: "")

        let loadedEmpty = ChatScreenProjection(
            requestedConversationID: summary.id,
            summary: summary,
            messages: [],
            hasLoadedSummary: true,
            messageRevision: 1,
            backfillPhase: .skipped
        )
        #expect(loadedEmpty.isBootstrappingPersistedConversation == false)
        #expect(loadedEmpty.loadState == .empty)
        let stillIdle = ChatScreenProjection(
            requestedConversationID: summary.id,
            summary: summary,
            messages: [],
            hasLoadedSummary: true,
            messageRevision: 1
        )
        #expect(stillIdle.loadState == .bootstrapping)

        let hasHistory = makeSummary(messageCount: 0, previewText: "we were halfway through last time")
        let skippedWithEvidence = ChatScreenProjection(
            requestedConversationID: hasHistory.id,
            summary: hasHistory,
            messages: [],
            hasLoadedSummary: true,
            messageRevision: 1,
            backfillPhase: .skipped
        )
        #expect(skippedWithEvidence.loadState == .bootstrapping)
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

    @Test("Remote Message Count Keeps Bootstrap Even Without Preview")
    func remoteMessageCountKeepsBootstrapEvenWithoutPreview() {
        let summary = makeSummary(messageCount: 0, previewText: "", remoteMessageCount: 8)

        let projection = ChatScreenProjection(
            requestedConversationID: summary.id,
            summary: summary,
            messages: [],
            hasLoadedSummary: true,
            messageRevision: 1
        )
        #expect(projection.isBootstrappingPersistedConversation == true)
    }

    @Test("Measured Empty Does Not Win Over Metadata History Evidence")
    func measuredEmptyDoesNotWinOverMetadataHistoryEvidence() {
        let byCount = makeSummary(messageCount: 0, previewText: "", remoteMessageCount: 8)
        #expect(
            ChatScreenProjection(
                requestedConversationID: byCount.id,
                summary: byCount,
                messages: [],
                hasLoadedSummary: true,
                messageRevision: 1,
                backfillPhase: .succeededEmpty
            ).loadState == .stalled
        )

        let byPreview = makeSummary(messageCount: 0, previewText: "we were halfway through last time")
        #expect(
            ChatScreenProjection(
                requestedConversationID: byPreview.id,
                summary: byPreview,
                messages: [],
                hasLoadedSummary: true,
                messageRevision: 1,
                backfillPhase: .succeededEmpty
            ).loadState == .stalled
        )

        let genuinelyEmpty = makeSummary(messageCount: 0, previewText: "")
        #expect(
            ChatScreenProjection(
                requestedConversationID: genuinelyEmpty.id,
                summary: genuinelyEmpty,
                messages: [],
                hasLoadedSummary: true,
                messageRevision: 1,
                backfillPhase: .succeededEmpty
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

        let context = resolveChatScreenContext(
            requestedProviderID: UUID(),
            requestedModelID: "missing-model",
            providers: [fallbackProvider],
            activeModel: activeModel,
            primaryProvider: fallbackProvider
        )

        #expect(context?.provider.id == fallbackProvider.id)
        #expect(context?.model?.id == "gpt-4o")
        #expect(context?.needsConversationRepair == true)
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
            primaryProvider: primaryProvider
        )

        #expect(context?.provider.id == clickedProvider.id)
        #expect(context?.model?.id == "claude-opus")
        #expect(context?.needsConversationRepair == false)
    }

    private func makeSummary(
        id: UUID = UUID(),
        providerID: UUID = UUID(),
        modelID: String = "gpt-4o",
        messageCount: Int = 0,
        previewText: String = "preview",
        remoteMessageCount: Int = 0,
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
            remoteMessageCount: remoteMessageCount,
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
