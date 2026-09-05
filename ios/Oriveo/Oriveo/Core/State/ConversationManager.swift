import Foundation

struct HomeConversationSnapshot {
    let recentConversations: [Conversation]
    let earlierConversations: [Conversation]
    let earlierTotalCount: Int
}

enum ConversationProjectionMerger {
    static func merge(preferred: [Conversation], fallback: [Conversation]) -> [Conversation] {
        guard !preferred.isEmpty else { return fallback.sorted(by: sort) }
        guard !fallback.isEmpty else { return preferred.sorted(by: sort) }

        var mergedByID = Dictionary(uniqueKeysWithValues: fallback.map { ($0.id, $0) })
        for conversation in preferred {
            if let existing = mergedByID[conversation.id] {
                mergedByID[conversation.id] = preferredConversation(
                    preferred: conversation,
                    fallback: existing
                )
            } else {
                mergedByID[conversation.id] = conversation
            }
        }

        let preferredIDs = Set(preferred.map(\.id))
        let orderedIDs = preferred.map(\.id) + fallback.map(\.id).filter { !preferredIDs.contains($0) }
        let stableOrder = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) })

        return mergedByID.values.sorted { lhs, rhs in
            if sort(lhs, rhs) {
                return true
            }
            if sort(rhs, lhs) {
                return false
            }
            return (stableOrder[lhs.id] ?? .max) < (stableOrder[rhs.id] ?? .max)
        }
    }

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

        if preferred.messages.count != fallback.messages.count {
            return preferred.messages.count > fallback.messages.count ? preferred : fallback
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

        if recovered.messages.count > authoritative.messages.count,
           recovered.displayMessageCount >= authoritative.displayMessageCount {
            return true
        }

        let recoveredMetadataUpdatedAt = recovered.metadataUpdatedAt ?? .distantPast
        let authoritativeMetadataUpdatedAt = authoritative.metadataUpdatedAt ?? .distantPast
        if recoveredMetadataUpdatedAt > authoritativeMetadataUpdatedAt,
           recovered.displayMessageCount >= authoritative.displayMessageCount,
           recovered.messages.count >= authoritative.messages.count {
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
    private var cachedSearchResults: [String: [Conversation]] = [:]
    private var cachedConversationVersion: UInt = .max
    private var cachedDayKey = ""
    private var cachedMonthKey = ""
    private var cachedHomeSnapshot: HomeConversationSnapshot?
    private var cachedHomeSnapshotVersion: UInt = .max
    private var cachedHomeSnapshotDayKey = ""
    private var cachedHomeSnapshotEarlierLimit: Int = 0
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
        refreshCachesIfNeeded(now: now)

        if let snapshot = authoritativeHomeConversationSnapshot(earlierLimit: earlierLimit, now: now) {
            let recentInput: [Conversation]
            if conversations.isEmpty {
                recentInput = snapshot.recentConversations
            } else {
                recentInput = ConversationProjectionMerger.merge(
                    preferred: cachedRecentConversations,
                    fallback: snapshot.recentConversations
                )
            }
            #if DEBUG
            let startOfToday = Calendar.current.startOfDay(for: now)
            AppLog.info(
                "Home sections from the authoritative branch: inMemory=\(conversations.count) "
                + "cachedRecent=\(cachedRecentConversations.count) storedRecent=\(snapshot.recentConversations.count) "
                + "storedEarlier=\(snapshot.earlierConversations.count) mergedRecent=\(recentInput.count)",
                module: "Conversations"
            )
            for c in recentInput.prefix(5) {
                let age = now.timeIntervalSince(c.updatedAt)
                let isToday = c.updatedAt >= startOfToday
                AppLog.info(
                    "  recent conversation \(c.id.uuidString.prefix(8)): updatedAt=\(c.updatedAt) "
                    + "age=\(String(format: "%.0f", age))s isToday=\(isToday) draft=\(c.isDraft) "
                    + "folder=\(c.folderID?.uuidString.prefix(8) ?? "none") "
                    + "visible=\(c.isVisibleInUngroupedConversationList)",
                    module: "Conversations"
                )
            }
            #endif
            let result = Self.makeHomeConversationSections(
                recentConversations: recentInput,
                earlierConversations: snapshot.earlierConversations,
                earlierTotalCount: snapshot.earlierTotalCount,
                now: now
            )
            #if DEBUG
            AppLog.info(
                "  sections: \(result.map { "\($0.section)=\($0.conversations.count)" })",
                module: "Conversations"
            )
            #endif
            return result
        }

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

        let lookup = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { lookup[$0] }
            .filter(\.isVisibleInConversationList)
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
            filtered = authoritative
        } else {
            filtered = inMemorySearchResults(matching: normalizedQuery, allowAuthoritativeFallback: true)
        }
        if appState.conversationsVersion == versionAtStart {
            cachedSearchResults[cacheKey] = filtered
        }
        return filtered
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
            conversation.messages.contains { $0.text.localizedCaseInsensitiveContains(normalizedQuery) }
        }
    }


    func deleteConversation(id: UUID) {
        var messageCount = 0
        var ageHours = 0
        if let ci = conversations.firstIndex(where: { $0.id == id }) {
            messageCount = conversations[ci].messages.count
            ageHours = Int(Date().timeIntervalSince(conversations[ci].createdAt) / 3600)
            if conversations[ci].messages.contains(where: { $0.state == .generating }) {
                appState.cancelGeneration(in: id)
            }
            cleanupDiskImages(in: [conversations[ci]])
        }
        appState.deleteConversationProjection(id: id)
    }

    func deleteConversations(ids: Set<UUID>) {
        let toRemove = conversations.filter { ids.contains($0.id) }
        for conv in toRemove {
            if conv.messages.contains(where: { $0.state == .generating }) {
                appState.cancelGeneration(in: conv.id)
            }
        }
        cleanupDiskImages(in: toRemove)
        appState.deleteConversationProjections(ids: ids)
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

    func updateDraftText(_ text: String, in conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = conversations[index]
        updated.draftText = text

        if trimmed.isEmpty {
            if updated.messages.isEmpty {
                updated.previewText = ""
                updated.isDraft = true
            } else if let lastDelivered = ConversationListMetadata.lastDeliveredMessage(in: updated.messages) {
                updated.previewText = ConversationListMetadata.makePreviewText(for: lastDelivered)
            }
        } else {
            updated.previewText = trimmed
            updated.isDraft = updated.messages.isEmpty
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
        cachedMonthlyCostSummary = CostSummaryCalculator.makeMonthlySummary(
            from: allActiveConversations,
            providers: appState.providers,
            now: now
        )
        cachedMonthlyCostByProvider = CostSummaryCalculator.monthlyCostByProvider(from: allActiveConversations, now: now)
        cachedSearchResults.removeAll(keepingCapacity: true)
        cachedConversationVersion = appState.conversationsVersion
        cachedDayKey = dayKey ?? Self.dayKey(for: now)
        cachedMonthKey = monthKey ?? Self.monthKey(for: now)
        cachedHomeSnapshot = nil
        cachedHomeSnapshotVersion = .max
    }

    private func authoritativeConversations() -> [Conversation] {
        let partitionUID = appState.sessionPartitionUID
        guard appState.prefersAuthoritativeConversationStore,
              DatabaseManager.shared.hasDatabase(for: partitionUID) else {
            return conversations
        }
        return (try? appState.authoritativeConversationProjection(
            for: partitionUID,
            hydrateFilePayloads: false
        )) ?? conversations
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
            cachedMonthlyCostSummary = CostSummaryCalculator.makeMonthlySummary(
                from: allActive,
                providers: appState.providers,
                now: now
            )
            cachedMonthlyCostByProvider = CostSummaryCalculator.monthlyCostByProvider(from: allActive, now: now)
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


    func cleanupDiskImages(in convos: [Conversation]) {
        let partitionUID = AppSessionStore.activeUID
        for conv in convos {
            for msg in conv.messages {
                guard let atts = msg.attachments else { continue }
                for att in atts {
                    if let lid = att.localImageID {
                        ImageStore.deleteImage(for: lid, partitionUID: partitionUID)
                    }
                    if att.kind == .image {
                        ImageStore.deleteImage(for: att.id.uuidString, partitionUID: partitionUID)
                    }
                }
            }
        }
    }
}
