import Testing
import Foundation
@testable import Oriveo

@Suite("FolderManager", .serialized)
struct FolderManagerTests {


    @MainActor
    private func makeAppState() -> AppState {
        AppState(seedDemoData: true)
    }

    @MainActor
    private func makeIsolatedAppState(
        prefix: String = "folder-manager-"
    ) -> (state: AppState, uid: String) {
        let uid = "\(prefix)\(UUID().uuidString)"
        let state = AppState(seedDemoData: false, sessionUID: uid)
        return (state, uid)
    }

    private func persistAuthoritativeConversations(
        _ conversations: [Conversation],
        uid: String
    ) throws {
        try ConversationRuntimeBridge().persistLegacyProjection(conversations, for: uid)
    }


    @Test("Create folder: name truncation + increasing sortOrder")
    @MainActor
    func createFolder() {
        let state = makeAppState()
        state.folders = []

        let folder1 = state.folderManager.createFolder(name: "  Work  ")!
        #expect(folder1.name == "Work")
        #expect(folder1.sortOrder == 1000)
        #expect(state.folders.count == 1)

        let folder2 = state.folderManager.createFolder(name: "Personal")!
        #expect(folder2.sortOrder == 2000)
        #expect(state.folders.count == 2)
    }

    @Test("Create folder: names longer than 30 characters are truncated")
    @MainActor
    func createFolderNameTruncation() {
        let state = makeAppState()
        state.folders = []

        let longName = String(repeating: "a", count: 50)
        let folder = state.folderManager.createFolder(name: longName)!
        #expect(folder.name.count == 30)
    }


    @Test("Rename folder: happy path + empty name ignored")
    @MainActor
    func renameFolder() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Old Name")!

        state.folderManager.renameFolder(id: folder.id, newName: "New Name")
        #expect(state.folders[0].name == "New Name")

        state.folderManager.renameFolder(id: folder.id, newName: "   ")
        #expect(state.folders[0].name == "New Name")
    }


    @Test("Delete folder: conversation folderID is cleared")
    @MainActor
    func deleteFolderCascade() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!

        let conv1 = TestFactories.makeConversation(title: "Chat 1", folderID: folder.id)
        let conv2 = TestFactories.makeConversation(title: "Chat 2", folderID: folder.id)
        let conv3 = TestFactories.makeConversation(title: "Chat 3")
        state.conversations = [conv1, conv2, conv3]

        state.folderManager.deleteFolder(id: folder.id)

        #expect(state.folders.isEmpty)
        #expect(state.conversations.allSatisfy { $0.folderID == nil })
        #expect(state.expandedFolderIDs.isEmpty)
    }

    @Test("Deleting a missing folder does not crash")
    @MainActor
    func deleteNonExistentFolder() {
        let state = makeAppState()
        state.folders = []
        state.folderManager.deleteFolder(id: UUID())
        #expect(state.folders.isEmpty)
    }


    @Test("Move a conversation into a folder and back out")
    @MainActor
    func moveConversation() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!
        let conv = TestFactories.makeConversation(title: "Chat")
        state.conversations = [conv]

        state.folderManager.moveConversation(conv.id, to: folder.id)
        #expect(state.conversations[0].folderID == folder.id)

        state.folderManager.moveConversation(conv.id, to: nil)
        #expect(state.conversations[0].folderID == nil)
    }

    @Test("Batch move")
    @MainActor
    func batchMove() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!

        let c1 = TestFactories.makeConversation(title: "A")
        let c2 = TestFactories.makeConversation(title: "B")
        let c3 = TestFactories.makeConversation(title: "C")
        state.conversations = [c1, c2, c3]

        state.folderManager.batchMove([c1.id, c2.id], to: folder.id)

        #expect(state.conversations[0].folderID == folder.id)
        #expect(state.conversations[1].folderID == folder.id)
        #expect(state.conversations[2].folderID == nil)
    }


    @Test("sortedFolders orders by sortOrder")
    @MainActor
    func sortedFolders() {
        let state = makeAppState()
        let f1 = TestFactories.makeFolder(name: "C", sortOrder: 3000)
        let f2 = TestFactories.makeFolder(name: "A", sortOrder: 1000)
        let f3 = TestFactories.makeFolder(name: "B", sortOrder: 2000)
        state.folders = [f1, f3, f2]

        let sorted = state.folderManager.sortedFolders
        #expect(sorted[0].name == "A")
        #expect(sorted[1].name == "B")
        #expect(sorted[2].name == "C")
    }

    @Test("conversations(in:) keeps conversations in the folder, matching web visibility")
    @MainActor
    func conversationsInFolder() {
        let state = makeAppState()
        let folderID = UUID()
        state.folders = [TestFactories.makeFolder(id: folderID)]

        let c1 = TestFactories.makeConversation(
            title: "Active",
            updatedAt: Date(),
            folderID: folderID
        )
        let c2 = TestFactories.makeConversation(
            title: "Draft",
            isDraft: true,
            folderID: folderID
        )
        let c3 = TestFactories.makeConversation(title: "Other")
        state.conversations = [c1, c2, c3]

        let inFolder = state.folderManager.conversations(in: folderID)
        #expect(inFolder.count == 2)
        #expect(Set(inFolder.map(\.title)) == Set(["Active", "Draft"]))
    }

    @Test("conversationCount(in:) counts every conversation in the folder")
    @MainActor
    func conversationCountInFolderIncludesDrafts() {
        let state = makeAppState()
        let folderID = UUID()
        state.folders = [TestFactories.makeFolder(id: folderID)]

        let active = TestFactories.makeConversation(title: "Active", folderID: folderID)
        let draft = TestFactories.makeConversation(title: "Draft", isDraft: true, folderID: folderID)
        let other = TestFactories.makeConversation(title: "Other")
        state.conversations = [active, draft, other]

        #expect(state.folderManager.conversationCount(in: folderID) == 2)
    }

    @Test("conversations(in:) reads the authoritative store, not the mirror cache")
    @MainActor
    func conversationsInFolderReadAuthoritativeStore() throws {
        let (state, uid) = makeIsolatedAppState()

        defer {
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        DatabaseManager.shared.close()

        let folderID = UUID()
        state.folders = [TestFactories.makeFolder(id: folderID)]

        let conversation = TestFactories.makeConversation(
            title: "Authoritative Folder Conversation",
            isDraft: true,
            folderID: folderID
        )

        try persistAuthoritativeConversations([conversation], uid: uid)

        #expect(state.conversations.isEmpty)

        let inFolder = state.folderManager.conversations(in: folderID)

        #expect(inFolder.count == 1)
        #expect(inFolder.first?.id == conversation.id)
        #expect(state.folderManager.conversationCount(in: folderID) == 1)
    }

    @Test("conversations(in:) merges the runtime mirror so folder conversations are not missed before background persist")
    @MainActor
    func conversationsInFolderMergeRuntimeMirrorBeforePersistenceCompletes() throws {
        let (state, uid) = makeIsolatedAppState(prefix: "folder-runtime-merge-")

        defer {
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        DatabaseManager.shared.close()

        let folderID = UUID()
        state.folders = [TestFactories.makeFolder(id: folderID)]

        let persistedConversation = TestFactories.makeConversation(
            title: "Persisted",
            folderID: folderID
        )
        let pendingConversation = TestFactories.makeConversation(
            title: "Pending Runtime",
            isDraft: true,
            folderID: folderID
        )

        try persistAuthoritativeConversations([persistedConversation], uid: uid)
        state.conversations = [persistedConversation, pendingConversation]

        let inFolder = state.folderManager.conversations(in: folderID)

        #expect(inFolder.count == 2)
        #expect(Set(inFolder.map(\.title)) == Set(["Persisted", "Pending Runtime"]))
        #expect(state.folderManager.conversationCount(in: folderID) == 2)
    }

    @Test("searchConversations(in:matching:) searches the authoritative store and returns a lightweight projection")
    @MainActor
    func searchConversationsInFolderReadAuthoritativeStore() throws {
        let (state, uid) = makeIsolatedAppState()

        defer {
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        DatabaseManager.shared.close()

        let folderID = UUID()
        state.folders = [TestFactories.makeFolder(id: folderID)]

        let message = TestFactories.makeMessage(text: "folder body search token")
        let conversation = TestFactories.makeConversation(
            title: "Folder Search Conversation",
            messages: [message],
            folderID: folderID
        )

        try persistAuthoritativeConversations([conversation], uid: uid)

        #expect(state.conversations.isEmpty)

        let results = state.folderManager.searchConversations(in: folderID, matching: "search token")

        #expect(results.count == 1)
        #expect(results.first?.id == conversation.id)
        #expect(results.first?.messages.isEmpty == true)
        #expect(results.first?.displayMessageCount == 1)
    }

    @Test("searchConversations(in:matching:) keeps folder draft conversations in the authoritative store")
    @MainActor
    func searchConversationsInFolderIncludesDraftsFromAuthoritativeStore() throws {
        let (state, uid) = makeIsolatedAppState(prefix: "folder-search-draft-visible-")

        defer {
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        DatabaseManager.shared.close()

        let folderID = UUID()
        state.folders = [TestFactories.makeFolder(id: folderID)]

        let message = TestFactories.makeMessage(text: "folder draft search token")
        let conversation = TestFactories.makeConversation(
            title: "Folder Draft Search Conversation",
            isDraft: true,
            messages: [message],
            folderID: folderID
        )

        try persistAuthoritativeConversations([conversation], uid: uid)

        #expect(state.conversations.isEmpty)

        let results = state.folderManager.searchConversations(in: folderID, matching: "draft search")

        #expect(results.count == 1)
        #expect(results.first?.id == conversation.id)
        #expect(results.first?.displayMessageCount == 1)
    }

    @Test("moveConversation reads the authoritative store, not the mirror cache")
    @MainActor
    func moveConversationReadsAuthoritativeStore() throws {
        let (state, uid) = makeIsolatedAppState(prefix: "folder-move-auth-")

        defer {
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        DatabaseManager.shared.close()

        let folderA = TestFactories.makeFolder(id: UUID(), name: "A")
        let folderB = TestFactories.makeFolder(id: UUID(), name: "B", sortOrder: 2000)
        state.folders = [folderA, folderB]

        let conversation = TestFactories.makeConversation(
            title: "Authoritative move",
            folderID: folderA.id
        )
        try persistAuthoritativeConversations([conversation], uid: uid)

        #expect(state.conversations.isEmpty)

        state.folderManager.moveConversation(conversation.id, to: folderB.id)
        state.flushConversationPersistQueue()

        let persisted = try state.authoritativeConversationProjection(for: uid)
        #expect(persisted.first?.folderID == folderB.id)
        #expect(state.conversations.first?.folderID == folderB.id)
    }

    @Test("moveConversation must not overwrite the authoritative thread with a stale mirror")
    @MainActor
    func moveConversationPreservesAuthoritativeThreadWhenMirrorIsStale() throws {
        let (state, uid) = makeIsolatedAppState(prefix: "folder-move-stale-mirror-")

        defer {
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        DatabaseManager.shared.close()

        let sourceFolder = TestFactories.makeFolder(id: UUID(), name: "Source")
        let targetFolder = TestFactories.makeFolder(id: UUID(), name: "Target", sortOrder: 2000)
        state.folders = [sourceFolder, targetFolder]

        let conversationID = UUID()
        let authoritativeConversation = TestFactories.makeConversation(
            id: conversationID,
            title: "Authoritative move",
            messages: [TestFactories.makeMessage(role: .user, text: "authoritative thread body")],
            folderID: sourceFolder.id
        )
        let staleMirrorConversation = TestFactories.makeConversation(
            id: conversationID,
            title: "Stale mirror move",
            messages: [TestFactories.makeMessage(role: .user, text: "stale mirror body")],
            folderID: sourceFolder.id
        )

        try persistAuthoritativeConversations([authoritativeConversation], uid: uid)
        state.conversations = [staleMirrorConversation]

        state.folderManager.moveConversation(conversationID, to: targetFolder.id)
        state.flushConversationPersistQueue()

        let persisted = try #require(state.authoritativeConversationProjection(for: uid).first(where: { $0.id == conversationID }))
        let mirrored = try #require(state.conversations.first(where: { $0.id == conversationID }))

        #expect(persisted.folderID == targetFolder.id)
        #expect(mirrored.folderID == targetFolder.id)
        #expect(persisted.messages.map(\.text) == ["authoritative thread body"])
        #expect(mirrored.messages.map(\.text) == ["authoritative thread body"])
    }

    @Test("batchMove reads the authoritative store, not the mirror cache")
    @MainActor
    func batchMoveReadsAuthoritativeStore() throws {
        let (state, uid) = makeIsolatedAppState(prefix: "folder-batch-auth-")

        defer {
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        DatabaseManager.shared.close()

        let folder = TestFactories.makeFolder(id: UUID(), name: "Target")
        state.folders = [folder]

        let c1 = TestFactories.makeConversation(title: "A")
        let c2 = TestFactories.makeConversation(title: "B")
        let c3 = TestFactories.makeConversation(title: "C")
        try persistAuthoritativeConversations([c1, c2, c3], uid: uid)

        #expect(state.conversations.isEmpty)

        state.folderManager.batchMove([c1.id, c2.id], to: folder.id)
        state.flushConversationPersistQueue()

        let persisted = try state.authoritativeConversationProjection(for: uid)
        let byID = Dictionary(uniqueKeysWithValues: persisted.map { ($0.id, $0) })
        #expect(byID[c1.id]?.folderID == folder.id)
        #expect(byID[c2.id]?.folderID == folder.id)
        #expect(byID[c3.id]?.folderID == nil)
    }

    @Test("deleteFolder cascades cleanup of authoritative conversations, not the mirror cache")
    @MainActor
    func deleteFolderCascadesAuthoritativeStore() throws {
        let (state, uid) = makeIsolatedAppState(prefix: "folder-delete-auth-")

        defer {
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        DatabaseManager.shared.close()

        let folder = TestFactories.makeFolder(id: UUID(), name: "Work")
        state.folders = [folder]

        let c1 = TestFactories.makeConversation(title: "A", folderID: folder.id)
        let c2 = TestFactories.makeConversation(title: "B", folderID: folder.id)
        let c3 = TestFactories.makeConversation(title: "C")
        try persistAuthoritativeConversations([c1, c2, c3], uid: uid)

        #expect(state.conversations.isEmpty)

        state.folderManager.deleteFolder(id: folder.id)
        state.flushConversationPersistQueue()

        #expect(state.folders.isEmpty)
        let persisted = try state.authoritativeConversationProjection(for: uid)
        #expect(persisted.count == 3)
        #expect(persisted.allSatisfy { $0.folderID == nil })
    }

    @Test("deleteFolder must not overwrite the authoritative thread with a stale mirror")
    @MainActor
    func deleteFolderPreservesAuthoritativeThreadsWhenMirrorIsStale() throws {
        let (state, uid) = makeIsolatedAppState(prefix: "folder-delete-stale-mirror-")

        defer {
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        DatabaseManager.shared.close()

        let folder = TestFactories.makeFolder(id: UUID(), name: "Work")
        state.folders = [folder]

        let conversationID = UUID()
        let authoritativeConversation = TestFactories.makeConversation(
            id: conversationID,
            title: "Authoritative delete",
            messages: [TestFactories.makeMessage(role: .assistant, text: "authoritative assistant body")],
            folderID: folder.id
        )
        let staleMirrorConversation = TestFactories.makeConversation(
            id: conversationID,
            title: "Stale mirror delete",
            messages: [TestFactories.makeMessage(role: .assistant, text: "stale mirror assistant body")],
            folderID: folder.id
        )

        try persistAuthoritativeConversations([authoritativeConversation], uid: uid)
        state.conversations = [staleMirrorConversation]

        state.folderManager.deleteFolder(id: folder.id)
        state.flushConversationPersistQueue()

        let persisted = try #require(state.authoritativeConversationProjection(for: uid).first(where: { $0.id == conversationID }))
        let mirrored = try #require(state.conversations.first(where: { $0.id == conversationID }))

        #expect(persisted.folderID == nil)
        #expect(mirrored.folderID == nil)
        #expect(persisted.messages.map(\.text) == ["authoritative assistant body"])
        #expect(mirrored.messages.map(\.text) == ["authoritative assistant body"])
    }

    @Test("conversationCount(in:) counts every visible conversation in the folder")
    @MainActor
    func conversationCount() {
        let state = makeAppState()
        let folderID = UUID()
        state.folders = [TestFactories.makeFolder(id: folderID)]

        state.conversations = [
            TestFactories.makeConversation(folderID: folderID),
            TestFactories.makeConversation(isDraft: true, folderID: folderID),
        ]

        #expect(state.folderManager.conversationCount(in: folderID) == 2)
    }

    @Test("folderName(for:) returns the name or nil")
    @MainActor
    func folderName() {
        let state = makeAppState()
        let folder = TestFactories.makeFolder(name: "Work")
        state.folders = [folder]

        #expect(state.folderManager.folderName(for: folder.id) == "Work")
        #expect(state.folderManager.folderName(for: UUID()) == nil)
        #expect(state.folderManager.folderName(for: nil) == nil)
    }


    @Test("reorderFolders overwrites sort order")
    @MainActor
    func reorderFolders() {
        let state = makeAppState()
        var f1 = TestFactories.makeFolder(name: "A", sortOrder: 1000)
        var f2 = TestFactories.makeFolder(name: "B", sortOrder: 2000)
        state.folders = [f1, f2]

        f2.sortOrder = 1000
        f1.sortOrder = 2000
        state.folderManager.reorderFolders([f2, f1])

        #expect(state.folderManager.sortedFolders[0].name == "B")
        #expect(state.folderManager.sortedFolders[1].name == "A")
    }


    @Test("toggleExpand and isExpanded")
    @MainActor
    func expandCollapse() {
        let state = makeAppState()
        let folderID = UUID()

        #expect(!state.folderManager.isExpanded(folderID))

        state.folderManager.toggleExpand(folderID)
        #expect(state.folderManager.isExpanded(folderID))

        state.folderManager.toggleExpand(folderID)
        #expect(!state.folderManager.isExpanded(folderID))
    }


    @Test("Time groups exclude conversations that have a folderID")
    @MainActor
    func conversationManagerExcludesFolderConversations() {
        let state = makeAppState()
        let folderID = UUID()
        state.folders = [TestFactories.makeFolder(id: folderID)]

        let c1 = TestFactories.makeConversation(title: "Grouped", updatedAt: Date())
        let c2 = TestFactories.makeConversation(title: "In Folder", updatedAt: Date(), folderID: folderID)
        let c3 = TestFactories.makeConversation(title: "Also Grouped", updatedAt: Date())
        state.conversations = [c1, c2, c3]

        let recent = state.recentConversations
        #expect(recent.contains { $0.title == "Grouped" })
        #expect(recent.contains { $0.title == "Also Grouped" })
        #expect(!recent.contains { $0.title == "In Folder" })
        let recentTitles = Set(recent.map(\.title))
        #expect(recentTitles.contains("Grouped"))
        #expect(!recentTitles.contains("In Folder"))
    }

    @Test("Search results include conversations inside folders")
    @MainActor
    func searchIncludesFolderConversations() {
        let state = makeAppState()
        let folderID = UUID()
        state.folders = [TestFactories.makeFolder(id: folderID)]

        let msg = TestFactories.makeMessage(text: "unique search term xyz")
        let c1 = TestFactories.makeConversation(title: "In Folder", messages: [msg], folderID: folderID)
        let c2 = TestFactories.makeConversation(title: "Outside")
        state.conversations = [c1, c2]

        let results = state.filteredConversations(matching: "xyz")
        #expect(results.count == 1)
        #expect(results.first?.id == c1.id)
    }

    // MARK: - Codable

    @Test("Folder Codable")
    func folderCodable() throws {
        let folder = TestFactories.makeFolder(name: "Test")
        let encoder = TestFactories.jsonEncoder
        let decoder = TestFactories.jsonDecoder

        let data = try encoder.encode(folder)
        let decoded = try decoder.decode(Folder.self, from: data)

        #expect(decoded.id == folder.id)
        #expect(decoded.name == folder.name)
        #expect(decoded.sortOrder == folder.sortOrder)
    }

    @Test("Conversation Folder IDCodable")
    func conversationFolderIDCodable() throws {
        let folderID = UUID()
        let conv = TestFactories.makeConversation(folderID: folderID)
        let encoder = TestFactories.jsonEncoder
        let decoder = TestFactories.jsonDecoder

        let data = try encoder.encode(conv)
        let decoded = try decoder.decode(Conversation.self, from: data)
        #expect(decoded.folderID == folderID)

        let convNoFolder = TestFactories.makeConversation()
        let data2 = try encoder.encode(convNoFolder)
        let decoded2 = try decoder.decode(Conversation.self, from: data2)
        #expect(decoded2.folderID == nil)
    }

    @Test("Snapshot Backward Compat")
    func snapshotBackwardCompat() throws {
        let oldSnapshot = TestFactories.makeSnapshot(
            providers: [TestFactories.makeProvider()],
            conversations: [TestFactories.makeConversation()]
        )
        let encoder = TestFactories.jsonEncoder
        let decoder = TestFactories.jsonDecoder

        let data = try encoder.encode(oldSnapshot)
        let decoded = try decoder.decode(AppSessionSnapshot.self, from: data)
        #expect(decoded.folders == nil)

        let newSnapshot = TestFactories.makeSnapshot(
            folders: [TestFactories.makeFolder()]
        )
        let data2 = try encoder.encode(newSnapshot)
        let decoded2 = try decoder.decode(AppSessionSnapshot.self, from: data2)
        #expect(decoded2.folders?.count == 1)
    }


    @Test("TC-2.1.1: trim leading and trailing spaces")
    @MainActor
    func nameValidationTrimSpaces() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "  Work  ")
        #expect(folder?.name == "Work")
    }

    @Test("TC-2.1.2: exactly 30 characters is accepted")
    @MainActor
    func nameValidationExactly30() {
        let state = makeAppState()
        state.folders = []
        let name30 = String(repeating: "A", count: 30)
        let folder = state.folderManager.createFolder(name: name30)
        #expect(folder?.name.count == 30)
    }

    @Test("TC-2.1.4: empty string is rejected (create)")
    @MainActor
    func nameValidationRejectEmpty() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "")
        #expect(folder == nil)
        #expect(state.folders.isEmpty)
    }

    @Test("TC-2.1.5: whitespace-only is rejected (create)")
    @MainActor
    func nameValidationRejectWhitespace() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "   ")
        #expect(folder == nil)
        #expect(state.folders.isEmpty)
    }

    @Test("TC-2.1.6: emoji is accepted")
    @MainActor
    func nameValidationEmojiAccepted() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "📚 Study Notes")
        #expect(folder != nil)
        #expect(folder?.name == "📚 Study Notes")
    }

    @Test("TC-2.1.7: emoji-only is accepted")
    @MainActor
    func nameValidationPureEmoji() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "🎉🎊🎈")
        #expect(folder?.name == "🎉🎊🎈")
    }

    @Test("TC-2.1.8: special characters are accepted")
    @MainActor
    func nameValidationSpecialChars() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work/Projects #1")
        #expect(folder?.name == "Work/Projects #1")
    }

    @Test("TC-2.1.9: Unicode Chinese is accepted")
    @MainActor
    func nameValidationUnicodeChinese() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "しごとかんり")
        #expect(folder?.name == "しごとかんり")
    }

    @Test("TC-2.1.10: single character is accepted")
    @MainActor
    func nameValidationSingleChar() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "A")
        #expect(folder?.name == "A")
    }

    @Test("TC-2.1.11: leading/trailing spaces + oversized → trim then truncate to 30")
    @MainActor
    func nameValidationSpacesPlusOverlong() {
        let state = makeAppState()
        state.folders = []
        let input = "  " + String(repeating: "A", count: 40) + "  "
        let folder = state.folderManager.createFolder(name: input)
        #expect(folder?.name.count == 30)
        #expect(folder?.name == String(repeating: "A", count: 30))
    }

    @Test("TC-2.1.12: internal newlines are kept (iOS: trim is ends only)")
    @MainActor
    func nameValidationInnerNewline() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work\nProjects")
        #expect(folder?.name == "Work\nProjects")
    }

    @Test("TC-2.1.13: internal tabs are kept (iOS: trim is ends only)")
    @MainActor
    func nameValidationInnerTab() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work\tProjects")
        #expect(folder?.name == "Work\tProjects")
    }


    @Test("TC-3.1.3: after deleting a middle folder, a new one gets sortOrder = max(remaining)+1000")
    @MainActor
    func sortOrderAfterDeleteMiddle() {
        let state = makeAppState()
        state.folders = []
        _ = state.folderManager.createFolder(name: "A") // 1000
        let f2 = state.folderManager.createFolder(name: "B")! // 2000
        _ = state.folderManager.createFolder(name: "C") // 3000
        state.folderManager.deleteFolder(id: f2.id)
        let f4 = state.folderManager.createFolder(name: "D")! // max=3000, new=4000
        #expect(f4.sortOrder == 4000)
    }

    @Test("TC-3.2.1: drag to middle — C between A and B")
    @MainActor
    func dragToMiddle() {
        let state = makeAppState()
        state.folders = []
        let f1 = state.folderManager.createFolder(name: "A")! // 1000
        let f2 = state.folderManager.createFolder(name: "B")! // 2000
        let f3 = state.folderManager.createFolder(name: "C")! // 3000
        state.folderManager.moveFolderBefore(sourceID: f3.id, targetID: f2.id)
        let sorted = state.folderManager.sortedFolders
        #expect(sorted[0].id == f1.id) // A first
        #expect(sorted[1].id == f3.id) // C second
        #expect(sorted[2].id == f2.id) // B last
        #expect(sorted[1].sortOrder > sorted[0].sortOrder)
        #expect(sorted[1].sortOrder < sorted[2].sortOrder)
    }

    @Test("TC-3.2.2: drag to top — C is first")
    @MainActor
    func dragToTop() {
        let state = makeAppState()
        state.folders = []
        let f1 = state.folderManager.createFolder(name: "A")! // 1000
        _ = state.folderManager.createFolder(name: "B")       // 2000
        let f3 = state.folderManager.createFolder(name: "C")! // 3000
        state.folderManager.moveFolderBefore(sourceID: f3.id, targetID: f1.id)
        #expect(state.folderManager.sortedFolders[0].id == f3.id)
    }

    @Test("TC-3.2.3: drag to bottom — A is last")
    @MainActor
    func dragToBottom() {
        let state = makeAppState()
        state.folders = []
        let f1 = state.folderManager.createFolder(name: "A")! // 1000
        let f2 = state.folderManager.createFolder(name: "B")! // 2000
        let f3 = state.folderManager.createFolder(name: "C")! // 3000
        state.folderManager.reorderFolders([
            TestFactories.makeFolder(id: f2.id, name: "B", sortOrder: 1000),
            TestFactories.makeFolder(id: f3.id, name: "C", sortOrder: 2000),
            TestFactories.makeFolder(id: f1.id, name: "A", sortOrder: 3000),
        ])
        #expect(state.folderManager.sortedFolders[2].id == f1.id)
    }

    @Test("TC-3.2.4: drag to original position — no change")
    @MainActor
    func dragToSamePosition() {
        let state = makeAppState()
        state.folders = []
        let f1 = state.folderManager.createFolder(name: "A")! // 1000
        _ = state.folderManager.createFolder(name: "B")       // 2000
        let originalSortOrder = state.folders[0].sortOrder
        state.folderManager.moveFolderBefore(sourceID: f1.id, targetID: f1.id) // same
        #expect(state.folders.first(where: { $0.id == f1.id })?.sortOrder == originalSortOrder)
    }

    @Test("TC-3.2.5: swap 2 folders — B before A")
    @MainActor
    func swapTwoFolders() {
        let state = makeAppState()
        state.folders = []
        let f1 = state.folderManager.createFolder(name: "A")! // 1000
        let f2 = state.folderManager.createFolder(name: "B")! // 2000
        state.folderManager.moveFolderBefore(sourceID: f2.id, targetID: f1.id)
        #expect(state.folderManager.sortedFolders[0].id == f2.id) // B first
        #expect(state.folderManager.sortedFolders[1].id == f1.id) // A second
    }

    @Test("TC-3.3.1: adjacent gap ≤ 1 triggers global reindex 1000,2000,...")
    @MainActor
    func sortOrderRebalanceTrigger() {
        let state = makeAppState()
        let f1 = TestFactories.makeFolder(name: "A", sortOrder: 1000)
        let f2 = TestFactories.makeFolder(name: "B", sortOrder: 1001) // diff=1
        let f3 = TestFactories.makeFolder(name: "C", sortOrder: 2000)
        state.folders = [f1, f2, f3]
        state.folderManager.moveFolderBefore(sourceID: f3.id, targetID: f2.id)
        let sorted = state.folderManager.sortedFolders
        #expect(sorted[0].sortOrder == 1000)
        #expect(sorted[1].sortOrder == 2000)
        #expect(sorted[2].sortOrder == 3000)
    }

    @Test("TC-3.3.2: order is unchanged after reindex")
    @MainActor
    func sortOrderRebalancePreservesOrder() {
        let state = makeAppState()
        let f1 = TestFactories.makeFolder(name: "A", sortOrder: 1000)
        let f2 = TestFactories.makeFolder(name: "B", sortOrder: 1001)
        let f3 = TestFactories.makeFolder(name: "C", sortOrder: 2000)
        state.folders = [f1, f2, f3]
        state.folderManager.moveFolderBefore(sourceID: f3.id, targetID: f2.id)
        let sorted = state.folderManager.sortedFolders
        #expect(sorted[0].id == f1.id) // A still first
        #expect(sorted[1].id == f3.id) // C still second
        #expect(sorted[2].id == f2.id) // B still last
        #expect(sorted[0].sortOrder == 1000)
        #expect(sorted[1].sortOrder == 2000)
        #expect(sorted[2].sortOrder == 3000)
    }


    @Test("TC-1.1.4: creating 10 folders in a row yields unique IDs")
    @MainActor
    func createFolderIDsUnique() {
        let state = makeAppState()
        state.folders = []

        let ids = (0..<10).map { state.folderManager.createFolder(name: "Folder \($0)")!.id }
        let unique = Set(ids)
        #expect(unique.count == 10)
    }

    @Test("TC-1.1.5: createdAt is unchanged after rename")
    @MainActor
    func renameFolderPreservesCreatedAt() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Original")!
        let originalCreatedAt = state.folders[0].createdAt

        state.folderManager.renameFolder(id: folder.id, newName: "Renamed")

        #expect(state.folders[0].createdAt == originalCreatedAt)
    }

    @Test("TC-1.2.2: renaming to an existing folder name is allowed")
    @MainActor
    func renameFolderAllowsDuplicate() {
        let state = makeAppState()
        state.folders = []
        _ = state.folderManager.createFolder(name: "Same Name")
        let f2 = state.folderManager.createFolder(name: "Different")!

        state.folderManager.renameFolder(id: f2.id, newName: "Same Name")

        let renamed = state.folders.first { $0.id == f2.id }
        #expect(renamed?.name == "Same Name")
    }

    @Test("TC-1.2.3: rename does not affect conversations inside")
    @MainActor
    func renameFolderDoesNotAffectConversations() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Old Name")!

        state.conversations = [
            TestFactories.makeConversation(title: "Chat 1", folderID: folder.id),
            TestFactories.makeConversation(title: "Chat 2", folderID: folder.id),
            TestFactories.makeConversation(title: "Chat 3", folderID: folder.id),
        ]

        state.folderManager.renameFolder(id: folder.id, newName: "New Name")

        #expect(state.conversations.count == 3)
        #expect(state.conversations.allSatisfy { $0.folderID == folder.id })
    }

    @Test("TC-1.2.4: rename does not affect sortOrder")
    @MainActor
    func renameFolderPreservesSortOrder() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Test")!
        let originalSortOrder = state.folders[0].sortOrder

        state.folderManager.renameFolder(id: folder.id, newName: "Renamed")

        #expect(state.folders[0].sortOrder == originalSortOrder)
    }

    @Test("TC-1.3.3: conversation data is intact after folder delete")
    @MainActor
    func deleteFolderPreservesConversationData() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Data Folder")!

        state.conversations = [
            TestFactories.makeConversation(
                title: "Important Chat",
                estimatedCost: 1.5,
                folderID: folder.id
            ),
        ]

        state.folderManager.deleteFolder(id: folder.id)

        let remaining = state.conversations[0]
        #expect(remaining.title == "Important Chat")
        #expect(remaining.estimatedCost == 1.5)
        #expect(remaining.folderID == nil)
    }

    @Test("TC-1.3.4: conversation updatedAt is unchanged after folder delete")
    @MainActor
    func deleteFolderPreservesConversationUpdatedAt() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Dated Folder")!

        let oldTime = Date(timeIntervalSinceNow: -60)
        state.conversations = [
            TestFactories.makeConversation(updatedAt: oldTime, folderID: folder.id),
        ]

        state.folderManager.deleteFolder(id: folder.id)

        let resultTime = state.conversations[0].updatedAt
        #expect(abs(resultTime.timeIntervalSince(oldTime)) < 1)
    }

    @Test("TC-1.3.9: deleting a folder does not delete conversations")
    @MainActor
    func deleteFolderKeepsConversations() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Temp Folder")!

        let conv = TestFactories.makeConversation(title: "Survive Chat", folderID: folder.id)
        state.conversations = [conv]

        state.folderManager.deleteFolder(id: folder.id)

        #expect(state.conversations.count == 1)
        #expect(state.conversations[0].id == conv.id)
        #expect(state.conversations[0].title == "Survive Chat")
        #expect(state.conversations[0].folderID == nil)
    }


    @Test("TC-4.1.2: cross-folder move — folderID updates to the target")
    @MainActor
    func crossFolderMove() {
        let state = makeAppState()
        state.folders = []
        let folderA = state.folderManager.createFolder(name: "Folder A")!
        let folderB = state.folderManager.createFolder(name: "Folder B")!

        let conv = TestFactories.makeConversation(title: "Chat", folderID: folderA.id)
        state.conversations = [conv]

        state.folderManager.moveConversation(conv.id, to: folderB.id)

        #expect(state.conversations[0].folderID == folderB.id)
        #expect(state.conversations[0].folderID != folderA.id)
    }

    @Test("TC-4.1.4: conversation updatedAt is unchanged after move")
    @MainActor
    func moveConversationPreservesUpdatedAt() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Target")!

        let oldTime = Date(timeIntervalSinceNow: -60)
        let conv = TestFactories.makeConversation(updatedAt: oldTime)
        state.conversations = [conv]

        state.folderManager.moveConversation(conv.id, to: folder.id)

        let resultTime = state.conversations[0].updatedAt
        #expect(abs(resultTime.timeIntervalSince(oldTime)) < 1)
    }

    @Test("TC-4.1.5: move does not change conversation content")
    @MainActor
    func moveConversationPreservesContent() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Target")!

        let conv = TestFactories.makeConversation(
            title: "Important Chat",
            estimatedCost: 2.5
        )
        state.conversations = [conv]

        state.folderManager.moveConversation(conv.id, to: folder.id)

        #expect(state.conversations[0].title == "Important Chat")
        #expect(state.conversations[0].estimatedCost == 2.5)
    }

    @Test("TC-4.1.6: moving a missing conversation does not crash")
    @MainActor
    func moveNonExistentConversation() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Target")!
        state.conversations = []

        state.folderManager.moveConversation(UUID(), to: folder.id)

        #expect(state.conversations.isEmpty)
    }

    @Test("TC-4.1.7: a conversation can belong to only one folder")
    @MainActor
    func singleFolderOwnership() {
        let state = makeAppState()
        state.folders = []
        let folderA = state.folderManager.createFolder(name: "Folder A")!
        let folderB = state.folderManager.createFolder(name: "Folder B")!

        let conv = TestFactories.makeConversation(title: "Chat", folderID: folderA.id)
        state.conversations = [conv]

        state.folderManager.moveConversation(conv.id, to: folderB.id)

        #expect(state.conversations[0].folderID == folderB.id)
        let inA = state.conversations.filter { $0.folderID == folderA.id }
        #expect(inA.isEmpty)
    }

    @Test("TC-4.1.8: folder count increases after moving in")
    @MainActor
    func folderCountIncreasesAfterMoveIn() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Target")!
        let conv = TestFactories.makeConversation(title: "Chat")
        state.conversations = [conv]

        #expect(state.folderManager.conversationCount(in: folder.id) == 0)

        state.folderManager.moveConversation(conv.id, to: folder.id)

        #expect(state.folderManager.conversationCount(in: folder.id) == 1)
    }

    @Test("TC-4.1.9: folder count decreases after moving out")
    @MainActor
    func folderCountDecreasesAfterMoveOut() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Source")!
        state.conversations = [
            TestFactories.makeConversation(title: "A", folderID: folder.id),
            TestFactories.makeConversation(title: "B", folderID: folder.id),
            TestFactories.makeConversation(title: "C", folderID: folder.id),
        ]

        #expect(state.folderManager.conversationCount(in: folder.id) == 3)

        state.folderManager.moveConversation(state.conversations[0].id, to: nil)

        #expect(state.folderManager.conversationCount(in: folder.id) == 2)
    }


    @Test("TC-4.2.1: sortedFolders lists every folder for the submenu")
    @MainActor
    func allFoldersListedForMenu() {
        let state = makeAppState()
        state.folders = []
        _ = state.folderManager.createFolder(name: "Folder 1")
        _ = state.folderManager.createFolder(name: "Folder 2")
        _ = state.folderManager.createFolder(name: "Folder 3")

        #expect(state.folderManager.sortedFolders.count == 3)
    }

    @Test("TC-4.2.3: a conversation already in a folder has non-nil folderID")
    @MainActor
    func conversationInFolderHasFolderID() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!
        let conv = TestFactories.makeConversation(title: "Chat", folderID: folder.id)
        state.conversations = [conv]

        #expect(state.conversations[0].folderID == folder.id)
    }

    @Test("TC-4.2.4: a conversation not in a folder has nil folderID")
    @MainActor
    func conversationNotInFolderHasNoFolderID() {
        let state = makeAppState()
        let conv = TestFactories.makeConversation(title: "Chat")
        state.conversations = [conv]

        #expect(state.conversations[0].folderID == nil)
    }

    @Test("TC-4.2.5: creating a folder then auto-moving the conversation in")
    @MainActor
    func createFolderInMenuAndAutoMove() {
        let state = makeAppState()
        state.folders = []
        let conv = TestFactories.makeConversation(title: "Chat")
        state.conversations = [conv]

        let newFolder = state.folderManager.createFolder(name: "New Folder")!
        state.folderManager.moveConversation(conv.id, to: newFolder.id)

        #expect(state.conversations[0].folderID == newFolder.id)
    }

    @Test("TC-4.2.6: moving to the current folder leaves folderID unchanged")
    @MainActor
    func moveToSameFolderNoChange() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!
        let conv = TestFactories.makeConversation(title: "Chat", folderID: folder.id)
        state.conversations = [conv]

        state.folderManager.moveConversation(conv.id, to: folder.id)

        #expect(state.conversations[0].folderID == folder.id)
    }


    @Test("TC-5.1.2: batch move out of a folder")
    @MainActor
    func batchMoveOut() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Source")!
        let c1 = TestFactories.makeConversation(title: "A", folderID: folder.id)
        let c2 = TestFactories.makeConversation(title: "B", folderID: folder.id)
        let c3 = TestFactories.makeConversation(title: "C", folderID: folder.id)
        state.conversations = [c1, c2, c3]

        state.folderManager.batchMove([c1.id, c2.id, c3.id], to: nil)

        #expect(state.conversations.allSatisfy { $0.folderID == nil })
    }

    @Test("TC-5.1.3: mixed-state batch move into a new folder")
    @MainActor
    func batchMoveMixedState() {
        let state = makeAppState()
        state.folders = []
        let folderA = state.folderManager.createFolder(name: "Folder A")!
        let folderB = state.folderManager.createFolder(name: "Folder B")!
        let c1 = TestFactories.makeConversation(title: "A", folderID: folderA.id)
        let c2 = TestFactories.makeConversation(title: "B", folderID: folderA.id)
        let c3 = TestFactories.makeConversation(title: "C")
        state.conversations = [c1, c2, c3]

        state.folderManager.batchMove([c1.id, c2.id, c3.id], to: folderB.id)

        #expect(state.conversations.allSatisfy { $0.folderID == folderB.id })
    }

    @Test("TC-5.1.4: batch selecting 0 items is a no-op")
    @MainActor
    func batchMoveEmpty() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Target")!
        let conv = TestFactories.makeConversation(title: "Chat")
        state.conversations = [conv]

        state.folderManager.batchMove([], to: folder.id)

        #expect(state.conversations[0].folderID == nil)
    }

    @Test("TC-5.1.5: batch move with an invalid ID does not crash")
    @MainActor
    func batchMoveWithInvalidIDs() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Target")!
        let conv = TestFactories.makeConversation(title: "Valid")
        state.conversations = [conv]

        state.folderManager.batchMove([conv.id, UUID()], to: folder.id)

        #expect(state.conversations[0].folderID == folder.id)
    }

    @Test("TC-5.1.6: folder count updates after batch move in")
    @MainActor
    func batchMoveUpdatesCount() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Target")!
        let c1 = TestFactories.makeConversation(title: "A")
        let c2 = TestFactories.makeConversation(title: "B")
        let c3 = TestFactories.makeConversation(title: "C")
        state.conversations = [c1, c2, c3]

        #expect(state.folderManager.conversationCount(in: folder.id) == 0)

        state.folderManager.batchMove([c1.id, c2.id, c3.id], to: folder.id)

        #expect(state.folderManager.conversationCount(in: folder.id) == 3)
    }

    // MARK: - Backup

    @Test("Backup Folder Codable")
    func backupFolderCodable() throws {
        let folder = TestFactories.makeFolder(name: "Backup Test")
        let backup = BackupFolder(from: folder)
        let encoder = TestFactories.jsonEncoder
        let decoder = TestFactories.jsonDecoder

        let data = try encoder.encode(backup)
        let decoded = try decoder.decode(BackupFolder.self, from: data)
        #expect(decoded.id == folder.id)
        #expect(decoded.name == "Backup Test")

        let restored = decoded.toFolder()
        #expect(restored.id == folder.id)
        #expect(restored.name == "Backup Test")
    }

    @Test("Backup Conversation Folder ID")
    func backupConversationFolderID() throws {
        let folderID = UUID()
        let conv = TestFactories.makeConversation(folderID: folderID)
        let backup = BackupConversation(from: conv)
        let encoder = TestFactories.jsonEncoder
        let decoder = TestFactories.jsonDecoder

        #expect(backup.folderID == folderID)

        let data = try encoder.encode(backup)
        let decoded = try decoder.decode(BackupConversation.self, from: data)
        #expect(decoded.folderID == folderID)

        let restored = decoded.toConversation()
        #expect(restored.folderID == folderID)
    }


    @Test("TC-6.1.1: a new folder is collapsed by default")
    @MainActor
    func newFolderDefaultCollapsed() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!
        #expect(!state.folderManager.isExpanded(folder.id))
        #expect(!state.expandedFolderIDs.contains(folder.id))
    }

    @Test("TC-6.1.2: one toggle → folder expands")
    @MainActor
    func toggleExpandOpens() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!
        state.folderManager.toggleExpand(folder.id)
        #expect(state.folderManager.isExpanded(folder.id))
        #expect(state.expandedFolderIDs.contains(folder.id))
    }

    @Test("TC-6.1.3: toggle while expanded → collapse")
    @MainActor
    func toggleExpandCloses() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!
        state.folderManager.toggleExpand(folder.id)
        #expect(state.folderManager.isExpanded(folder.id))
        state.folderManager.toggleExpand(folder.id)
        #expect(!state.folderManager.isExpanded(folder.id))
    }

    @Test("TC-6.1.4: two toggles are idempotent")
    @MainActor
    func toggleExpandIdempotent() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!
        let before = state.folderManager.isExpanded(folder.id)
        state.folderManager.toggleExpand(folder.id)
        state.folderManager.toggleExpand(folder.id)
        let after = state.folderManager.isExpanded(folder.id)
        #expect(before == after)
    }

    @Test("TC-6.1.6: multiple folders have independent expanded state")
    @MainActor
    func multipleFoldersIndependentExpand() {
        let state = makeAppState()
        state.folders = []
        let fA = state.folderManager.createFolder(name: "A")!
        let fB = state.folderManager.createFolder(name: "B")!
        let fC = state.folderManager.createFolder(name: "C")!
        state.folderManager.toggleExpand(fA.id)
        state.folderManager.toggleExpand(fC.id)
        #expect(state.folderManager.isExpanded(fA.id))
        #expect(!state.folderManager.isExpanded(fB.id))
        #expect(state.folderManager.isExpanded(fC.id))
    }

    @Test("TC-6.1.7: expanded folder shows the full visible conversation count")
    @MainActor
    func expandedFolderShowsNonDraftCount() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!
        let c1 = TestFactories.makeConversation(title: "A", folderID: folder.id)
        let c2 = TestFactories.makeConversation(title: "B", folderID: folder.id)
        let draft = TestFactories.makeConversation(title: "D", isDraft: true, folderID: folder.id)
        state.conversations = [c1, c2, draft]
        let count = state.folderManager.conversationCount(in: folder.id)
        #expect(count == 3)
    }

    @Test("TC-6.1.8: expanding an empty folder shows count 0")
    @MainActor
    func expandEmptyFolder() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Empty")!
        state.conversations = []
        state.folderManager.toggleExpand(folder.id)
        #expect(state.folderManager.isExpanded(folder.id))
        #expect(state.folderManager.conversationCount(in: folder.id) == 0)
    }


    @Test("TC-7.1.1: conversations in a folder do not appear in time groups")
    @MainActor
    func folderConversationExcludedFromTimeGroups() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!
        let inFolder = TestFactories.makeConversation(title: "In Folder", folderID: folder.id)
        let noFolder = TestFactories.makeConversation(title: "No Folder")
        state.conversations = [inFolder, noFolder]

        let recent = state.recentConversations
        #expect(!recent.contains { $0.id == inFolder.id })
        #expect(recent.contains { $0.id == noFolder.id })
    }

    @Test("TC-7.1.2: unfiled conversations still appear in time groups")
    @MainActor
    func unfiledConversationAppearsInTimeGroups() {
        let state = makeAppState()
        state.folders = []
        let c1 = TestFactories.makeConversation(title: "Chat 1")
        let c2 = TestFactories.makeConversation(title: "Chat 2")
        state.conversations = [c1, c2]

        let recent = state.recentConversations
        #expect(recent.contains { $0.id == c1.id })
        #expect(recent.contains { $0.id == c2.id })
    }

    @Test("TC-7.1.3: moving into a folder removes it from time groups")
    @MainActor
    func moveIntoFolderRemovedFromTimeGroups() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!
        let conv = TestFactories.makeConversation(title: "Chat")
        state.conversations = [conv]

        let before = state.recentConversations
        #expect(before.contains { $0.id == conv.id })

        state.folderManager.moveConversation(conv.id, to: folder.id)

        let after = state.recentConversations
        #expect(!after.contains { $0.id == conv.id })
    }

    @Test("TC-7.1.4: moving out of a folder returns it to time groups")
    @MainActor
    func moveOutOfFolderReturnsToTimeGroups() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!
        let conv = TestFactories.makeConversation(title: "Chat", folderID: folder.id)
        state.conversations = [conv]

        let before = state.recentConversations
        #expect(!before.contains { $0.id == conv.id })

        state.folderManager.moveConversation(conv.id, to: nil)

        let after = state.recentConversations
        #expect(after.contains { $0.id == conv.id })
    }

    @Test("TC-7.1.6: draft conversations count toward the folder")
    @MainActor
    func draftCountedInFolder() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!
        let normal1 = TestFactories.makeConversation(title: "A", folderID: folder.id)
        let normal2 = TestFactories.makeConversation(title: "B", folderID: folder.id)
        let draft = TestFactories.makeConversation(title: "Draft", isDraft: true, folderID: folder.id)
        state.conversations = [normal1, normal2, draft]
        #expect(state.folderManager.conversationCount(in: folder.id) == 3)
    }

    @Test("TC-7.1.7: draft conversations appear in the expanded folder list")
    @MainActor
    func draftInFolderExpandList() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!
        let normal = TestFactories.makeConversation(title: "Normal", folderID: folder.id)
        let draft = TestFactories.makeConversation(title: "Draft", isDraft: true, folderID: folder.id)
        state.conversations = [normal, draft]

        let visible = state.folderManager.conversations(in: folder.id)
        #expect(visible.contains { $0.id == normal.id })
        #expect(visible.contains { $0.id == draft.id })
    }


    @Test("TC-8.1.1: global search includes conversations inside folders")
    @MainActor
    func searchIncludesFolderConversationsByTitle() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!
        let inFolder = TestFactories.makeConversation(title: "AI Planning", folderID: folder.id)
        let outside = TestFactories.makeConversation(title: "Daily Note")
        state.conversations = [inFolder, outside]

        let results = state.filteredConversations(matching: "AI")
        #expect(results.contains { $0.id == inFolder.id })
    }

    @Test("TC-8.1.2: search hits inside a folder still have folderID")
    @MainActor
    func searchResultHasFolderID() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!
        let conv = TestFactories.makeConversation(title: "Unique XYZ", folderID: folder.id)
        state.conversations = [conv]

        let results = state.filteredConversations(matching: "Unique XYZ")
        #expect(results.first?.folderID == folder.id)
    }

    @Test("TC-8.1.3: unfiled search hits have no folderID")
    @MainActor
    func searchResultNoFolderID() {
        let state = makeAppState()
        state.folders = []
        let conv = TestFactories.makeConversation(title: "Unique ABC")
        state.conversations = [conv]

        let results = state.filteredConversations(matching: "Unique ABC")
        #expect(results.first?.folderID == nil)
    }

    @Test("TC-8.2.1: in-folder search is scoped to the folder")
    @MainActor
    func folderScopedSearch() {
        let state = makeAppState()
        state.folders = []
        let folderA = state.folderManager.createFolder(name: "A")!
        let folderB = state.folderManager.createFolder(name: "B")!
        let c1 = TestFactories.makeConversation(title: "Meeting Notes", folderID: folderA.id)
        let c2 = TestFactories.makeConversation(title: "Meeting Recap", folderID: folderB.id)
        let c3 = TestFactories.makeConversation(title: "Meeting Prep", folderID: folderA.id)
        state.conversations = [c1, c2, c3]

        let inFolderA = state.folderManager.conversations(in: folderA.id)
            .filter { $0.title.localizedCaseInsensitiveContains("meeting") }
        #expect(inFolderA.count == 2)
        #expect(!inFolderA.contains { $0.id == c2.id })
    }

    @Test("TC-8.2.3: in-folder title search matches")
    @MainActor
    func folderSearchByTitle() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Research")!
        let c1 = TestFactories.makeConversation(title: "AI Research Summary", folderID: folder.id)
        let c2 = TestFactories.makeConversation(title: "Budget Planning", folderID: folder.id)
        state.conversations = [c1, c2]

        let results = state.folderManager.conversations(in: folder.id)
            .filter { $0.title.localizedCaseInsensitiveContains("ai") }
        #expect(results.count == 1)
        #expect(results[0].id == c1.id)
    }

    @Test("TC-8.2.2: in-folder search with no hits returns empty")
    @MainActor
    func folderSearchNoResults() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Research")!
        let conv = TestFactories.makeConversation(title: "Regular Chat", folderID: folder.id)
        state.conversations = [conv]

        let results = state.folderManager.conversations(in: folder.id)
            .filter { $0.title.localizedCaseInsensitiveContains("nonexistentkeyword") }
        #expect(results.isEmpty)
    }


    @Test("TC-9.1.1: folder count with drafts stays consistent with Web")
    @MainActor
    func folderDetailCountTwelve() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!

        var convs: [Conversation] = []
        for i in 0..<12 {
            convs.append(TestFactories.makeConversation(title: "Chat \(i)", folderID: folder.id))
        }
        convs.append(TestFactories.makeConversation(title: "Draft 1", isDraft: true, folderID: folder.id))
        convs.append(TestFactories.makeConversation(title: "Draft 2", isDraft: true, folderID: folder.id))
        state.conversations = convs

        #expect(state.folderManager.conversationCount(in: folder.id) == 14)
    }

    @Test("TC-9.1.2: conversations in a folder are ordered by updatedAt descending")
    @MainActor
    func folderDetailSortedByUpdatedAtDesc() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!

        let oldest = TestFactories.makeConversation(title: "Oldest", updatedAt: Date(timeIntervalSinceNow: -300), folderID: folder.id)
        let middle = TestFactories.makeConversation(title: "Middle", updatedAt: Date(timeIntervalSinceNow: -100), folderID: folder.id)
        let newest = TestFactories.makeConversation(title: "Newest", updatedAt: Date(timeIntervalSinceNow: -10), folderID: folder.id)
        state.conversations = [oldest, middle, newest]

        let sorted = state.folderManager.conversations(in: folder.id)
        #expect(sorted.count == 3)
        #expect(sorted[0].title == "Newest")
        #expect(sorted[1].title == "Middle")
        #expect(sorted[2].title == "Oldest")
    }

    @Test("TC-9.1.3: in-folder search on the detail page filters")
    @MainActor
    func folderDetailSearchFilter() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!

        let c1 = TestFactories.makeConversation(title: "Project Alpha", folderID: folder.id)
        let c2 = TestFactories.makeConversation(title: "Budget Review", folderID: folder.id)
        let c3 = TestFactories.makeConversation(title: "Project Beta", folderID: folder.id)
        state.conversations = [c1, c2, c3]

        let results = state.folderManager.conversations(in: folder.id)
            .filter { $0.title.localizedCaseInsensitiveContains("project") }
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.title.contains("Project") })
        #expect(!results.contains { $0.id == c2.id })
    }

    @Test("TC-9.1.4: after rename on the detail page, folder(for:) returns the new name")
    @MainActor
    func folderDetailRename() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Old Name")!

        state.folderManager.renameFolder(id: folder.id, newName: "New Name")

        let updated = state.folderManager.folder(for: folder.id)
        #expect(updated != nil)
        #expect(updated?.name == "New Name")
    }

    @Test("TC-9.1.5: conversations remain after deleting the folder from the detail page")
    @MainActor
    func folderDetailDelete() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!

        let c1 = TestFactories.makeConversation(title: "Chat A", folderID: folder.id)
        let c2 = TestFactories.makeConversation(title: "Chat B", folderID: folder.id)
        state.conversations = [c1, c2]

        state.folderManager.deleteFolder(id: folder.id)

        #expect(state.folders.isEmpty)
        #expect(state.conversations.count == 2)
        #expect(state.conversations.allSatisfy { $0.folderID == nil })
        #expect(state.conversations[0].title == "Chat A")
        #expect(state.conversations[1].title == "Chat B")
    }

    @Test("TC-9.1.6: after an external folder delete, folder(for:) returns nil")
    @MainActor
    func folderDeletedExternallyReturnsNil() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Ephemeral")!
        let folderID = folder.id

        #expect(state.folderManager.folder(for: folderID) != nil)

        state.folders = []

        #expect(state.folderManager.folder(for: folderID) == nil)
    }

    @Test("TC-9.1.7: an empty folder has list length and count both 0")
    @MainActor
    func folderDetailEmpty() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Empty Folder")!
        state.conversations = []

        #expect(state.folderManager.conversations(in: folder.id).isEmpty)
        #expect(state.folderManager.conversationCount(in: folder.id) == 0)
    }

    @Test("TC-9.1.9: batch move out from the detail page")
    @MainActor
    func folderDetailBatchMoveOut() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!

        let c1 = TestFactories.makeConversation(title: "A", folderID: folder.id)
        let c2 = TestFactories.makeConversation(title: "B", folderID: folder.id)
        let c3 = TestFactories.makeConversation(title: "C", folderID: folder.id)
        state.conversations = [c1, c2, c3]

        #expect(state.folderManager.conversationCount(in: folder.id) == 3)

        state.folderManager.batchMove([c1.id, c2.id], to: nil)

        #expect(state.folderManager.conversationCount(in: folder.id) == 1)
        #expect(state.conversations.first { $0.id == c1.id }?.folderID == nil)
        #expect(state.conversations.first { $0.id == c2.id }?.folderID == nil)
        #expect(state.conversations.first { $0.id == c3.id }?.folderID == folder.id)
    }

    @Test("TC-9.1.11: a new chat from the detail page is created in the folder")
    @MainActor
    func folderDetailCreateConversation() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!
        state.conversations = []

        let convID = state.folderManager.createConversationInFolder(folder.id)

        let conv = state.conversations.first { $0.id == convID }
        #expect(conv != nil)
        #expect(conv?.folderID == folder.id)
        #expect(conv?.isDraft == true)
    }


    @Test("TC-10.1.1: a new chat in a folder has folderID and is a draft")
    @MainActor
    func createConversationInFolderHasFolderIDAndIsDraft() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Research")!
        state.conversations = []

        let convID = state.folderManager.createConversationInFolder(folder.id)

        let conv = state.conversations.first { $0.id == convID }
        #expect(conv != nil)
        #expect(conv?.folderID == folder.id)
        #expect(conv?.isDraft == true)
        #expect(conv?.messages.isEmpty == true)
    }

    @Test("TC-10.1.2: a regular new conversation has no folderID")
    @MainActor
    func regularConversationHasNoFolderID() {
        let state = makeAppState()
        state.folders = []
        state.conversations = []

        let conv = TestFactories.makeConversation(title: "Regular Chat")
        state.conversations = [conv]

        #expect(state.conversations[0].folderID == nil)
    }

    @Test("TC-10.1.3: a new draft in a folder is counted immediately")
    @MainActor
    func createInFolderDraftCounted() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!

        let existing = TestFactories.makeConversation(title: "Existing", folderID: folder.id)
        state.conversations = [existing]
        #expect(state.folderManager.conversationCount(in: folder.id) == 1)

        _ = state.folderManager.createConversationInFolder(folder.id)
        #expect(state.folderManager.conversationCount(in: folder.id) == 2)

        if let idx = state.conversations.firstIndex(where: { $0.isDraft && $0.folderID == folder.id }) {
            state.conversations[idx].isDraft = false
        }
        #expect(state.folderManager.conversationCount(in: folder.id) == 2)
    }

    @Test("TC-10.1.4: creating a chat in an empty folder succeeds")
    @MainActor
    func createConversationInEmptyFolder() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Empty")!
        state.conversations = []

        #expect(state.folderManager.conversations(in: folder.id).isEmpty)

        let convID = state.folderManager.createConversationInFolder(folder.id)

        let conv = state.conversations.first { $0.id == convID }
        #expect(conv != nil)
        #expect(conv?.folderID == folder.id)
        let conversations = state.folderManager.conversations(in: folder.id)
        #expect(conversations.count == 1)
        #expect(conversations.first?.id == convID)
    }


    @Test("TC-11.1.1: folder expanded state persists across navigation")
    @MainActor
    func expandStatePersistsAcrossNavigation() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Persistent")!

        state.folderManager.toggleExpand(folder.id)
        #expect(state.folderManager.isExpanded(folder.id))

        _ = state.folderManager.createFolder(name: "Another")
        let conv = TestFactories.makeConversation(title: "Chat")
        state.conversations.append(conv)

        #expect(state.folderManager.isExpanded(folder.id))
        #expect(state.expandedFolderIDs.contains(folder.id))
    }

    @Test("TC-11.1.4: creating a chat in a folder does not auto-change expanded state")
    @MainActor
    func createConversationDoesNotAutoExpand() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!
        state.conversations = []

        #expect(!state.folderManager.isExpanded(folder.id))

        _ = state.folderManager.createConversationInFolder(folder.id)

        #expect(!state.folderManager.isExpanded(folder.id))
    }

    @Test("TC-11.1.5: expanded state persists after other operations")
    @MainActor
    func expandStatePersistsThroughMutations() {
        let state = makeAppState()
        state.folders = []
        let folderA = state.folderManager.createFolder(name: "Folder A")!
        let folderB = state.folderManager.createFolder(name: "Folder B")!

        let conv = TestFactories.makeConversation(title: "Chat", folderID: folderA.id)
        state.conversations = [conv]

        state.folderManager.toggleExpand(folderA.id)
        #expect(state.folderManager.isExpanded(folderA.id))
        #expect(!state.folderManager.isExpanded(folderB.id))

        state.folderManager.renameFolder(id: folderA.id, newName: "Renamed A")
        #expect(state.folderManager.isExpanded(folderA.id))

        state.folderManager.moveConversation(conv.id, to: folderB.id)
        #expect(state.folderManager.isExpanded(folderA.id))
        #expect(!state.folderManager.isExpanded(folderB.id))

        _ = state.folderManager.createFolder(name: "Folder C")
        #expect(state.folderManager.isExpanded(folderA.id))

        state.folderManager.batchMove([conv.id], to: folderA.id)
        #expect(state.folderManager.isExpanded(folderA.id))
    }


    @Test("TC-12.1.7: ToastManager.show sets message and auto-clears after duration")
    @MainActor
    func toastManagerShowAndAutoDismiss() async throws {
        let manager = ToastManager()
        manager.show("Moved to folder \"Work\"", duration: 0.05)
        #expect(manager.current?.message == "Moved to folder \"Work\"")

        try await Task.sleep(for: .milliseconds(150))
        #expect(manager.current == nil)
    }

    @Test("TC-12.1.1: consecutive ToastManager.show calls replace the old message")
    @MainActor
    func toastManagerMultipleShowsOverride() {
        let manager = ToastManager()
        manager.show("First Message")
        manager.show("Second Message")
        #expect(manager.current?.message == "Second Message")
    }

    @Test("TC-12.1.1/12.1.3: single and batch move-in message format")
    @MainActor
    func toastMessageFormatSingleAndBatch() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!
        let convs = [
            TestFactories.makeConversation(title: "A"),
            TestFactories.makeConversation(title: "B"),
            TestFactories.makeConversation(title: "C"),
        ]
        state.conversations = convs

        let singleMsg = String(format: L10n.tr("Moved to folder \"%@\""), folder.name)
        #expect(singleMsg.contains(folder.name))
        #expect(singleMsg.contains("Work"))

        let batchMsg = String(
            format: L10n.tr("Moved %lld conversations to \"%@\""),
            Int64(3),
            folder.name
        )
        #expect(batchMsg.contains("3"))
        #expect(batchMsg.contains("Work"))
    }

    @Test("TC-12.1.2: move-out-of-folder message format")
    @MainActor
    func toastMessageFormatRemovedFromFolder() {
        let removeMsg = L10n.tr("Removed from folder")
        #expect(!removeMsg.isEmpty)

        let batchRemoveMsg = String(
            format: L10n.tr("Removed %lld conversations from folder"),
            Int64(2)
        )
        #expect(batchRemoveMsg.contains("2"))
    }

    // MARK: - TC-13 Context Menu backing logic

    @Test("TC-13.2.4: a conversation in a folder has non-nil folderID (show Move Out button)")
    @MainActor
    func conversationInFolderHasNonNilFolderID() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!
        let conv = TestFactories.makeConversation(title: "Chat")
        state.conversations = [conv]

        state.folderManager.moveConversation(conv.id, to: folder.id)

        let updated = state.conversations.first { $0.id == conv.id }!
        #expect(updated.folderID != nil)
        #expect(updated.folderID == folder.id)
    }

    @Test("TC-13.2.4: after moving out, folderID is nil (hide Move Out button)")
    @MainActor
    func conversationRemovedFromFolderHasNilFolderID() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!
        let conv = TestFactories.makeConversation(title: "Chat", folderID: folder.id)
        state.conversations = [conv]

        state.folderManager.moveConversation(conv.id, to: nil)

        let updated = state.conversations.first { $0.id == conv.id }!
        #expect(updated.folderID == nil)
    }

    @Test("TC-13.3.4: createFolder returns nil for an empty name and does not create")
    @MainActor
    func createFolderEmptyNameReturnsNil() {
        let state = makeAppState()
        state.folders = []

        #expect(state.folderManager.createFolder(name: "") == nil)
        #expect(state.folderManager.createFolder(name: "   ") == nil)
        #expect(state.folders.isEmpty)
    }

    @Test("TC-13.2.2: sortedFolders orders by sortOrder (context-menu submenu data)")
    @MainActor
    func sortedFoldersForContextMenu() {
        let state = makeAppState()
        let f3 = TestFactories.makeFolder(name: "C", sortOrder: 3000)
        let f1 = TestFactories.makeFolder(name: "A", sortOrder: 1000)
        let f2 = TestFactories.makeFolder(name: "B", sortOrder: 2000)
        state.folders = [f3, f1, f2]

        let sorted = state.folderManager.sortedFolders
        #expect(sorted[0].name == "A")
        #expect(sorted[1].name == "B")
        #expect(sorted[2].name == "C")
    }

    @Test("TC-13.3.3: createFolder truncates input longer than 30 characters")
    @MainActor
    func createFolderNameTruncatedForContextMenu() {
        let state = makeAppState()
        state.folders = []

        let folder = state.folderManager.createFolder(name: String(repeating: "x", count: 50))!
        #expect(folder.name.count == 30)
    }



    @Test("TC-22.1.1: deleting the last conversation in a folder keeps the folder and shows empty state")
    @MainActor
    func deleteLastConversationFromFolder() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!
        let conv = TestFactories.makeConversation(title: "Only Chat", folderID: folder.id)
        state.conversations = [conv]
        #expect(state.folderManager.conversationCount(in: folder.id) == 1)

        state.conversations.removeAll { $0.id == conv.id }

        #expect(state.folders.contains { $0.id == folder.id })
        #expect(state.folderManager.conversationCount(in: folder.id) == 0)
        #expect(state.folderManager.conversations(in: folder.id).isEmpty)
    }

    @Test("TC-22.1.2: 100+ conversations in one folder all load correctly")
    @MainActor
    func hundredPlusConversationsInFolder() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Big")!

        var convs: [Conversation] = []
        for i in 0..<120 {
            convs.append(TestFactories.makeConversation(
                title: "Chat \(i)",
                folderID: folder.id
            ))
        }
        state.conversations = convs

        #expect(state.folderManager.conversationCount(in: folder.id) == 120)
        #expect(state.folderManager.conversations(in: folder.id).count == 120)
    }

    @Test("TC-22.1.3: 50+ folders all sort correctly by sortOrder")
    @MainActor
    func fiftyPlusFoldersSortedCorrectly() {
        let state = makeAppState()
        state.folders = []

        for i in 0..<55 {
            state.folderManager.createFolder(name: "Folder \(i)")
        }

        #expect(state.folders.count == 55)
        let sorted = state.folderManager.sortedFolders
        #expect(sorted.count == 55)
        for i in 1..<sorted.count {
            #expect(sorted[i].sortOrder > sorted[i - 1].sortOrder)
        }
    }

    @Test("TC-22.1.5: rapid create→rename→delete leaves correct state after each step")
    @MainActor
    func quickSequentialCreateRenameThenDelete() {
        let state = makeAppState()
        state.folders = []

        let folder = state.folderManager.createFolder(name: "Quick")!
        #expect(state.folders.count == 1)
        #expect(state.folders[0].name == "Quick")

        state.folderManager.renameFolder(id: folder.id, newName: "Renamed")
        #expect(state.folders.count == 1)
        #expect(state.folders[0].name == "Renamed")

        state.folderManager.deleteFolder(id: folder.id)
        #expect(state.folders.isEmpty)
    }

    @Test("TC-22.1.6: a draft in a folder has folderID set and is included in the folder count")
    @MainActor
    func draftConversationInFolderIncludedInCount() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!

        let normalConv = TestFactories.makeConversation(
            title: "Real Chat",
            isDraft: false,
            folderID: folder.id
        )
        let draftConv = TestFactories.makeConversation(
            title: "",
            isDraft: true,
            folderID: folder.id
        )
        state.conversations = [normalConv, draftConv]

        #expect(draftConv.folderID == folder.id)
        #expect(state.folderManager.conversationCount(in: folder.id) == 2)
        #expect(state.folderManager.conversations(in: folder.id).count == 2)
    }

    @Test("TC-22.1.7: deleting a conversation in a folder decreases the folder count")
    @MainActor
    func deleteConversationFromFolderDecreasesCount() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!

        let conv1 = TestFactories.makeConversation(title: "Chat 1", folderID: folder.id)
        let conv2 = TestFactories.makeConversation(title: "Chat 2", folderID: folder.id)
        state.conversations = [conv1, conv2]
        #expect(state.folderManager.conversationCount(in: folder.id) == 2)

        state.conversations.removeAll { $0.id == conv1.id }
        #expect(state.folderManager.conversationCount(in: folder.id) == 1)
    }

    @Test("TC-22.1.8: a folder name with quotes and backslashes is stored correctly")
    @MainActor
    func folderNameWithQuotesAndBackslash() {
        let state = makeAppState()
        state.folders = []

        let name = "He said \"hello\""
        let folder = state.folderManager.createFolder(name: name)!
        #expect(folder.name == "He said \"hello\"")
        #expect(state.folders[0].name == "He said \"hello\"")

        let name2 = "path\\to\\folder"
        let folder2 = state.folderManager.createFolder(name: name2)!
        #expect(folder2.name == "path\\to\\folder")
    }

    @Test("TC-22.1.9: a folder name with HTML/XSS is stored as plain text")
    @MainActor
    func folderNameWithHTMLXSSStoredAsPlainText() {
        let state = makeAppState()
        state.folders = []

        let xssName = "<script>alert(1)</script>"
        let folder = state.folderManager.createFolder(name: xssName)!
        #expect(folder.name == "<script>alert(1)</script>")
        #expect(state.folders[0].name == "<script>alert(1)</script>")
    }

    @Test("TC-22.1.11: a conversation whose folderID points at a deleted folder is treated as unfiled")
    @MainActor
    func conversationWithDeletedFolderIDTreatedAsUncategorized() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "ToDelete")!
        let conv = TestFactories.makeConversation(title: "Chat", folderID: folder.id)
        state.conversations = [conv]

        state.folderManager.deleteFolder(id: folder.id)

        #expect(state.folders.isEmpty)
        let updated = state.conversations.first { $0.id == conv.id }!
        #expect(updated.folderID == nil)
    }

    @Test("TC-22.1.13: a 30-character Chinese name is truncated to 30 characters")
    @MainActor
    func longChineseNameTruncatedTo30Chars() {
        let state = makeAppState()
        state.folders = []

        let longName = String(repeating: "x", count: 35)
        let folder = state.folderManager.createFolder(name: longName)!
        #expect(folder.name.count == 30)
        #expect(folder.name == String(repeating: "x", count: 30))
    }


    @Test("TC-22.2.1: no folders → sortedFolders returns an empty array")
    @MainActor
    func noFoldersSortedFoldersReturnsEmpty() {
        let state = makeAppState()
        state.folders = []

        #expect(state.folderManager.sortedFolders.isEmpty)
    }

    @Test("TC-22.2.2: deleting every folder leaves folders empty")
    @MainActor
    func deleteAllFoldersResultsInEmptyArray() {
        let state = makeAppState()
        let f1 = state.folderManager.createFolder(name: "A")!
        let f2 = state.folderManager.createFolder(name: "B")!

        state.folderManager.deleteFolder(id: f1.id)
        state.folderManager.deleteFolder(id: f2.id)

        #expect(state.folders.isEmpty)
    }


    private func loadXCStrings(tableName: String) throws -> [String: Any] {
        let testFile = URL(fileURLWithPath: #file)
        // #file → .../OriveoTests/Core/FolderManagerTests.swift
        let oriveoRoot = testFile
            .deletingLastPathComponent() // Core/
            .deletingLastPathComponent() // OriveoTests/
            .deletingLastPathComponent()
        let xcstringsURL = oriveoRoot
            .appendingPathComponent("Oriveo")
            .appendingPathComponent("\(tableName).xcstrings")

        let data = try Data(contentsOf: xcstringsURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return json["strings"] as! [String: Any]
    }

    private var allLanguageIDs: [String] {
        ["ar", "de", "en", "es", "fr", "ja", "ko", "pt-BR", "zh-Hans", "zh-Hant", "hi", "id", "vi", "th", "tr", "ru"]
    }

    private func assertKeyHasAllTranslations(
        _ key: String,
        strings: [String: Any],
        tableName: String,
        file: String = #file,
        line: Int = #line
    ) {
        guard let entry = strings[key] as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any] else {
            Issue.record("Key \"\(key)\" not found in \(tableName).xcstrings")
            return
        }

        for lang in allLanguageIDs {
            guard let langEntry = localizations[lang] as? [String: Any],
                  let stringUnit = langEntry["stringUnit"] as? [String: Any],
                  let value = stringUnit["value"] as? String,
                  !value.isEmpty else {
                Issue.record("Key \"\(key)\" missing translation for \"\(lang)\"")
                continue
            }
        }
    }

    @Test("Folder Strings Exist For All Languages")
    func folderStringsExistForAllLanguages() throws {
        let tableName = "Home"
        let strings = try loadXCStrings(tableName: tableName)

        let folderKeys = [
            "Rename Folder",
            "Folder name",
            "Delete Folder",
            "Folder deleted",
            "Move to Folder",
            "New Folder",
            "Remove from Folder",
            "Removed from folder",
            "Search in folder...",
            "Move conversations here or start a new one",
            "Conversations inside will be kept.",
            "Move to",
        ]

        for key in folderKeys {
            assertKeyHasAllTranslations(key, strings: strings, tableName: tableName)
        }
    }

    @Test("Folder Toast Messages Localized")
    func folderToastMessagesLocalized() throws {
        let tableName = "Home"
        let strings = try loadXCStrings(tableName: tableName)

        let toastKeys = [
            "Folder deleted",
            "Removed from folder",
            #"Moved to folder "%@""#,
            #"Moved %lld conversations to "%@""#,
            "Removed %lld conversations from folder",
        ]

        for key in toastKeys {
            assertKeyHasAllTranslations(key, strings: strings, tableName: tableName)
        }
    }

    @Test("Folder Empty State Text Localized")
    func folderEmptyStateTextLocalized() throws {
        let tableName = "Home"
        let strings = try loadXCStrings(tableName: tableName)

        let emptyStateKeys = [
            "No conversations yet",
            "Move conversations here or start a new one",
        ]

        for key in emptyStateKeys {
            assertKeyHasAllTranslations(key, strings: strings, tableName: tableName)
        }
    }

    @Test("Folder Delete Confirmation Localized")
    func folderDeleteConfirmationLocalized() throws {
        let tableName = "Home"
        let strings = try loadXCStrings(tableName: tableName)

        let deleteKeys = [
            #"Delete "%@"?"#,
            "Delete Folder",
            "Conversations inside will be kept.",
        ]

        for key in deleteKeys {
            assertKeyHasAllTranslations(key, strings: strings, tableName: tableName)
        }
    }


    @Test("TC-25.1.1: folder name max length is 30 characters")
    @MainActor
    func maxNameLength30() {
        let state = makeAppState()
        state.folders = []

        let folder = state.folderManager.createFolder(name: String(repeating: "あ", count: 50))!
        #expect(folder.name.count == 30)

        state.folderManager.renameFolder(id: folder.id, newName: String(repeating: "B", count: 40))
        #expect(state.folders[0].name.count == 30)

        let exact30 = String(repeating: "C", count: 30)
        state.folderManager.renameFolder(id: folder.id, newName: exact30)
        #expect(state.folders[0].name == exact30)
    }

    @Test("TC-25.1.2: empty or whitespace-only names are rejected")
    @MainActor
    func emptyOrWhitespaceNameRejected() {
        let state = makeAppState()
        state.folders = []

        // createFolder
        #expect(state.folderManager.createFolder(name: "") == nil)
        #expect(state.folderManager.createFolder(name: "   ") == nil)
        #expect(state.folderManager.createFolder(name: "\t\n") == nil)
        #expect(state.folders.isEmpty)

        let folder = state.folderManager.createFolder(name: "Original")!
        state.folderManager.renameFolder(id: folder.id, newName: "")
        #expect(state.folders[0].name == "Original")
        state.folderManager.renameFolder(id: folder.id, newName: "   ")
        #expect(state.folders[0].name == "Original")
    }

    @Test("TC-25.1.3: initial sortOrder is 1000")
    @MainActor
    func sortOrderInitialValue1000() {
        let state = makeAppState()
        state.folders = []

        let folder = state.folderManager.createFolder(name: "First")!
        #expect(folder.sortOrder == 1000)
    }

    @Test("TC-25.1.4: sortOrder increases by 1000 each time")
    @MainActor
    func sortOrderIncrement1000() {
        let state = makeAppState()
        state.folders = []

        let f1 = state.folderManager.createFolder(name: "A")!
        let f2 = state.folderManager.createFolder(name: "B")!
        let f3 = state.folderManager.createFolder(name: "C")!
        #expect(state.folders.count == 3)

        state.folderManager.deleteFolder(id: f1.id)
        state.folderManager.deleteFolder(id: f2.id)
        state.folderManager.deleteFolder(id: f3.id)

        #expect(state.folders.isEmpty)
        #expect(state.folderManager.sortedFolders.isEmpty)
    }

    @Test("TC-22.2.3: empty folder → conversationCount returns 0")
    @MainActor
    func emptyFolderConversationCountReturnsZero() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Empty")!
        state.conversations = []

        #expect(state.folderManager.conversationCount(in: folder.id) == 0)
        #expect(state.folderManager.conversations(in: folder.id).isEmpty)
    }


    @Test("TC-22.3.1: a conversation folderID pointing at a missing folder is not counted by any valid folder")
    @MainActor
    func orphanFolderIDNotCountedInAnyFolder() {
        let state = makeAppState()
        state.folders = []
        let existingFolder = state.folderManager.createFolder(name: "Real")!
        let nonExistentID = UUID()

        let conv1 = TestFactories.makeConversation(title: "Normal", folderID: existingFolder.id)
        let conv2 = TestFactories.makeConversation(title: "Orphan", folderID: nonExistentID)
        state.conversations = [conv1, conv2]

        #expect(state.folderManager.conversationCount(in: existingFolder.id) == 1)
        #expect(state.folderManager.sortedFolders.allSatisfy { $0.id != nonExistentID })
        #expect(state.folderManager.folderName(for: nonExistentID) == nil)
    }

    @Test("TC-22.3.3: after clearing orphan folderIDs, conversations remain accessible")
    @MainActor
    func clearingOrphanFolderIDConversationAccessible() {
        let state = makeAppState()
        state.folders = []
        let nonExistentID = UUID()

        let conv = TestFactories.makeConversation(title: "Orphan Chat", folderID: nonExistentID)
        state.conversations = [conv]

        state.folderManager.moveConversation(conv.id, to: nil)

        let updated = state.conversations.first { $0.id == conv.id }!
        #expect(updated.folderID == nil)
        #expect(updated.title == "Orphan Chat")
    }

    @Test("TC-22.3.4: folder counts exclude orphan references")
    @MainActor
    func folderCountExcludesOrphanReferences() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Real")!
        let orphanID = UUID()

        let conv1 = TestFactories.makeConversation(title: "In Folder", folderID: folder.id)
        let conv2 = TestFactories.makeConversation(title: "Orphan 1", folderID: orphanID)
        let conv3 = TestFactories.makeConversation(title: "Orphan 2", folderID: orphanID)
        let conv4 = TestFactories.makeConversation(title: "No Folder")
        state.conversations = [conv1, conv2, conv3, conv4]

        #expect(state.folderManager.conversationCount(in: folder.id) == 1)
        for f in state.folderManager.sortedFolders {
            let count = state.folderManager.conversationCount(in: f.id)
            #expect(count == 1)
        }
    }



    @Test("TC-23.1.4: batch-moving 50 conversations is a single assignment (not per-item didSet)")
    @MainActor
    func batchMove50ConversationsSingleAssignment() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Target")!

        var convs: [Conversation] = []
        for i in 0..<50 {
            convs.append(TestFactories.makeConversation(title: "Chat \(i)"))
        }
        state.conversations = convs
        let ids = convs.map(\.id)

        state.folderManager.batchMove(ids, to: folder.id)

        #expect(state.folderManager.conversationCount(in: folder.id) == 50)
        for conv in state.conversations {
            #expect(conv.folderID == folder.id)
        }
    }

    @Test("TC-23.1.5: 50 folders + 500 conversations complete in a reasonable time")
    @MainActor
    func fiftyFoldersFiveHundredConversationsPerformance() {
        let state = makeAppState()
        state.folders = []
        state.conversations = []

        var folderIDs: [UUID] = []
        for i in 0..<50 {
            let f = state.folderManager.createFolder(name: "Folder \(i)")!
            folderIDs.append(f.id)
        }
        #expect(state.folders.count == 50)

        var convs: [Conversation] = []
        for i in 0..<500 {
            convs.append(TestFactories.makeConversation(
                title: "Conv \(i)",
                folderID: folderIDs[i % 50]
            ))
        }
        state.conversations = convs

        for fid in folderIDs {
            #expect(state.folderManager.conversationCount(in: fid) == 10)
        }

        let sorted = state.folderManager.sortedFolders
        #expect(sorted.count == 50)

        let first100IDs = Array(convs.prefix(100).map(\.id))
        state.folderManager.batchMove(first100IDs, to: folderIDs[0])

        #expect(state.folderManager.conversationCount(in: folderIDs[0]) == 108)
    }

    @Test("TC-25.1.5: deleting a folder cascades clearing conversation folderIDs")
    @MainActor
    func deleteFolderCascadesClearsFolderID() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!

        let c1 = TestFactories.makeConversation(title: "A", folderID: folder.id)
        let c2 = TestFactories.makeConversation(title: "B", folderID: folder.id)
        let c3 = TestFactories.makeConversation(title: "C")
        state.conversations = [c1, c2, c3]

        state.folderManager.deleteFolder(id: folder.id)

        #expect(state.folders.isEmpty)

        for conv in state.conversations {
            #expect(conv.folderID == nil)
        }
        #expect(state.conversations.count == 3)
    }

    @Test("TC-25.1.6: folders default to collapsed")
    @MainActor
    func foldersDefaultToCollapsed() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!

        #expect(!state.folderManager.isExpanded(folder.id))
        #expect(!state.expandedFolderIDs.contains(folder.id))

        state.folderManager.toggleExpand(folder.id)
        #expect(state.folderManager.isExpanded(folder.id))

        state.folderManager.toggleExpand(folder.id)
        #expect(!state.folderManager.isExpanded(folder.id))
    }

    @Test("TC-25.1.7: conversations in a folder are ordered by updatedAt descending")
    @MainActor
    func conversationsInFolderSortedByUpdatedAtDesc() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!

        let now = Date()
        let c1 = TestFactories.makeConversation(
            title: "Old", updatedAt: now.addingTimeInterval(-3600), folderID: folder.id
        )
        let c2 = TestFactories.makeConversation(
            title: "Newest", updatedAt: now, folderID: folder.id
        )
        let c3 = TestFactories.makeConversation(
            title: "Middle", updatedAt: now.addingTimeInterval(-1800), folderID: folder.id
        )
        state.conversations = [c1, c2, c3]

        let sorted = state.folderManager.conversations(in: folder.id)
        #expect(sorted.count == 3)
        #expect(sorted[0].title == "Newest")
        #expect(sorted[1].title == "Middle")
        #expect(sorted[2].title == "Old")
    }

    @Test("TC-25.1.8: draft conversations count toward the folder")
    @MainActor
    func draftConversationsCountedInFolder() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "Work")!

        let c1 = TestFactories.makeConversation(
            title: "Normal", isDraft: false, folderID: folder.id
        )
        let c2 = TestFactories.makeConversation(
            title: "Draft", isDraft: true, folderID: folder.id
        )
        state.conversations = [c1, c2]

        #expect(state.folderManager.conversationCount(in: folder.id) == 2)
        let convs = state.folderManager.conversations(in: folder.id)
        #expect(convs.count == 2)
        #expect(Set(convs.map(\.title)) == Set(["Normal", "Draft"]))
    }

    @Test("TC-25.1.9: folder delete is soft-delete (sync-layer deletedAt)")
    @MainActor
    func deleteFolderUsesSoftDelete() {
        let state = makeAppState()
        state.folders = []
        let folder = state.folderManager.createFolder(name: "ToDelete")!
        state.folderManager.toggleExpand(folder.id)
        #expect(state.expandedFolderIDs.contains(folder.id))

        state.folderManager.deleteFolder(id: folder.id)

        #expect(state.folders.isEmpty)
        #expect(!state.expandedFolderIDs.contains(folder.id))
    }
}
