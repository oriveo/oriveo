import Testing
import Foundation
@testable import Oriveo

@Suite("ConversationManager refreshConversationCost", .serialized)
struct ConversationManagerTests {
    @MainActor
    private static var retainedStates: [AppState] = []


    @MainActor
    private func makeAppStateWithConversations(_ conversations: [Conversation]) -> AppState {
        let state = AppState(seedDemoData: true)
        state.conversations = conversations
        Self.retainedStates.append(state)
        return state
    }

    @MainActor
    private func makeIsolatedAppState(
        prefix: String = "conversation-manager-"
    ) -> (state: AppState, uid: String) {
        let uid = "\(prefix)\(UUID().uuidString)"
        let state = AppState(seedDemoData: false, sessionUID: uid)
        Self.retainedStates.append(state)
        return (state, uid)
    }

    @MainActor
    private func cleanupIsolatedAppState(_ state: AppState, uid: String) {
        state.flushConversationPersistQueue()
        DatabaseManager.shared.close()
        try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
    }

    private func persistAuthoritativeConversations(
        _ conversations: [Conversation],
        uid: String
    ) throws {
        try ConversationRuntimeBridge().persistLegacyProjection(conversations, for: uid)
    }


    @Test("refreshConversationCost drops after deleting a high-cost message")
    @MainActor
    func refreshCostAfterDeletion() {
        let convID = UUID()
        let msg1 = TestFactories.makeMessage(
            role: .assistant,
            text: "response 1",
            estimatedCost: 0.05,
            state: .delivered
        )
        let msg2 = TestFactories.makeMessage(
            role: .assistant,
            text: "response 2",
            estimatedCost: 0.10,
            state: .delivered
        )
        let conv = TestFactories.makeConversation(
            id: convID,
            estimatedCost: 0.15,
            messages: [msg1, msg2]
        )

        let state = makeAppStateWithConversations([conv])

        #expect(state.conversations[0].estimatedCost == 0.15)

        state.conversations[0].messages.removeAll { $0.id == msg2.id }

        state.conversationManager.refreshConversationCost(for: convID)

        #expect(abs(state.conversations[0].estimatedCost - 0.05) < 0.0001)
    }


    @Test("refreshConversationCost recomputes after resending a message")
    @MainActor
    func refreshCostAfterResend() {
        let convID = UUID()
        let userMsg = TestFactories.makeMessage(
            role: .user,
            text: "question",
            estimatedCost: 0.01,
            state: .delivered
        )
        let oldReply = TestFactories.makeMessage(
            role: .assistant,
            text: "old reply",
            estimatedCost: 0.08,
            state: .delivered
        )
        let conv = TestFactories.makeConversation(
            id: convID,
            estimatedCost: 0.09,
            messages: [userMsg, oldReply]
        )

        let state = makeAppStateWithConversations([conv])

        state.conversations[0].messages.removeAll { $0.id == oldReply.id }
        let newReply = TestFactories.makeMessage(
            role: .assistant,
            text: "new reply",
            estimatedCost: 0.12,
            state: .delivered
        )
        state.conversations[0].messages.append(newReply)

        state.conversationManager.refreshConversationCost(for: convID)

        let expected = 0.01 + 0.12  // userMsg + newReply
        #expect(abs(state.conversations[0].estimatedCost - expected) < 0.0001)
    }


    @Test("refreshConversationCost only counts delivered messages above epsilon")
    @MainActor
    func refreshCostFiltersNonDeliveredAndEpsilon() {
        let convID = UUID()
        let delivered = TestFactories.makeMessage(
            role: .assistant,
            text: "delivered",
            estimatedCost: 0.05,
            state: .delivered
        )
        let generating = TestFactories.makeMessage(
            role: .assistant,
            text: "generating",
            estimatedCost: 0.03,
            state: .generating
        )
        let failed = TestFactories.makeMessage(
            role: .assistant,
            text: "failed",
            estimatedCost: 0.02,
            state: .failed
        )
        let tinyDelivered = TestFactories.makeMessage(
            role: .assistant,
            text: "tiny",
            estimatedCost: 0.000005,  // <= costEpsilon
            state: .delivered
        )
        let conv = TestFactories.makeConversation(
            id: convID,
            estimatedCost: 999.0,  // intentionally wrong
            messages: [delivered, generating, failed, tinyDelivered]
        )

        let state = makeAppStateWithConversations([conv])
        state.conversationManager.refreshConversationCost(for: convID)

        #expect(abs(state.conversations[0].estimatedCost - 0.05) < 0.0001)
    }


    @Test("refreshConversationCost zeros an empty conversation")
    @MainActor
    func refreshCostEmptyMessages() {
        let convID = UUID()
        let conv = TestFactories.makeConversation(
            id: convID,
            estimatedCost: 0.50,
            messages: []
        )

        let state = makeAppStateWithConversations([conv])
        state.conversationManager.refreshConversationCost(for: convID)

        #expect(state.conversations[0].estimatedCost == 0)
    }


    @Test("refreshConversationCost is a no-op for an unknown ID")
    @MainActor
    func refreshCostNonexistentConversation() {
        let convID = UUID()
        let conv = TestFactories.makeConversation(
            id: convID,
            estimatedCost: 0.50,
            messages: [TestFactories.makeMessage(estimatedCost: 0.50, state: .delivered)]
        )

        let state = makeAppStateWithConversations([conv])
        let unknownID = UUID()
        state.conversationManager.refreshConversationCost(for: unknownID)

        #expect(state.conversations[0].estimatedCost == 0.50)
    }

    @Test("filteredConversations searches the authoritative store, not the mirror cache")
    @MainActor
    func filteredConversationsReadsAuthoritativeStore() async throws {
        let (state, uid) = makeIsolatedAppState()

        defer { cleanupIsolatedAppState(state, uid: uid) }

        DatabaseManager.shared.close()

        let message = TestFactories.makeMessage(text: "authoritative store only search token")
        let conversation = TestFactories.makeConversation(
            title: "Store Authoritative Conversation",
            messages: [message]
        )

        try persistAuthoritativeConversations([conversation], uid: uid)

        #expect(state.conversations.isEmpty)

        let results = await state.conversationManager.searchConversations(matching: "search token")

        #expect(results.count == 1)
        #expect(results.first?.id == conversation.id)
        #expect(results.first?.messages.isEmpty == true)
        #expect(results.first?.displayMessageCount == 1)
    }

    @Test("filteredConversations keeps draft conversations that have messages from the authoritative store")
    @MainActor
    func filteredConversationsIncludesDraftsWithMessagesFromAuthoritativeStore() async throws {
        let (state, uid) = makeIsolatedAppState(prefix: "search-draft-visible-")

        defer { cleanupIsolatedAppState(state, uid: uid) }

        DatabaseManager.shared.close()

        let message = TestFactories.makeMessage(text: "authoritative visible draft token")
        let conversation = TestFactories.makeConversation(
            title: "Visible Draft Search",
            isDraft: true,
            messages: [message]
        )

        try persistAuthoritativeConversations([conversation], uid: uid)

        #expect(state.conversations.isEmpty)

        let results = await state.conversationManager.searchConversations(matching: "draft token")

        #expect(results.count == 1)
        #expect(results.first?.id == conversation.id)
        #expect(results.first?.displayMessageCount == 1)
    }

    @Test("recentConversations is built from the authoritative store, not the mirror cache")
    @MainActor
    func recentConversationsReadAuthoritativeStore() throws {
        let (state, uid) = makeIsolatedAppState()

        defer { cleanupIsolatedAppState(state, uid: uid) }

        DatabaseManager.shared.close()

        let conversation = TestFactories.makeConversation(
            title: "Authoritative Home Conversation",
            updatedAt: Date()
        )

        try persistAuthoritativeConversations([conversation], uid: uid)

        #expect(state.conversations.isEmpty)

        let recent = state.recentConversations

        #expect(recent.count == 1)
        #expect(recent.first?.id == conversation.id)
    }

    @Test("recentConversations keeps draft conversations that have messages from the authoritative store")
    @MainActor
    func recentConversationsIncludeDraftsWithMessagesFromAuthoritativeStore() throws {
        let (state, uid) = makeIsolatedAppState(prefix: "recent-draft-visible-")

        defer { cleanupIsolatedAppState(state, uid: uid) }

        DatabaseManager.shared.close()

        let message = TestFactories.makeMessage(text: "Visible draft message", state: .delivered)
        let conversation = TestFactories.makeConversation(
            title: "Visible Draft",
            isDraft: true,
            messages: [message],
            updatedAt: Date()
        )

        try persistAuthoritativeConversations([conversation], uid: uid)

        #expect(state.conversations.isEmpty)

        let recent = state.recentConversations

        #expect(recent.count == 1)
        #expect(recent.first?.id == conversation.id)
        #expect(recent.first?.displayMessageCount == 1)
    }

    @Test("homeConversationSections applies the Earlier limit and returns the remainder count")
    @MainActor
    func homeConversationSectionsLimitsEarlierRows() {
        let state = AppState(seedDemoData: true)
        let providerID = UUID()
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        state.conversationManager.nowProvider = { now }
        state.providers = [TestFactories.makeProvider(id: providerID)]

        let recent = TestFactories.makeConversation(
            title: "Recent",
            providerID: providerID,
            updatedAt: now.addingTimeInterval(-2 * 86_400)
        )
        let earlierConversations = (0..<12).map { index in
            TestFactories.makeConversation(
                title: "Earlier \(index + 1)",
                providerID: providerID,
                updatedAt: now.addingTimeInterval(-TimeInterval(index + 10) * 86_400)
            )
        }

        state.conversations = [recent] + earlierConversations

        let sections = state.homeConversationSections(earlierLimit: 10)

        #expect(sections.map(\.section) == [.past7Days, .earlier])

        let recentSection = try? #require(sections.first(where: { $0.section == .past7Days }))
        #expect(recentSection?.conversations.map(\.title) == ["Recent"])
        #expect(recentSection?.remainingCount == 0)

        let earlierSection = try? #require(sections.first(where: { $0.section == .earlier }))
        #expect(earlierSection?.conversations.map(\.title) == [
            "Earlier 1",
            "Earlier 2",
            "Earlier 3",
            "Earlier 4",
            "Earlier 5",
            "Earlier 6",
            "Earlier 7",
            "Earlier 8",
            "Earlier 9",
            "Earlier 10",
        ])
        #expect(earlierSection?.remainingCount == 2)
    }

    @Test("homeConversationSections keeps draft conversations that have messages and puts them in today")
    @MainActor
    func homeConversationSectionsIncludeDraftsWithMessages() {
        let state = AppState(seedDemoData: true)
        let providerID = UUID()
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        state.conversationManager.nowProvider = { now }
        state.providers = [TestFactories.makeProvider(id: providerID)]

        let draftMessage = TestFactories.makeMessage(text: "draft but visible", state: .delivered)
        let visibleDraft = TestFactories.makeConversation(
            title: "Visible Draft Today",
            providerID: providerID,
            isDraft: true,
            messages: [draftMessage],
            updatedAt: now
        )

        state.conversations = [visibleDraft]

        let sections = state.homeConversationSections(earlierLimit: 10)

        #expect(sections.map(\.section) == [.today])
        #expect(sections.first?.conversations.map(\.title) == ["Visible Draft Today"])
    }

    @Test("homeConversationSections keeps draft conversations that have messages on the authoritative snapshot path")
    @MainActor
    func homeConversationSectionsIncludeDraftsWithMessagesFromAuthoritativeSnapshot() throws {
        let (state, uid) = makeIsolatedAppState(prefix: "home-snapshot-draft-visible-")

        defer { cleanupIsolatedAppState(state, uid: uid) }

        DatabaseManager.shared.close()

        let providerID = UUID()
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        state.conversationManager.nowProvider = { now }
        state.providers = [TestFactories.makeProvider(id: providerID)]

        let draftMessage = TestFactories.makeMessage(text: "authoritative draft", state: .delivered)
        let visibleDraft = TestFactories.makeConversation(
            title: "Authoritative Visible Draft Today",
            providerID: providerID,
            isDraft: true,
            messages: [draftMessage],
            updatedAt: now
        )

        try persistAuthoritativeConversations([visibleDraft], uid: uid)

        #expect(state.conversations.isEmpty)

        let sections = state.homeConversationSections(earlierLimit: 10)

        #expect(sections.map(\.section) == [.today])
        #expect(sections.first?.conversations.map(\.title) == ["Authoritative Visible Draft Today"])
        #expect(sections.first?.conversations.first?.messages.isEmpty == true)
        #expect(sections.first?.conversations.first?.displayMessageCount == 1)
    }

    @Test("home sections are cached by conversations version and day: the same inputs do not recompute, a conversation change or a new day recomputes")
    @MainActor
    func homeConversationSectionsAreCachedUntilInputsChange() {
        let state = AppState(seedDemoData: true)
        let providerID = UUID()
        var now = Date(timeIntervalSince1970: 1_760_000_000)
        state.conversationManager.nowProvider = { now }
        state.providers = [TestFactories.makeProvider(id: providerID)]
        let message = TestFactories.makeMessage(text: "hello", state: .delivered)
        state.conversations = [
            TestFactories.makeConversation(title: "Today", providerID: providerID, messages: [message], updatedAt: now),
            TestFactories.makeConversation(
                title: "Old", providerID: providerID, messages: [message], updatedAt: now.addingTimeInterval(-20 * 86_400)
            ),
        ]

        let first = state.homeConversationSections(earlierLimit: 10)
        let computed = state.conversationManager.debugHomeSectionsComputationCount
        for _ in 0..<20 {
            #expect(state.homeConversationSections(earlierLimit: 10).map(\.section) == first.map(\.section))
        }
        #expect(state.conversationManager.debugHomeSectionsComputationCount == computed)

        // A different earlier limit recomputes.
        _ = state.homeConversationSections(earlierLimit: 20)
        #expect(state.conversationManager.debugHomeSectionsComputationCount == computed + 1)

        // A conversation change: the new title is visible immediately.
        state.conversations[0].title = "Renamed"
        let renamed = state.homeConversationSections(earlierLimit: 20)
        #expect(renamed.first?.conversations.first?.title == "Renamed")

        // A new day: what was today moves to yesterday.
        now = now.addingTimeInterval(86_400)
        let nextDay = state.homeConversationSections(earlierLimit: 20)
        #expect(nextDay.first?.section == .yesterday)
    }

    @Test("updateDraftText does not refresh updatedAt, so an old conversation stays out of today")
    @MainActor
    func updateDraftTextDoesNotBumpUpdatedAt() {
        let state = AppState(seedDemoData: true)
        let providerID = UUID()
        let convID = UUID()
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        state.conversationManager.nowProvider = { now }
        state.providers = [TestFactories.makeProvider(id: providerID)]

        let threeDaysAgo = now.addingTimeInterval(-3 * 86_400)
        let msg = TestFactories.makeMessage(text: "old message", state: .delivered)
        let oldConversation = TestFactories.makeConversation(
            id: convID,
            title: "Old Chat",
            providerID: providerID,
            messages: [msg],
            updatedAt: threeDaysAgo
        )
        state.conversations = [oldConversation]

        let beforeSections = state.homeConversationSections(earlierLimit: 10)
        #expect(beforeSections.map(\.section) == [.past7Days])

        state.conversationManager.updateDraftText("typing something", in: convID)

        #expect(state.conversations[0].updatedAt == threeDaysAgo)

        let afterSections = state.homeConversationSections(earlierLimit: 10)
        #expect(afterSections.map(\.section) == [.past7Days])
    }

    @Test("Typing and clearing a draft after a summary load does not mark an existing chat as a draft or wipe the preview")
    @MainActor
    func updateDraftTextAfterSummaryLoadKeepsPreviewAndIsDraft() throws {
        let (state, uid) = makeIsolatedAppState(prefix: "draft-summary-")
        defer { cleanupIsolatedAppState(state, uid: uid) }
        DatabaseManager.shared.close()

        let delivered = TestFactories.makeMessage(
            role: .user,
            text: "hello from thread",
            state: .delivered
        )
        var conversation = TestFactories.makeConversation(
            title: "Existing Chat",
            messages: [delivered]
        )
        conversation.isDraft = false
        conversation.previewText = ConversationListMetadata.makePreviewText(for: delivered)
        try persistAuthoritativeConversations([conversation], uid: uid)

        DatabaseManager.shared.close()
        let reloaded = AppState(sessionUID: uid)
        Self.retainedStates.append(reloaded)
        defer { cleanupIsolatedAppState(reloaded, uid: uid) }

        let listed = try #require(reloaded.conversations.first { $0.id == conversation.id })
        #expect(listed.messages.isEmpty)
        #expect(listed.displayMessageCount == 1)
        #expect(listed.isDraft == false)
        let expectedPreview = ConversationListMetadata.makePreviewText(for: delivered)

        reloaded.conversationManager.updateDraftText("typing a draft", in: listed.id)
        #expect(reloaded.conversations.first { $0.id == listed.id }?.isDraft == false)

        reloaded.conversationManager.updateDraftText("", in: listed.id)
        let afterClear = try #require(reloaded.conversations.first { $0.id == listed.id })
        #expect(afterClear.isDraft == false)
        #expect(afterClear.previewText == expectedPreview)
        #expect(afterClear.messages.isEmpty, "The draft path must not refill the summary mirror with full bodies")
    }

    @Test("homeConversationSections prefers a newer authoritative recent snapshot when the mirror is stale")
    @MainActor
    func homeConversationSectionsPreferNewerAuthoritativeSnapshotWhenMirrorIsStale() throws {
        let (state, uid) = makeIsolatedAppState(prefix: "home-recent-mirror-")

        defer { cleanupIsolatedAppState(state, uid: uid) }

        DatabaseManager.shared.close()

        let providerID = UUID()
        let conversationID = UUID()
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        state.conversationManager.nowProvider = { now }
        state.providers = [TestFactories.makeProvider(id: providerID)]

        let mirrorConversation = TestFactories.makeConversation(
            id: conversationID,
            title: "Mirror Yesterday",
            providerID: providerID,
            updatedAt: now.addingTimeInterval(-86_400)
        )
        let authoritativeConversation = TestFactories.makeConversation(
            id: conversationID,
            title: "Authoritative Today",
            providerID: providerID,
            updatedAt: now
        )

        try persistAuthoritativeConversations([authoritativeConversation], uid: uid)
        state.conversations = [mirrorConversation]

        let homeSections = state.homeConversationSections(earlierLimit: 10)

        #expect(homeSections.map(\.section) == [.today])
        #expect(homeSections.first?.conversations.map(\.title) == ["Authoritative Today"])
    }
}
