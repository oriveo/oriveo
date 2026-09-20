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
    let noteAIManager = NoteAIManager()
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
    /// Text waiting to be placed in the composer, from a starter chip in the wide-screen detail
    /// column's empty state. ChatView consumes it on appear and clears it.
    /// Prefill only, never send: the checks that run before a first message hang off the send
    /// path, and going around them would put the message ahead of them.
    var pendingComposerPrefill: String?

    /// Whether the home conversation section has already played its entrance animation
    /// (UI only, not persisted, valid for the lifetime of the app).
    ///
    /// The animation is driven by `HomeView`'s `@State contentAppeared`, and `@State` resets
    /// whenever the view is rebuilt. The wide-screen two-column layout makes rebuilds a frequent
    /// path — folding and unfolding swaps between `NavigationSplitView { HomeView }` and a bare
    /// `HomeView()` — and once a rebuild's onAppear fails to set it back, the whole conversation
    /// section sits at `opacity 0`: the home screen looks like it holds no conversations at all,
    /// not even the empty-state placeholder, while the data is perfectly fine.
    /// Visibility therefore cannot rest on a post-rebuild callback alone; once the entrance has
    /// played, this flag keeps the section visible.
    var hasPlayedHomeIntro = false

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
    nonisolated(unsafe) private static let conversationPersistFailureThrottle = AppLog.FailureThrottle()

    nonisolated private static func reportConversationPersistFailure(_ error: Error, op: String) {
        let result = conversationPersistFailureThrottle.shouldReport(key: op)
        guard result.shouldReport else { return }
        var context = ["persist.op": op]
        if result.suppressedSinceLastReport > 0 {
            context["persist.suppressed_since_last_report"] = String(result.suppressedSinceLastReport)
        }
        AppLog.error(error, module: "persistence", context: context)
    }

    /// Run a conversation persist write with SQLITE_BUSY/LOCKED/INTERRUPT retried in place.
    /// Call only on `conversationPersistQueue` so retry sleeps stay off the main thread.
    nonisolated private static func runConversationPersistWrite(op: String, _ write: () throws -> Void) {
        do {
            try SQLitePersistRetry.run(write)
        } catch {
            #if DEBUG
            AppLog.error(error, module: "AppState", context: ["op": op])
            #endif
            reportConversationPersistFailure(error, op: op)
        }
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
        noteAIManager.bind(to: self)
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
    /// Cold-start memory is a summary projection, so this has to be SQL.
    private func sanitizeStaleGeneratingMessages() {
        try? conversationRuntimeBridge.sanitizeStaleGeneratingMessages(uid: boundPartitionUID)
        // When the database cannot be opened, memory comes from the recovery snapshot (full threads)
        // and the SQL above fails, so memory is the only copy. Without settling it here a leftover
        // .generating message keeps spinning forever.
        var dirty: [Conversation] = []
        for conversation in conversations where conversation.messagesAreLoaded {
            var updated = conversation
            var hasGenerating = false
            for index in updated.messages.indices
                where updated.messages[index].role == .assistant
                    && updated.messages[index].state == .generating {
                updated.messages[index].state = .interrupted
                hasGenerating = true
            }
            if hasGenerating {
                dirty.append(updated)
            }
        }
        if !dirty.isEmpty {
            upsertConversationProjections(dirty)
        }
    }

    /// - Parameter deletingMessageIDs: Message ids removed by this change (for example an edit that
    ///   truncates the thread). The store never treats an empty `messages` as "delete everything", so
    ///   truncating to zero messages must pass them, or the old rows stay in the database.
    func upsertConversationProjection(
        _ conversation: Conversation,
        expectedUID: String? = nil,
        deletingMessageIDs: Set<UUID> = []
    ) {
        guard partitionIsStillBound(expectedUID) else { return }

        // Keep the in-memory array in sync with the metadata the DB write derives
        // (auto-title, previewText) so list UI and persistence stay aligned.
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
        conversationPersistQueue.async(qos: .userInitiated) {
            Self.runConversationPersistWrite(op: "upsert_conversation_projection") {
                try bridge.upsertConversationWithoutReadback(
                    conversation,
                    uid: persistedUID,
                    deletingMessageIDs: deletingMessageIDs
                )
            }
        }
    }

    /// Cold-start memory is a summary projection. Every path that reads or writes a conversation's
    /// messages (send, edit, retry, merge) calls this first to bring the thread back from the
    /// database; editing an empty `messages` and writing it back would lose data or fail silently.
    ///
    /// Only messages are filled in: in-memory metadata can be newer than the database (a rename or
    /// draft write may still be queued) and must not be overwritten by the stored row.
    /// - Parameter acceptsEmptyThread: Whether an empty local thread still counts as loaded when the
    ///   display count says there is history. Sending does not accept it (context would be lost).
    /// - Returns: true when memory already holds the full thread or hydration succeeded; false when the
    ///   read fails, the conversation is not in the database, or (unless accepted) the stored thread is
    ///   empty while the display count says otherwise.
    @discardableResult
    func hydrateConversationMessagesIfNeeded(
        id: UUID,
        hydrateFilePayloads: Bool = true,
        acceptsEmptyThread: Bool = false
    ) -> Bool {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return false }
        let conversation = conversations[index]
        guard !conversation.messagesAreLoaded else { return true }
        guard let fetched = try? conversationRuntimeBridge.fetchConversationProjections(
            ids: [id],
            uid: sessionPartitionUID,
            hydrateFilePayloads: hydrateFilePayloads
        ).first else {
            return false
        }
        // The count says there is history but no local message exists: sending on an empty thread
        // would silently drop context.
        if !acceptsEmptyThread, fetched.messages.isEmpty, conversation.displayMessageCount > 0 {
            return false
        }
        guard let currentIndex = conversations.firstIndex(where: { $0.id == id }) else { return false }
        var merged = conversations[currentIndex]
        merged.messages = fetched.messages
        merged.messagesAreLoaded = true
        merged.messageCountOverride = max(merged.messageCountOverride ?? 0, fetched.displayMessageCount)
        conversations[currentIndex] = merged
        return true
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
        conversationPersistQueue.async(qos: .userInitiated) {
            Self.runConversationPersistWrite(op: "upsert_conversation_projections") {
                _ = try bridge.upsertConversations(updatedConversations, uid: persistedUID)
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
        conversationPersistQueue.async(qos: .userInitiated) {
            Self.runConversationPersistWrite(op: "update_conversation_model_projections") {
                _ = try bridge.updateConversationModels(updates, uid: persistedUID)
            }
        }
    }

    func replaceConversationProjectionOrThrow(
        _ replacement: [Conversation],
        persistedUID: String? = nil
    ) throws {
        let persistedUID = persistedUID ?? boundPartitionUID
        // The readback is a summary: the database holds the bodies, so all messages and attachments are
        // not loaded into memory again. Conversations passed in with full threads keep them, which saves
        // a hydrate when one is opened right away.
        let refreshedProjection = try conversationRuntimeBridge.replaceAllConversations(replacement, uid: persistedUID)
        let refreshedByID = Dictionary(uniqueKeysWithValues: refreshedProjection.map { ($0.id, $0) })
        conversations = replacement.compactMap { conversation in
            guard var refreshed = refreshedByID[conversation.id] else { return conversation }
            refreshed = normalizeRuntimeConversation(refreshed, preservingTimestampsFrom: conversation)
            if conversation.messagesAreLoaded, !conversation.messages.isEmpty {
                refreshed.messages = conversation.messages
                refreshed.messagesAreLoaded = true
            }
            return refreshed
        }
        syncRuntimePinnedNotesWithConversationProjection()
    }

    func replaceConversationProjection(_ replacement: [Conversation]) {
        // Update memory right away, keeping the messages and load state of conversations that are streaming.
        conversations = replacement.compactMap { conv in
            if let existing = conversationLookup[conv.id], !existing.messages.isEmpty, conv.messages.isEmpty {
                var merged = conv
                merged.messages = existing.messages
                merged.messagesAreLoaded = existing.messagesAreLoaded
                return merged
            }
            return conv
        }
        syncRuntimePinnedNotesWithConversationProjection()

        let persistedUID = boundPartitionUID
        let bridge = conversationRuntimeBridge
        conversationPersistQueue.async(qos: .userInitiated) {
            Self.runConversationPersistWrite(op: "replace_conversation_projection") {
                _ = try bridge.replaceAllConversations(replacement, uid: persistedUID)
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

    /// Refresh the recovery snapshot right after a destructive change (deleting a conversation,
    /// truncating messages on edit-resend or regenerate).
    ///
    /// The snapshot is no longer written on every `conversations` change; it is written at cold
    /// start, on backgrounding and on partition switches, so a destructive change has to ask for
    /// one or the snapshot stays on the pre-change state.
    ///
    /// This refresh is best effort, not a safety guarantee: it runs on a background queue, and a
    /// full disk, a killed process or a power cut all make it silently not happen. Deleted
    /// conversations are kept from coming back by `recoveryProjectionExcludingDeleted` instead.
    /// What this protects is message truncation, which has no journal and depends on the snapshot
    /// being fresh.
    func persistRecoverySnapshotAfterDestructiveChange() {
        guard persistsSession else { return }
        let persistedUID = boundPartitionUID
        let bridge = conversationRuntimeBridge
        conversationPersistQueue.async(qos: .userInitiated) {
            Self.runConversationPersistWrite(op: "persist_recovery_snapshot_after_destructive_change") {
                try bridge.persistRecoveryProjectionFromDatabase(uid: persistedUID)
            }
        }
    }

    /// Drop conversations this device has already deleted from the cold-start recovery projection.
    ///
    /// The recovery snapshot is always dumped from the database, so "in the snapshot, not in the
    /// database" has only two sources: the user deleted it and the refresh that should have
    /// followed never landed, or the database really lost rows. The first is an everyday action,
    /// the second takes the whole SQLite transaction layer failing. Meanwhile
    /// `ConversationProjectionMerger.recover` adopts snapshot-only conversations unconditionally
    /// and `replaceAllConversations` writes the result back, so one failed snapshot refresh is
    /// enough to bring a deleted conversation back for good.
    ///
    /// The test is the deletion journal, not how fresh the snapshot looks: journal rows are
    /// written in the same transaction as the hard delete, so they cannot half-succeed. If the
    /// journal cannot be read the whole recovery projection is dropped — a database that opens
    /// but cannot answer this query is already in an unexpected state, and not recovering beats
    /// resurrecting.
    private func recoveryProjectionExcludingDeleted(
        _ recovered: [Conversation],
        uid: String
    ) -> [Conversation] {
        guard !recovered.isEmpty else { return recovered }
        let deletedIDs: Set<UUID>
        do {
            deletedIDs = try conversationRuntimeBridge.deletedConversationIDs(uid: uid)
        } catch {
            AppLog.error(error, module: "Conversations", context: ["op": "readDeletionJournal"])
            return []
        }
        guard !deletedIDs.isEmpty else { return recovered }
        return recovered.filter { !deletedIDs.contains($0.id) }
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

    /// The single entry point for opening a conversation.
    ///
    /// At regular width the detail column lives **inside the Home tab**, so writing
    /// `chatDetail` alone is not enough: while another route is still on the outer stack (a note
    /// detail, a folder detail, the skills list), the conversation opens behind that full-screen
    /// page and the user sees nothing happen. Compact pushes onto the outer stack, which covers
    /// the screen anyway, so the stack is only cleared at regular width.
    private func presentChat(conversationID: UUID?) {
        if navigation.isRegularWidth {
            selectedTab = .home
            navigation.popToRoot()
        }
        navigation.presentChat(conversationID: conversationID)
    }

    func openChat(conversationID: UUID) {
        presentChat(conversationID: conversationID)
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
            hasCompletedOnboarding = true
            selectedTab = .home
            commitNewChatNavigation(deferringIfNeeded: !navigation.path.isEmpty)
        case .providers:
            selectedTab = .home
            commitNewChatNavigation(deferringIfNeeded: !navigation.path.isEmpty)
        case .modelPicker, .skillEdit:
            navigation.returnToProviderSetupCaller()
        }
    }

    private func commitNewChatNavigation(deferringIfNeeded: Bool) {
        pendingNavigationPathCommitTask?.cancel()

        guard deferringIfNeeded else {
            navigation.resetToNewChat()
            pendingNavigationPathCommitTask = nil
            return
        }

        // NavigationStack swaps its root content synchronously when onboarding succeeds
        // (Welcome -> MainTab). Defer the path change by one turn so it cannot overlap the
        // in-flight push/pop transition and trip a UIKit assertion.
        pendingNavigationPathCommitTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.navigation.resetToNewChat()
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
            navigation.popToRoot()
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
              ProviderSetupCatalog.current().usesConfigurableBaseURL(provider.kind) else { return }
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
        navigation.popToRoot()
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

    /// Starts a new conversation with the starter text already in the composer. Whether to send
    /// it stays with the user.
    func startNewChat(withPrefilledText text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            startNewChat()
            return
        }
        pendingComposerPrefill = trimmed
        startNewChat()
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

        presentChat(conversationID: nil)
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

            presentChat(conversationID: targetConversationID)
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

        guard await chatManager.sendMessage(
            text,
            attachments: attachments,
            quoteContext: quoteContext,
            in: targetConversationID,
            capabilitySelection: capabilitySelection
        ) != nil else {
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
                recovered: recoveryProjectionExcludingDeleted(recoveredProjection, uid: activeUID)
            )

            #if DEBUG
            let now = Date()
            AppLog.info(
                "Loaded session: stored=\(authoritativeProjection.count) recovered=\(recoveredProjection.count) "
                + "merged=\(mergedProjection.count) "
                + "usedMerge=\(ConversationProjectionMerger.hasRecoveredChanges(merged: mergedProjection, authoritative: authoritativeProjection))",
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

            // Compare by id and content, not array order: the merge sorts with `sort`, SQL orders by
            // updatedAt/createdAt/id, and when updatedAt ties the orders differ. A positional compare
            // would report a recovery and rewrite the whole table.
            if ConversationProjectionMerger.hasRecoveredChanges(
                merged: mergedProjection,
                authoritative: authoritativeProjection
            ) {
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

        // Age out the deletion journal. Cold start on a background queue is fine: it only drops
        // rows past the retention window, so running it a few launches late changes nothing.
        let journalUID = activeUID
        let journalBridge = conversationRuntimeBridge
        conversationPersistQueue.async(qos: .utility) {
            try? journalBridge.pruneDeletionJournal(uid: journalUID)
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
        let uid = persistedUID ?? boundPartitionUID
        let bridge = conversationRuntimeBridge
        return {
            Self.runConversationPersistWrite(op: "persist_recovery_projection_immediate") {
                try bridge.persistRecoveryProjectionFromDatabase(uid: uid, skipIfUnchanged: true)
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
        let bridge = conversationRuntimeBridge

        pendingSessionPersistWorkItem?.cancel()

        let holder = BackgroundTaskHolder()
        holder.id = UIApplication.shared.beginBackgroundTask(withName: "oriveo.persistLifecycle") {
            holder.endOnMain()
        }

        conversationPersistQueue.async(qos: .userInitiated) {
            Self.runConversationPersistWrite(op: "persist_lifecycle_recovery") {
                try bridge.persistRecoveryProjectionFromDatabase(uid: persistedUID, skipIfUnchanged: true)
            }
            AppSessionStore.save(snapshot, for: persistedUID)
            if checkpoint {
                Self.runConversationPersistWrite(op: "persist_lifecycle_checkpoint") {
                    try bridge.checkpoint()
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
        navigation.openSkillsList()
    }

    func openSkillEdit(skillID: UUID? = nil) {
        navigation.openSkillEdit(skillID: skillID)
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

        presentChat(conversationID: conversation.id)

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
