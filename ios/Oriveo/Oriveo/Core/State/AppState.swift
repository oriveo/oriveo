import Combine
import Observation
import SwiftUI

struct PendingSearchScrollTarget: Equatable, Sendable {
    let conversationID: UUID
    let query: String
}

enum AppStateLaunchPolicy {
    static func shouldRunProviderPriceMigration(
        seedDemoData: Bool,
        isRunningTests: Bool,
        providers: [Provider]
    ) -> Bool {
        guard !seedDemoData, !isRunningTests else { return false }
        return providers.contains(where: providerNeedsPriceMigration(_:))
    }

    private static func providerNeedsPriceMigration(_ provider: Provider) -> Bool {
        provider.kind == .openRouter && provider.models.contains { $0.promptPrice == nil }
    }
}

final class BackgroundTaskHolder: @unchecked Sendable {
    var id: UIBackgroundTaskIdentifier = .invalid

    func endOnMain() {
        if Thread.isMainThread {
            endInternal()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.endInternal()
            }
        }
    }

    private func endInternal() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

private final class AppStatePendingWorkItems: @unchecked Sendable {
    private let lock = NSLock()
    private var sessionPersistWorkItem: DispatchWorkItem?
    private var navigationPathCommitTask: Task<Void, Never>?

    var sessionPersist: DispatchWorkItem? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return sessionPersistWorkItem
        }
        set {
            lock.lock()
            sessionPersistWorkItem = newValue
            lock.unlock()
        }
    }

    var navigationPathCommit: Task<Void, Never>? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return navigationPathCommitTask
        }
        set {
            lock.lock()
            navigationPathCommitTask = newValue
            lock.unlock()
        }
    }

    func cancelAll() {
        lock.lock()
        let session = sessionPersistWorkItem
        let navigation = navigationPathCommitTask
        sessionPersistWorkItem = nil
        navigationPathCommitTask = nil
        lock.unlock()

        session?.cancel()
        navigation?.cancel()
    }
}

@MainActor
@Observable
final class AppState {
    var providerManager: ProviderManager
    var relayCatalogRefreshingProviderIDs = Set<UUID>()
    var chatManager: ChatManager
    let skillManager = SkillManager()
    let conversationRuntimeBridge = ConversationRuntimeBridge()
    private let persistsSession: Bool
    private var pendingChatAnchorUserMessageIDs: [UUID: UUID] = [:]

    var selectedTab: AppTab {
        didSet { persistSessionIfNeeded() }
    }
    var navigation = NavigationManager()
    var conversationManager = ConversationManager()
    var hasCompletedOnboarding: Bool {
        didSet { persistSessionIfNeeded() }
    }
    var providers: [Provider] {
        didSet {
            providersVersion &+= 1
            rebuildProviderLookup()
            persistSessionIfNeeded()
        }
    }
    var conversations: [Conversation] {
        didSet {
            conversationsVersion &+= 1
            rebuildConversationLookup()
            if conversationManager.isBound {
                conversationManager.handleConversationsDidChange()
            }
            persistSessionIfNeeded()
        }
    }
    var folders: [Folder] = [] {
        didSet {
            foldersVersion &+= 1
            if folderManager.isBound {
                folderManager.handleFoldersDidChange()
            }
            persistSessionIfNeeded()
        }
    }
    private(set) var foldersVersion: UInt = 0
    var folderManager = FolderManager()

    // MARK: Notes — persisted in GRDB only, deliberately outside `AppSessionSnapshot`
    var noteManager = NoteManager()
    var conversationPinnedNoteIds: [UUID: [UUID]] = [:]
    var pendingPinnedNoteIds: [UUID] = []
    var noteSummaries: [NoteSummary] = [] {
        didSet { notesVersion &+= 1 }
    }
    var trashedNoteSummaries: [NoteSummary] = [] {
        didSet { notesVersion &+= 1 }
    }
    var noteFolders: [NoteFolder] = [] {
        didSet { notesVersion &+= 1 }
    }
    private(set) var notesVersion: UInt = 0
    var pendingNoteSourceJump: NoteSourceJump?
    var activeReturnToNoteID: UUID?

    var expandedFolderIDs: Set<UUID> = []
    var preferences: AppPreference
    var pendingSuccessBanner: String?
    /// A Skill needs a provider before it can start a conversation: shown as a prompt to open provider setup.
    var showSkillProviderPrompt = false
    var hasConfiguredProviderKey: Bool {
        providers.contains { !$0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    var lastUsedModelRef: LastUsedModelRef? {
        didSet { persistSessionIfNeeded() }
    }

    var pendingSearchScrollTarget: PendingSearchScrollTarget?

    var memoryUsageCount: Int = 0
    var memoryUsageConversationIDs: Set<UUID> = []

    private(set) var partitionSwitchGeneration: UInt = 0


    /// The assistant message ID currently streaming in `conversationID`, or nil when nothing is.
    func streamingMessageID(in conversationID: UUID) -> UUID? {
        chatManager.streamingMessageID(in: conversationID)
    }

    func pendingChatAnchorUserMessageID(in conversationID: UUID) -> UUID? {
        pendingChatAnchorUserMessageIDs[conversationID]
    }

    func consumePendingChatAnchorUserMessageID(_ userMessageID: UUID, in conversationID: UUID) {
        guard pendingChatAnchorUserMessageIDs[conversationID] == userMessageID else { return }
        pendingChatAnchorUserMessageIDs.removeValue(forKey: conversationID)
    }

    func stagePendingChatAnchorUserMessageID(_ userMessageID: UUID, in conversationID: UUID) {
        pendingChatAnchorUserMessageIDs[conversationID] = userMessageID
    }

#if DEBUG
    var _testingBeforeConversationProjectionUpsert: ((Conversation) -> Void)?

    func _testingSetPendingChatAnchorUserMessageID(_ userMessageID: UUID, in conversationID: UUID) {
        pendingChatAnchorUserMessageIDs[conversationID] = userMessageID
    }
#endif

    func streamingText(in conversationID: UUID) -> String {
        chatManager.streamingText(in: conversationID)
    }

    func streamingReasoning(in conversationID: UUID) -> String {
        chatManager.streamingReasoning(in: conversationID)
    }

    func streamingReasoningSnapshot(in conversationID: UUID) -> ReasoningStreamSnapshot? {
        chatManager.streamingReasoningSnapshot(in: conversationID)
    }

    func streamingTextDidChange(in conversationID: UUID) -> AnyPublisher<Void, Never> {
        chatManager.streamingTextDidChange(in: conversationID)
    }

    func streamingReasoningDidChange(in conversationID: UUID) -> AnyPublisher<ReasoningStreamDelta, Never> {
        chatManager.streamingReasoningDidChange(in: conversationID)
    }

    func isBusyStreaming(in conversationID: UUID) -> Bool {
        chatManager.isBusyStreaming(in: conversationID)
    }

    var isAnyStreaming: Bool { chatManager.isAnyStreaming }

    var streamingConversationIDs: Set<UUID> { chatManager.streamingConversationIDs }
    @ObservationIgnored private let pendingWorkItems = AppStatePendingWorkItems()
    @ObservationIgnored private var pendingSessionPersistWorkItem: DispatchWorkItem? {
        get { pendingWorkItems.sessionPersist }
        set { pendingWorkItems.sessionPersist = newValue }
    }
    @ObservationIgnored private var pendingNavigationPathCommitTask: Task<Void, Never>? {
        get { pendingWorkItems.navigationPathCommit }
        set { pendingWorkItems.navigationPathCommit = newValue }
    }
    private let conversationPersistQueue = DispatchQueue(label: "com.oriveo.conversation-persist", qos: .utility)
    private static let conversationPersistFailureThrottle = AppLog.FailureThrottle()

    private static func reportConversationPersistFailure(_ error: Error, op: String) {
        let result = conversationPersistFailureThrottle.shouldReport(key: op)
        guard result.shouldReport else { return }
        var context = ["persist.op": op]
        if result.suppressedSinceLastReport > 0 {
            context["persist.suppressed_since_last_report"] = String(result.suppressedSinceLastReport)
        }
        AppLog.error(error, module: "persistence", context: context)
    }
    @ObservationIgnored private var providerLookup: [UUID: Provider] = [:]
    @ObservationIgnored private var conversationLookup: [UUID: Conversation] = [:]
    @ObservationIgnored private var boundPartitionUID: String
    private(set) var providersVersion: UInt = 0
    private(set) var conversationsVersion: UInt = 0
    private var lastAutoRefreshDate: Date?

    init(
        seedDemoData: Bool = false,
        sessionUID: String? = nil,
        providerSession: URLSession = .shared,
        toolCallMemory: ToolCallMemoryStore = .shared
    ) {
        let isRunningTests = AppRuntime.isRunningTests
        let requestedSessionUID = sessionUID
        providerManager = ProviderManager(session: providerSession)
        chatManager = ChatManager(providerSession: providerSession, toolCallMemory: toolCallMemory)
        persistsSession = !seedDemoData
        boundPartitionUID = requestedSessionUID ?? AppSessionStore.activeUID
        selectedTab = .home
        preferences = AppPreferencesStore.load()
        pendingSuccessBanner = nil

        if seedDemoData {
            let provider = SampleData.makeProvider(kind: .anthropic, apiKey: "sk-ant-demo-1234")
            providers = [
                provider,
                SampleData.makeProvider(kind: .openAI, apiKey: "sk-openai-demo-5678"),
                SampleData.makeProvider(kind: .gemini, apiKey: "AIza-gemini-demo-3456"),
                SampleData.makeProvider(kind: .openRouter, apiKey: "sk-or-demo-9012")
            ]
            conversations = SampleData.makeStarterConversations(provider: provider)
            hasCompletedOnboarding = true
            if let defaultModel = provider.defaultModel {
                lastUsedModelRef = LastUsedModelRef(
                    providerID: provider.id,
                    modelID: ModelResolver.preferredStoredModelIdentifier(for: defaultModel, providerKind: provider.kind)
                )
            } else {
                lastUsedModelRef = nil
            }
        } else {
            providers = []
            conversations = []
            hasCompletedOnboarding = false
            lastUsedModelRef = nil
            AppSessionStore.migrateToPartitionedStorageIfNeeded()
            loadSession(boundTo: requestedSessionUID ?? AppSessionStore.activeUID)
        }

        rebuildProviderLookup()
        rebuildConversationLookup()

        conversationManager.bind(to: self)
        folderManager.bind(to: self)
        folderManager.assignColorsIfNeeded()
        noteManager.bind(to: self)
        providerManager.bind(to: self)
        chatManager.bind(to: self)
        skillManager.bind(to: self)
        loadMemoryUsageData()

        if AppStateLaunchPolicy.shouldRunProviderPriceMigration(
            seedDemoData: seedDemoData,
            isRunningTests: isRunningTests,
            providers: providers
        ) {
            Task { [weak self] in
                guard let self else { return }
                for provider in self.providers where provider.kind == .openRouter {
                    try? await self.resyncProvider(providerID: provider.id)
                }
            }
        }

    }

    static let preview: AppState = {
        AppState(seedDemoData: true)
    }()

    nonisolated deinit {
        pendingWorkItems.cancelAll()
    }

    func prepareForPartitionSwitch() {
        partitionSwitchGeneration &+= 1
    }

    private func resetTransientNoteContext() {
        conversationPinnedNoteIds = [:]
        pendingPinnedNoteIds = []
        pendingNoteSourceJump = nil
        activeReturnToNoteID = nil
    }

    func triggerPersistSession() {
        persistSessionIfNeeded()
    }

    private func persistSessionIfNeeded() {
        guard persistsSession, !chatManager.isAnyStreaming else { return }

        let snapshot = AppSessionSnapshot(
            selectedTab: selectedTab,
            hasCompletedOnboarding: hasCompletedOnboarding || !persistableProviders.isEmpty || !conversations.isEmpty,
            providers: persistableProviders,
            conversations: nil,
            lastUsedModelRef: lastUsedModelRef,
            folders: folders
        )
        let persistedUID = boundPartitionUID

        pendingSessionPersistWorkItem?.cancel()

        var workItem: DispatchWorkItem?
        workItem = DispatchWorkItem {
            guard let workItem, !workItem.isCancelled else { return }
            AppSessionStore.save(snapshot, for: persistedUID)
        }

        pendingSessionPersistWorkItem = workItem
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3, execute: workItem!)

    }

    var primaryProvider: Provider? {
        providers.first(where: { provider in
            if case .connected = provider.status {
                return true
            }
            return false
        }) ?? providers.first
    }

    var activeModel: (provider: Provider, model: AIModel)? {
        ProviderSelectionSnapshot.activeModel(
            in: providers,
            lastUsedModelRef: lastUsedModelRef
        )
    }

    var activeModelProviderIssue: String? {
        guard let active = activeModel else { return nil }
        if case .issue(let message) = active.provider.status {
            return message
        }
        return nil
    }

    var unresolvedProviderIssue: (providerID: UUID, providerName: String, message: String)? {
        guard activeModel == nil else { return nil }
        if let ref = lastUsedModelRef, let provider = provider(for: ref.providerID) {
            if case .issue(let message) = provider.status {
                return (provider.id, provider.displayName, message)
            }
        }
        if let fallback = providers.first(where: { if case .issue = $0.status { return true }; return false }) {
            if case .issue(let message) = fallback.status {
                return (fallback.id, fallback.displayName, message)
            }
        }
        return nil
    }

    func setActiveModel(providerID: UUID, modelID: String) {
        if let provider = provider(for: providerID),
           let model = ProviderSelectionSnapshot.currentModel(storedModelID: modelID, in: provider) {
            let nextRef = LastUsedModelRef(
                providerID: providerID,
                modelID: ModelResolver.preferredStoredModelIdentifier(for: model, providerKind: provider.kind)
            )
            guard lastUsedModelRef != nextRef else { return }
            lastUsedModelRef = nextRef
            return
        }

        let nextRef = LastUsedModelRef(providerID: providerID, modelID: modelID)
        guard lastUsedModelRef != nextRef else { return }
        lastUsedModelRef = nextRef
    }

    /// Whether a subscription connection still lacks its catalog, which lets
    /// `refreshActiveProviderIfNeeded` bypass its refresh throttle.
    ///
    /// Reasoning levels are normally served from the persisted `modelFacts`
    /// (`CapabilityControlResolution.subscriptionDeclaredReasoningLevels`); this check stays as
    /// the fallback for connections the public catalog does not describe.
    nonisolated static func subscriptionCatalogColdStartGap(provider: Provider) -> Bool {
        guard provider.authMode == .subscription else { return false }
        return provider.models.contains { model in
            if model.reasoningModeAvailable && model.upstreamReasoningLevels.isEmpty { return true }
            // `upstreamAPIBackend` is the outbound-protocol source of truth on the Grok path
            // only, backfilled while fetching the catalog. Codex hard-codes the
            // `.openaiResponses` transport and never writes the field, so without the kind
            // guard it would always report a gap and defeat the refresh throttle.
            if provider.kind == .grok && model.upstreamAPIBackend == nil { return true }
            return false
        }
    }

    func refreshActiveProviderIfNeeded() async {
        guard let active = activeModel,
              active.provider.kind.supportsModelCatalogSync else { return }

        let subscriptionColdStartGap = Self.subscriptionCatalogColdStartGap(provider: active.provider)

        if !subscriptionColdStartGap,
           let lastCheckedAt = active.provider.lastCheckedAt,
           Date().timeIntervalSince(lastCheckedAt) < 6 * 60 * 60 {
            return
        }

        if let last = lastAutoRefreshDate, Date().timeIntervalSince(last) < 60 { return }
        lastAutoRefreshDate = Date()

        try? await resyncProvider(providerID: active.provider.id)
    }

    var recentConversations: [Conversation] {
        _ = conversationsVersion
        return conversationManager.recentConversations
    }

    var recentConversationSections: [(ConversationManager.ConversationSection, [Conversation])] {
        _ = conversationsVersion
        return conversationManager.recentConversationSections
    }

    func homeConversationSections(earlierLimit: Int) -> [HomeConversationSectionState] {
        _ = conversationsVersion
        return conversationManager.homeConversationSections(earlierLimit: earlierLimit)
    }

    var localMonthlyCostSummary: MonthlyCostSummary {
        _ = conversationsVersion
        return conversationManager.localMonthlyCostSummary
    }

    var localMonthlyCostByProvider: [UUID: Double] {
        _ = conversationsVersion
        return conversationManager.localMonthlyCostByProvider
    }

    var draftConversation: Conversation? {
        _ = conversationsVersion
        return conversationManager.draftConversation
    }

    func filteredConversations(matching query: String) -> [Conversation] {
        _ = conversationsVersion
        return conversationManager.filteredConversations(matching: query)
    }

    func searchConversations(matching query: String) async -> [Conversation] {
        _ = conversationsVersion
        return await conversationManager.searchConversations(matching: query)
    }

    func provider(for id: UUID) -> Provider? {
        _ = providersVersion
        return providerLookup[id]
    }

    func conversation(for id: UUID) -> Conversation? {
        _ = conversationsVersion
        return conversationLookup[id]
    }

    /// Mark leftover `.generating` assistants as interrupted after a cold start.
    private func sanitizeStaleGeneratingMessages() {
        var dirty: [Conversation] = []
        for conv in conversations {
            var hasGenerating = false
            var updated = conv
            for mi in updated.messages.indices
                where updated.messages[mi].role == .assistant
                    && updated.messages[mi].state == .generating {
                updated.messages[mi].state = .interrupted
                hasGenerating = true
            }
            if hasGenerating {
                dirty.append(updated)
            }
        }
        guard !dirty.isEmpty else { return }
        upsertConversationProjections(dirty)
    }

    func upsertConversationProjection(_ conversation: Conversation, expectedUID: String? = nil) {
        guard partitionIsStillBound(expectedUID) else { return }

        //  DB (auto-title,previewText), DB 
        var derived = conversation
        ConversationListMetadata.apply(to: &derived)
        #if DEBUG
        _testingBeforeConversationProjectionUpsert?(derived)
        #endif
        if let index = conversations.firstIndex(where: { $0.id == derived.id }) {
            conversations[index] = derived
        } else {
            conversations.insert(derived, at: 0)
        }

        let persistedUID = boundPartitionUID
        let bridge = conversationRuntimeBridge
        conversationPersistQueue.async {
            do {
                try bridge.upsertConversationWithoutReadback(conversation, uid: persistedUID)
            } catch {
                #if DEBUG
                AppLog.error(error, module: "AppState", context: ["op": "upsertConversation"])
                #endif
                Self.reportConversationPersistFailure(error, op: "upsert_conversation_projection")
            }
        }
    }

    func upsertConversationProjections(
        _ updatedConversations: [Conversation],
        expectedUID: String? = nil
    ) {
        guard !updatedConversations.isEmpty else { return }
        guard partitionIsStillBound(expectedUID) else { return }

        var nextConversations = conversations
        for updated in updatedConversations {
            if let index = nextConversations.firstIndex(where: { $0.id == updated.id }) {
                nextConversations[index] = updated
            } else {
                nextConversations.insert(updated, at: 0)
            }
        }
        conversations = nextConversations

        let persistedUID = boundPartitionUID
        let bridge = conversationRuntimeBridge
        conversationPersistQueue.async {
            do {
                _ = try bridge.upsertConversations(updatedConversations, uid: persistedUID)
            } catch {
                #if DEBUG
                AppLog.error(error, module: "AppState", context: ["op": "upsertConversations"])
                #endif
                Self.reportConversationPersistFailure(error, op: "upsert_conversation_projections")
            }
        }
    }

    func updateConversationModelProjections(_ updates: [ConversationModelUpdate]) {
        guard !updates.isEmpty else { return }

        var nextConversations = conversations
        for update in updates {
            guard let index = nextConversations.firstIndex(where: { $0.id == update.conversationID }) else { continue }
            nextConversations[index].providerID = update.providerID
            nextConversations[index].providerKind = update.providerKind
            nextConversations[index].modelID = update.modelID
            nextConversations[index].metadataUpdatedAt = update.metadataUpdatedAt
        }
        conversations = nextConversations

        let persistedUID = boundPartitionUID
        let bridge = conversationRuntimeBridge
        conversationPersistQueue.async {
            do {
                _ = try bridge.updateConversationModels(updates, uid: persistedUID)
            } catch {
                #if DEBUG
                AppLog.error(error, module: "AppState", context: ["op": "updateConversationModels"])
                #endif
                Self.reportConversationPersistFailure(error, op: "update_conversation_model_projections")
            }
        }
    }

    func replaceConversationProjectionOrThrow(
        _ replacement: [Conversation],
        persistedUID: String? = nil
    ) throws {
        let persistedUID = persistedUID ?? boundPartitionUID
        let refreshedProjection = try conversationRuntimeBridge.replaceAllConversations(replacement, uid: persistedUID)
        let refreshedByID = Dictionary(uniqueKeysWithValues: refreshedProjection.map { ($0.id, $0) })
        conversations = replacement.compactMap { conversation in
            guard let refreshed = refreshedByID[conversation.id] else { return conversation }
            return normalizeRuntimeConversation(refreshed, preservingTimestampsFrom: conversation)
        }
        syncRuntimePinnedNotesWithConversationProjection()
    }

    func replaceConversationProjection(_ replacement: [Conversation]) {
        conversations = replacement.compactMap { conv in
            if let existing = conversationLookup[conv.id], !existing.messages.isEmpty, conv.messages.isEmpty {
                var merged = conv
                merged.messages = existing.messages
                return merged
            }
            return conv
        }
        syncRuntimePinnedNotesWithConversationProjection()

        let persistedUID = boundPartitionUID
        let bridge = conversationRuntimeBridge
        conversationPersistQueue.async {
            do {
                _ = try bridge.replaceAllConversations(replacement, uid: persistedUID)
            } catch {
                #if DEBUG
                AppLog.error(error, module: "AppState", context: ["op": "replaceAllConversations"])
                #endif
                Self.reportConversationPersistFailure(error, op: "replace_conversation_projection")
            }
        }
    }

    private func syncRuntimePinnedNotesWithConversationProjection() {
        guard !conversationPinnedNoteIds.isEmpty else { return }
        let byID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0.pinnedNoteIds) })
        for convID in Array(conversationPinnedNoteIds.keys) {
            guard let pinned = byID[convID] else {
                conversationPinnedNoteIds.removeValue(forKey: convID)
                continue
            }
            conversationPinnedNoteIds[convID] = Array(pinned.suffix(Self.maxPinnedNotes))
        }
    }

    func deleteConversationProjection(id: UUID) {
        let persistedUID = boundPartitionUID
        chatManager.discardStreamingResources(for: id)
        do {
            try conversationRuntimeBridge.deleteConversation(id: id, uid: persistedUID)
            conversations.removeAll { $0.id == id }
            persistRecoverySnapshotAfterDestructiveChange()
        } catch {
            #if DEBUG
            AppLog.error(error, module: "AppState", context: ["op": "deleteConversationProjection"])
            #endif
        }
    }

    func deleteConversationProjections(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let persistedUID = boundPartitionUID
        for id in ids {
            chatManager.discardStreamingResources(for: id)
        }
        do {
            try conversationRuntimeBridge.deleteConversations(ids: Array(ids), uid: persistedUID)
            conversations.removeAll { ids.contains($0.id) }
            persistRecoverySnapshotAfterDestructiveChange()
        } catch {
            #if DEBUG
            AppLog.error(error, module: "AppState", context: ["op": "deleteConversationProjections"])
            #endif
        }
    }

    func persistRecoverySnapshotAfterDestructiveChange() {
        guard persistsSession else { return }
        let conversationsSnapshot = conversations
        let persistedUID = boundPartitionUID
        let bridge = conversationRuntimeBridge
        conversationPersistQueue.async {
            do {
                try bridge.persistRecoveryProjectionOnly(conversationsSnapshot, for: persistedUID)
            } catch {
                #if DEBUG
                AppLog.error(error, module: "AppState", context: ["op": "postDestructiveRecoveryPersist"])
                #endif
                Self.reportConversationPersistFailure(error, op: "persist_recovery_snapshot_after_destructive_change")
            }
        }
    }

    func authoritativeConversationProjection(
        for persistedUID: String? = nil,
        hydrateFilePayloads: Bool = true
    ) throws -> [Conversation] {
        try conversationRuntimeBridge.fetchConversationProjection(
            uid: persistedUID ?? boundPartitionUID,
            hydrateFilePayloads: hydrateFilePayloads
        )
    }

    var sessionPartitionUID: String {
        boundPartitionUID
    }

    /// Partition gate: an async pipeline captures the uid when it starts and checks here that
    /// the bound partition is still the same before it writes. On a mismatch the whole write
    /// must be discarded, touching neither the database nor the in-memory projections, so a
    /// record can never land in a different partition.
    func partitionIsStillBound(_ expectedUID: String?) -> Bool {
        guard let expectedUID else { return true }
        return expectedUID == boundPartitionUID
    }

    var prefersAuthoritativeConversationStore: Bool {
        persistsSession
    }

    func resetConversationProjectionMirror() {
        conversations = []
    }

    func flushConversationPersistQueue() {
        conversationPersistQueue.sync {}
    }

    func currentModel(for conversation: Conversation) -> AIModel? {
        guard let provider = provider(for: conversation.providerID) else { return nil }
        return ProviderSelectionSnapshot.currentModel(
            storedModelID: conversation.modelID,
            in: provider
        )
    }

    func startOnboarding() {
        hasCompletedOnboarding = true
    }

    func openProviderSetup(from entryPoint: ProviderSetupEntryPoint, preselectedKind: ProviderKind? = nil) {
        navigation.openProviderSetup(from: entryPoint, preselectedKind: preselectedKind)
    }

    func openProviderDetail(providerID: UUID) {
        navigation.openProviderDetail(providerID: providerID)
    }

    func openManualModelEntry(providerID: UUID, context: ManualModelEntryContext) {
        navigation.openManualModelEntry(providerID: providerID, context: context)
    }

    func openChat(conversationID: UUID) {
        navigation.openChat(conversationID: conversationID)
    }

    private func rebuildProviderLookup() {
        providerLookup = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
    }

    private func rebuildConversationLookup() {
        conversationLookup = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
    }

    private func normalizeRuntimeConversation(
        _ refreshed: Conversation,
        preservingTimestampsFrom original: Conversation
    ) -> Conversation {
        var normalized = refreshed
        normalized.createdAt = original.createdAt
        return normalized
    }

    func openBackup() {
        navigation.openBackup()
    }

    func openNotes() {
        navigation.openNotesList()
    }

    func openNoteDetail(noteID: UUID) {
        navigation.openNoteDetail(noteID: noteID)
    }

    func prepareReturnToConversation(noteID: UUID, conversationID: UUID, messageID: UUID?) {
        pendingNoteSourceJump = NoteSourceJump(
            conversationID: conversationID,
            messageID: messageID,
            fromNoteID: noteID
        )
        navigation.attemptNavigate(to: .chat(conversationID: conversationID))
    }

    // MARK: - (v1 )

    private static let maxPinnedNotes = 3

    func pinNote(_ noteID: UUID, to convID: UUID?) {
        if let convID {
            var ids = conversationPinnedNoteIds[convID] ?? []
            guard !ids.contains(noteID) else { return }
            ids.append(noteID)
            conversationPinnedNoteIds[convID] = Array(ids.suffix(Self.maxPinnedNotes))
            persistPinnedNotes(for: convID)
        } else {
            guard !pendingPinnedNoteIds.contains(noteID) else { return }
            pendingPinnedNoteIds = Array((pendingPinnedNoteIds + [noteID]).suffix(Self.maxPinnedNotes))
        }
    }

    func unpinNote(_ noteID: UUID, from convID: UUID?) {
        if let convID {
            conversationPinnedNoteIds[convID]?.removeAll { $0 == noteID }
            persistPinnedNotes(for: convID)
        } else {
            pendingPinnedNoteIds.removeAll { $0 == noteID }
        }
    }

    private func persistPinnedNotes(for convID: UUID) {
        guard var conv = conversation(for: convID) else { return }
        conv.pinnedNoteIds = conversationPinnedNoteIds[convID] ?? []
        conv.metadataUpdatedAt = Date()
        upsertConversationProjection(conv)
    }

    func seedPinnedNotes(for convID: UUID) {
        guard conversationPinnedNoteIds[convID] == nil, let conv = conversation(for: convID) else { return }
        conversationPinnedNoteIds[convID] = Array(conv.pinnedNoteIds.suffix(Self.maxPinnedNotes))
    }

    func pinnedNoteIDs(for convID: UUID?) -> [UUID] {
        if let convID { return conversationPinnedNoteIds[convID] ?? [] }
        return pendingPinnedNoteIds
    }

    func isNotePinned(_ noteID: UUID, in convID: UUID?) -> Bool {
        pinnedNoteIDs(for: convID).contains(noteID)
    }

    func commitPendingPinsIfNeeded(to convID: UUID) {
        guard !pendingPinnedNoteIds.isEmpty else { return }
        var ids = conversationPinnedNoteIds[convID] ?? []
        for n in pendingPinnedNoteIds where !ids.contains(n) { ids.append(n) }
        conversationPinnedNoteIds[convID] = Array(ids.suffix(Self.maxPinnedNotes))
        pendingPinnedNoteIds = []
        persistPinnedNotes(for: convID)
    }

    func resolvePinnedNoteSnapshots(for convID: UUID) -> [ChatRequestPinnedNoteSnapshot] {
        (conversationPinnedNoteIds[convID] ?? []).compactMap { id in
            guard let note = noteManager.note(id: id), note.deletedAt == nil else { return nil }
            return ChatRequestPinnedNoteSnapshot(id: id, title: NoteText.displayTitle(note.title), body: note.body)
        }
    }

    func openRelaySetup(from entryPoint: ProviderSetupEntryPoint) {
        navigation.openRelaySetup(from: entryPoint)
    }

    func registerRelay(name: String, endpoint: String, apiKey: String) -> Provider {
        providerManager.registerRelay(name: name, endpoint: endpoint, apiKey: apiKey)
    }

    func updateProviderName(providerID: UUID, newName: String) {
        providerManager.updateProviderName(providerID: providerID, newName: newName)
    }

    func pop() {
        navigation.pop()
    }

    func registerProvider(
        kind: ProviderKind,
        apiKey: String,
        manualModelID: String? = nil,
        baseURLText: String? = nil,
        customName: String? = nil,
        isAdditionalInstance: Bool = false,
        authMode: ProviderAuthMode = .apiKey,
        subscriptionAccountID: String? = nil
    ) async throws -> Provider {
        try await providerManager.registerProvider(
            kind: kind,
            apiKey: apiKey,
            manualModelID: manualModelID,
            baseURLText: baseURLText,
            customName: customName,
            isAdditionalInstance: isAdditionalInstance,
            authMode: authMode,
            subscriptionAccountID: subscriptionAccountID
        )
    }

    func completeProviderSetup(providerID: UUID, entryPoint: ProviderSetupEntryPoint) {
        guard let provider = provider(for: providerID),
              let defaultModel = ProviderSelectionSnapshot.defaultModel(in: provider) else {
            return
        }

        // Every successful setup selects the exact model produced by the verified persistence
        // path before navigation changes. Entry points differ only in where the caller resumes.
        setActiveModel(providerID: provider.id, modelID: defaultModel.id)

        switch entryPoint {
        case .welcome:
            let wasCompleted = hasCompletedOnboarding
            hasCompletedOnboarding = true
            if !wasCompleted {
            }
            selectedTab = .home
            commitNavigationPath([.chat(conversationID: nil)], deferringIfNeeded: !navigation.path.isEmpty)
        case .providers:
            selectedTab = .home
            commitNavigationPath([.chat(conversationID: nil)], deferringIfNeeded: !navigation.path.isEmpty)
        case .modelPicker, .skillEdit:
            navigation.path = ProviderSetupCompletionPolicy.returnedCallerPath(from: navigation.path)
        }
    }

    private func commitNavigationPath(_ path: [AppRoute], deferringIfNeeded: Bool) {
        pendingNavigationPathCommitTask?.cancel()

        guard deferringIfNeeded else {
            navigation.path = path
            pendingNavigationPathCommitTask = nil
            return
        }

        // NavigationStack swaps its root content synchronously when onboarding succeeds
        // (Welcome -> MainTab). Defer the path change by one turn so it cannot overlap the
        // in-flight push/pop transition and trip a UIKit assertion.
        pendingNavigationPathCommitTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.navigation.path = path
            self.pendingNavigationPathCommitTask = nil
        }
    }

    @discardableResult
    func saveManualModel(
        providerID: UUID,
        modelID: String,
        context: ManualModelEntryContext,
        capabilities: Set<ModelCapability>? = nil
    ) -> Bool {
        guard provider(for: providerID) != nil else { return false }
        guard providerManager.saveManualModelData(
            providerID: providerID,
            modelID: modelID,
            capabilities: capabilities
        ) else {
            return false
        }

        switch context {
        case .onboarding:
            completeProviderSetup(providerID: providerID, entryPoint: .welcome)
        case .providers:
            selectedTab = .providers
            navigation.path = []
        case .providerDetail:
            pop()
        case .modelPicker:
            pop()
        case .skillEdit:
            pop()
            pop()
        }
        return true
    }

    func resyncProvider(providerID: UUID) async throws {
        try await providerManager.resyncProvider(providerID: providerID)
    }

    func updateAPIKey(providerID: UUID, newKey: String) async throws {
        try await providerManager.updateAPIKey(providerID: providerID, newKey: newKey)
    }

    func updateBaseURL(providerID: UUID, baseURLText: String?) async throws {
        guard let provider = provider(for: providerID),
              provider.kind.usesConfigurableBaseURL else { return }
        try await providerManager.updateBaseURL(providerID: providerID, baseURLText: baseURLText)
    }

    @discardableResult
    func deleteProvider(providerID: UUID) -> Bool {
        guard provider(for: providerID) != nil,
              providerManager.removeProvider(providerID) else { return false }
        UnsupportedParamCache.shared.clearCapabilityRejections(
            connectionID: providerID.uuidString
        )
        GenerationParameterSettingsStore.shared.removeScopes(providerID: providerID)
        GenerationParameterSettingsStore.shared.removeCapabilityScopes(providerID: providerID)
        GenerationParameterPresetStore.shared.removeScopes(providerID: providerID)
        selectedTab = .providers
        navigation.path = []
        return true
    }

    func deleteConversation(id: UUID) {
        conversationManager.deleteConversation(id: id)
        GenerationParameterSettingsStore.shared.removeScopes(conversationID: id)
        GenerationParameterSettingsStore.shared.removeCapabilityScopes(conversationID: id)
    }

    func deleteConversations(ids: Set<UUID>) {
        conversationManager.deleteConversations(ids: ids)
        for id in ids {
            GenerationParameterSettingsStore.shared.removeScopes(conversationID: id)
            GenerationParameterSettingsStore.shared.removeCapabilityScopes(conversationID: id)
        }
    }

    func renameConversation(id: UUID, newTitle: String) {
        conversationManager.renameConversation(id: id, newTitle: newTitle)
    }

    func startNewChat(preferredProviderID: UUID? = nil, preferredModelID: String? = nil) {
        let resolvedProvider: Provider
        let resolvedModelID: String

        if let pid = preferredProviderID, let p = providers.first(where: { $0.id == pid }) {
            resolvedProvider = p
            resolvedModelID = preferredModelID ?? ProviderSelectionSnapshot.defaultModel(in: p)?.id ?? ""
        } else if let active = activeModel {
            resolvedProvider = active.provider
            resolvedModelID = preferredModelID ?? active.model.id
        } else {
            selectedTab = .providers
            openProviderSetup(from: .providers)
            return
        }

        setActiveModel(providerID: resolvedProvider.id, modelID: resolvedModelID)

        if case .chat = navigation.path.last {
            navigation.replaceLast(with: .chat(conversationID: nil))
        } else {
            navigation.path.append(.chat(conversationID: nil))
        }
    }

    func startNewChatWithProviderFallback() async {
        if activeModel != nil || primaryProvider != nil || !providers.isEmpty {
            startNewChat()
            return
        }
        selectedTab = .providers
        openProviderSetup(from: .providers)
    }

    func ensureActiveModelWithProviderFallback() async -> Bool {
        if activeModel != nil {
            return true
        }

        if let primary = primaryProvider,
           let defaultModel = ProviderSelectionSnapshot.defaultModel(in: primary) {
            setActiveModel(providerID: primary.id, modelID: defaultModel.id)
            return true
        }

        if !providers.isEmpty,
           let any = providers.first,
           let defaultModel = ProviderSelectionSnapshot.defaultModel(in: any) {
            setActiveModel(providerID: any.id, modelID: defaultModel.id)
            return true
        }

        selectedTab = .providers
        openProviderSetup(from: .providers)
        return false
    }

    func setDefaultModel(modelID: String, for providerID: UUID) {
        providerManager.setDefaultModel(modelID: modelID, for: providerID)
        setActiveModel(providerID: providerID, modelID: modelID)
    }

    func enableModel(modelID: String, for providerID: UUID) {
        providerManager.enableModel(modelID: modelID, for: providerID)
    }

    func disableModel(modelID: String, for providerID: UUID) {
        providerManager.disableModel(modelID: modelID, for: providerID)
        GenerationParameterSettingsStore.shared.removeScopes(providerID: providerID, modelID: modelID)
        GenerationParameterSettingsStore.shared.removeCapabilityScopes(providerID: providerID, modelID: modelID)
        GenerationParameterPresetStore.shared.removeScopes(providerID: providerID, modelID: modelID)
    }

    func selectModel(modelID: String, providerID: UUID? = nil, for conversationID: UUID?) {
        let ownerProvider: Provider?
        if let providerID {
            ownerProvider = providers.first(where: { $0.id == providerID })
        } else {
            ownerProvider = providers.first(where: {
                ProviderSelectionSnapshot.selectedModel(storedModelID: modelID, in: $0) != nil
            })
        }
        guard let ownerProvider else { return }
        let metadataUpdatedAt = Date()

        setActiveModel(providerID: ownerProvider.id, modelID: modelID)

        guard let conversationID,
              let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }

        var updated = conversations[index]
        updated.providerID = ownerProvider.id
        updated.modelID = Self.persistedConversationModelID(
            requestedModelID: modelID,
            in: ownerProvider
        )
        updated.metadataUpdatedAt = metadataUpdatedAt

        updateConversationModelProjections(
            [
                ConversationModelUpdate(
                    conversationID: updated.id,
                    providerID: updated.providerID,
                    providerKind: ownerProvider.kind,
                    modelID: updated.modelID,
                    metadataUpdatedAt: metadataUpdatedAt
                )
            ]
        )
    }

    func updateDraftText(_ text: String, in conversationID: UUID) {
        conversationManager.updateDraftText(text, in: conversationID)
    }

    func prepareConversationSelectionForSend(
        conversationID: UUID?,
        providerID: UUID,
        modelID: String?,
        needsRepair: Bool
    ) {
        guard needsRepair,
              let conversationID,
              let modelID,
              !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        selectModel(modelID: modelID, providerID: providerID, for: conversationID)
    }

    func sendMessage(
        _ text: String,
        attachments: [Attachment] = [],
        quoteContext: QuoteContext? = nil,
        in conversationID: UUID?,
        generationParameterDraftSessionID: UUID? = nil,
        capabilitySelection: ChatCapabilitySelection = ChatCapabilitySelection()
    ) async -> UUID? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || !attachments.isEmpty else { return nil }

        let targetConversationID: UUID
        let isNewConversation = conversationID == nil
        if let conversationID {
            targetConversationID = conversationID
        } else {
            guard let active = activeModel else { return nil }
            let newConversation = createConversation(provider: active.provider, modelID: active.model.id)
            upsertConversationProjection(newConversation)
            targetConversationID = newConversation.id

            if case .chat = navigation.path.last {
                navigation.replaceLast(with: .chat(conversationID: targetConversationID))
            } else {
                navigation.path.append(.chat(conversationID: targetConversationID))
            }
        }

        guard let targetConversation = conversation(for: targetConversationID) else {
            return nil
        }

        if isNewConversation,
           let generationParameterDraftSessionID,
           let provider = provider(for: targetConversation.providerID),
           let model = ProviderSelectionSnapshot.currentModel(
               storedModelID: targetConversation.modelID,
               in: provider
           ) {
            let capabilityIdentity = CapabilityPreferenceRuntimeIdentity.make(provider: provider, model: model)
            GenerationParameterSettingsStore.shared.migrateSession(
                providerID: provider.id,
                modelID: model.id,
                from: generationParameterDraftSessionID,
                to: targetConversationID,
                profileFingerprint: GenerationParameterProfileFingerprint.make(provider: provider, model: model)
            )
            GenerationParameterSettingsStore.shared.migrateCapabilitySession(
                providerID: provider.id,
                modelID: capabilityIdentity?.canonicalModelID ?? "",
                from: generationParameterDraftSessionID,
                to: targetConversationID,
                transportIdentity: capabilityIdentity?.wireValue ?? ""
            )
            GenerationParameterSettingsStore.shared.migrateLocalCustomConfiguration(
                providerID: provider.id,
                modelID: capabilityIdentity?.canonicalModelID ?? "",
                from: generationParameterDraftSessionID,
                to: targetConversationID,
                transportIdentity: capabilityIdentity?.wireValue ?? ""
            )
        }

        if provider(for: targetConversation.providerID) != nil {
        }

        guard let userMessageID = await chatManager.sendMessage(
            text,
            attachments: attachments,
            quoteContext: quoteContext,
            in: targetConversationID,
            capabilitySelection: capabilitySelection
        ) else {
            return nil
        }
        return targetConversationID
    }

    nonisolated static func persistedConversationModelID(
        requestedModelID: String,
        in provider: Provider,
        metadata: MetadataClient = .shared
    ) -> String {
        ProviderSelectionSnapshot.persistedModelID(
            requestedModelID: requestedModelID,
            in: provider,
            metadata: metadata
        ) ?? ModelResolver.resolvedProviderModelIdentifier(
            requestedModelID,
            providerKind: provider.kind
        )
    }

    func cancelGeneration(in conversationID: UUID) {
        chatManager.cancelGeneration(in: conversationID)
    }

    func editUserMessage(messageID: UUID, in conversationID: UUID) -> String? {
        chatManager.editUserMessage(messageID: messageID, in: conversationID)
    }

    func editPromptingMessage(for assistantMessageID: UUID, in conversationID: UUID) -> String? {
        chatManager.editPromptingMessage(for: assistantMessageID, in: conversationID)
    }

    func continueMessage(
        messageID: UUID,
        in conversationID: UUID,
        capabilitySelection: ChatCapabilitySelection = ChatCapabilitySelection()
    ) async {
        await chatManager.continueMessage(
            messageID: messageID,
            in: conversationID,
            capabilitySelection: capabilitySelection
        )
    }

    func regenerateMessage(
        messageID: UUID,
        in conversationID: UUID,
        capabilitySelection: ChatCapabilitySelection = ChatCapabilitySelection()
    ) async {
        await chatManager.regenerateMessage(
            messageID: messageID,
            in: conversationID,
            capabilitySelection: capabilitySelection
        )
    }

    func retryMessage(
        messageID: UUID,
        in conversationID: UUID,
        capabilitySelection: ChatCapabilitySelection = ChatCapabilitySelection(),
        localCustomFragmentDisposition: LocalCustomFragmentDisposition = .include
    ) async {
        await chatManager.retryMessage(
            messageID: messageID,
            in: conversationID,
            capabilitySelection: capabilitySelection,
            localCustomFragmentDisposition: localCustomFragmentDisposition
        )
    }

    private func createConversation(provider: Provider, modelID: String) -> Conversation {
        let storedModelID = Self.persistedConversationModelID(
            requestedModelID: modelID,
            in: provider
        )

        return Conversation(
            id: UUID(),
            title: L10n.tr("New Chat"),
            providerID: provider.id,
            providerKind: provider.kind,
            modelID: storedModelID,
            previewText: "",
            estimatedCost: 0,
            isDraft: false,
            messages: [],
            draftText: ""
        )
    }

    func loadSession(boundTo uid: String? = nil) {
        resetTransientNoteContext()
        preferences = AppPreferencesStore.load()
        let activeUID = uid ?? AppSessionStore.activeUID
        boundPartitionUID = activeUID

        let snapshot = AppSessionStore.load(for: activeUID)

        if let snapshot {
            selectedTab = snapshot.selectedTab
            providers = snapshot.providers.map { $0.recoveredFromPersistence() }
            hasCompletedOnboarding = snapshot.hasCompletedOnboarding || !snapshot.providers.isEmpty || !(snapshot.conversations ?? []).isEmpty
            lastUsedModelRef = snapshot.lastUsedModelRef
            folders = snapshot.folders ?? []    // :
        } else {
            providers = []
            folders = []
            lastUsedModelRef = nil
        }

        do {
            let recoveredProjection = conversationRuntimeBridge.loadRecoveryProjection(
                snapshot: snapshot,
                uid: activeUID
            )
            let authoritativeProjection = try conversationRuntimeBridge.loadLegacyProjection(uid: activeUID, hydrateFilePayloads: false)
            let mergedProjection = ConversationProjectionMerger.recover(
                authoritative: authoritativeProjection,
                recovered: recoveredProjection
            )

            #if DEBUG
            let now = Date()
            AppLog.info(
                "Loaded session: stored=\(authoritativeProjection.count) recovered=\(recoveredProjection.count) "
                + "merged=\(mergedProjection.count) usedMerge=\(mergedProjection != authoritativeProjection)",
                module: "Conversations"
            )
            for c in authoritativeProjection.prefix(10) {
                let age = now.timeIntervalSince(c.updatedAt)
                AppLog.info(
                    "  stored conversation \(c.id.uuidString.prefix(8)): updatedAt=\(c.updatedAt) "
                    + "age=\(String(format: "%.0f", age))s draft=\(c.isDraft) "
                    + "folder=\(c.folderID?.uuidString.prefix(8) ?? "none") messages=\(c.displayMessageCount)",
                    module: "Conversations"
                )
            }
            #endif

            if mergedProjection != authoritativeProjection {
                conversations = (try? conversationRuntimeBridge.replaceAllConversations(
                    mergedProjection,
                    uid: activeUID
                )) ?? mergedProjection
            } else {
                conversations = authoritativeProjection
            }
        } catch {
            #if DEBUG
            AppLog.error(error, module: "Conversations", context: ["op": "loadSession"])
            #endif
            conversations = conversationRuntimeBridge.loadRecoveryProjection(snapshot: snapshot, uid: activeUID)
        }

        migrateProvidersToDeterministicIDsIfNeeded(uid: activeUID)

        sanitizeStaleGeneratingMessages()

        if !providers.isEmpty || !conversations.isEmpty {
            hasCompletedOnboarding = true
        }

        loadMemoryUsageData()
        skillManager.reloadCacheForCurrentAccount()

        if !providers.isEmpty {
            Task {
                await MetadataClient.shared.ensureInitialized()
                await refreshProviderMetadata()
            }
        }
    }

    /// Refreshes the stored providers' model metadata once Metadata has initialized.
    /// Reads from the MetadataClient actor over the async path so a stale shared snapshot
    /// cannot hide a fresh value.
    func refreshProviderMetadata() async {
        guard !providers.isEmpty else { return }
        await MetadataClient.shared.ensureInitialized()

        var changed = false
        var enriched: [Provider] = []
        enriched.reserveCapacity(providers.count)

        for provider in providers {
            guard provider.kind != .relay else {
                enriched.append(provider)
                continue
            }
            var updatedProvider = provider
            let resolvedCatalog = ProviderCatalogResolver.resolve(provider: updatedProvider)
            let canonicalCatalogModels = resolvedCatalog.catalog
                .filter { !$0.isManual }
                .map(\.model)

            if !updatedProvider.catalogModels.isEmpty && !canonicalCatalogModels.isEmpty {
                updatedProvider.models = ModelResolver.makeEnabledModels(
                    from: updatedProvider.models,
                    catalogModels: canonicalCatalogModels,
                    providerKind: updatedProvider.kind,
                    legacyCatalogModels: updatedProvider.catalogModels,
                    repairLegacyAutoEnabledAll: true
                )
                updatedProvider.catalogModels = []
                updatedProvider = ModelResolver.synchronizeDefaultSelection(
                    in: updatedProvider,
                    preferredModelID: updatedProvider.defaultModel?.id
                )
            }

            let enrichedModels = updatedProvider.models.map {
                CatalogModelBuilder.enrichStoredModel($0, providerKind: updatedProvider.kind)
            }
            if enrichedModels != updatedProvider.models {
                updatedProvider.models = enrichedModels
            }

            if updatedProvider != provider {
                changed = true
            }
            enriched.append(updatedProvider)
        }

        if changed {
            providers = enriched
        }
    }

    func persistSessionNow(for persistedUID: String? = nil) {
        guard let work = makeImmediateSessionPersistWork(for: persistedUID) else { return }
        conversationPersistQueue.sync(execute: work)
    }

    func persistSessionNowOffMainThread(for persistedUID: String? = nil) async {
        guard let work = makeImmediateSessionPersistWork(for: persistedUID) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            conversationPersistQueue.async {
                work()
                continuation.resume()
            }
        }
    }

    private func makeImmediateSessionPersistWork(for persistedUID: String?) -> (@Sendable () -> Void)? {
        guard persistsSession else { return nil }
        pendingSessionPersistWorkItem?.cancel()
        let snapshot = AppSessionSnapshot(
            selectedTab: selectedTab,
            hasCompletedOnboarding: hasCompletedOnboarding || !persistableProviders.isEmpty || !conversations.isEmpty,
            providers: persistableProviders,
            conversations: nil,
            lastUsedModelRef: lastUsedModelRef,
            folders: folders
        )
        let conversationsSnapshot = conversations
        let uid = persistedUID ?? boundPartitionUID
        let bridge = conversationRuntimeBridge
        return {
            do {
                try bridge.persistRecoveryProjectionOnly(conversationsSnapshot, for: uid)
            } catch {
                #if DEBUG
                AppLog.error(error, module: "AppState", context: ["op": "recoveryImmediatePersist"])
                #endif
            }
            AppSessionStore.save(snapshot, for: uid)
        }
    }

    func persistLifecycleCriticalData(checkpoint: Bool) {
        guard persistsSession else { return }

        let persistedUID = boundPartitionUID
        let snapshot = AppSessionSnapshot(
            selectedTab: selectedTab,
            hasCompletedOnboarding: hasCompletedOnboarding || !persistableProviders.isEmpty || !conversations.isEmpty,
            providers: persistableProviders,
            conversations: nil,
            lastUsedModelRef: lastUsedModelRef,
            folders: folders
        )
        let conversationsSnapshot = conversations
        let bridge = conversationRuntimeBridge

        pendingSessionPersistWorkItem?.cancel()

        let holder = BackgroundTaskHolder()
        holder.id = UIApplication.shared.beginBackgroundTask(withName: "oriveo.persistLifecycle") {
            holder.endOnMain()
        }

        conversationPersistQueue.async {
            do {
                try bridge.persistRecoveryProjectionOnly(conversationsSnapshot, for: persistedUID)
            } catch {
                #if DEBUG
                AppLog.error(error, module: "AppState", context: ["op": "lifecycleRecoveryPersist"])
                #endif
                Self.reportConversationPersistFailure(error, op: "persist_lifecycle_recovery")
            }
            AppSessionStore.save(snapshot, for: persistedUID)
            if checkpoint {
                do {
                    try bridge.checkpoint()
                } catch {
                    #if DEBUG
                    AppLog.error(error, module: "AppState", context: ["op": "lifecycleCheckpoint"])
                    #endif
                    Self.reportConversationPersistFailure(error, op: "persist_lifecycle_checkpoint")
                }
            }
            holder.endOnMain()
        }
    }

    private var persistableProviders: [Provider] { providers }

    func updateTheme(_ theme: ThemeOption) {
        preferences.theme = theme
        preferences.themeSetByUser = true
        AppPreferencesStore.save(preferences)
    }

    func updateLanguage(_ language: LanguageOption) {
        preferences.language = language
        AppPreferencesStore.save(preferences)
    }

    func migrateLanguagePreferenceToSystem() {
        updateLanguage(.system)
    }

    // MARK: - Memory

    func saveMemory(text: String, antiForgetEnabled: Bool, antiForgetText: String) {
        preferences.memoryText = text
        preferences.memoryAntiForgetEnabled = antiForgetEnabled
        preferences.memoryAntiForgetText = antiForgetText
        preferences.memoryUpdatedAt = Date()
        AppPreferencesStore.save(preferences)
    }

    func setConversationUseMemory(_ conversationID: UUID, useMemory: Bool) {
        let persistedUID = boundPartitionUID
        let mirrorIndex = conversations.firstIndex(where: { $0.id == conversationID })
        let mirroredConversation = mirrorIndex.map { conversations[$0] }

        do {
            let refreshed = try conversationRuntimeBridge.setConversationUseMemory(
                id: conversationID,
                useMemory: useMemory,
                uid: persistedUID
            ) ?? {
                guard var updated = mirroredConversation else { return nil }
                updated.useMemory = useMemory
                return try conversationRuntimeBridge.upsertConversation(updated, uid: persistedUID)
            }()

            guard let refreshed else { return }
            let normalized = mirroredConversation.map {
                normalizeRuntimeConversation(refreshed, preservingTimestampsFrom: $0)
            } ?? refreshed

            if let mirrorIndex {
                conversations[mirrorIndex] = normalized
            } else {
                conversations.insert(normalized, at: 0)
            }
        } catch {
            #if DEBUG
            AppLog.error(error, module: "AppState", context: ["op": "setConversationUseMemory"])
            #endif
        }
    }

    func markMemoryUsedIfNeeded(in conversationID: UUID) {
        guard !memoryUsageConversationIDs.contains(conversationID) else { return }
        memoryUsageConversationIDs.insert(conversationID)
        memoryUsageCount = memoryUsageConversationIDs.count
        AppPreferencesStore.memoryUsageConversationIDs = memoryUsageConversationIDs.map(\.uuidString)
        AppPreferencesStore.memoryUsageCount = memoryUsageCount
    }

    func openMemory() {
        navigation.openMemory()
    }

    func loadMemoryUsageData() {
        let ids = AppPreferencesStore.memoryUsageConversationIDs.compactMap { UUID(uuidString: $0) }
        memoryUsageConversationIDs = Set(ids)
        memoryUsageCount = memoryUsageConversationIDs.count
    }

    // MARK: - Skills

    func openSkillsList() {
        navigation.path.append(.skillsList)
    }

    func openSkillEdit(skillID: UUID? = nil) {
        navigation.path.append(.skillEdit(skillID))
    }

    func startConversationWithSkill(_ skill: Skill) {
        let (resolvedProviderID, resolvedModelID) = resolveModelForSkill(skill)

        guard let providerID = resolvedProviderID,
              let provider = provider(for: providerID) else {
            ToastManager.shared.show(L10n.tr("You need at least one AI provider to start a conversation."))
            showSkillProviderPrompt = true
            return
        }

        let modelID = resolvedModelID ?? ProviderSelectionSnapshot.defaultModel(in: provider)?.id ?? ""

        var conversation = createConversation(provider: provider, modelID: modelID)
        conversation.title = skill.localizedName
        conversation.skillId = skill.id
        conversation.useMemory = skill.useMemory
        conversation.isDraft = true
        upsertConversationProjection(conversation)

        if case .chat = navigation.path.last {
            navigation.replaceLast(with: .chat(conversationID: conversation.id))
        } else {
            navigation.path.append(.chat(conversationID: conversation.id))
        }

        Task { await skillManager.recordUse(skill.id) }
    }

    private func resolveModelForSkill(_ skill: Skill) -> (UUID?, String?) {
        // 1. The suggested model is usable (suggestedProviderId is a ProviderKind string,
        //    not a UUID).
        if let suggestedModelId = skill.suggestedModelId,
           let suggestedProviderId = skill.suggestedProviderId {
            if let provider = providers.first(where: { $0.kind.rawValue == suggestedProviderId }),
               ProviderSelectionSnapshot.currentModel(storedModelID: suggestedModelId, in: provider) != nil {
                return (provider.id, suggestedModelId)
            }
        }

        if skill.modelCapabilityHint != "any" {
            if let match = bestModelForCapability(skill.modelCapabilityHint) {
                return (match.providerID, match.modelID)
            }
        }

        if let active = activeModel {
            return (active.provider.id, active.model.id)
        }

        return (nil, nil)
    }

    private func bestModelForCapability(_ hint: String) -> (providerID: UUID, modelID: String)? {
        let sortedProviders: [Provider]
        if let active = activeModel {
            sortedProviders = [active.provider] + providers.filter { $0.id != active.provider.id }
        } else {
            sortedProviders = providers
        }

        for provider in sortedProviders {
            for model in provider.models {
                let matched: Bool
                switch hint {
                case "reasoning":
                    matched = ModelCapabilityEvidencePresentation(
                        provider: provider,
                        model: model,
                        partitionID: boundPartitionUID
                    ).permitsDisplay(.reasoning)
                case "vision":
                    matched = ModelCapabilityEvidencePresentation(
                        provider: provider,
                        model: model,
                        partitionID: boundPartitionUID
                    ).permitsDisplay(.image)
                case "fast":
                    matched = model.id.lowercased().contains("flash")
                        || model.id.lowercased().contains("mini")
                        || model.id.lowercased().contains("haiku")
                case "large-context":
                    matched = (model.contextLength ?? 0) >= 128_000
                default:
                    matched = false
                }
                if matched {
                    return (provider.id, model.id)
                }
            }
        }
        return nil
    }

    // queueAssistantResponse through sampleContinuation live in ChatManager.
    // makeProviderError lives in AppErrors.swift.
}
