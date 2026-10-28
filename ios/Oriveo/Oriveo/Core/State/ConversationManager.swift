import Foundation
import OriveoProviderKit

struct HomeConversationSnapshot {
    let recentConversations: [Conversation]
    let earlierConversations: [Conversation]
    let earlierTotalCount: Int
}

enum ConversationProjectionMerger {
    static func recover(authoritative: [Conversation], recovered: [Conversation]) -> [Conversation] {
        guard !authoritative.isEmpty else { return recovered.sorted(by: sort) }
        guard !recovered.isEmpty else { return authoritative.sorted(by: sort) }

        var mergedByID = Dictionary(uniqueKeysWithValues: authoritative.map { ($0.id, $0) })
        for conversation in recovered {
            if let existing = mergedByID[conversation.id] {
                if shouldAdoptRecovered(conversation, over: existing) {
                    mergedByID[conversation.id] = preferredConversation(
                        preferred: conversation,
                        fallback: existing
                    )
                }
            } else {
                mergedByID[conversation.id] = conversation
            }
        }

        return mergedByID.values.sorted(by: sort)
    }

    /// Whether the cold-start recovery merge actually changed the authoritative projection
    /// (compared by id and content, independent of order).
    static func hasRecoveredChanges(merged: [Conversation], authoritative: [Conversation]) -> Bool {
        guard merged.count == authoritative.count else { return true }
        let authoritativeByID = Dictionary(authoritative.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard authoritativeByID.count == authoritative.count else { return true }
        return merged.contains { authoritativeByID[$0.id] != $0 }
    }

    static func sort(_ lhs: Conversation, _ rhs: Conversation) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }

        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func preferredConversation(
        preferred: Conversation,
        fallback: Conversation
    ) -> Conversation {
        if preferred.updatedAt != fallback.updatedAt {
            return preferred.updatedAt > fallback.updatedAt
                ? preservingFolderID(in: preferred, from: fallback)
                : preservingFolderID(in: fallback, from: preferred)
        }

        let preferredMetadataUpdatedAt = preferred.metadataUpdatedAt ?? .distantPast
        let fallbackMetadataUpdatedAt = fallback.metadataUpdatedAt ?? .distantPast
        if preferredMetadataUpdatedAt != fallbackMetadataUpdatedAt {
            return preferredMetadataUpdatedAt > fallbackMetadataUpdatedAt ? preferred : fallback
        }

        if preferred.displayMessageCount != fallback.displayMessageCount {
            return preferred.displayMessageCount > fallback.displayMessageCount ? preferred : fallback
        }

        return preservingFolderID(in: preferred, from: fallback)
    }

    private static func preservingFolderID(
        in selected: Conversation,
        from alternate: Conversation
    ) -> Conversation {
        guard selected.folderID == nil,
              let alternateFolderID = alternate.folderID else { return selected }

        let selectedMetadataUpdatedAt = selected.metadataUpdatedAt ?? .distantPast
        let alternateMetadataUpdatedAt = alternate.metadataUpdatedAt ?? .distantPast
        guard alternateMetadataUpdatedAt >= selectedMetadataUpdatedAt else { return selected }

        var merged = selected
        merged.folderID = alternateFolderID
        return merged
    }

    private static func shouldAdoptRecovered(
        _ recovered: Conversation,
        over authoritative: Conversation
    ) -> Bool {
        if recovered.displayMessageCount > authoritative.displayMessageCount {
            return true
        }

        // Summary projections keep `messages` empty and the count in `displayMessageCount`.
        // A recovered snapshot that still has bodies must not win just because of that,
        // or cold start rehydrates every thread into memory.
        let recoveredMetadataUpdatedAt = recovered.metadataUpdatedAt ?? .distantPast
        let authoritativeMetadataUpdatedAt = authoritative.metadataUpdatedAt ?? .distantPast
        if recoveredMetadataUpdatedAt > authoritativeMetadataUpdatedAt,
           recovered.displayMessageCount >= authoritative.displayMessageCount {
            return true
        }

        return false
    }
}

struct HomeConversationSectionState: Hashable {
    let section: ConversationManager.ConversationSection
    let conversations: [Conversation]
    let remainingCount: Int
}

func resolveHomeConversationSectionDisplay(
    section: ConversationManager.ConversationSection,
    conversations: [Conversation],
    isEditing: Bool,
    earlierDisplayCount: Int
) -> HomeConversationSectionState {
    if section == .earlier && !isEditing {
        let display = Array(conversations.prefix(earlierDisplayCount))
        return HomeConversationSectionState(
            section: section,
            conversations: display,
            remainingCount: max(0, conversations.count - display.count)
        )
    }
    return HomeConversationSectionState(
        section: section,
        conversations: conversations,
        remainingCount: 0
    )
}

@MainActor
final class ConversationManager {
    enum ConversationSection: Hashable {
        case pinned
        case today
        case yesterday
        case past7Days
        case earlier
    }

    unowned private(set) var appState: AppState!
    private(set) var isBound = false
    var nowProvider: () -> Date = Date.init
    private var cachedRecentConversations: [Conversation] = []
    private var cachedRecentConversationSections: [(ConversationSection, [Conversation])] = []
    private var cachedMonthlyCostSummary = MonthlyCostSummary()
    private var cachedMonthlyCostByProvider: [UUID: Double] = [:]
    private var cachedMonthlyActivityByProvider: [UUID: ProviderMonthlyActivity] = [:]
    private var cachedSearchResults: [String: [Conversation]] = [:]
    private var cachedConversationVersion: UInt = .max
    private var cachedDayKey = ""
    private var cachedMonthKey = ""
    private var cachedHomeSnapshot: HomeConversationSnapshot?
    private var cachedHomeSnapshotVersion: UInt = .max
    private var cachedHomeSnapshotDayKey = ""
    private var cachedHomeSnapshotEarlierLimit: Int = 0
    /// Cached home sections. HomeView's body reads the hero composer text, so every keystroke asks
    /// for the sections again, and building them merges the in-memory recent conversations with the
    /// stored snapshot and sorts the result; unchanged inputs give the same result. The key matches
    /// the snapshot cache (conversations version, day and earlier limit) plus the partition.
    private var cachedHomeSections: (key: HomeSectionsCacheKey, sections: [HomeConversationSectionState])?
    #if DEBUG
    private(set) var debugHomeSectionsComputationCount = 0
    #endif

    private struct HomeSectionsCacheKey: Equatable {
        let conversationsVersion: UInt
        let dayKey: String
        let earlierLimit: Int
        let partitionUID: String
    }
    private var cachedPinnedConversations: [Conversation] = []
    private var cachedPinnedVersion: UInt = .max
    private var cachedPinnedIDs: [UUID] = []

    func bind(to appState: AppState) {
        self.appState = appState
        isBound = true
        let source = appState.conversations.isEmpty ? authoritativeConversations() : appState.conversations
        rebuildCaches(from: source, now: nowProvider())
    }


    private var conversations: [Conversation] {
        appState.conversations
    }


    var recentConversations: [Conversation] {
        refreshCachesIfNeeded()
        return cachedRecentConversations
    }

    var recentConversationSections: [(ConversationSection, [Conversation])] {
        refreshCachesIfNeeded()
        return cachedRecentConversationSections
    }

    func homeConversationSections(earlierLimit: Int) -> [HomeConversationSectionState] {
        let raw = computeHomeConversationSections(earlierLimit: earlierLimit)
        return excludePinnedFromSections(raw)
    }

    private func excludePinnedFromSections(_ sections: [HomeConversationSectionState]) -> [HomeConversationSectionState] {
        let pinnedIDs = Set(appState.preferences.pinnedConversationIDs)
        guard !pinnedIDs.isEmpty else { return sections }
        return sections.compactMap { state in
            let filtered = state.conversations.filter { !pinnedIDs.contains($0.id) }
            if filtered.isEmpty { return nil }
            return HomeConversationSectionState(
                section: state.section,
                conversations: filtered,
                remainingCount: state.remainingCount
            )
        }
    }

    private func computeHomeConversationSections(earlierLimit: Int) -> [HomeConversationSectionState] {
        let now = nowProvider()
        let cacheKey = HomeSectionsCacheKey(
            conversationsVersion: appState.conversationsVersion,
            dayKey: Self.dayKey(for: now),
            earlierLimit: earlierLimit,
            partitionUID: appState.sessionPartitionUID
        )
        // With no conversations in memory every call has to check the store for outside writes
        // (see refreshCachesIfNeeded), so that case skips the result cache.
        if !conversations.isEmpty, let cached = cachedHomeSections, cached.key == cacheKey {
            return cached.sections
        }
        let sections = computeHomeConversationSectionsUncached(earlierLimit: earlierLimit, now: now)
        cachedHomeSections = conversations.isEmpty ? nil : (cacheKey, sections)
        return sections
    }

    private func computeHomeConversationSectionsUncached(
        earlierLimit: Int,
        now: Date
    ) -> [HomeConversationSectionState] {
        #if DEBUG
        debugHomeSectionsComputationCount += 1
        #endif
        refreshCachesIfNeeded(now: now)

        // While the in-memory mirror is non-empty it is the whole conversation table (writes change memory
        // first and reach the store asynchronously), so section membership and content come from memory only.
        // Unioning in a store snapshot would bring back changes that are still queued and costs a
        // synchronous store read on the main thread per version change.
        if !conversations.isEmpty {
            return cachedRecentConversationSections.map { section, conversations in
                if section == .earlier {
                    let displayConversations = Array(conversations.prefix(earlierLimit))
                    return HomeConversationSectionState(
                        section: section,
                        conversations: displayConversations,
                        remainingCount: max(0, conversations.count - displayConversations.count)
                    )
                }
                return HomeConversationSectionState(
                    section: section,
                    conversations: conversations,
                    remainingCount: 0
                )
            }
        }

        if let snapshot = authoritativeHomeConversationSnapshot(earlierLimit: earlierLimit, now: now) {
            let result = Self.makeHomeConversationSections(
                recentConversations: snapshot.recentConversations,
                earlierConversations: snapshot.earlierConversations,
                earlierTotalCount: snapshot.earlierTotalCount,
                now: now
            )
            return result
        }

        let sections = Self.makeConversationSections(
            from: authoritativeConversations().filter(\.isVisibleInUngroupedConversationList),
            now: now
        )
        return sections.map { section, conversations in
            if section == .earlier {
                let displayConversations = Array(conversations.prefix(earlierLimit))
                return HomeConversationSectionState(
                    section: section,
                    conversations: displayConversations,
                    remainingCount: max(0, conversations.count - displayConversations.count)
                )
            }
            return HomeConversationSectionState(
                section: section,
                conversations: conversations,
                remainingCount: 0
            )
        }
    }

    var localMonthlyCostSummary: MonthlyCostSummary {
        refreshCachesIfNeeded()
        return cachedMonthlyCostSummary
    }

    var localMonthlyCostByProvider: [UUID: Double] {
        refreshCachesIfNeeded()
        return cachedMonthlyCostByProvider
    }

    var localMonthlyActivityByProvider: [UUID: ProviderMonthlyActivity] {
        refreshCachesIfNeeded()
        return cachedMonthlyActivityByProvider
    }

    var draftConversation: Conversation? {
        conversations.first(where: \.isDraft)
    }

    var pinnedConversations: [Conversation] {
        let ids = appState.preferences.pinnedConversationIDs
        guard !ids.isEmpty else { return [] }

        let version = appState.conversationsVersion
        if cachedPinnedVersion == version, cachedPinnedIDs == ids {
            return cachedPinnedConversations
        }

        let resolved = resolvePinnedConversations(ids: ids)
        cachedPinnedConversations = resolved
        cachedPinnedVersion = version
        cachedPinnedIDs = ids
        return resolved
    }

    private func resolvePinnedConversations(ids: [UUID]) -> [Conversation] {
        // The in-memory mirror, when non-empty, is the whole conversation table: resolve by id from memory
        // and skip the store (it may still hold a conversation whose removal is queued).
        if !conversations.isEmpty {
            return ids.compactMap { appState.conversation(for: $0) }
                .filter(\.isVisibleInConversationList)
        }
        let ordering = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let partitionUID = appState.sessionPartitionUID
        if appState.prefersAuthoritativeConversationStore,
           DatabaseManager.shared.hasDatabase(for: partitionUID),
           let summaries = try? appState.conversationRuntimeBridge.fetchConversationSummaryProjections(
               ids: ids,
               uid: partitionUID
           ) {
            return summaries
                .filter(\.isVisibleInConversationList)
                .sorted { (ordering[$0.id] ?? .max) < (ordering[$1.id] ?? .max) }
        }

        return []
    }

    func togglePin(conversationID: UUID) {
        var current = appState.preferences.pinnedConversationIDs
        if let idx = current.firstIndex(of: conversationID) {
            current.remove(at: idx)
        } else {
            current.append(conversationID)
        }
        var preferences = appState.preferences
        preferences.pinnedConversationIDs = current
        preferences.pinnedConversationIDsUpdatedAt = nowProvider()
        appState.preferences = preferences
        AppPreferencesStore.save(preferences)
        cachedHomeSnapshot = nil
        cachedHomeSnapshotVersion = .max
        cachedHomeSections = nil
    }

    func isPinned(_ conversationID: UUID) -> Bool {
        appState.preferences.pinnedConversationIDs.contains(conversationID)
    }

    func filteredConversations(matching query: String) -> [Conversation] {
        refreshCachesIfNeeded()
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return cachedRecentConversations }

        if let cached = cachedSearchResults[normalizedQuery.lowercased()] {
            return cached
        }
        return inMemorySearchResults(matching: normalizedQuery, allowAuthoritativeFallback: false)
    }

    func searchConversations(matching query: String) async -> [Conversation] {
        refreshCachesIfNeeded()
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return cachedRecentConversations }

        let cacheKey = normalizedQuery.lowercased()
        if let cached = cachedSearchResults[cacheKey] {
            return cached
        }

        let versionAtStart = appState.conversationsVersion
        let filtered: [Conversation]
        if let authoritative = await authoritativeSearchResults(matching: normalizedQuery) {
            filtered = projectSearchHitsOntoMemory(authoritative)
        } else {
            filtered = inMemorySearchResults(matching: normalizedQuery, allowAuthoritativeFallback: true)
        }
        if appState.conversationsVersion == versionAtStart {
            cachedSearchResults[cacheKey] = filtered
        }
        return filtered
    }

    /// The store's full-text search only says which ids match and in what order. While the in-memory mirror
    /// is non-empty it is the whole conversation table: drop hits memory no longer has (removal still queued
    /// for the store) and use the memory row, which may be newer than the stored title or folder.
    private func projectSearchHitsOntoMemory(_ hits: [Conversation]) -> [Conversation] {
        guard !conversations.isEmpty else { return hits }
        return hits.compactMap { appState.conversation(for: $0.id) }
    }

    private func inMemorySearchResults(
        matching normalizedQuery: String,
        allowAuthoritativeFallback: Bool
    ) -> [Conversation] {
        let searchSource: [Conversation]
        if conversations.isEmpty, allowAuthoritativeFallback {
            searchSource = authoritativeConversations()
        } else {
            searchSource = conversations
        }
        let visibleConversations = searchSource.filter(\.isVisibleInConversationList)
        return visibleConversations.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(normalizedQuery) ||
            conversation.previewText.localizedCaseInsensitiveContains(normalizedQuery) ||
            conversation.messages.contains { $0.text.localizedCaseInsensitiveContains(normalizedQuery) }
        }
    }


    func deleteConversation(id: UUID) {
        guard let conversation = conversations.first(where: { $0.id == id }) else {
            appState.deleteConversationProjection(id: id)
            return
        }
        deleteConversations([conversation]) {
            appState.deleteConversationProjection(id: id)
        }
    }

    func deleteConversations(ids: Set<UUID>) {
        let toRemove = conversations.filter { ids.contains($0.id) }
        deleteConversations(toRemove) {
            appState.deleteConversationProjections(ids: ids)
        }
    }

    /// Removes the conversations' on-device images before deleting them. Cold-start memory is a
    /// summary (no messages), so attachment references are read from the database, and they must be
    /// read before the rows are deleted.
    private func deleteConversations(_ toRemove: [Conversation], deleteProjection: () -> Task<Bool, Never>) {
        for conv in toRemove {
            if conv.messages.contains(where: { $0.state == .generating })
                || appState.streamingConversationIDs.contains(conv.id) {
                // An interruption caused by deleting the conversation is not a user stop, so chat_message_stopped is not reported.
                appState.chatManager.cancelGeneration(in: conv.id, userInitiated: false)
            }
        }
        let partitionUID = AppSessionStore.activeUID
        let imageCandidates = Self.imagePurgeCandidates(attachmentCleanupRefs(for: toRemove))
        // The reference-set connection is fixed before the delete (main thread, partition already open): the row
        // delete runs on the persist queue, and the image purge waits for it to commit.
        let imageReferences = imageCandidates.isEmpty ? nil : imageReferenceReader(partitionUID: partitionUID)
        let committed = deleteProjection()
        if let imageReferences {
            // Purge after the delete commits, by reference set: files that conflict copies still reference are not removed. Nothing is purged if the delete failed.
            pendingImagePurge = Task.detached(priority: .utility) {
                guard await committed.value else { return }
                ImageOrphanSweeper.purgeUnreferencedImages(
                    imageCandidates, partitionUID: partitionUID, references: imageReferences
                )
            }
        }
    }

    private func attachmentCleanupRefs(for conversations: [Conversation]) -> [ConversationStore.AttachmentCleanupRef] {
        var refs = conversations.filter(\.messagesAreLoaded).flatMap { conversation in
            conversation.messages.flatMap { message in
                (message.attachments ?? []).map {
                    ConversationStore.AttachmentCleanupRef(id: $0.id, kind: $0.kind, localImageID: $0.localImageID)
                }
            }
        }
        let unloadedIDs = conversations.filter { !$0.messagesAreLoaded }.map(\.id)
        if !unloadedIDs.isEmpty {
            refs += (try? appState.conversationRuntimeBridge.fetchAttachmentCleanupRefs(
                conversationIDs: unloadedIDs,
                uid: appState.sessionPartitionUID
            )) ?? []
        }
        return refs
    }

    func renameConversation(id: UUID, newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        var updated = conversations[index]
        updated.title = trimmed
        updated.hasCustomTitle = true
        updated.metadataUpdatedAt = Date()
        appState.upsertConversationProjection(updated)
    }

    /// Sets the conversation instructions: normalize and change only
    /// `instructions` (business `updatedAt` untouched), then persist.
    /// Returns false when the value is unchanged (no write).
    @discardableResult
    func setInstructions(id: UUID, text: String) -> Bool {
        let normalized = ConversationInstructions.normalize(text)
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return false }
        var updated = conversations[index]
        guard updated.instructions != normalized else { return false }
        updated.instructions = normalized
        appState.upsertConversationProjection(updated)
        return true
    }

    /// Sets the per-conversation context cap (nil = follow global). Like `setInstructions`: only
    /// `contextCap` changes (business `updatedAt` untouched), then persist.
    /// Returns false when the value is unchanged (no write).
    @discardableResult
    func setContextCap(id: UUID, cap: ContextBudgetCap?) -> Bool {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return false }
        var updated = conversations[index]
        guard updated.contextCap != cap else { return false }
        updated.contextCap = cap
        appState.upsertConversationProjection(updated)
        // The usage ring and panel recompute their denominator now, not at the next send.
        NotificationCenter.default.post(
            name: .contextUsageInputsDidChange,
            object: nil,
            userInfo: [ContextCompactionStore.conversationIdKey: id.uuidString]
        )
        return true
    }

    func updateDraftText(_ text: String, in conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = conversations[index]
        updated.draftText = text

        // Cold-start summary projections leave `messages` empty, but
        // `displayMessageCount` still means the thread exists. An empty in-memory
        // body is not "this is an empty draft".
        let hasThread = updated.displayMessageCount > 0

        if trimmed.isEmpty {
            if !hasThread {
                updated.previewText = ""
                updated.isDraft = true
            } else {
                let threadMessages: [ChatMessage] = {
                    if !updated.messages.isEmpty { return updated.messages }
                    guard isBound else { return [] }
                    return (try? appState.conversationRuntimeBridge.fetchConversationProjections(
                        ids: [conversationID],
                        uid: appState.sessionPartitionUID,
                        hydrateFilePayloads: false
                    ))?.first?.messages ?? []
                }()
                if let lastDelivered = ConversationListMetadata.lastDeliveredMessage(in: threadMessages) {
                    updated.previewText = ConversationListMetadata.makePreviewText(for: lastDelivered)
                }
                updated.isDraft = false
            }
        } else {
            updated.previewText = trimmed
            updated.isDraft = !hasThread
        }

        appState.upsertConversationProjection(updated)
    }

    func refreshConversationCost(for conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        var updated = conversations[index]
        updated.estimatedCost = updated.messages
            .filter { $0.state == .delivered && $0.estimatedCost > CostFormatter.costEpsilon }
            .map(\.estimatedCost)
            .reduce(0, +)
        appState.upsertConversationProjection(updated)
    }


    private func refreshCachesIfNeeded(now: Date? = nil) {
        let currentNow = now ?? nowProvider()
        let dayKey = Self.dayKey(for: currentNow)
        let monthKey = Self.monthKey(for: currentNow)

        let versionChanged = cachedConversationVersion != appState.conversationsVersion
        let dayChanged = cachedDayKey != dayKey
        let monthChanged = cachedMonthKey != monthKey
        let cacheIsEmptyButMayHaveData = cachedRecentConversations.isEmpty && conversations.isEmpty

        guard versionChanged || dayChanged || monthChanged || cacheIsEmptyButMayHaveData else { return }

        if versionChanged || cacheIsEmptyButMayHaveData {
            let source = conversations.isEmpty ? authoritativeConversations() : conversations
            rebuildCaches(
                from: source,
                now: currentNow,
                dayKey: dayKey,
                monthKey: monthKey
            )
        } else {
            refreshTimeDerivedCaches(now: currentNow, dayKey: dayKey, monthKey: monthKey)
        }
    }

    func handleConversationsDidChange(now: Date? = nil) {
        rebuildCaches(from: conversations, now: now ?? nowProvider())
    }

    private func rebuildCaches(
        from sourceConversations: [Conversation],
        now: Date = Date(),
        dayKey: String? = nil,
        monthKey: String? = nil
    ) {
        let ungroupedConversations = sourceConversations
            .filter(\.isVisibleInUngroupedConversationList)
            .sorted { $0.updatedAt > $1.updatedAt }

        let allActiveConversations = sourceConversations
            .filter(\.isVisibleInConversationList)

        cachedRecentConversations = ungroupedConversations
        cachedRecentConversationSections = Self.makeConversationSections(
            from: ungroupedConversations,
            now: now
        )
        let costAggregates = monthlyCostAggregates(from: allActiveConversations, now: now)
        cachedMonthlyCostSummary = CostSummaryCalculator.makeMonthlySummary(
            from: costAggregates,
            providers: appState.providers
        )
        cachedMonthlyCostByProvider = CostSummaryCalculator.monthlyCostByProvider(from: costAggregates)
        cachedMonthlyActivityByProvider = CostSummaryCalculator.monthlyActivityByProvider(from: costAggregates)
        cachedSearchResults.removeAll(keepingCapacity: true)
        cachedConversationVersion = appState.conversationsVersion
        cachedDayKey = dayKey ?? Self.dayKey(for: now)
        cachedMonthKey = monthKey ?? Self.monthKey(for: now)
        cachedHomeSnapshot = nil
        cachedHomeSnapshotVersion = .max
        cachedHomeSections = nil
    }

    private func authoritativeConversations() -> [Conversation] {
        let partitionUID = appState.sessionPartitionUID
        guard appState.prefersAuthoritativeConversationStore,
              DatabaseManager.shared.hasDatabase(for: partitionUID) else {
            return conversations
        }
        // Cache rebuild and grouping only need conversation rows. Message bodies
        // come from FTS / the chat window on demand; cold start no longer hydrates the store.
        return (try? appState.conversationRuntimeBridge.fetchConversationSummaryProjection(
            uid: partitionUID
        )) ?? conversations
    }

    private func monthlyCostAggregates(
        from conversations: [Conversation],
        now: Date
    ) -> [MonthlyCostAggregate] {
        // Conversations with a loaded thread use memory (a background write may not have landed yet);
        // the rest are aggregated in SQL.
        let hydrated = conversations.filter { $0.messagesAreLoaded && !$0.messages.isEmpty }
        let hydratedIDs = Set(hydrated.map(\.id))
        let fromMemory = CostSummaryCalculator.aggregates(from: hydrated, now: now)
        let fromStore = (try? appState.conversationRuntimeBridge.fetchMonthlyCostAggregates(
            uid: appState.sessionPartitionUID,
            now: now,
            excludingConversationIDs: hydratedIDs
        )) ?? []
        return fromMemory + fromStore
    }

    private func authoritativeSearchResults(matching query: String) async -> [Conversation]? {
        let partitionUID = appState.sessionPartitionUID
        guard appState.prefersAuthoritativeConversationStore,
              DatabaseManager.shared.hasDatabase(for: partitionUID) else {
            return nil
        }
        return try? await appState.conversationRuntimeBridge.searchConversationProjections(
            query: query,
            uid: partitionUID
        )
    }

    private func authoritativeHomeConversationSnapshot(
        earlierLimit: Int,
        now: Date
    ) -> HomeConversationSnapshot? {
        let partitionUID = appState.sessionPartitionUID
        guard appState.prefersAuthoritativeConversationStore,
              DatabaseManager.shared.hasDatabase(for: partitionUID) else {
            return nil
        }

        let version = appState.conversationsVersion
        let dayKey = Self.dayKey(for: now)
        if let cached = cachedHomeSnapshot,
           cachedHomeSnapshotVersion == version,
           cachedHomeSnapshotDayKey == dayKey,
           cachedHomeSnapshotEarlierLimit >= earlierLimit {
            return cached
        }

        guard let snapshot = try? appState.conversationRuntimeBridge.fetchHomeConversationSnapshot(
            uid: partitionUID,
            earlierLimit: earlierLimit,
            now: now
        ) else {
            return nil
        }

        cachedHomeSnapshot = snapshot
        cachedHomeSnapshotVersion = version
        cachedHomeSnapshotDayKey = dayKey
        cachedHomeSnapshotEarlierLimit = earlierLimit
        return snapshot
    }

    private func refreshTimeDerivedCaches(now: Date, dayKey: String, monthKey: String) {
        cachedRecentConversationSections = Self.makeConversationSections(
            from: cachedRecentConversations,
            now: now
        )
        if cachedMonthKey != monthKey {
            let allActive = conversations.filter(\.isVisibleInConversationList)
            let costAggregates = monthlyCostAggregates(from: allActive, now: now)
            cachedMonthlyCostSummary = CostSummaryCalculator.makeMonthlySummary(
                from: costAggregates,
                providers: appState.providers
            )
            cachedMonthlyCostByProvider = CostSummaryCalculator.monthlyCostByProvider(from: costAggregates)
            cachedMonthlyActivityByProvider = CostSummaryCalculator.monthlyActivityByProvider(from: costAggregates)
        }
        cachedDayKey = dayKey
        cachedMonthKey = monthKey
    }

    private static func makeConversationSections(
        from conversations: [Conversation],
        now: Date
    ) -> [(ConversationSection, [Conversation])] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday)!

        var today: [Conversation] = []
        var yesterday: [Conversation] = []
        var past7Days: [Conversation] = []
        var earlier: [Conversation] = []

        for conversation in conversations {
            if conversation.updatedAt >= startOfToday && conversation.updatedAt < startOfTomorrow {
                today.append(conversation)
            } else if conversation.updatedAt >= startOfYesterday && conversation.updatedAt < startOfToday {
                yesterday.append(conversation)
            } else if conversation.updatedAt >= sevenDaysAgo {
                past7Days.append(conversation)
            } else {
                earlier.append(conversation)
            }
        }

        var sections: [(ConversationSection, [Conversation])] = []
        if !today.isEmpty { sections.append((.today, today)) }
        if !yesterday.isEmpty { sections.append((.yesterday, yesterday)) }
        if !past7Days.isEmpty { sections.append((.past7Days, past7Days)) }
        if !earlier.isEmpty { sections.append((.earlier, earlier)) }
        return sections
    }

    private static func makeHomeConversationSections(
        recentConversations: [Conversation],
        earlierConversations: [Conversation],
        earlierTotalCount: Int,
        now: Date
    ) -> [HomeConversationSectionState] {
        let recentSections = makeConversationSections(
            from: recentConversations,
            now: now
        ).filter { $0.0 != .earlier }

        var sections = recentSections.map { section, conversations in
            HomeConversationSectionState(
                section: section,
                conversations: conversations,
                remainingCount: 0
            )
        }

        if !earlierConversations.isEmpty || earlierTotalCount > 0 {
            sections.append(
                HomeConversationSectionState(
                    section: .earlier,
                    conversations: earlierConversations,
                    remainingCount: max(0, earlierTotalCount - earlierConversations.count)
                )
            )
        }

        return sections
    }

    private static func dayKey(for date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    private static func monthKey(for date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)"
    }


    /// The most recent background image purge; tests wait on it.
    private(set) var pendingImagePurge: Task<Void, Never>?

    @discardableResult
    func cleanupDiskImages(
        in convos: [Conversation],
        partitionUID: String = AppSessionStore.activeUID
    ) -> Task<Void, Never>? {
        let refs = convos.flatMap { conv in
            conv.messages.flatMap { msg in
                (msg.attachments ?? []).map {
                    ConversationStore.AttachmentCleanupRef(id: $0.id, kind: $0.kind, localImageID: $0.localImageID)
                }
            }
        }
        return cleanupDiskImages(candidates: Self.imagePurgeCandidates(refs), partitionUID: partitionUID)
    }

    /// Image candidate keys of the deleted attachments. Downloaded originals are stored under the
    /// attachment.id key while locally imported images use localImageID; both are candidates, otherwise
    /// originals restored on another device would stay on disk forever.
    private static func imagePurgeCandidates(_ refs: [ConversationStore.AttachmentCleanupRef]) -> Set<String> {
        var candidates = Set<String>()
        for att in refs {
            if let lid = att.localImageID, !lid.isEmpty { candidates.insert(lid) }
            if att.kind == .image { candidates.insert(att.id.uuidString) }
        }
        return candidates
    }

    /// The caller captures the partition when the deletion starts: reading it at deletion time would fall
    /// back to the guest partition after sign-out (a no-op), leaving the account's image files behind. The
    /// reference set's database connection is bound on the main thread; reading it and deleting files both
    /// happen in the background.
    @discardableResult
    private func cleanupDiskImages(candidates: Set<String>, partitionUID: String) -> Task<Void, Never>? {
        guard !candidates.isEmpty, let references = imageReferenceReader(partitionUID: partitionUID) else { return nil }
        let task = Task.detached(priority: .utility) {
            ImageOrphanSweeper.purgeUnreferencedImages(candidates, partitionUID: partitionUID, references: references)
            return
        }
        pendingImagePurge = task
        return task
    }

    private func imageReferenceReader(partitionUID: String) -> ImageOrphanSweeper.ReferenceReader? {
        let bridge = isBound ? appState.conversationRuntimeBridge : ConversationRuntimeBridge()
        return try? bridge.imageReferenceReader(uid: partitionUID)
    }
}
