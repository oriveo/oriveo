import Foundation

struct ConversationModelUpdate {
    let conversationID: UUID
    let providerID: UUID
    let providerKind: ProviderKind
    let modelID: String
    let metadataUpdatedAt: Date?

    init(
        conversationID: UUID,
        providerID: UUID,
        providerKind: ProviderKind,
        modelID: String,
        metadataUpdatedAt: Date? = nil
    ) {
        self.conversationID = conversationID
        self.providerID = providerID
        self.providerKind = providerKind
        self.modelID = modelID
        self.metadataUpdatedAt = metadataUpdatedAt
    }
}

final class ConversationRuntimeBridge {
    private let databaseManager: DatabaseManager
    private let attachmentFileStoreOverride: AttachmentFileStore?

    init() {
        self.databaseManager = .shared
        self.attachmentFileStoreOverride = nil
    }

    init(
        databaseManager: DatabaseManager,
        attachmentFileStore: AttachmentFileStore
    ) {
        self.databaseManager = databaseManager
        self.attachmentFileStoreOverride = attachmentFileStore
    }

    func persistLegacyProjection(_ conversations: [Conversation], for uid: String) throws {
        var databaseError: Error?
        do {
            try makeStore(for: uid).replaceAllConversations(conversations)
        } catch {
            databaseError = error
        }

        do {
            try persistRecoveryProjection(conversations, for: uid, source: "ConversationRuntimeBridge.persist")
        } catch {
            if databaseError == nil {
                return
            }
        }

        if let databaseError {
            throw databaseError
        }
    }

    func persistRecoveryProjectionOnly(_ conversations: [Conversation], for uid: String) throws {
        try persistRecoveryProjection(conversations, for: uid, source: "ConversationRuntimeBridge.recovery")
    }

    func fetchConversationProjection(uid: String, hydrateFilePayloads: Bool = true) throws -> [Conversation] {
        try makeStore(for: uid).fetchAllConversations(hydrateFilePayloads: hydrateFilePayloads)
    }

    func fetchConversationProjection(ids: [UUID], uid: String) throws -> [Conversation] {
        try fetchConversationProjections(ids: ids, uid: uid)
    }

    func fetchConversationSummaryProjections(ids: [UUID], uid: String) throws -> [Conversation] {
        guard !ids.isEmpty else { return [] }
        let summaries = try makeStore(for: uid).fetchConversationSummaries(ids: ids)
        return summaries.map {
            ConversationProjectionBuilder.buildLegacyConversation(summary: $0, messages: [])
        }
    }

    func fetchConversationProjection(id: UUID, uid: String) throws -> Conversation? {
        guard let thread = try makeStore(for: uid).fetchConversationThread(id: id, hydrateFilePayloads: true) else {
            return nil
        }
        return RecordMappers.conversation(from: thread)
    }

    func fetchConversationProjections(
        ids: [UUID],
        uid: String,
        hydrateFilePayloads: Bool = true
    ) throws -> [Conversation] {
        guard !ids.isEmpty else { return [] }
        let store = try makeStore(for: uid)
        return try ids.compactMap { id in
            guard let thread = try store.fetchConversationThread(
                id: id,
                hydrateFilePayloads: hydrateFilePayloads
            ) else {
                return nil
            }
            return RecordMappers.conversation(from: thread)
        }
    }

    func fetchHomeConversationSnapshot(
        uid: String,
        earlierLimit: Int,
        now: Date
    ) throws -> HomeConversationSnapshot {
        let store = try makeStore(for: uid)
        let recentStart = recentConversationStart(for: now)

        let recentSummaries = try store.fetchUngroupedRecentConversationSummaries(
            recentStart: recentStart
        )
        let earlierSummaries = try store.fetchUngroupedEarlierConversationSummaries(
            recentStart: recentStart,
            limit: earlierLimit
        )
        let earlierCount = try store.fetchUngroupedEarlierConversationCount(
            recentStart: recentStart
        )

        #if DEBUG
        let totalDB = (try? store.fetchConversationCount()) ?? -1
        AppLog.info(
            "Home snapshot: recentStart=\(recentStart) now=\(now) storedTotal=\(totalDB) "
            + "recent=\(recentSummaries.count) earlier=\(earlierSummaries.count) earlierTotal=\(earlierCount)",
            module: "Conversations"
        )
        if recentSummaries.isEmpty, totalDB > 0 {
            let allSummaries = (try? store.fetchConversationList()) ?? []
            for s in allSummaries.prefix(5) {
                let age = now.timeIntervalSince(s.updatedAt)
                AppLog.info(
                    "  stored conversation \(s.id.uuidString.prefix(8)): updatedAt=\(s.updatedAt) "
                    + "age=\(String(format: "%.0f", age))s draft=\(s.isDraft) "
                    + "folder=\(s.folderID?.uuidString.prefix(8) ?? "none") messages=\(s.messageCount) "
                    + "visible=\(s.isVisibleInUngroupedConversationList)",
                    module: "Conversations"
                )
            }
        }
        #endif

        return HomeConversationSnapshot(
            recentConversations: recentSummaries.map {
                ConversationProjectionBuilder.buildLegacyConversation(summary: $0, messages: [])
            },
            earlierConversations: earlierSummaries.map {
                ConversationProjectionBuilder.buildLegacyConversation(summary: $0, messages: [])
            },
            earlierTotalCount: earlierCount
        )
    }

    func replaceAllConversations(_ conversations: [Conversation], uid: String) throws -> [Conversation] {
        let store = try makeStore(for: uid)
        try store.replaceAllConversations(conversations)
        return try store.fetchAllConversations(hydrateFilePayloads: true)
    }

    func upsertConversation(_ conversation: Conversation, uid: String) throws -> Conversation {
        let store = try makeStore(for: uid)
        try store.upsertConversation(conversation)
        guard let refreshed = try store.fetchConversationThread(id: conversation.id, hydrateFilePayloads: true) else {
            return conversation
        }
        return RecordMappers.conversation(from: refreshed)
    }

    func upsertConversationWithoutReadback(_ conversation: Conversation, uid: String) throws {
        try makeStore(for: uid).upsertConversation(conversation)
    }

    func upsertConversations(_ conversations: [Conversation], uid: String) throws -> [Conversation] {
        let store = try makeStore(for: uid)
        try store.upsertConversations(conversations)
        return try conversations.compactMap { conv in
            guard let thread = try store.fetchConversationThread(id: conv.id, hydrateFilePayloads: true) else {
                return nil as Conversation?
            }
            return RecordMappers.conversation(from: thread)
        }
    }

    func setConversationUseMemory(id: UUID, useMemory: Bool, uid: String) throws -> Conversation? {
        let store = try makeStore(for: uid)
        try store.setUseMemory(id: id, useMemory: useMemory)
        guard let refreshed = try store.fetchConversationThread(id: id, hydrateFilePayloads: true) else {
            return nil
        }
        return RecordMappers.conversation(from: refreshed)
    }

    func deleteConversation(id: UUID, uid: String) throws {
        let store = try makeStore(for: uid)
        try store.deleteConversation(id: id, enqueueForSync: Self.shouldEnqueueDeletion(uid: uid))
    }

    func deleteConversations(ids: [UUID], uid: String) throws {
        let store = try makeStore(for: uid)
        try store.deleteConversations(ids: ids, enqueueForSync: Self.shouldEnqueueDeletion(uid: uid))
    }

    private static func shouldEnqueueDeletion(uid: String) -> Bool {
        !uid.isEmpty && uid != "guest"
    }

    func pendingDeletionIDs(uid: String) throws -> [UUID] {
        try makeStore(for: uid).pendingDeletionIDs()
    }

    func clearPendingDeletions(ids: [UUID], uid: String) throws {
        try makeStore(for: uid).clearPendingDeletions(ids: ids)
    }

    func loadLegacyProjection(uid: String, hydrateFilePayloads: Bool = true) throws -> [Conversation] {
        let conversations = try makeStore(for: uid).fetchAllConversations(hydrateFilePayloads: hydrateFilePayloads)
        scheduleRecoveryProjectionPersist(conversations, for: uid, source: "ConversationRuntimeBridge.load")
        return conversations
    }

    func loadRecoveryProjection(snapshot: AppSessionSnapshot?, uid: String) -> [Conversation] {
        if let conversations = snapshot?.conversations {
            return conversations
        }
        if let recovery = loadRecoverySnapshot(for: uid) {
            return recovery.conversations
        }
        if let backup = loadBackupSnapshot(for: uid) {
            return backup.conversations ?? []
        }
        return []
    }

    func checkpoint() throws {
        try databaseManager.checkpoint()
    }

    func close() {
        databaseManager.close()
    }

    func searchConversationProjections(query: String, uid: String) async throws -> [Conversation] {
        let summaries = try await makeStore(for: uid).search(query: query)
        return summaries.map { summary in
            ConversationProjectionBuilder.buildLegacyConversation(summary: summary, messages: [])
        }
    }

    func searchConversationProjections(in folderID: UUID, query: String, uid: String) throws -> [Conversation] {
        let summaries = try makeStore(for: uid).searchInFolderSync(folderID: folderID, query: query)
        return summaries.map { summary in
            ConversationProjectionBuilder.buildLegacyConversation(summary: summary, messages: [])
        }
    }

    func fetchFolderAssignments(uid: String) throws -> [ConversationFolderAssignment] {
        try makeStore(for: uid).fetchFolderAssignments()
    }

    func fetchConversationIDs(in folderID: UUID, uid: String) throws -> [UUID] {
        try makeStore(for: uid).fetchConversationIDs(in: folderID)
    }

    func updateConversationModels(_ updates: [ConversationModelUpdate], uid: String) throws -> [Conversation] {
        guard !updates.isEmpty else { return [] }

        let store = try makeStore(for: uid)
        for update in updates {
            try store.updateModel(
                id: update.conversationID,
                providerID: update.providerID,
                providerKind: update.providerKind,
                modelID: update.modelID,
                metadataUpdatedAt: update.metadataUpdatedAt
            )
        }

        return try updates.compactMap { update in
            guard let thread = try store.fetchConversationThread(id: update.conversationID, hydrateFilePayloads: true) else {
                return nil as Conversation?
            }
            return RecordMappers.conversation(from: thread)
        }
    }

    private func makeStore(for uid: String) throws -> ConversationStore {
        let pool = try databaseManager.openIfNeeded(for: uid)
        let attachmentFileStore = attachmentFileStoreOverride
            ?? AttachmentFileStore(rootDirectory: AppSessionStore.filesDir(for: uid))
        return ConversationStore(
            dbPool: pool,
            attachmentFileStore: attachmentFileStore,
            continuationOrphanSweep: { try RecipeContinuationStore.purgeOrphans(for: uid, parentPool: pool) }
        )
    }

    private func recentConversationStart(for now: Date) -> Date {
        Calendar.current.date(
            byAdding: .day,
            value: -7,
            to: Calendar.current.startOfDay(for: now)
        ) ?? now
    }

    /// "loadSession falls back to recovery projection when SQLite becomes unreadable"
    private static let recoverySnapshotQueue = DispatchQueue(
        label: "com.oriveo.conversation.recovery-snapshot",
        qos: .utility
    )

    private func scheduleRecoveryProjectionPersist(
        _ conversations: [Conversation],
        for uid: String,
        source: String
    ) {
        Self.recoverySnapshotQueue.async {
            try? Self.writeRecoveryProjection(conversations, for: uid, source: source)
        }
    }

    private func persistRecoveryProjection(
        _ conversations: [Conversation],
        for uid: String,
        source: String
    ) throws {
        try Self.recoverySnapshotQueue.sync {
            try Self.writeRecoveryProjection(conversations, for: uid, source: source)
        }
    }

    nonisolated private static func writeRecoveryProjection(
        _ conversations: [Conversation],
        for uid: String,
        source: String
    ) throws {
        let snapshot = LegacyConversationRecoverySnapshot(
            conversations: conversations,
            exportedAt: Date(),
            source: source
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let url = AppSessionStore.recoverySnapshotPath(for: uid)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func loadRecoverySnapshot(for uid: String) -> LegacyConversationRecoverySnapshot? {
        let url = AppSessionStore.recoverySnapshotPath(for: uid)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LegacyConversationRecoverySnapshot.self, from: data)
    }

    private func loadBackupSnapshot(for uid: String) -> AppSessionSnapshot? {
        let url = AppSessionStore.backupSnapshotPath(for: uid)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AppSessionSnapshot.self, from: data)
    }
}
