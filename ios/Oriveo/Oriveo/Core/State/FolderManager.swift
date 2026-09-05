import Foundation

@MainActor
final class FolderManager {
    unowned private(set) var appState: AppState!
    private(set) var isBound = false
    private var cachedMergedProjection: [Conversation] = []
    private var cachedMergedProjectionVersion: UInt = .max
    private var cachedMergedProjectionUID = ""
    private var cachedMergedProjectionUsesAuthoritative = false
    private var cachedFolderCounts: [UUID: Int] = [:]
    private var cachedFolderCountsVersion: UInt = .max
    private var cachedFolderCountsUID = ""
    private var cachedFolderCountsUsesAuthoritative = false

    func bind(to appState: AppState) {
        self.appState = appState
        isBound = true
    }

    private var folders: [Folder] {
        get { appState.folders }
        set { appState.folders = newValue }
    }


    var sortedFolders: [Folder] {
        folders.sorted { $0.sortOrder < $1.sortOrder }
    }

    func conversations(in folderID: UUID) -> [Conversation] {
        mergedConversationProjection()
            .filter { $0.folderID == folderID }
            .sorted(by: ConversationProjectionMerger.sort)
    }

    func conversationCount(in folderID: UUID) -> Int {
        folderConversationCounts()[folderID] ?? 0
    }

    private func folderConversationCounts() -> [UUID: Int] {
        let partitionUID = appState.sessionPartitionUID
        let version = appState.conversationsVersion
        let usesAuthoritative = usesAuthoritativeProjection(for: partitionUID)

        if cachedFolderCountsVersion == version,
           cachedFolderCountsUID == partitionUID,
           cachedFolderCountsUsesAuthoritative == usesAuthoritative {
            return cachedFolderCounts
        }

        var counts: [UUID: Int] = [:]
        for folderID in mergedFolderAssignments().values {
            counts[folderID, default: 0] += 1
        }

        cachedFolderCounts = counts
        cachedFolderCountsVersion = version
        cachedFolderCountsUID = partitionUID
        cachedFolderCountsUsesAuthoritative = usesAuthoritative
        return counts
    }

    private func mergedFolderAssignments() -> [UUID: UUID] {
        let partitionUID = appState.sessionPartitionUID
        var databaseAssignments: [UUID: ConversationFolderAssignment] = [:]
        if usesAuthoritativeProjection(for: partitionUID),
           let rows = try? appState.conversationRuntimeBridge.fetchFolderAssignments(uid: partitionUID) {
            databaseAssignments = Dictionary(
                rows.map { ($0.conversationID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }

        var assignments = databaseAssignments.mapValues(\.folderID)
        for conversation in appState.conversations {
            if let folderID = conversation.folderID {
                assignments[conversation.id] = folderID
                continue
            }
            guard let stored = databaseAssignments[conversation.id] else { continue }
            let storedAt = stored.metadataUpdatedAt ?? .distantPast
            let memoryAt = conversation.metadataUpdatedAt ?? .distantPast
            if storedAt < memoryAt {
                assignments.removeValue(forKey: conversation.id)
            }
        }
        return assignments
    }

    func searchConversations(in folderID: UUID, matching query: String) -> [Conversation] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return conversations(in: folderID)
        }

        let partitionUID = appState.sessionPartitionUID
        guard appState.prefersAuthoritativeConversationStore,
              DatabaseManager.shared.hasDatabase(for: partitionUID) else {
            return conversations(in: folderID).filter { conversation in
                conversation.title.localizedCaseInsensitiveContains(normalizedQuery) ||
                conversation.messages.contains { $0.text.localizedCaseInsensitiveContains(normalizedQuery) }
            }
        }

        return (try? appState.conversationRuntimeBridge.searchConversationProjections(
            in: folderID,
            query: normalizedQuery,
            uid: partitionUID
        )) ?? []
    }

    func folder(for id: UUID) -> Folder? {
        folders.first { $0.id == id }
    }

    func folderName(for folderID: UUID?) -> String? {
        guard let folderID else { return nil }
        return folders.first { $0.id == folderID }?.name
    }

    // MARK: - CRUD

    @discardableResult
    func createFolder(name: String) -> Folder? {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
        guard !trimmed.isEmpty else { return nil }
        let sortOrder = folders.isEmpty ? 1000 : (folders.map(\.sortOrder).max()! + 1000)
        let colorTag = FolderColor.nextColor(after: folders).rawValue

        let folder = Folder(
            id: UUID(),
            name: trimmed,
            sortOrder: sortOrder,
            colorTag: colorTag
        )
        folders.append(folder)
        return folder
    }

    func updateFolderColor(id: UUID, colorTag: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].colorTag = colorTag
        folders[index].updatedAt = Date()
    }

    func assignColorsIfNeeded() {
        let sorted = folders.sorted { $0.sortOrder < $1.sortOrder }
        var previousIndex = -1

        for folder in sorted {
            guard let idx = folders.firstIndex(where: { $0.id == folder.id }) else { continue }
            if folders[idx].colorTag == nil {
                let nextIndex = (previousIndex + 1) % FolderColor.ordered.count
                let color = FolderColor.ordered[nextIndex]
                folders[idx].colorTag = color.rawValue
                folders[idx].updatedAt = Date()
                previousIndex = nextIndex
            } else {
                previousIndex = FolderColor.ordered.firstIndex(of: FolderColor.from(folders[idx].colorTag)) ?? previousIndex
            }
        }
    }

    func renameFolder(id: UUID, newName: String) {
        let trimmed = String(newName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
        guard !trimmed.isEmpty,
              let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = trimmed
        folders[index].updatedAt = Date()
    }

    func deleteFolder(id: UUID) {
        guard folders.contains(where: { $0.id == id }) else { return }

        var affectedConvIDs = Set(authoritativeConversationIDs(in: id))
        affectedConvIDs.formUnion(
            appState.conversations
                .filter { $0.folderID == id }
                .map(\.id)
        )

        var affectedConversations = conversationsForFolderMutation(ids: affectedConvIDs)
        let metadataUpdatedAt = Date()

        for index in affectedConversations.indices {
            affectedConversations[index].folderID = nil
            affectedConversations[index].metadataUpdatedAt = metadataUpdatedAt
        }
        appState.upsertConversationProjections(affectedConversations)

        folders.removeAll { $0.id == id }


        appState.expandedFolderIDs.remove(id)
    }


    func moveConversation(_ convID: UUID, to folderID: UUID?) {
        guard var updated = conversationForFolderMutation(id: convID) else { return }
        updated.folderID = folderID
        updated.metadataUpdatedAt = Date()
        appState.upsertConversationProjection(updated)
    }

    func batchMove(_ convIDs: [UUID], to folderID: UUID?) {
        guard !convIDs.isEmpty else { return }
        let idSet = Set(convIDs)
        var updatedConversations = conversationsForFolderMutation(ids: idSet)
        let metadataUpdatedAt = Date()
        for index in updatedConversations.indices {
            updatedConversations[index].folderID = folderID
            updatedConversations[index].metadataUpdatedAt = metadataUpdatedAt
        }
        appState.upsertConversationProjections(updatedConversations)
    }

    func createConversationInFolder(_ folderID: UUID) -> UUID? {
        guard let active = appState.activeModel else { return nil }
        let convID = UUID()
        let conv = Conversation(
            id: convID,
            title: "",
            providerID: active.provider.id,
            providerKind: active.provider.kind,
            modelID: active.model.id,
            previewText: "",
            estimatedCost: 0,
            isDraft: true,
            messages: [],
            folderID: folderID
        )
        appState.upsertConversationProjection(conv)
        return convID
    }


    func reorderFolders(_ reordered: [Folder]) {
        folders = reordered
    }

    func moveFolderBefore(sourceID: UUID, targetID: UUID) {
        var sorted = sortedFolders
        guard let sourceIdx = sorted.firstIndex(where: { $0.id == sourceID }),
              let targetIdx = sorted.firstIndex(where: { $0.id == targetID }),
              sourceIdx != targetIdx else { return }

        let moved = sorted.remove(at: sourceIdx)
        let insertIdx = sourceIdx < targetIdx ? targetIdx - 1 : targetIdx
        sorted.insert(moved, at: insertIdx)

        reassignSortOrders(&sorted)
        reorderFolders(sorted)
    }

    private func reassignSortOrders(_ sorted: inout [Folder]) {
        for (i, _) in sorted.enumerated() {
            sorted[i].sortOrder = (i + 1) * 1000
            sorted[i].updatedAt = Date()
        }
    }


    func toggleExpand(_ folderID: UUID) {
        if appState.expandedFolderIDs.contains(folderID) {
            appState.expandedFolderIDs.remove(folderID)
        } else {
            appState.expandedFolderIDs.insert(folderID)
        }
    }

    func isExpanded(_ folderID: UUID) -> Bool {
        appState.expandedFolderIDs.contains(folderID)
    }


    func handleFoldersDidChange() {
        invalidateMergedProjectionCache()
    }

    private func authoritativeConversations() -> [Conversation] {
        let partitionUID = appState.sessionPartitionUID
        guard usesAuthoritativeProjection(for: partitionUID) else {
            return appState.conversations
        }
        return (try? appState.authoritativeConversationProjection(
            for: partitionUID,
            hydrateFilePayloads: false
        )) ?? appState.conversations
    }

    private func mergedConversationProjection() -> [Conversation] {
        let partitionUID = appState.sessionPartitionUID
        let conversationVersion = appState.conversationsVersion
        let usesAuthoritative = usesAuthoritativeProjection(for: partitionUID)

        if cachedMergedProjectionVersion == conversationVersion,
           cachedMergedProjectionUID == partitionUID,
           cachedMergedProjectionUsesAuthoritative == usesAuthoritative {
            return cachedMergedProjection
        }

        let authoritative = authoritativeConversations()
        let merged: [Conversation]
        if appState.conversations.isEmpty {
            merged = authoritative
        } else {
            merged = ConversationProjectionMerger.merge(
            preferred: appState.conversations,
            fallback: authoritative
        )
        }

        cachedMergedProjection = merged
        cachedMergedProjectionVersion = conversationVersion
        cachedMergedProjectionUID = partitionUID
        cachedMergedProjectionUsesAuthoritative = usesAuthoritative
        return merged
    }

    private func usesAuthoritativeProjection(for partitionUID: String) -> Bool {
        appState.prefersAuthoritativeConversationStore &&
        DatabaseManager.shared.hasDatabase(for: partitionUID)
    }

    private func invalidateMergedProjectionCache() {
        cachedMergedProjection = []
        cachedMergedProjectionVersion = .max
        cachedMergedProjectionUID = ""
        cachedMergedProjectionUsesAuthoritative = false
        cachedFolderCounts = [:]
        cachedFolderCountsVersion = .max
        cachedFolderCountsUID = ""
        cachedFolderCountsUsesAuthoritative = false
    }

    private func authoritativeConversationIDs(in folderID: UUID) -> [UUID] {
        let partitionUID = appState.sessionPartitionUID
        guard appState.prefersAuthoritativeConversationStore,
              DatabaseManager.shared.hasDatabase(for: partitionUID) else {
            return []
        }
        return (try? appState.conversationRuntimeBridge.fetchConversationIDs(in: folderID, uid: partitionUID)) ?? []
    }

    private func authoritativeConversations(ids: [UUID]) -> [Conversation] {
        guard !ids.isEmpty else { return [] }
        let partitionUID = appState.sessionPartitionUID
        guard appState.prefersAuthoritativeConversationStore,
              DatabaseManager.shared.hasDatabase(for: partitionUID) else {
            return []
        }
        return (try? appState.conversationRuntimeBridge.fetchConversationProjection(ids: ids, uid: partitionUID)) ?? []
    }

    private func conversationForFolderMutation(id: UUID) -> Conversation? {
        if let conversation = authoritativeConversationForMutation(id: id) {
            return conversation
        }
        return appState.conversations.first(where: { $0.id == id })
    }

    private func conversationsForFolderMutation(ids: Set<UUID>) -> [Conversation] {
        guard !ids.isEmpty else { return [] }

        let authoritative = authoritativeConversationsForMutation(ids: ids)
        var byID = Dictionary(
            uniqueKeysWithValues: authoritative
                .filter { ids.contains($0.id) }
                .map { ($0.id, $0) }
        )

        for conversation in appState.conversations where ids.contains(conversation.id) {
            if byID[conversation.id] == nil {
                byID[conversation.id] = conversation
            }
        }

        var ordered: [Conversation] = []
        ordered.reserveCapacity(byID.count)

        for conversation in appState.conversations where ids.contains(conversation.id) {
            guard let merged = byID.removeValue(forKey: conversation.id) else { continue }
            ordered.append(merged)
        }

        for conversation in authoritative where ids.contains(conversation.id) {
            guard let merged = byID.removeValue(forKey: conversation.id) else { continue }
            ordered.append(merged)
        }

        ordered.append(contentsOf: byID.values)
        return ordered
    }

    private func authoritativeConversationForMutation(id: UUID) -> Conversation? {
        let partitionUID = appState.sessionPartitionUID
        guard appState.prefersAuthoritativeConversationStore,
              DatabaseManager.shared.hasDatabase(for: partitionUID) else {
            return nil
        }
        return try? appState.conversationRuntimeBridge.fetchConversationProjection(
            id: id,
            uid: partitionUID
        )
    }

    private func authoritativeConversationsForMutation(ids: Set<UUID>) -> [Conversation] {
        let partitionUID = appState.sessionPartitionUID
        guard appState.prefersAuthoritativeConversationStore,
              DatabaseManager.shared.hasDatabase(for: partitionUID) else {
            return []
        }
        return (try? appState.conversationRuntimeBridge.fetchConversationProjections(
            ids: Array(ids),
            uid: partitionUID
        )) ?? []
    }
}
