import Foundation
import GRDB
import Testing
@testable import Oriveo

@Suite("MessageWindowLoader + Keyset Pagination", .serialized)
struct MessageWindowLoaderTests {


    @Test("Latest Window Returns Tail And More")
    func latestWindowReturnsTailAndMore() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let conv = makeConversationWithMessages(count: 150, prefix: "msg-")
        try harness.store.replaceAllConversations([conv])

        let window = try harness.dbPool.read { db in
            try ConversationStore.fetchLatestMessageWindow(
                db: db,
                conversationID: conv.id,
                limit: 60,
                attachmentFileStore: harness.fileStore
            )
        }

        #expect(window.messages.count == 60)
        #expect(window.messages.first?.text == "msg-90")
        #expect(window.messages.last?.text == "msg-149")
        #expect(window.hasMoreAbove == true)
        #expect(window.hasMoreBelow == false)
        #expect(window.earliestBoundary != nil)
        #expect(window.latestBoundary != nil)
    }

    @Test("Latest Window Small Conversation")
    func latestWindowSmallConversation() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let conv = makeConversationWithMessages(count: 5, prefix: "small-")
        try harness.store.replaceAllConversations([conv])

        let window = try harness.dbPool.read { db in
            try ConversationStore.fetchLatestMessageWindow(
                db: db,
                conversationID: conv.id,
                limit: 60,
                attachmentFileStore: harness.fileStore
            )
        }

        #expect(window.messages.count == 5)
        #expect(window.hasMoreAbove == false)
        #expect(window.messages.first?.text == "small-0")
        #expect(window.messages.last?.text == "small-4")
    }

    @Test("Window Around Returns Centered Window")
    func windowAroundReturnsCenteredWindow() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let conv = makeConversationWithMessages(count: 200, prefix: "m-")
        try harness.store.replaceAllConversations([conv])

        let anchorMessageID = conv.messages[100].id
        let anchor = try harness.dbPool.read { db -> ConversationStore.MessageBoundary in
            let boundary = try ConversationStore.fetchMessageBoundary(
                db: db,
                conversationID: conv.id,
                messageID: anchorMessageID
            )
            return try #require(boundary)
        }

        let window = try harness.dbPool.read { db in
            try ConversationStore.fetchMessageWindowAround(
                db: db,
                conversationID: conv.id,
                anchor: anchor,
                before: 30,
                after: 30,
                attachmentFileStore: harness.fileStore
            )
        }

        #expect(window.messages.count == 61)
        #expect(window.messages.first?.text == "m-70")
        #expect(window.messages.contains(where: { $0.id == anchorMessageID }))
        #expect(window.messages.last?.text == "m-130")
        #expect(window.hasMoreAbove == true)
        #expect(window.hasMoreBelow == true)
    }

    @Test("Fetch Before Keyset Pagination")
    func fetchBeforeKeysetPagination() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let conv = makeConversationWithMessages(count: 100, prefix: "k-")
        try harness.store.replaceAllConversations([conv])

        let initial = try harness.dbPool.read { db in
            try ConversationStore.fetchLatestMessageWindow(
                db: db,
                conversationID: conv.id,
                limit: 30,
                attachmentFileStore: harness.fileStore
            )
        }
        #expect(initial.messages.count == 30)
        #expect(initial.messages.first?.text == "k-70")

        let boundary = try #require(initial.earliestBoundary)
        let extended = try harness.dbPool.read { db in
            try ConversationStore.fetchMessagesBefore(
                db: db,
                conversationID: conv.id,
                boundary: boundary,
                limit: 30,
                attachmentFileStore: harness.fileStore
            )
        }

        #expect(extended.messages.count == 30)
        #expect(extended.messages.first?.text == "k-40")
        #expect(extended.messages.last?.text == "k-69")
        #expect(extended.messages.contains(where: { $0.text == "k-70" }) == false)
        #expect(extended.hasMoreAbove == true)
    }

    @Test("Fetch Before At Beginning")
    func fetchBeforeAtBeginning() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let conv = makeConversationWithMessages(count: 20, prefix: "edge-")
        try harness.store.replaceAllConversations([conv])

        let initial = try harness.dbPool.read { db in
            try ConversationStore.fetchLatestMessageWindow(
                db: db,
                conversationID: conv.id,
                limit: 10,
                attachmentFileStore: harness.fileStore
            )
        }
        let boundary = try #require(initial.earliestBoundary)
        let extended = try harness.dbPool.read { db in
            try ConversationStore.fetchMessagesBefore(
                db: db,
                conversationID: conv.id,
                boundary: boundary,
                limit: 100,
                attachmentFileStore: harness.fileStore
            )
        }

        #expect(extended.messages.count == 10)
        #expect(extended.hasMoreAbove == false)
    }

    @Test("Fetch After Keyset Pagination")
    func fetchAfterKeysetPagination() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let conv = makeConversationWithMessages(count: 100, prefix: "after-")
        try harness.store.replaceAllConversations([conv])

        let anchorMessage = conv.messages[30]
        let anchor = try harness.dbPool.read { db -> ConversationStore.MessageBoundary in
            let b = try ConversationStore.fetchMessageBoundary(
                db: db,
                conversationID: conv.id,
                messageID: anchorMessage.id
            )
            return try #require(b)
        }
        let around = try harness.dbPool.read { db in
            try ConversationStore.fetchMessageWindowAround(
                db: db,
                conversationID: conv.id,
                anchor: anchor,
                before: 5,
                after: 5,
                attachmentFileStore: harness.fileStore
            )
        }
        let latestBoundary = try #require(around.latestBoundary)

        let extended = try harness.dbPool.read { db in
            try ConversationStore.fetchMessagesAfter(
                db: db,
                conversationID: conv.id,
                boundary: latestBoundary,
                limit: 30,
                attachmentFileStore: harness.fileStore
            )
        }
        #expect(extended.messages.count == 30)
        #expect(extended.messages.first?.text == "after-36")
        #expect(extended.messages.last?.text == "after-65")
        #expect(extended.hasMoreBelow == true)
    }

    @Test("Search Match Returns Earliest")
    func searchMatchReturnsEarliest() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let conv = TestFactories.makeConversation(
            messages: [
                TestFactories.makeMessage(text: "alpha intro"),
                TestFactories.makeMessage(text: "middle text"),
                TestFactories.makeMessage(text: "another alpha keyword"),
                TestFactories.makeMessage(text: "trailing")
            ]
        )
        try harness.store.replaceAllConversations([conv])

        let matchID = try harness.dbPool.read { db in
            try ConversationStore.fetchSearchMatchMessageID(
                db: db,
                conversationID: conv.id,
                query: "alpha"
            )
        }
        #expect(matchID == conv.messages[0].id)
    }

    @Test("Search Match Returns Nil When Absent")
    func searchMatchReturnsNilWhenAbsent() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let conv = TestFactories.makeConversation(
            messages: [TestFactories.makeMessage(text: "nothing here")]
        )
        try harness.store.replaceAllConversations([conv])

        let matchID = try harness.dbPool.read { db in
            try ConversationStore.fetchSearchMatchMessageID(
                db: db,
                conversationID: conv.id,
                query: "zzz"
            )
        }
        #expect(matchID == nil)
    }

    @Test("Search Match Case Insensitive")
    func searchMatchCaseInsensitive() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let conv = TestFactories.makeConversation(
            messages: [TestFactories.makeMessage(text: "Mixed CASE Text")]
        )
        try harness.store.replaceAllConversations([conv])

        let matchID = try harness.dbPool.read { db in
            try ConversationStore.fetchSearchMatchMessageID(
                db: db,
                conversationID: conv.id,
                query: "case"
            )
        }
        #expect(matchID == conv.messages[0].id)
    }


    @Test("MessageWindowLoader: .latest anchor initially loads the tail window")
    @MainActor
    func windowLoaderLatestInitialLoad() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let conv = makeConversationWithMessages(count: 100, prefix: "L-")
        try harness.store.replaceAllConversations([conv])

        let loader = MessageWindowLoader(attachmentFileStore: harness.fileStore)
        loader.observe(conversationID: conv.id, anchor: .latest, in: harness.dbPool)

        await waitUntil { loader.messages.count == MessageWindowLoader.windowSize }

        #expect(loader.messages.count == MessageWindowLoader.windowSize)
        #expect(loader.messages.first?.text == "L-40")
        #expect(loader.messages.last?.text == "L-99")
        #expect(loader.hasMoreAbove == true)
        #expect(loader.hasMoreBelow == false)
        #expect(loader.revision >= 1)
    }

    @Test("MessageWindowLoader: extendUpward prepends an earlier prefix into messages")
    @MainActor
    func windowLoaderExtendUpwardPrepends() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let conv = makeConversationWithMessages(count: 200, prefix: "E-")
        try harness.store.replaceAllConversations([conv])

        let loader = MessageWindowLoader(attachmentFileStore: harness.fileStore)
        loader.observe(conversationID: conv.id, anchor: .latest, in: harness.dbPool)

        await waitUntil { loader.messages.count == MessageWindowLoader.windowSize }
        let initialFirstText = loader.messages.first?.text
        #expect(initialFirstText == "E-140")

        loader.extendUpward()
        await waitUntil { (loader.messages.first?.text ?? "") != initialFirstText }

        #expect(loader.messages.count == MessageWindowLoader.windowSize * 2)
        #expect(loader.messages.first?.text == "E-80")
        #expect(loader.messages.last?.text == "E-199")
        #expect(loader.hasMoreAbove == true)
    }

    @Test("MessageWindowLoader: hasMoreAbove is false after consecutive extendUpward reaches the top")
    @MainActor
    func windowLoaderExtendUpwardUntilEnd() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let conv = makeConversationWithMessages(count: 100, prefix: "U-")
        try harness.store.replaceAllConversations([conv])

        let loader = MessageWindowLoader(attachmentFileStore: harness.fileStore)
        loader.observe(conversationID: conv.id, anchor: .latest, in: harness.dbPool)

        await waitUntil { loader.messages.count == MessageWindowLoader.windowSize }

        loader.extendUpward()
        await waitUntil { loader.messages.count > MessageWindowLoader.windowSize }
        #expect(loader.hasMoreAbove == false)
        #expect(loader.messages.count == 100)
        #expect(loader.messages.first?.text == "U-0")
    }

    @Test("MessageWindowLoader: .messageID anchor loads a window around the specified message")
    @MainActor
    func windowLoaderMessageIDAnchor() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let conv = makeConversationWithMessages(count: 200, prefix: "J-")
        try harness.store.replaceAllConversations([conv])
        let targetMessage = conv.messages[100]

        let loader = MessageWindowLoader(attachmentFileStore: harness.fileStore)
        loader.observe(conversationID: conv.id, anchor: .messageID(targetMessage.id), in: harness.dbPool)

        await waitUntil { !loader.messages.isEmpty }

        #expect(loader.messages.contains(where: { $0.id == targetMessage.id }))
        #expect(loader.hasMoreAbove == true)
        #expect(loader.hasMoreBelow == true)
    }

    @Test("MessageWindowLoader: missing local source anchor triggers remote-anchor hydrate and retries lookup")
    @MainActor
    func windowLoaderHydratesMissingMessageAnchor() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let local = makeConversationWithMessages(count: 3, prefix: "local-")
        let target = TestFactories.makeMessage(
            role: .assistant,
            text: "remote-anchor",
            createdAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let around = [
            TestFactories.makeMessage(
                role: .user,
                text: "remote-before",
                createdAt: Date(timeIntervalSince1970: 1_700_000_100)
            ),
            target,
            TestFactories.makeMessage(
                role: .user,
                text: "remote-after",
                createdAt: Date(timeIntervalSince1970: 1_700_000_300)
            )
        ]
        try harness.store.replaceAllConversations([local])

        var hydrateCalls: [(UUID, UUID)] = []
        let loader = MessageWindowLoader(
            attachmentFileStore: harness.fileStore,
            remoteAnchorHydrator: { conversationID, messageID in
                hydrateCalls.append((conversationID, messageID))
                return around
            }
        )

        loader.observe(conversationID: local.id, anchor: .messageID(target.id), in: harness.dbPool)

        await waitUntil { loader.messages.contains(where: { $0.id == target.id }) }

        #expect(hydrateCalls.count == 1)
        #expect(hydrateCalls.first?.0 == local.id)
        #expect(hydrateCalls.first?.1 == target.id)
        #expect(loader.messages.map(\.text).contains("remote-before"))
        #expect(loader.messages.map(\.text).contains("remote-anchor"))
        #expect(loader.messages.map(\.text).contains("remote-after"))
        #expect(loader.initialLoadFailed == false)
    }

    @Test("MessageWindowLoader: jumpToLatest rebuilds the window at the tail")
    @MainActor
    func windowLoaderJumpToLatestResetsAnchor() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let conv = makeConversationWithMessages(count: 200, prefix: "T-")
        try harness.store.replaceAllConversations([conv])
        let target = conv.messages[50]

        let loader = MessageWindowLoader(attachmentFileStore: harness.fileStore)
        loader.observe(conversationID: conv.id, anchor: .messageID(target.id), in: harness.dbPool)
        await waitUntil { !loader.messages.isEmpty }
        #expect(loader.hasMoreBelow == true)

        loader.jumpToLatest()
        await waitUntil { loader.hasMoreBelow == false && !loader.messages.isEmpty }

        #expect(loader.messages.last?.text == "T-199")
        #expect(loader.hasMoreBelow == false)
    }

    @Test("MessageWindowLoader: switching conversations stop then observe does not mix state")
    @MainActor
    func windowLoaderRebindToOtherConversation() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let convA = makeConversationWithMessages(count: 30, prefix: "A-")
        let convB = makeConversationWithMessages(count: 50, prefix: "B-")
        try harness.store.replaceAllConversations([convA, convB])

        let loader = MessageWindowLoader(attachmentFileStore: harness.fileStore)
        loader.observe(conversationID: convA.id, in: harness.dbPool)
        await waitUntil { loader.messages.first?.text == "A-0" }

        loader.observe(conversationID: convB.id, in: harness.dbPool)
        await waitUntil { loader.messages.first?.text == "B-0" }

        #expect(loader.messages.allSatisfy { $0.text.hasPrefix("B-") })
        #expect(loader.messages.count == 50)
    }

    @Test("MessageWindowLoader: snapshot head id change after extendUpward (remote LWW replacing the window start) does not wipe the extended segment")
    @MainActor
    func windowLoaderPreservesExtensionWhenSnapshotHeadIDChanges() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let conv = makeConversationWithMessages(count: 200, prefix: "P-")
        try harness.store.replaceAllConversations([conv])

        let loader = MessageWindowLoader(attachmentFileStore: harness.fileStore)
        loader.observe(conversationID: conv.id, anchor: .latest, in: harness.dbPool)

        await waitUntil { loader.messages.count == MessageWindowLoader.windowSize }
        #expect(loader.messages.first?.text == "P-140")

        loader.extendUpward()
        await waitUntil { loader.messages.count == MessageWindowLoader.windowSize * 2 }
        #expect(loader.messages.first?.text == "P-80")
        let extensionHeadID = loader.messages.first?.id
        #expect(extensionHeadID != nil)

        var updated = conv
        let original140 = conv.messages[140]
        updated.messages[140] = TestFactories.makeMessage(
            id: UUID(),
            role: original140.role,
            text: "P-140-replaced",
            providerKind: original140.providerKind,
            modelName: original140.modelName,
            createdAt: original140.createdAt
        )
        try harness.store.replaceAllConversations([updated])

        await waitUntil { loader.messages.contains(where: { $0.text == "P-140-replaced" }) }

        #expect(loader.messages.first?.id == extensionHeadID)
        #expect(loader.messages.contains(where: { $0.text == "P-80" }))
        #expect(loader.messages.contains(where: { $0.text == "P-100" }))
        #expect(loader.messages.contains(where: { $0.text == "P-139" }))
        #expect(loader.messages.contains(where: { $0.text == "P-140-replaced" }))
        #expect(loader.messages.last?.text == "P-199")
    }

    @Test("MessageWindowLoader: reordering that moves an extended-segment message into the tail window must not duplicate IDs")
    @MainActor
    func windowLoaderDropsExtensionDuplicatesWhenMessageReordersIntoTail() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let conv = makeConversationWithMessages(count: 200, prefix: "P-")
        try harness.store.replaceAllConversations([conv])

        let loader = MessageWindowLoader(attachmentFileStore: harness.fileStore)
        loader.observe(conversationID: conv.id, anchor: .latest, in: harness.dbPool)
        await waitUntil { loader.messages.count == MessageWindowLoader.windowSize }

        loader.extendUpward()
        await waitUntil { loader.messages.count == MessageWindowLoader.windowSize * 2 }
        #expect(loader.messages.first?.text == "P-80")
        #expect(loader.messages.contains(where: { $0.text == "P-100" }))

        var reordered = conv
        let moved = reordered.messages.remove(at: 100)
        reordered.messages.append(moved)
        try harness.store.replaceAllConversations([reordered])

        await waitUntil { loader.messages.last?.id == moved.id }

        let ids = loader.messages.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(loader.messages.filter { $0.text == "P-100" }.count == 1)
        #expect(loader.messages.first?.text == "P-80")
        #expect(loader.messages.contains(where: { $0.text == "P-139" }))
    }

    @Test("MessageWindowLoader: snapshot fully disjoint from existing messages (first N all mismatch) uses full-replace reset semantics")
    @MainActor
    func windowLoaderFullyDivergedSnapshotResetsState() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let conv = makeConversationWithMessages(count: 30, prefix: "D-")
        try harness.store.replaceAllConversations([conv])

        let loader = MessageWindowLoader(attachmentFileStore: harness.fileStore)
        loader.observe(conversationID: conv.id, anchor: .latest, in: harness.dbPool)
        await waitUntil { loader.messages.count == 30 }
        #expect(loader.messages.first?.text == "D-0")

        let replacements = (0..<30).map { i in
            TestFactories.makeMessage(role: i % 2 == 0 ? .user : .assistant, text: "X-\(i)")
        }
        var rewritten = conv
        rewritten.messages = replacements
        try harness.store.replaceAllConversations([rewritten])

        await waitUntil { loader.messages.first?.text == "X-0" }
        #expect(loader.messages.count == 30)
        #expect(loader.messages.last?.text == "X-29")
        #expect(loader.messages.allSatisfy { $0.text.hasPrefix("X-") })
    }

    @Test("MessageWindowLoader: streaming new messages append to the tail window")
    @MainActor
    func windowLoaderObservesAppendedMessages() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let conv = makeConversationWithMessages(count: 30, prefix: "S-")
        try harness.store.replaceAllConversations([conv])

        let loader = MessageWindowLoader(attachmentFileStore: harness.fileStore)
        loader.observe(conversationID: conv.id, in: harness.dbPool)
        await waitUntil { loader.messages.count == 30 }

        var updated = conv
        updated.messages.append(TestFactories.makeMessage(text: "new-token-1"))
        updated.messages.append(TestFactories.makeMessage(text: "new-token-2"))
        try harness.store.replaceAllConversations([updated])

        await waitUntil { loader.messages.last?.text == "new-token-2" }
        #expect(loader.messages.count == 32)
        #expect(loader.messages.last?.text == "new-token-2")
    }

    // MARK: - Helpers

    @MainActor
    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .nanoseconds(Int(timeoutNanoseconds)))
        while condition() == false && ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }

    private func makeConversationWithMessages(count: Int, prefix: String) -> Conversation {
        let messages = (0..<count).map { i in
            TestFactories.makeMessage(role: i % 2 == 0 ? .user : .assistant, text: "\(prefix)\(i)")
        }
        return TestFactories.makeConversation(messages: messages)
    }

    @MainActor
    private func makeViewModel(conversationID: UUID, messages: [ChatMessage]) -> ChatCollectionViewModel {
        let metadata = ChatCollectionProviderMetadata.empty
        let rows = ChatCollectionProjectionBuilder.makeRows(from: messages, metadata: metadata)
        return ChatCollectionViewModel(
            conversationID: conversationID,
            messageRevision: 0,
            rows: rows,
            isSendingMessage: false,
            streamingMessageID: nil,
            streamingText: "",
            pendingAnchorUserMessageID: nil,
            pendingSearchScrollTarget: nil,
            isBootstrappingPersistedConversation: false,
            retryCapabilitySelection: .init(reasoningMode: .automatic, webSearchEnabled: true)
        )
    }
}
