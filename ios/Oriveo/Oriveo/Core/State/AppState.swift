import Combine
import Observation
import OriveoProviderKit
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
    /// Per-session state of the lazy verification of enabled relay models (connection -> model id -> verifying /
    /// unreachable). In memory only: written by ProviderManager, read by the model library rows; never persisted
    /// and not kept across restarts.
    var relayModelProbeStates: [UUID: [String: RelayModelProbeState]] = [:]
    var chatManager: ChatManager
    /// The confirmation gate before sending: the send waits here after context trimming and before going out,
    /// and the chat page's confirmation dialog sends the user's choice back.
    let contextCapConfirmCoordinator = ContextCapConfirmCoordinator()
    /// The confirmation gate for remote MCP tools: the tool loop suspends here and the confirmation sheet
    /// sends the user's choice back.
    let mcpConfirmationCoordinator = McpConfirmationCoordinator()
    /// The gate for a sign-in that expired mid-answer: the loop stops at that step and waits for
    /// "Re-authorize" or "Skip". Server management calls `serverReauthorized(_:)` after a successful sign-in.
    let mcpReauthorizationCoordinator = McpReauthorizationCoordinator()
    let skillManager = SkillManager()
    let conversationRuntimeBridge = ConversationRuntimeBridge()
    /// Entry point for remote MCP server records (opens the store of a partition, updates and removes).
    let mcpServerDirectory: McpServerDirectory
    private let persistsSession: Bool
    private var pendingChatAnchorUserMessageIDs: [UUID: UUID] = [:]

    /// The active window's tab. Each window has its own (see `NavigationManager.selectedTab`);
    /// this is only a convenience accessor. Persistence is triggered by each manager's `onSelectedTabChange`.
    var selectedTab: AppTab {
        get { navigation.selectedTab }
        set { navigation.selectedTab = newValue }
    }

    // MARK: - Per-window navigation

    /// The navigation manager of the first window (and of the app while no window is registered).
    let primaryNavigation = NavigationManager()
    /// Window token → that window's navigation manager. Changes only when a window registers or is released; views observe `activeWindowToken`.
    @ObservationIgnored private var windowNavigations: [UUID: NavigationManager] = [:]
    /// The window currently using `primaryNavigation`; nil means it is free and the next window to register reuses it.
    @ObservationIgnored private var primaryNavigationOwner: UUID?
    /// The active window (the one the user touched most recently). `navigation` and `openXxx()` act on it.
    private(set) var activeWindowToken: UUID?
    /// Number of registered (live) windows. The menu bar's ⌘W availability depends on it; `windowNavigations` is not observed, so the count is kept separately.
    private(set) var registeredWindowCount = 0

    /// The active window's navigation manager; falls back to `primaryNavigation` when no window is registered.
    var navigation: NavigationManager {
        activeWindowToken.flatMap { windowNavigations[$0] } ?? primaryNavigation
    }

    /// The primary manager plus every registered window's manager (deduplicated), for app-wide events that must reach every window.
    var allWindowNavigations: [NavigationManager] {
        var result = [primaryNavigation]
        for manager in windowNavigations.values where !result.contains(where: { $0 === manager }) {
            result.append(manager)
        }
        return result
    }

    /// Gets (or creates) a window's navigation manager. Idempotent, so it can be called from a view body.
    /// Hands out the primary manager when no live window holds it; otherwise creates a new one and wires its observers.
    /// When there is no active window, this window becomes the active one.
    func windowNavigation(for token: UUID) -> NavigationManager {
        if let existing = windowNavigations[token] { return existing }
        let manager: NavigationManager
        if primaryNavigationOwner == nil {
            primaryNavigationOwner = token
            manager = primaryNavigation
        } else {
            manager = NavigationManager()
            manager.onSelectedTabChange = { [weak self] in self?.persistSessionIfNeeded() }
        }
        windowNavigations[token] = manager
        registeredWindowCount = windowNavigations.count
        if activeWindowToken == nil {
            activeWindowToken = token
        }
        return manager
    }

    /// Releases a window's manager when the window closes. The primary manager is only marked free so it can be reused;
    /// releasing the active window makes one of the remaining windows active (preferring the one holding the primary manager).
    func releaseWindowNavigation(_ token: UUID) {
        guard windowNavigations.removeValue(forKey: token) != nil else { return }
        registeredWindowCount = windowNavigations.count
        if primaryNavigationOwner == token {
            primaryNavigationOwner = nil
        }
        if activeWindowToken == token {
            activeWindowToken = primaryNavigationOwner ?? windowNavigations.keys.first
        }
    }

    /// Makes a registered window the active one; an unregistered token is ignored.
    func activateWindowNavigation(_ token: UUID) {
        guard windowNavigations[token] != nil, activeWindowToken != token else { return }
        activeWindowToken = token
    }

    func isActiveWindow(_ token: UUID) -> Bool {
        activeWindowToken == token
    }

    var conversationManager = ConversationManager()
    /// The "Set as instruction" suggestion bar; tests can swap in an instance with injected defaults.
    var directiveSuggestions = DirectiveSuggestionController()
    /// The "Save to memory?" suggestion bar; in memory only.
    var memorySuggestions = MemorySuggestionController()
    /// The background memory candidate generation triggered by the latest fresh send; tests await it before reading the repository.
    @ObservationIgnored private(set) var memoryCandidateGeneration: Task<Void, Never>?
    /// Serial tail task for checkpoint-invalidation writes (see `invalidateCheckpointsAfterTruncation`).
    @ObservationIgnored private var checkpointInvalidationTail: Task<Void, Never>?
    /// Test seam: when non-nil, `memoryCandidateRepository()` returns its result (simulates a candidate repository that cannot be opened).
    @ObservationIgnored var memoryCandidateRepositoryOverride: (() -> MemoryCandidateRepository?)?
    var hasCompletedOnboarding: Bool {
        didSet { persistSessionIfNeeded() }
    }
    var providers: [Provider] {
        didSet {
            providersVersion &+= 1
            rebuildProviderLookup()
            // The needed catalogs follow the configured providers; new ones that are not loaded are
            // fetched individually.
            MetadataClient.shared.registerConfiguredProviders(providers)
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
    /// A quote waiting to be attached to the composer (new conversation that carries the summary). ChatView consumes it when it appears and resets it to nil; nothing is sent automatically.
    var pendingComposerQuote: QuoteContext?
    /// Set to true when the new-chat chain is empty but connections exist; ChatView opens the model picker when it sees this and resets it to false.
    var pendingNewChatModelPicker = false
    /// The connection a new chat that carries a summary is restricted to when the conversation's model cannot send: the draft takes its model from this
    /// connection's new-chat chain and does not write last used. Cleared on a new chat and whenever last used is written (model pick, send).
    var pendingNewChatProviderID: UUID?
    /// Instructions written in conversation settings while still a draft (no conversation yet), already normalized. On the first send they are written
    /// into the new object, saved, and then cleared; a new chat / switching conversations clears them. In memory only.
    var pendingDraftInstructions: String = ""
    /// The conversation that should show the third-trim hint; written by ChatManager, reset to nil once the UI taps "New chat" / "Got it".
    var pendingCompactionHint: UUID?
    /// Conversations with an AI summary trim in progress; written by ChatManager, and the composer shows "Organizing" and a cancel button accordingly.
    var aiCompactingConversationIDs: Set<UUID> = []

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
    /// One-shot notice for the provider detail page: "Added n models..." after setup, or the explanation when a
    /// manual setup failed verification. The page takes it when it appears and it is cleared at once, so it shows only once.
    var providerDetailNotice: ProviderDetailNotice?
    /// A Skill needs a provider before it can start a conversation: shown as a prompt to open provider setup.
    var showSkillProviderPrompt = false
    var hasConfiguredProviderKey: Bool {
        providers.contains { !$0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    var lastUsedModelRef: LastUsedModelRef? {
        didSet { persistSessionIfNeeded() }
    }

    var pendingSearchScrollTarget: PendingSearchScrollTarget?

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
    /// Test seam: parks a blocker on the persist queue so later writes and reads wait until `signal()`,
    /// which reproduces the "memory already changed, store not yet written" window deterministically.
    func _testingBlockConversationPersistQueue() -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        conversationPersistQueue.async { gate.wait() }
        return gate
    }

    var _testingBeforeConversationProjectionUpsert: ((Conversation) -> Void)?
    /// A simulated write failure when the home realtime empty conversation is deleted.
    var _testingEmptyConversationDeleteFailure: Error?
    /// A simulated write failure when a conversation is deleted (locks "read back from the database on failure").
    var _testingConversationDeleteFailure: Error?
    /// The home realtime empty conversation delete finished (after the callback): tests wait on it for the delete to end.
    var _testingAfterEmptyConversationDelete: ((UUID, Bool) -> Void)?

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

    /// The stream-finished signal for `conversationID` (completed, failed or stopped).
    func streamingDidFinish(in conversationID: UUID) -> AnyPublisher<Void, Never> {
        chatManager.streamingDidFinish(in: conversationID)
    }

    func streamingActivity(in conversationID: UUID) -> StreamActivityState? {
        chatManager.streamingActivity(in: conversationID)
    }

    func streamingActivityDidChange(in conversationID: UUID) -> AnyPublisher<StreamActivityState, Never> {
        chatManager.streamingActivityDidChange(in: conversationID)
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

    /// The three states of the local database. The real result of the cold-start read feeds it,
    /// and the UI decides from it whether to show the blocking page.
    let databaseHealthProbe = DatabaseHealthProbe()

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
            // A successful write means the path recovered. Only dispatches while degraded.
            StorageWriteHealthSignal.recordSuccess()
        } catch {
            #if DEBUG
            AppLog.error(error, module: "AppState", context: ["op": op])
            #endif
            reportConversationPersistFailure(error, op: op)
            // The log is for us, the banner is for the user. Messages come from a
            // `ValueObservation`, not an in-memory array, so saying nothing leaves the user
            // watching the model's reply vanish.
            StorageWriteHealthSignal.recordFailure(error)
        }
    }
    @ObservationIgnored private var providerLookup: [UUID: Provider] = [:]
    @ObservationIgnored private var conversationLookup: [UUID: Conversation] = [:]
    @ObservationIgnored private var boundPartitionUID: String
    /// The launch time: the grace period of the launch orphan sweep counts from it (images written during this run are never candidates). Tests can inject it.
    @ObservationIgnored let launchedAt: Date
    /// In-memory copy of the current partition's memory items: request snapshots read it, so the database is not read on the main thread.
    @ObservationIgnored let memoryItemsCache = MemoryItemsCache()
    /// Lowercased id of the memory item to edit after "This one is wrong"; the memory page takes it when it appears.
    var pendingMemoryEditItemID: String?
    private(set) var providersVersion: UInt = 0
    /// The local connection list has been loaded by `loadSession`: until then a conversation whose connection cannot be found only counts as "loading", not deleted.
    private(set) var providersLoaded = false
    private(set) var conversationsVersion: UInt = 0
    /// The model display name lookup shared by Home and folder conversation rows (built in the background, reused by
    /// fingerprint); see `ConversationModelLookupStore`.
    @ObservationIgnored let conversationModelLookupStore = ConversationModelLookupStore()
    @ObservationIgnored private nonisolated(unsafe) var metadataPublishObserver: NSObjectProtocol?
    private var lastAutoRefreshDate: Date?

    init(
        seedDemoData: Bool = false,
        sessionUID: String? = nil,
        providerSession: URLSession = .shared,
        toolCallMemory: ToolCallMemoryStore = .shared,
        mcpServerDirectory: McpServerDirectory? = nil,
        launchedAt: Date = Date()
    ) {
        self.launchedAt = launchedAt
        let isRunningTests = AppRuntime.isRunningTests
        self.mcpServerDirectory = mcpServerDirectory ?? McpServerDirectory()
        let requestedSessionUID = sessionUID
        providerManager = ProviderManager(session: providerSession)
        chatManager = ChatManager(providerSession: providerSession, toolCallMemory: toolCallMemory)
        persistsSession = !seedDemoData
        boundPartitionUID = requestedSessionUID ?? AppSessionStore.activeUID
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
            // Migrations inside loadSession write through providerManager.updateProvider, which reads
            // the unowned appState!. Bind first, or that unwraps nil; the migration flag is set in a
            // defer and never persists, so every cold launch would crash. bind only assigns, so the
            // second bind below (needed by the demo-data branch) is harmless.
            providerManager.bind(to: self)
            loadSession(boundTo: requestedSessionUID ?? AppSessionStore.activeUID)
        }

        primaryNavigation.onSelectedTabChange = { [weak self] in self?.persistSessionIfNeeded() }
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

        // Legacy relay key aliases depend on metadata resolution: register them again when the snapshot arrives after the providers (the fingerprint makes this idempotent, and unchanged connections are skipped)
        metadataPublishObserver = NotificationCenter.default.addObserver(
            forName: .metadataSnapshotDidPublish, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                CapabilityPreferenceRuntimeIdentity.registerRelayLegacyAliases(for: self.providers)
            }
        }
        #if DEBUG
        Self.liveInstancesForTesting.setObject(boundPartitionUID as NSString, forKey: self)
        #endif
    }

    #if DEBUG
    /// Test seam: the AppStates still alive in the process (weak references) -> the partition they were built for. Before a test
    /// deletes a partition it finds them by partition and waits for their in-flight reads and writes to drain (see
    /// OriveoTests/Support/TestPartitionCleanup), so cases do not have to pass instances around.
    private static let liveInstancesForTesting = NSMapTable<AppState, NSString>.weakToStrongObjects()

    /// Live instances built for, or currently bound to, one of the given partitions.
    static func liveInstancesForTesting(boundTo uids: Set<String>) -> [AppState] {
        guard let states = liveInstancesForTesting.keyEnumerator().allObjects as? [AppState] else { return [] }
        return states.filter { state in
            let initial = liveInstancesForTesting.object(forKey: state) as String?
            return uids.contains(state.boundPartitionUID) || initial.map(uids.contains) == true
        }
    }

    /// Test seam: waits until every queued background read / write tail of this AppState has drained.
    func drainPendingWrites() async {
        await memoryReconcileTail?.value
        await memoryItemUndoTail?.value
        await useMemoryWriteTail?.value
        await waitForCheckpointInvalidations()
        await chatManager.waitForContextLedgerWrites()
        await noteManager.waitForPendingWrites()
        await drainConversationPersistQueue()
    }
    #endif

    static let preview: AppState = {
        AppState(seedDemoData: true)
    }()

    nonisolated deinit {
        pendingWorkItems.cancelAll()
        if let metadataPublishObserver {
            NotificationCenter.default.removeObserver(metadataPublishObserver)
        }
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
        pendingNewChatProviderID = nil
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

    var localMonthlyActivityByProvider: [UUID: ProviderMonthlyActivity] {
        _ = conversationsVersion
        return conversationManager.localMonthlyActivityByProvider
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
        // Only the leftover ids are read here (a read does not wait for the write lock); the UPDATE for exactly those
        // ids is queued on the persist queue so the main thread never writes synchronously.
        let uid = boundPartitionUID
        let bridge = conversationRuntimeBridge
        if let staleIDs = try? bridge.staleGeneratingMessageIDs(uid: uid), !staleIDs.isEmpty {
            conversationPersistQueue.async(qos: .userInitiated) {
                Self.runConversationPersistWrite(op: "sanitize_stale_generating") {
                    try bridge.sanitizeStaleGeneratingMessages(messageIDs: staleIDs, uid: uid)
                }
            }
        }
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

    /// The attachments of this message, with file payloads guaranteed to be loaded in memory.
    ///
    /// The in-memory thread may come from a projection that does not read file payloads (window loading, observation);
    /// when a file is missing its payload, this one conversation is re-read from the database with payloads,
    /// and the attachments are returned unchanged if that fails.
    func attachmentsWithFilePayloads(of message: ChatMessage, in conversationID: UUID) -> [Attachment] {
        let attachments = message.attachments ?? []
        let missingPayload = attachments.contains {
            $0.kind == .file && ($0.base64Data?.isEmpty ?? true) && $0.extractionErrorAllowsText
        }
        guard missingPayload,
              let fetched = try? conversationRuntimeBridge.fetchConversationProjections(
                  ids: [conversationID], uid: sessionPartitionUID, hydrateFilePayloads: true
              ).first,
              let hydrated = fetched.messages.first(where: { $0.id == message.id })?.attachments
        else { return attachments }
        return hydrated
    }

    func upsertConversationProjections(
        _ updatedConversations: [Conversation],
        expectedUID: String? = nil
    ) {
        guard !updatedConversations.isEmpty else { return }
        guard partitionIsStillBound(expectedUID) else { return }

        // Index by id once: a firstIndex per update costs updates x conversations, and folder batch moves and
        // deletes come through here. The result matches replacing each match and prepending each miss in turn:
        // new conversations end up first in reverse arrival order, and a repeated new id in the same batch
        // replaces the earlier one.
        var nextConversations = conversations
        var indexByID: [UUID: Int] = [:]
        indexByID.reserveCapacity(nextConversations.count)
        for (index, conversation) in nextConversations.enumerated() where indexByID[conversation.id] == nil {
            indexByID[conversation.id] = index
        }
        var inserted: [Conversation] = []
        var insertedIndexByID: [UUID: Int] = [:]
        for updated in updatedConversations {
            if let index = indexByID[updated.id] {
                nextConversations[index] = updated
            } else if let index = insertedIndexByID[updated.id] {
                inserted[index] = updated
            } else {
                insertedIndexByID[updated.id] = inserted.count
                inserted.append(updated)
            }
        }
        if !inserted.isEmpty {
            nextConversations.insert(contentsOf: inserted.reversed(), at: 0)
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

        // Index by id once (first occurrence wins, as firstIndex did): a firstIndex per update costs updates x
        // conversations, and when a model is retired every conversation on it falls back to the default, so there are
        // as many updates as conversations.
        var nextConversations = conversations
        var indexByID: [UUID: Int] = [:]
        indexByID.reserveCapacity(nextConversations.count)
        for (index, conversation) in nextConversations.enumerated() where indexByID[conversation.id] == nil {
            indexByID[conversation.id] = index
        }
        for update in updates {
            guard let index = indexByID[update.conversationID] else { continue }
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
    ) async throws {
        let persistedUID = persistedUID ?? boundPartitionUID
        guard boundPartitionUID == persistedUID else { throw BackupError.sessionChangedDuringImport }
        // The whole-table write is queued on the persist queue so the main thread never waits on database IO.
        // The readback is a summary: the database holds the bodies, so all messages and attachments are
        // not loaded into memory again. Conversations passed in with full threads keep them, which saves
        // a hydrate when one is opened right away.
        let bridge = conversationRuntimeBridge
        let queue = conversationPersistQueue
        let refreshedProjection = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<[Conversation], Error>) in
            queue.async(qos: .userInitiated) {
                continuation.resume(with: Result {
                    try bridge.replaceAllConversations(replacement, uid: persistedUID)
                })
            }
        }
        // The partition was switched while the write ran: the memory of the new partition stays as it is.
        guard boundPartitionUID == persistedUID else { return }
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

    /// Deletes a conversation in two phases so the main thread never waits for the write lock (a whole-table write can hold it for seconds).
    /// 1. In the same main-thread turn: release streaming resources and remove it from memory.
    /// 2. Queue the row delete on the persist queue (behind whole-table writes and upserts already queued, ahead of the
    ///    recovery snapshot refresh queued right after). On success the search sources are cleared; on failure the
    ///    conversation is read back from the database into memory (the storage banner shows as for any failed write).
    /// - Returns: the outcome (true = deleted); callers that clean up images await it.
    @discardableResult
    func deleteConversationProjection(id: UUID) -> Task<Bool, Never> {
        enqueueConversationDeletion(ids: [id], op: "delete_conversation")
    }

    @discardableResult
    func deleteConversationProjections(ids: Set<UUID>) -> Task<Bool, Never> {
        guard !ids.isEmpty else { return Task { true } }
        return enqueueConversationDeletion(ids: ids, op: "delete_conversations")
    }

    private func enqueueConversationDeletion(ids: Set<UUID>, op: String) -> Task<Bool, Never> {
        let persistedUID = boundPartitionUID
        // Streaming resources must be released before the database / memory removal:
        // discardStreamingResources goes through the full cancel path first.
        for id in ids {
            chatManager.discardStreamingResources(for: id)
        }
        let writer: ConversationDeletionWriter
        do {
            writer = try conversationRuntimeBridge.conversationDeletionWriter(uid: persistedUID)
        } catch {
            // The partition database cannot be opened: change nothing and show the storage banner.
            Self.reportConversationPersistFailure(error, op: op)
            StorageWriteHealthSignal.recordFailure(error)
            return Task { false }
        }
        conversations.removeAll { ids.contains($0.id) }
        let idList = Array(ids)
        var injectedFailure: Error?
        #if DEBUG
        injectedFailure = _testingConversationDeleteFailure
        #endif
        let failure = injectedFailure
        // The row delete is queued in this turn (not inside a Task): writes the main thread queues afterwards
        // (recovery snapshot refresh, upserts) land behind it.
        let (outcomes, outcome) = AsyncStream.makeStream(of: (Bool, [Conversation]).self, bufferingPolicy: .bufferingNewest(1))
        conversationPersistQueue.async(qos: .userInitiated) {
            var deleted = false
            Self.runConversationPersistWrite(op: op) {
                if let failure { throw failure }
                try writer.delete(ids: idList)
                deleted = true
            }
            // Not deleted: read the stored conversations back so memory agrees with the database.
            outcome.yield((deleted, deleted ? [] : writer.storedConversations(ids: idList)))
            outcome.finish()
        }
        persistRecoverySnapshotAfterDestructiveChange()
        return Task { @MainActor [weak self] () -> Bool in
            var iterator = outcomes.makeAsyncIterator()
            let (deleted, stored) = await iterator.next() ?? (false, [])
            guard let self, self.partitionIsStillBound(persistedUID) else { return deleted }
            if deleted {
                self.removeSearchSources(idList)
            } else {
                let restored = stored.filter { conversation in
                    !self.conversations.contains { $0.id == conversation.id }
                }
                self.conversations.insert(contentsOf: restored, at: 0)
            }
            return deleted
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
    func deleteConversationIfEmpty(id: UUID, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let current = conversations.first(where: { $0.id == id }), current.messages.isEmpty else {
            completion(false)
            #if DEBUG
            _testingAfterEmptyConversationDelete?(id, false)
            #endif
            return
        }
        let persistedUID = boundPartitionUID
        chatManager.discardStreamingResources(for: id)
        conversations.removeAll { $0.id == id }
        completion(true)

        let bridge = conversationRuntimeBridge
        var injectedFailure: Error?
        #if DEBUG
        injectedFailure = _testingEmptyConversationDeleteFailure
        #endif
        conversationPersistQueue.async(qos: .userInitiated) { [injectedFailure] in
            var deleted = false
            Self.runConversationPersistWrite(op: "delete_empty_conversation") {
                if let injectedFailure { throw injectedFailure }
                deleted = try bridge.deleteConversationIfEmpty(id: id, uid: persistedUID)
            }
            // Not deleted: the stored conversation (if still there) is read back as is, so memory and the database agree.
            let stored = deleted ? nil : (try? bridge.fetchConversationProjections(
                ids: [id], uid: persistedUID, hydrateFilePayloads: false
            ))?.first
            Task { @MainActor [weak self, deleted, stored] in
                guard let self else { return }
                if self.partitionIsStillBound(persistedUID) {
                    if deleted {
                        self.persistRecoverySnapshotAfterDestructiveChange()
                    } else if let stored, !self.conversations.contains(where: { $0.id == id }) {
                        self.conversations.insert(stored, at: 0)
                    }
                }
                #if DEBUG
                self._testingAfterEmptyConversationDelete?(id, deleted)
                #endif
            }
        }
    }

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

    /// Waits for the writes already queued on the persist queue (without occupying the main thread).
    func drainConversationPersistQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            conversationPersistQueue.async { continuation.resume() }
        }
    }

    /// Blocks until the persist queue has drained (for tests).
    /// Not `sync {}`: when the main thread dispatch_syncs onto an idle serial queue, libdispatch lets the calling thread run
    /// the writes queued ahead itself, so the database writes would run on the main thread (a violation of the main-thread
    /// write gate). Post a signal and wait for it on the main thread instead; the queued writes still run on the queue.
    func flushConversationPersistQueue() {
        let drained = DispatchSemaphore(value: 0)
        conversationPersistQueue.async { drained.signal() }
        drained.wait()
    }

    func currentModel(for conversation: Conversation) -> AIModel? {
        guard let provider = provider(for: conversation.providerID) else { return nil }
        // Relay: a removed conversation model is not replaced.
        if provider.kind == .relay, case .removed = conversationModelState(for: conversation) { return nil }
        // An empty conversation model follows the new-chat chain (last used on this connection, then the catalog default,
        // then the first available one); the connection's isDefault is not read.
        if conversation.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallbackModel(in: provider)
        }
        return ProviderSelectionSnapshot.currentModel(
            storedModelID: conversation.modelID,
            in: provider
        )
    }

    /// Conversation model state: a relay conversation whose stored model is no longer among the connection's
    /// enabled models is `removed`; an official conversation model that was retired or is missing from the
    /// catalog is `retired` / `missing`.
    func conversationModelState(for conversation: Conversation) -> ProviderSelectionSnapshot.ConversationModelState {
        guard let provider = provider(for: conversation.providerID) else { return .resolved }
        return ProviderSelectionSnapshot.conversationModelState(
            storedModelID: conversation.modelID,
            in: provider
        )
    }

    /// The model used by send / retry / continue / regenerate: nil when the conversation model was removed, and
    /// the caller returns immediately without sending any request.
    /// A retired or missing official conversation model is nil as well; when an alias is available this returns the
    /// enabled canonical model. When an official conversation model is judged available but cannot be resolved to a
    /// model (catalog pending, bundled snapshot, ...) the stored id is sent as is: if the upstream really lacks the
    /// model it answers 404, which beats silently swapping in the default model. Relays are unchanged.
    func sendableModel(for conversation: Conversation, provider: Provider) -> AIModel? {
        if conversationModelState(for: conversation).blocksSend { return nil }
        let storedID = conversation.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !storedID.isEmpty, provider.kind != .relay, provider.authMode != .subscription else {
            return currentModel(for: conversation)
        }
        // Not through currentModel: when it cannot resolve the id it falls back to the default model by itself.
        if let model = ProviderSelectionSnapshot.selectedModel(storedModelID: storedID, in: provider) {
            return model
        }
        return AIModel(
            id: storedID,
            name: ModelResolver.displayName(forManualModelID: storedID, providerKind: provider.kind),
            capabilities: [.text],
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: false,
            priceTier: "",
            summary: nil,
            groupKey: nil,
            groupName: nil
        )
    }

    /// Fallback model for a connection = the new-chat chain limited to this connection: last used (if it points at this
    /// connection and is available), then the catalog default, then the first available one; the connection's isDefault
    /// is not read. A relay follows the same chain.
    /// Credentials are not judged: an existing conversation with an empty modelID does not end up without a model
    /// because a credential is missing; the missing-credential guard sits where a conversation is opened on a
    /// specific connection and in the summary card layout.
    func fallbackModel(in provider: Provider) -> AIModel? {
        return ProviderSelectionSnapshot.newChatModel(in: provider, lastUsedModelRef: lastUsedModelRef)
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

    func openRelayModelLibrary(providerID: UUID, keyID: String? = nil) {
        navigation.openRelayModelLibrary(providerID: providerID, keyID: keyID)
    }

    func openRelayKeys(providerID: UUID) {
        navigation.openRelayKeys(providerID: providerID)
    }

    func openRelayWebSearch(providerID: UUID) {
        navigation.openRelayWebSearch(providerID: providerID)
    }

    func openRelayModelAdvanced(providerID: UUID, modelID: String, readOnly: Bool) {
        navigation.openRelayModelAdvanced(providerID: providerID, modelID: modelID, readOnly: readOnly)
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
        // Switching conversations: pending suggestions disappear and are not counted as dismissed.
        directiveSuggestions.clearAll()
        memorySuggestions.clearAll()
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
        // Read-compat for relay parameter / capability keys: aliases are registered as providers land, without waiting for the send path to compute the identity first
        CapabilityPreferenceRuntimeIdentity.registerRelayLegacyAliases(for: providers)
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
        presentChat(conversationID: conversationID)
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
        subscriptionAccountID: String? = nil,
        endpointSource: ProviderEndpointSource? = nil,
        setupValues: [String: String]? = nil
    ) async throws -> Provider {
        try await providerManager.registerProvider(
            kind: kind,
            apiKey: apiKey,
            manualModelID: manualModelID,
            baseURLText: baseURLText,
            customName: customName,
            isAdditionalInstance: isAdditionalInstance,
            authMode: authMode,
            subscriptionAccountID: subscriptionAccountID,
            endpointSource: endpointSource,
            setupValues: setupValues
        )
    }

    func completeProviderSetup(
        providerID: UUID,
        entryPoint: ProviderSetupEntryPoint,
        verifiedModelID: String? = nil
    ) {
        guard let provider = provider(for: providerID) else { return }
        // After setup, select the model that was just verified; if it is not among the enabled models, navigate by the
        // fallback model only and do not write last used.
        let verifiedModel = verifiedModelID.flatMap {
            ModelResolver.matchingModel(modelID: $0, in: provider.models, providerKind: provider.kind)
        }
        guard verifiedModel != nil || fallbackModel(in: provider) != nil else { return }

        // Only a verified model writes last used; a fallback result only navigates.
        if let verifiedModel {
            setActiveModel(providerID: provider.id, modelID: verifiedModel.id)
        }

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

    /// Relay setup finished: the providers entry point opens the detail page with a one-shot notice; other entry points keep using `completeProviderSetup`.
    func completeRelaySetup(
        providerID: UUID,
        entryPoint: ProviderSetupEntryPoint,
        verifiedModelID: String?,
        addedModelCount: Int
    ) {
        guard entryPoint == .providers else {
            completeProviderSetup(providerID: providerID, entryPoint: entryPoint, verifiedModelID: verifiedModelID)
            return
        }
        guard let provider = provider(for: providerID) else { return }
        let verifiedModel = verifiedModelID.flatMap {
            ModelResolver.matchingModel(modelID: $0, in: provider.models, providerKind: provider.kind)
        }
        // Only a verified model writes last used; without one the fallback result is not written.
        if let verifiedModel {
            setActiveModel(providerID: provider.id, modelID: verifiedModel.id)
        }
        providerDetailNotice = ProviderDetailNotice(providerID: providerID, kind: .addedModels(addedModelCount))
        pendingNavigationPathCommitTask?.cancel()
        pendingNavigationPathCommitTask = nil
        selectedTab = .providers
        navigation.path = [.providerDetail(providerID: providerID)]
    }

    /// The detail page takes the one-shot notice that belongs to it; taking it clears it.
    func consumeProviderDetailNotice(for providerID: UUID) -> ProviderDetailNotice.Kind? {
        guard let notice = providerDetailNotice, notice.providerID == providerID else { return nil }
        providerDetailNotice = nil
        return notice.kind
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

    /// On the official detail page a template entry with placeholders was chosen: the address, the source and the template values are written together, then it syncs again.
    func updateEndpointSetup(providerID: UUID, submission: ProviderSetupSubmission) async throws {
        guard let provider = provider(for: providerID),
              ProviderSetupCatalog.current().usesConfigurableBaseURL(provider.kind) else { return }
        try await providerManager.updateEndpointSetup(providerID: providerID, submission: submission)
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
        // A wide-screen right-column selection is not on the path, so popToRoot cannot clear it; any window whose right column still points at the provider falls back to the default detail
        for manager in allWindowNavigations where manager.providersDetail == .providerDetail(providerID: providerID) {
            manager.providersDetail = nil
        }
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

        /// Deleting a conversation deletes `conversationSource:<id>` (external search services contract): hooked into the projection delete layer and the sync remote delete,
        /// so both a local delete and a delete arriving via sync clear it; file IO stays off the main thread.
    func removeSearchSources(_ ids: [UUID]) {
        let store = SearchServiceStore(scope: sessionPartitionUID)
        let keys = ids.map(\.uuidString)
        Task.detached(priority: .utility) { try? await store.removeConversationSources(keys) }
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

    /// Returns whether the chat page was opened; false when routed to the connection detail or to adding a connection.
    @discardableResult
    func startNewChat(
        preferredProviderID: UUID? = nil,
        preferredModelID: String? = nil,
        recordsLastUsed: Bool = true
    ) -> Bool {
        pendingDraftInstructions = ""
        pendingNewChatModelPicker = false
        pendingNewChatProviderID = nil
        directiveSuggestions.clearAll()
        memorySuggestions.clearAll()

        let preferredModelID = preferredModelID.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        if let pid = preferredProviderID, let p = providers.first(where: { $0.id == pid }) {
            // A restricted connection does not cross over to another one. When this connection has no usable model, no
            // conversation is opened with an empty id and last used is not written; the user goes to the connection
            // detail to pick a model. A connection missing its credential cannot start one either, by the same rule
            // as the summary card layout; the same goes when a model is specified (model row in the detail page,
            // new conversation with a summary).
            let isUsable = ProviderSelectionSnapshot.isUsableForNewChat(p)
            guard isUsable, let modelID = preferredModelID ?? fallbackModel(in: p)?.id else {
                selectedTab = .providers
                openProviderDetail(providerID: p.id)
                return false
            }
            // Last used is written only once both the connection and the model are settled. A call that does not record
            // last used (with a summary and a conversation model that cannot send) only restricts to this connection,
            // and the draft opens on this connection's new-chat chain.
            if recordsLastUsed {
                setActiveModel(providerID: p.id, modelID: modelID)
            } else {
                pendingNewChatProviderID = p.id
            }
        } else if activeModel == nil {
            // A new conversation that is not tied to a connection does not rewrite last used: the chat page judges the
            // retirement notice from the unrewritten last used; a call that carries a model but no connection does not
            // write it either.
            // Chain empty: with any connection, open the new-chat page and its model picker; only without one go to
            // adding a connection.
            guard !providers.isEmpty else {
                selectedTab = .providers
                openProviderSetup(from: .providers)
                return false
            }
            pendingNewChatModelPicker = true
        }

        presentChat(conversationID: nil)
        return true
    }

    /// Start a new conversation with the original conversation's provider/model and attach a reference to the
    /// latest valid checkpoint row to the composer (the caller passes the localized label).
    /// If there is no row or nothing quotable, no new conversation is started and false is returned.
    @discardableResult
    func startNewChatWithSummary(conversationId conversationID: UUID, label: String) -> Bool {
        guard hydrateConversationMessagesIfNeeded(id: conversationID),
              let conversation = conversations.first(where: { $0.id == conversationID }),
              let store = ContextCompactionStore.forPartition(sessionPartitionUID)
        else { return false }
        let quote: QuoteContext?
        do {
            quote = try ContextCompactionQuote.resolve(
                store: store,
                conversationId: conversationID.uuidString,
                messages: conversation.messages,
                label: label
            )
        } catch {
            print("[AppState] checkpoint latestValid failed: \(error.localizedDescription)")
            return false
        }
        guard let quote else { return false }
        pendingComposerQuote = quote
        // Take the model the conversation can send with (same as send / retry) and write last used only when it can
        // send; when it is retired, missing or removed, open on this connection's new-chat chain without writing it
        // and without reading the connection's isDefault.
        let sendable = provider(for: conversation.providerID).flatMap {
            sendableModel(for: conversation, provider: $0)
        }
        guard startNewChat(
            preferredProviderID: conversation.providerID,
            preferredModelID: sendable?.id,
            recordsLastUsed: sendable != nil
        ) else {
            // The chat page was not opened (missing credential, no usable model and routed to the detail page, ...): leave no quote behind.
            pendingComposerQuote = nil
            return false
        }
        return true
    }

    func startNewChatWithProviderFallback() async {
        // activeModel already includes the last tier across connections; with connections but no usable model,
        // startNewChat opens the model picker; only without any connection does it go to adding one.
        if activeModel != nil || !providers.isEmpty {
            startNewChat()
            return
        }
        selectedTab = .providers
        openProviderSetup(from: .providers)
    }

    /// Makes sure activeModel is ready. Returns true when it is ready to send; false means the user was routed to the
    /// model picker (connections exist but the chain is empty) or to provider setup, and the caller should abort the follow-up action.
    /// - Parameter prefillOnModelPicker: text carried into the new-chat composer when routed to the model picker
    ///   (the home input draft); it is never sent automatically.
    func ensureActiveModelWithProviderFallback(prefillOnModelPicker: String? = nil) async -> Bool {
        if activeModel != nil {
            return true
        }

        // activeModel is already the new-chat chain across all connections; when it is empty and connections exist, open the model picker.
        if !providers.isEmpty {
            startNewChat(withPrefilledText: prefillOnModelPicker ?? "")
            return false
        }

        selectedTab = .providers
        openProviderSetup(from: .providers)
        return false
    }

    func setDefaultModel(modelID: String, for providerID: UUID) {
        // Relays have no default model.
        guard provider(for: providerID)?.kind != .relay else { return }
        providerManager.setDefaultModel(modelID: modelID, for: providerID)
        setActiveModel(providerID: providerID, modelID: modelID)
    }

    /// Restores the default model when a delete is undone: only the connection default is restored and last used is not written.
    func restoreDefaultModel(modelID: String, for providerID: UUID) {
        guard provider(for: providerID)?.kind != .relay else { return }
        providerManager.setDefaultModel(modelID: modelID, for: providerID)
    }

    @discardableResult
    func enableModel(
        modelID: String,
        for providerID: UUID,
        lazilyVerifiesRelayTransport: Bool = false
    ) -> ProviderManager.EnableModelResult {
        providerManager.enableModel(
            modelID: modelID,
            for: providerID,
            lazilyVerifiesRelayTransport: lazilyVerifiesRelayTransport
        )
    }

    @discardableResult
    func enableModels(modelIDs: [String], for providerID: UUID) -> Int {
        providerManager.enableModels(modelIDs: modelIDs, for: providerID)
    }

    func disableModel(modelID: String, for providerID: UUID) {
        let before = provider(for: providerID)
        providerManager.disableModel(modelID: modelID, for: providerID)
        for key in Self.parameterKeysToRemove(onDisabling: modelID, before: before, after: provider(for: providerID)) {
            GenerationParameterSettingsStore.shared.removeScopes(providerID: providerID, modelID: key)
            GenerationParameterSettingsStore.shared.removeCapabilityScopes(providerID: providerID, modelID: key)
            GenerationParameterPresetStore.shared.removeScopes(providerID: providerID, modelID: key)
        }
    }

    /// Keys whose saved parameters are removed when a model is disabled. Official providers remove the key that
    /// was passed in. Relays remove the literal key; a legacy canonical key is removed only when no remaining
    /// enabled model of the connection still uses it (by canonical or literal), because a dated snapshot under
    /// the same canonical may still be in use.
    private static func parameterKeysToRemove(onDisabling modelID: String, before: Provider?, after: Provider?) -> [String] {
        guard let before, before.kind == .relay,
              let removed = ModelResolver.matchingModel(for: modelID, in: before) else { return [modelID] }
        let literal = ModelResolver.preferredStoredModelIdentifier(for: removed, providerKind: before.kind)
        // Compare by identity key: both the literal keys of the remaining enabled models and their legacy canonical keys count as "still in use".
        var stillUsed = Set<String>()
        for model in after?.models ?? [] {
            stillUsed.insert(ModelResolver.relayIdentityKey(model.id))
            for legacy in CapabilityPreferenceRuntimeIdentity.legacyRelayModelIDs(provider: before, model: model) {
                stillUsed.insert(ModelResolver.relayIdentityKey(legacy))
            }
        }
        var keys = [literal]
        if modelID != literal { keys.append(modelID) }
        for legacy in CapabilityPreferenceRuntimeIdentity.legacyRelayModelIDs(provider: before, model: removed)
        where !stillUsed.contains(ModelResolver.relayIdentityKey(legacy)) && !keys.contains(legacy) {
            keys.append(legacy)
        }
        return keys
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

    /// Called when the composer's send is tapped: non-nil means this turn's attachments do not fit, so do not send and do not clear the composer.
    func composerAttachmentOverLimit(
        text: String,
        attachments: [Attachment],
        in conversationID: UUID?,
        generationParameterDraftSessionID: UUID?,
        capabilitySelection: ChatCapabilitySelection
    ) -> ProviderServiceError? {
        chatManager.composerAttachmentOverLimit(
            text: text,
            attachments: attachments,
            conversationID: conversationID,
            draftSessionID: generationParameterDraftSessionID,
            capabilitySelection: capabilitySelection
        )
    }

    /// For callers that only need the conversation id; the composer, which must tell "blocked while sending" from "refused", uses `sendMessageOutcome`.
    func sendMessage(
        _ text: String,
        attachments: [Attachment] = [],
        quoteContext: QuoteContext? = nil,
        in conversationID: UUID?,
        generationParameterDraftSessionID: UUID? = nil,
        capabilitySelection: ChatCapabilitySelection = ChatCapabilitySelection(),
        evaluatesDirectiveSuggestion: Bool = true
    ) async -> UUID? {
        await sendMessageOutcome(
            text,
            attachments: attachments,
            quoteContext: quoteContext,
            in: conversationID,
            generationParameterDraftSessionID: generationParameterDraftSessionID,
            capabilitySelection: capabilitySelection,
            evaluatesDirectiveSuggestion: evaluatesDirectiveSuggestion
        ).sentID
    }

    /// `.sent` in the result carries the conversation id (not the user message id).
    func sendMessageOutcome(
        _ text: String,
        attachments: [Attachment] = [],
        quoteContext: QuoteContext? = nil,
        in conversationID: UUID?,
        generationParameterDraftSessionID: UUID? = nil,
        capabilitySelection: ChatCapabilitySelection = ChatCapabilitySelection(),
        evaluatesDirectiveSuggestion: Bool = true,
        /// A voice conversation turn passes .voice; nil means a normal send.
        delivery: ContextDelivery? = nil
    ) async -> ChatSendOutcome {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || !attachments.isEmpty else { return .refused }
        // Checkpoint invalidations queued by an edit truncation land before the checkpoints are read to build the context.
        if checkpointInvalidationTail != nil { await waitForCheckpointInvalidations() }

        let targetConversationID: UUID
        let isNewConversation = conversationID == nil
        if let conversationID {
            targetConversationID = conversationID
        } else {
            guard let active = activeModel else {
                return .refused
            }
            let newConversation = createConversationForFirstSend(provider: active.provider, modelID: active.model.id)
            targetConversationID = newConversation.id
            // First sentence of a voice conversation: hand the new conversation id to the voice session before the chat page
            // opens (same beat as the realtime makeConversation), so the home voice bar does not keep rendering "no
            // conversation" once the chat page is already open.
            if delivery == .voice { VoiceSendContext.onConversationCreated?(targetConversationID) }

            presentChat(conversationID: targetConversationID)
        }

        guard let targetConversation = conversation(for: targetConversationID) else {
            return .refused
        }

        if isNewConversation, let generationParameterDraftSessionID {
            // Before the first message of a new conversation, the tool panel's switches are kept under the
            // draft id. They move to the real id when the conversation is created, and that has to happen
            // before sending: assembling the usable tools reads by conversation id. If the move fails, this
            // one send simply carries no tools.
            try? await mcpServerDirectory.store(for: sessionPartitionUID).moveConversationSwitchesAsync(
                from: generationParameterDraftSessionID, to: targetConversationID
            )
                        // External search is keyed by conversation source: for a draft it lives in memory only and is written once under the real id after the conversation is created; sending the first message reads this in-memory copy.
            SearchSourceDrafts.shared.adopt(
                from: generationParameterDraftSessionID, to: targetConversationID,
                store: SearchServiceStore(scope: sessionPartitionUID)
            )
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
            // The relay web switch is addressed by its own fixed identity, which the move above cannot reach.
            RelayWebSwitch.migrateSession(
                provider: provider, model: model, from: generationParameterDraftSessionID, to: targetConversationID
            )
            // The on-device custom configuration is also keyed by conversationID; without moving it, it would vanish (neither sent nor readable back).
            GenerationParameterSettingsStore.shared.migrateLocalCustomConfiguration(
                providerID: provider.id,
                modelID: capabilityIdentity?.canonicalModelID ?? "",
                from: generationParameterDraftSessionID,
                to: targetConversationID,
                transportIdentity: capabilityIdentity?.wireValue ?? ""
            )
            GenerationParameterSettingsStore.shared.migrateAdditionalRequestBody(
                providerID: provider.id,
                modelID: CapabilityPreferenceRuntimeIdentity.canonicalModelID(provider: provider, model: model),
                from: generationParameterDraftSessionID,
                to: targetConversationID
            )
        }

        // The edit-resend marker is consumed by chatManager.sendMessage, so read it first: an edit-resend does not evaluate the suggestion bar.
        let isEditResend = chatManager.isPendingEditResend(targetConversationID)
        // The propose_memory mode is only decided for a fresh send; with mode=tool the request carries propose_memory.
        let useMemory = effectiveUseMemory(targetConversation)
        let memoryMode = memoryProposeMode(
            conversation: targetConversation,
            freshSend: evaluatesDirectiveSuggestion && !isEditResend,
            useMemory: useMemory,
            capabilitySelection: capabilitySelection
        )
        // When mode=tool was decided but the request does not actually carry propose_memory, this turn runs as fallback, at most once per message.
        let proposeFallback = ProposeFallbackOnce()
        let proposeContext = memoryMode == .tool
            ? proposeMemoryContext(
                text: text, conversationID: targetConversationID, useMemory: useMemory, fallback: proposeFallback
            )
            : nil
        // If the repository cannot be opened no tool is carried: this turn runs as fallback.
        let sentMemoryMode: MemoryPropose.Mode = memoryMode == .tool && proposeContext == nil ? .fallback : memoryMode
        let outcome = await chatManager.sendMessageOutcome(
            text,
            attachments: attachments,
            quoteContext: quoteContext,
            in: targetConversationID,
            capabilitySelection: capabilitySelection,
            proposeMemory: proposeContext,
            delivery: delivery
        )
        guard case .sent(let userMessageID) = outcome else { return outcome }
        // Every actual send (the first message of a new conversation and existing conversations) writes last used: the connection and model sent with this time.
        if let sentConversation = conversation(for: targetConversationID),
           let sentProvider = provider(for: sentConversation.providerID),
           let sentModel = sendableModel(for: sentConversation, provider: sentProvider) {
            setActiveModel(providerID: sentProvider.id, modelID: sentModel.id)
        }
        // Only a freshly sent message is evaluated: edit-resend and automatic sends from guided flows are not; resend / regenerate do not come through here.
        guard evaluatesDirectiveSuggestion, !isEditResend, sentMemoryMode != .none else { return .sent(targetConversationID) }
        // The fallback already ran during the send because no tool was carried: do not override its result in tool mode here.
        guard proposeFallback.markSettled() else { return .sent(targetConversationID) }
        // Routing: memory -> memory bar; conversationInstruction -> instruction bar; none -> nothing.
        // With mode=tool neither the v1 memory routing nor the lexical instruction bar runs; the instruction bar comes only from the
        // model's instruct. In the other modes the lexical instruction bar is gated on the recognizer language being one of the suggestion languages.
        let suggestion = MemoryIntent.classify(text).suggestion
        memorySuggestions.reset(conversationID: targetConversationID)
        if sentMemoryMode == .tool {
            directiveSuggestions.beginToolTurn(messageID: userMessageID, conversationID: targetConversationID)
        } else {
            directiveSuggestions.evaluate(
                text: text,
                messageID: userMessageID,
                conversationID: targetConversationID,
                instructions: conversation(for: targetConversationID)?.instructions ?? "",
                suggestion: suggestion
            )
        }
        generateMemoryCandidate(
            text: text,
            messageID: userMessageID,
            assistantMessageID: assistantMessageID(after: userMessageID, in: targetConversationID),
            conversationID: targetConversationID,
            suggestion: suggestion,
            mode: sentMemoryMode,
            useMemory: useMemory
        )
        return .sent(targetConversationID)
    }

    /// Same decision as injection: conversation ?? Skill ?? true.
    private func effectiveUseMemory(_ conversation: Conversation?) -> Bool {
        conversation?.useMemory
            ?? conversation?.skillId.flatMap { skillManager.skill(by: $0) }?.useMemory
            ?? true
    }

    /// The propose_memory mode for this send.
    func memoryProposeMode(
        conversation: Conversation,
        freshSend: Bool,
        useMemory: Bool,
        capabilitySelection: ChatCapabilitySelection
    ) -> MemoryPropose.Mode {
        let provider = provider(for: conversation.providerID)
        // The same model resolution as sending.
        let model = provider.flatMap { sendableModel(for: conversation, provider: $0) }
        // Relay web search uses the same criterion as ChatManager when sending (switch + default layer + user override), not the composer's raw selection.
        var webSearchEnabled = capabilitySelection.webSearchEnabled
        if let provider, let model, ProviderForm.of(provider) == .relay {
            webSearchEnabled = ChatManager.relayWebIsOn(
                provider: provider, model: model, conversationID: conversation.id, skillID: conversation.skillId
            )
        }
        let mode = ProposeMemoryRuntime.shared.mode(
            purpose: .chat,
            freshSend: freshSend,
            memoryEnabled: useMemory,
            autoSuggest: memoryCandidateRepository()?.autoSuggestEnabled() ?? true,
            provider: provider,
            model: model,
            webSearchEnabled: webSearchEnabled,
            structuredOutputActive: provider.flatMap { provider in
                model.map { chatManager.structuredOutputActive(provider: provider, model: $0, conversationID: conversation.id) }
            } ?? false,
            toolCallMemory: chatManager.toolCallMemory
        )
        // The MiniMax web route (Anthropic messages web recipe) sends the request without clientTools: judged with the same
        // criterion as the outbound dispatch, so the answer is fallback.
        // Gemini Interactions and llama.cpp native /completion are already excluded by ProposeMemoryRuntime's tool decision.
        if mode == .tool, provider?.kind == .miniMax, let model,
           MiniMaxService.exactAnthropicWebRecipe(
               modelID: model.id, requested: capabilitySelection.typedPreferences?.web == .automatic
           ) != nil {
            return .fallback
        }
        return mode
    }

    /// The propose context handed to ChatManager for mode=tool: the first candidate created becomes this turn's bar;
    /// if the first leg is rejected and degrades, or the request did not actually carry propose_memory, this turn runs the
    /// fallback (v1 path) and the bar is attached to the same assistant message, at most once per message.
    /// If the repository cannot be opened, no tool is carried. instruct attaches only to the latest user message of the
    /// conversation; a late one is dropped.
    func proposeMemoryContext(
        text: String, conversationID: UUID, useMemory: Bool, fallback: ProposeFallbackOnce? = nil
    ) -> ProposeMemoryTurnContext? {
        guard let repository = memoryCandidateRepository() else { return nil }
        let fallback = fallback ?? ProposeFallbackOnce()
        return ProposeMemoryTurnContext(
            repository: repository,
            userText: text,
            folderID: conversation(for: conversationID)?.folderID?.uuidString,
            onCandidate: { [weak self] candidate, assistantMessageID in
                self?.memorySuggestions.presentProposed(
                    candidate, messageID: assistantMessageID, conversationID: conversationID
                )
            },
            onInstruct: { [weak self] sentence, userMessageID in
                guard let self, self.latestUserMessageID(in: conversationID) == userMessageID else { return }
                self.directiveSuggestions.offerInstruct(
                    sentence: sentence,
                    messageID: userMessageID,
                    conversationID: conversationID,
                    instructions: self.conversation(for: conversationID)?.instructions ?? ""
                )
            },
            onDegraded: { [weak self] userMessageID, assistantMessageID in
                guard fallback.begin() else { return }
                // Ran before the send returned (the request carried no tool): do the bar clearing that would have followed the send.
                if !fallback.settled { self?.memorySuggestions.reset(conversationID: conversationID) }
                // Degrade as fallback: the lexical instruction bar (language-gated) plus the v1 memory path.
                self?.directiveSuggestions.evaluate(
                    text: text,
                    messageID: userMessageID,
                    conversationID: conversationID,
                    instructions: self?.conversation(for: conversationID)?.instructions ?? "",
                    suggestion: MemoryIntent.classify(text).suggestion
                )
                self?.generateMemoryCandidate(
                    text: text,
                    messageID: userMessageID,
                    assistantMessageID: assistantMessageID,
                    conversationID: conversationID,
                    suggestion: MemoryIntent.classify(text).suggestion,
                    mode: .fallback,
                    useMemory: useMemory
                )
            }
        )
    }

    /// This turn's assistant message: it lands right after the user message when sending.
    private func assistantMessageID(after userMessageID: UUID, in conversationID: UUID) -> UUID? {
        guard let messages = conversation(for: conversationID)?.messages,
              let index = messages.firstIndex(where: { $0.id == userMessageID }),
              messages.indices.contains(index + 1),
              messages[index + 1].role == .assistant
        else { return nil }
        return messages[index + 1].id
    }

    /// The last assistant message of this conversation.
    private func latestAssistantMessageID(in conversationID: UUID) -> UUID? {
        conversation(for: conversationID)?.messages.last(where: { $0.role == .assistant })?.id
    }

    /// The last user message of this conversation.
    private func latestUserMessageID(in conversationID: UUID) -> UUID? {
        conversation(for: conversationID)?.messages.last(where: { $0.role == .user })?.id
    }

    /// After a fresh user send, generate a memory candidate in the background; failures are only logged.
    /// mode=tool: v1 does not run and only waits for this turn's first propose candidate.
    /// mode=fallback: the memory bar is shown only for a new candidate while this turn's assistant message is still the latest
    /// assistant message of the conversation; suggestion=memory with memory turned off shows only a hint.
    /// The bar is always attached to this turn's assistant message, and the candidate source still records the user message id.
    private func generateMemoryCandidate(
        text: String,
        messageID: UUID,
        assistantMessageID: UUID?,
        conversationID: UUID,
        suggestion: MemoryIntent.Suggestion,
        mode: MemoryPropose.Mode,
        useMemory: Bool
    ) {
        if mode == .tool {
            memoryCandidateGeneration = nil
            if let assistantMessageID {
                memorySuggestions.awaitCandidate(messageID: assistantMessageID, conversationID: conversationID)
            }
            return
        }
        if suggestion == .memory, !useMemory, let assistantMessageID {
            memorySuggestions.showMemoryOffHint(messageID: assistantMessageID, conversationID: conversationID)
        }
        guard let repository = memoryCandidateRepository() else { return }
        let folderID = conversation(for: conversationID)?.folderID?.uuidString
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let barMessageID = suggestion == .memory && useMemory ? assistantMessageID : nil
        if let barMessageID {
            memorySuggestions.awaitCandidate(messageID: barMessageID, conversationID: conversationID)
        }
        memoryCandidateGeneration = Task { [weak self] in
            do {
                let candidate = try await repository.generate(
                    text: text,
                    messageId: messageID.uuidString,
                    conversationId: conversationID.uuidString,
                    folderId: folderID,
                    useMemory: useMemory,
                    nowMs: nowMs
                )
                guard let barMessageID, let self else { return }
                self.memorySuggestions.present(
                    candidate,
                    messageID: barMessageID,
                    conversationID: conversationID,
                    latestAssistantMessageID: self.latestAssistantMessageID(in: conversationID)
                )
            } catch {
                #if DEBUG
                print("[AppState] generateMemoryCandidate failed: \(error)")
                #endif
            }
        }
    }

    func resolveContextCapConfirmation(id: UUID, choice: ContextCapConfirmChoice) {
        contextCapConfirmCoordinator.resolve(id: id, choice: choice)
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

    /// Edit a user message: truncates the conversation and returns the text and original attachments to put back in the composer.
    func beginEditingUserMessage(messageID: UUID, in conversationID: UUID) -> ComposerEditDraft? {
        let historyIds = checkpointHistoryIds(of: conversationID)
        let draft = chatManager.beginEditingUserMessage(messageID: messageID, in: conversationID)
        invalidateCheckpointsAfterTruncation(conversationID: conversationID, historyIdsBefore: historyIds)
        return draft
    }

    func beginEditingPromptingMessage(for assistantMessageID: UUID, in conversationID: UUID) -> ComposerEditDraft? {
        let historyIds = checkpointHistoryIds(of: conversationID)
        let draft = chatManager.beginEditingPromptingMessage(for: assistantMessageID, in: conversationID)
        invalidateCheckpointsAfterTruncation(conversationID: conversationID, historyIdsBefore: historyIds)
        return draft
    }

    func continueMessage(
        messageID: UUID,
        in conversationID: UUID,
        capabilitySelection: ChatCapabilitySelection = ChatCapabilitySelection()
    ) async {
        // Continuing deletes no messages; when an empty interruption falls back to regenerate, the checkpoints of the truncated segment are invalidated.
        let historyIds = checkpointHistoryIds(of: conversationID)
        await chatManager.continueMessage(
            messageID: messageID,
            in: conversationID,
            capabilitySelection: capabilitySelection
        )
        // Continuing does not truncate, so the invalidation is only queued and not awaited: awaiting it changes how
        // the continue entry interleaves with managed recovery tasks. Ordering is covered by
        // `waitForCheckpointInvalidations` before the next send and by the digest check at read time.
        invalidateCheckpointsAfterTruncation(conversationID: conversationID, historyIdsBefore: historyIds)
    }

    func regenerateMessage(
        messageID: UUID,
        in conversationID: UUID,
        capabilitySelection: ChatCapabilitySelection = ChatCapabilitySelection(),
        searchRegenerateAction: SearchRegenerateAction = .regenerate
    ) async {
        let historyIds = checkpointHistoryIds(of: conversationID)
        await chatManager.regenerateMessage(
            messageID: messageID,
            in: conversationID,
            capabilitySelection: capabilitySelection,
            searchRegenerateAction: searchRegenerateAction
        )
        await invalidateCheckpointsAfterTruncation(conversationID: conversationID, historyIdsBefore: historyIds).value
    }

    /// The full history ids before truncation (complete the summary projection first, otherwise the pre-change history is incomplete).
    private func checkpointHistoryIds(of conversationID: UUID) -> [String] {
        guard hydrateConversationMessagesIfNeeded(id: conversationID),
              let conversation = conversations.first(where: { $0.id == conversationID })
        else { return [] }
        return conversation.messages.map(\.id.uuidString)
    }

    /// Invalidation hook for edit / regenerate: messages in the pre-change history that are gone after truncation are affected;
    /// when the send is refused or nothing is truncated the set is empty and invalidate deletes nothing.
    /// The write must not wait synchronously on the main thread (the write lock can be held by a whole-table write for
    /// seconds): it is queued on a serial tail task. Async entry points await the returned task; the synchronous
    /// entry (edit) only queues, and `waitForCheckpointInvalidations` waits for it before the next send.
    @discardableResult
    private func invalidateCheckpointsAfterTruncation(conversationID: UUID, historyIdsBefore: [String]) -> Task<Void, Never> {
        let previous = checkpointInvalidationTail
        guard !historyIdsBefore.isEmpty,
              let conversation = conversations.first(where: { $0.id == conversationID })
        else { return previous ?? Task {} }
        let remaining = Set(conversation.messages.map(\.id.uuidString))
        let affected = historyIdsBefore.filter { !remaining.contains($0) }
        guard !affected.isEmpty,
              let store = ContextCompactionStore.forPartition(sessionPartitionUID)
        else { return previous ?? Task {} }
        let task = Task { @MainActor in
            await previous?.value
            _ = await store.invalidateAndPropagateAsync(
                conversationId: conversationID.uuidString,
                historyIds: historyIdsBefore,
                affectedIds: affected
            )
        }
        checkpointInvalidationTail = task
        return task
    }

    /// Wait for queued checkpoint invalidations to land (before a send reads checkpoints, and before test assertions).
    func waitForCheckpointInvalidations() async {
        while let task = checkpointInvalidationTail {
            await task.value
            if checkpointInvalidationTail == task {
                checkpointInvalidationTail = nil
                return
            }
        }
    }

    func retryMessage(
        messageID: UUID,
        in conversationID: UUID,
        capabilitySelection: ChatCapabilitySelection = ChatCapabilitySelection(),
        localCustomFragmentDisposition: LocalCustomFragmentDisposition = .include
    ) async {
        // Rewriting a failed message in place deletes no messages, so an empty affected set deletes nothing; when it falls back to regenerate, the checkpoints of the truncated segment are invalidated.
        let historyIds = checkpointHistoryIds(of: conversationID)
        await chatManager.retryMessage(
            messageID: messageID,
            in: conversationID,
            capabilitySelection: capabilitySelection,
            localCustomFragmentDisposition: localCustomFragmentDisposition
        )
        await invalidateCheckpointsAfterTruncation(conversationID: conversationID, historyIdsBefore: historyIds).value
    }

    /// Create the conversation for the first send: pending instructions are written into the object first, then saved, and then cleared.
    @discardableResult
    func createConversationForFirstSend(provider: Provider, modelID: String) -> Conversation {
        let conversation = conversationForFirstSend(provider: provider, modelID: modelID)
        pendingDraftInstructions = ""
        upsertConversationProjection(conversation)
        return conversation
    }

    /// The conversation the first send will create (not saved): the opening plan of the home realtime session is assembled from its defaults.
    func conversationForFirstSend(provider: Provider, modelID: String) -> Conversation {
        var conversation = createConversation(provider: provider, modelID: modelID)
        conversation.instructions = ConversationInstructions.normalize(pendingDraftInstructions)
        return conversation
    }

    /// Creates the conversation before the home realtime session's first message is saved: the model is the one currently
    /// shown in the home pill, and the chat page opens right away (same as a first send from home).
    func createConversationForRealtimeVoice() -> UUID? {
        guard let active = activeModel else { return nil }
        let conversation = createConversationForFirstSend(provider: active.provider, modelID: active.model.id)
        // Last used was already written when the call started (recordLastUsedForRealtimeVoice), so it is not written again here.
        presentChat(conversationID: conversation.id)
        return conversation.id
    }

    /// Starting a realtime call is actual use: an existing conversation writes its sendable model and writes nothing when
    /// it cannot send; the home page (conversation id nil) writes the model currently selected in the pill.
    func recordLastUsedForRealtimeVoice(conversationID: UUID?) {
        guard let conversationID else {
            guard let active = activeModel else { return }
            setActiveModel(providerID: active.provider.id, modelID: active.model.id)
            return
        }
        guard let conversation = conversation(for: conversationID),
              let provider = provider(for: conversation.providerID),
              let model = sendableModel(for: conversation, provider: provider)
        else { return }
        setActiveModel(providerID: provider.id, modelID: model.id)
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

    /// Starts this partition's attachment sweep (sidecar files plus orphan images). The grace period counts from the launch time,
    /// so files written during this run are never candidates.
    @discardableResult
    func startAttachmentCleanup(uid: String) -> Task<Void, Never> {
        let bridge = conversationRuntimeBridge
        let imageReferences = try? bridge.imageReferenceReader(uid: uid)
        let sweepLaunchedAt = launchedAt
        let queue = conversationPersistQueue
        return Task.detached(priority: .utility) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async(qos: .utility) {
                    try? bridge.pruneAttachmentFiles(uid: uid, launchedAt: sweepLaunchedAt)
                    continuation.resume()
                }
            }
            guard let imageReferences else { return }
            await ImageOrphanSweeper.sweepOnLaunch(
                partitionUID: uid,
                references: imageReferences,
                launchedAt: sweepLaunchedAt
            )
        }
    }

    /// Loads the current partition's data into memory.
    /// - Parameter startsAttachmentCleanup: whether to start this partition's attachment sweep here (sidecar files plus orphan images).
    ///
    /// When the partition database is not open yet (cold start) the main thread does not open it: the non-database data of the
    /// session snapshot is installed first, the database is prepared in the background (connection + migrations) while
    /// `sessionStoreReady == false` and the root view shows nothing that could reach the database, and then the conversations
    /// are read on the main thread (`loadSessionStore`).
    func loadSession(boundTo uid: String? = nil, startsAttachmentCleanup: Bool = true) {
        resetTransientNoteContext()
        preferences = AppPreferencesStore.load()
        let activeUID = uid ?? AppSessionStore.activeUID
        boundPartitionUID = activeUID
        sessionLoadGeneration &+= 1

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

        if DatabaseManager.shared.openedPool(for: activeUID) != nil || DatabaseManager.allowsMainThreadFirstOpen {
            sessionStoreReady = true
            sessionStoreReadyTask = nil
            loadSessionStore(uid: activeUID, snapshot: snapshot, startsAttachmentCleanup: startsAttachmentCleanup)
            return
        }
        sessionStoreReady = false
        conversations = []
        let generation = sessionLoadGeneration
        sessionStoreReadyTask = Task { @MainActor [weak self] in
            var openError: Error?
            do {
                _ = try await DatabaseManager.shared.prepare(for: activeUID)
            } catch {
                openError = error
            }
            guard let self, self.sessionLoadGeneration == generation, self.partitionIsStillBound(activeUID) else { return }
            // Mark ready first: the cache rebuilds triggered by installing the conversations below must be able to read the database.
            self.sessionStoreReady = true
            if let openError {
                // It cannot be opened: same as a failed read, fall back to the recovery snapshot and enter the blocked state.
                self.databaseHealthProbe.recordFailure(openError)
                self.conversations = self.conversationRuntimeBridge.loadRecoveryProjection(snapshot: snapshot, uid: activeUID)
            } else {
                self.loadSessionStore(uid: activeUID, snapshot: snapshot, startsAttachmentCleanup: startsAttachmentCleanup)
            }
        }
    }

    /// The partition database is open: read the conversations, memory items, startup recovery and so on (the main thread only reads; every write is queued).
    private func loadSessionStore(
        uid activeUID: String,
        snapshot: AppSessionSnapshot?,
        startsAttachmentCleanup: Bool
    ) {
        // Partition activation: migrate legacy fields into memory items / reflow edits from old clients
        reconcileMemoryItems()
        memoryItemsCache.bind(uid: activeUID)

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
                // The whole-table write is queued on the persist queue (the main thread never waits for the write lock) and
                // every write queued afterwards lands behind it; memory uses the summary form of the merge result
                // (the cold-start mirror holds summaries only, the same shape as reading them back from the database).
                let bridge = conversationRuntimeBridge
                conversationPersistQueue.async(qos: .userInitiated) {
                    Self.runConversationPersistWrite(op: "load_session_recovery_replace") {
                        _ = try bridge.replaceAllConversations(mergedProjection, uid: activeUID)
                    }
                }
                conversations = mergedProjection.map(\.coldStartSummary)
            } else {
                conversations = authoritativeProjection
            }
            // The local database read through. While blocked, this success is the user having
            // freed space and retried.
            databaseHealthProbe.recordSuccess()
        } catch {
            #if DEBUG
            AppLog.error(error, module: "Conversations", context: ["op": "loadSession"])
            #endif
            // The recovery snapshot below keeps the app looking usable — but from here on nothing
            // the user does is kept. Saying nothing would be a lie, so turn the failure into a
            // blocked state and let the UI explain it. A false return means the failure is not a
            // storage access failure, and then only the snapshot fallback applies.
            databaseHealthProbe.recordFailure(error)
            conversations = conversationRuntimeBridge.loadRecoveryProjection(snapshot: snapshot, uid: activeUID)
        }

        // Age out the deletion journal. Cold start on a background queue is fine: it only drops
        // rows past the retention window, so running it a few launches late changes nothing.
        let journalUID = activeUID
        let journalBridge = conversationRuntimeBridge
        conversationPersistQueue.async(qos: .utility) {
            try? journalBridge.pruneDeletionJournal(uid: journalUID)
        }
        if startsAttachmentCleanup {
            startAttachmentCleanup(uid: activeUID)
        }

        migrateProvidersToDeterministicIDsIfNeeded(uid: activeUID)
        migrateLlamaCppConnectionsToChatChannelIfNeeded(uid: activeUID)

        sanitizeStaleGeneratingMessages()

        if !providers.isEmpty || !conversations.isEmpty {
            hasCompletedOnboarding = true
        }

        skillManager.reloadCacheForCurrentAccount()
        providersLoaded = true

        if !providers.isEmpty {
            Task {
                await MetadataClient.shared.ensureInitialized()
                backfillProviderEndpointSources()
                await refreshProviderMetadata()
            }
        }
    }

    /// Refreshes the stored providers' model metadata once Metadata has initialized.
    /// Reads from the MetadataClient actor over the async path so a stale shared snapshot
    /// cannot hide a fresh value.
    /// Classify unclassified official providers against the current metadata, then run the lazy migrations
    /// (retired regions, endpoint-source reconciliation) over every official provider and write the result back
    /// locally. It mutates the array directly instead of going through updateProvider: updatedAt is untouched and
    /// nothing is uploaded. When metadata is missing, providers stay unclassified but the retired-region
    /// migration still runs.
    func backfillProviderEndpointSources(catalog: ProviderSetupCatalog = .current()) {
        var updated = providers
        var changed = false
        for index in updated.indices where updated[index].reconcileEndpointSource(catalog: catalog) {
            changed = true
        }
        if changed { providers = updated }
    }

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
            // Catalog not loaded: no conclusion is possible, so leave the stored models alone until
            // that provider arrives and the next refresh reconciles it.
            guard !resolvedCatalog.catalogPending else {
                enriched.append(provider)
                continue
            }
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

    /// Saves the current data to the partition (no debounce, so nothing is lost before a switch) without waiting: the
    /// snapshot is fixed on the main thread now and the write is queued on the persist queue. The main thread never
    /// waits on a queue that may be busy with a whole-table write. Callers that must continue only after the write use
    /// `persistSessionNowOffMainThread()`.
    func enqueueSessionPersist(for persistedUID: String? = nil) {
        guard let work = makeImmediateSessionPersistWork(for: persistedUID) else { return }
        conversationPersistQueue.async(qos: .userInitiated, execute: work)
    }

    #if DEBUG
    /// Tests only: persist synchronously (the main thread waits for the persist queue; forbidden in production).
    func persistSessionNow(for persistedUID: String? = nil) {
        enqueueSessionPersist(for: persistedUID)
        flushConversationPersistQueue()
    }
    #endif

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
        let checkpointPool = checkpoint ? bridge.openedPool() : nil

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
            if let checkpointPool {
                Self.runConversationPersistWrite(op: "persist_lifecycle_checkpoint") {
                    try DatabaseManager.checkpoint(checkpointPool)
                }
            }
            holder.endOnMain()
        }
    }

    private var persistableProviders: [Provider] { providers }

    /// The partition database is open and the session loaded (the database phase of `loadSession` has run). While false the
    /// root view shows nothing and database-related entry points wait for `sessionStoreReadyTask`.
    private(set) var sessionStoreReady = true
    /// The task that prepares the partition database in the background and loads the session; nil when already ready.
    @ObservationIgnored private(set) var sessionStoreReadyTask: Task<Void, Never>?
    @ObservationIgnored private var sessionLoadGeneration: UInt = 0

    /// Waits until the partition database is open and the session loaded (returns at once when already ready).
    func waitForSessionStore() async {
        while !sessionStoreReady, let task = sessionStoreReadyTask {
            await task.value
            // This load was superseded by a newer `loadSession` with no new task (or invalidated): do not spin.
            if sessionStoreReadyTask == task, !sessionStoreReady { return }
        }
    }

    func updateTheme(_ theme: ThemeOption) {
        preferences.theme = theme
        preferences.themeSetByUser = true
        AppPreferencesStore.save(preferences)
    }

    func updateDarkPalette(_ choice: OriveoDarkPaletteChoice) {
        preferences.darkPalette = choice.storageID
        // Writing a custom palette also writes its seed color; choosing a preset again keeps the seed
        if case let .custom(seed) = choice {
            preferences.darkPaletteCustom = OriveoCustomPalette.format(seed)
        }
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
        // The old settings page only changes memoryText without a summary, so edit it back into the items as an old client would (transition bridge)
        reconcileMemoryItems()
    }

    /// Serial tail task for undoing a memory-item save (see `removeMemoryItemInBackground`).
    @ObservationIgnored private var memoryItemUndoTail: Task<Void, Never>?

    /// The toast "Undo" deletes the just-created memory item: the tombstone write runs in the background instead of
    /// waiting synchronously for the write lock on the main thread (behind a whole-table write that stalls for seconds);
    /// repeated undos queue on one serial tail task so they land in tap order.
    func removeMemoryItemInBackground(id: String) {
        guard let repository = memoryItemRepository() else { return }
        let previous = memoryItemUndoTail
        memoryItemUndoTail = Task { @MainActor in
            await previous?.value
            _ = try? await repository.perform { try $0.remove(id: id) }
        }
    }

    /// Wait for queued undo deletions to land (for tests).
    func waitForMemoryItemUndo() async {
        await memoryItemUndoTail?.value
    }

    /// The memory item repository of the current partition; legacy field reads and writes go through this object's preferences. nil when the database cannot be opened.
    func memoryItemRepository() -> MemoryItemRepository? {
        MemoryItemRepository.forPartition(
            sessionPartitionUID,
            bridge: MemoryLegacyPrefsBridge(
                read: { [weak self] in
                    self?.preferences.memoryLegacyPrefs ?? MemoryLegacyPrefs(memoryText: nil)
                },
                write: { [weak self] compiled in self?.writeMemoryLegacy(compiled) }
            )
        )
    }

    /// The memory candidate repository of the current partition; once confirmed, a candidate becomes an item through the same partition's item repository. nil when the database cannot be opened.
    func memoryCandidateRepository() -> MemoryCandidateRepository? {
        if let memoryCandidateRepositoryOverride { return memoryCandidateRepositoryOverride() }
        guard let items = memoryItemRepository() else { return nil }
        return MemoryCandidateRepository.forPartition(sessionPartitionUID, items: items)
    }

    /// Runs when a partition is activated or memoryText changes: migrate / reflow, and dual-write the legacy fields when needed.
    /// Database writes run in the background and are serialized in call order (a partition activation and a memoryText change land in the order they were triggered).
    @discardableResult
    func reconcileMemoryItems() -> Task<Void, Never> {
        let repository = memoryItemRepository()
        // The legacy fields are fixed at trigger time: a later preference change is handled by its own reconcile.
        let prefs = preferences.memoryLegacyPrefs
        let previous = memoryReconcileTail
        let task = Task { @MainActor in
            await previous?.value
            do {
                try await repository?.reconcileLegacy(prefs: prefs)
            } catch {
                #if DEBUG
                print("[AppState] reconcileMemoryItems failed: \(error)")
                #endif
            }
        }
        memoryReconcileTail = task
        return task
    }

    @ObservationIgnored private var memoryReconcileTail: Task<Void, Never>?

    /// Dual-write memory items back to the legacy fields (same as updateMemory): save the preferences locally.
    private func writeMemoryLegacy(_ compiled: MemoryLegacyCompile) {
        let updated = preferences.applyingMemoryLegacy(compiled, now: Date())
        guard updated != preferences else { return }
        AppPreferencesStore.save(updated)
        preferences = updated
    }

    func setConversationUseMemory(_ conversationID: UUID, useMemory: Bool) {
        let persistedUID = boundPartitionUID
        let mirrorIndex = conversations.firstIndex(where: { $0.id == conversationID })
        let mirroredConversation = mirrorIndex.map { conversations[$0] }

        // The in-memory mirror changes first; the write is queued on the conversation persist queue (serial with the other
        // conversation writes, landing in call order), so the main thread never waits for the write lock. A failed write
        // rolls the mirror back (unless the switch was flipped again meanwhile).
        if let mirrorIndex { conversations[mirrorIndex].useMemory = useMemory }
        let bridge = conversationRuntimeBridge
        let outcome = ConversationPersistOutcome<Conversation?>()
        conversationPersistQueue.async(qos: .userInitiated) {
            outcome.fulfill(Result {
                try bridge.setConversationUseMemory(id: conversationID, useMemory: useMemory, uid: persistedUID) ?? {
                    guard var updated = mirroredConversation else { return nil }
                    updated.useMemory = useMemory
                    return try bridge.upsertConversation(updated, uid: persistedUID)
                }()
            })
        }
        let previous = useMemoryWriteTail
        useMemoryWriteTail = Task { @MainActor [weak self] in
            await previous?.value
            let result = await outcome.value
            guard let self, self.partitionIsStillBound(persistedUID) else { return }
            self.finishConversationUseMemoryWrite(result, conversationID: conversationID, useMemory: useMemory)
        }
    }

    @ObservationIgnored private var useMemoryWriteTail: Task<Void, Never>?

    private func finishConversationUseMemoryWrite(
        _ result: Result<Conversation?, Error>,
        conversationID: UUID,
        useMemory: Bool
    ) {
        let index = conversations.firstIndex(where: { $0.id == conversationID })
        switch result {
        case let .success(refreshed):
            // Not in memory (only in the store): insert the row read back at the top, as the synchronous path did.
            // When it is in memory the read-back row does not overwrite it: memory may have changed again while the write
            // was queued, and the switch value is already set.
            if let refreshed, index == nil { conversations.insert(refreshed, at: 0) }
        case let .failure(error):
            if let index, conversations[index].useMemory == useMemory {
                conversations[index].useMemory = !useMemory
            }
            #if DEBUG
            AppLog.error(error, module: "AppState", context: ["op": "setConversationUseMemory"])
            #endif
        }
    }

    /// Waits for the queued use-memory writes and their wrap-up (for tests).
    func waitForConversationUseMemoryWrites() async {
        await useMemoryWriteTail?.value
    }

    /// Open the Settings memory page; when `editItemId` is non-nil, the memory page edits that item right after appearing
    /// ("This one is wrong" in "Memory used").
    func openMemory(editItemId: String? = nil) {
        pendingMemoryEditItemID = editItemId?.lowercased()
        navigation.openMemory()
    }

    /// The memory page takes the pending item id to edit (cleared once taken).
    func consumePendingMemoryEditItemID() -> String? {
        defer { pendingMemoryEditItemID = nil }
        return pendingMemoryEditItemID
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
              let provider = provider(for: providerID),
              let modelID = resolvedModelID else {
            // No usable provider: only show a prompt, do not force a navigation.
            ToastManager.shared.show(L10n.tr("You need at least one AI provider to start a conversation."))
            showSkillProviderPrompt = true
            return
        }

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
            // Drop connections that are not usable first, then match by kind (same criterion as the new-chat chain).
            if let provider = providers.first(where: {
                ProviderSelectionSnapshot.isUsableForNewChat($0) && $0.kind.rawValue == suggestedProviderId
            }),
               // Only an enabled and available model counts: not enabled, retired or absent from the catalog are all skipped.
               ProviderSelectionSnapshot.availableEnabledModel(storedModelID: suggestedModelId, in: provider) != nil {
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
        // The current connection first (the one the new-chat chain picked), then the connection list order; unusable connections are skipped.
        let usable = providers.filter { ProviderSelectionSnapshot.isUsableForNewChat($0) }
        let sortedProviders: [Provider]
        if let active = activeModel {
            sortedProviders = [active.provider] + usable.filter { $0.id != active.provider.id }
        } else {
            sortedProviders = usable
        }

        for provider in sortedProviders {
            // The capability-match tier also requires an available, enabled model first.
            let unavailable = ProviderSelectionSnapshot.unavailableEnabledModelIDs(in: provider)
            for model in provider.models where !unavailable.contains(model.id) {
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

/// One-shot notice at the top of the provider detail page.
struct ProviderDetailNotice: Equatable {
    enum Kind: Equatable {
        /// Setup finished: how many models were enabled.
        case addedModels(Int)
        /// A manual setup failed its liveness probe but was saved anyway: the raw failure reason.
        case unverifiedSave(String)
    }

    let providerID: UUID
    let kind: Kind
}

/// The fallback gate of one fresh mode=tool send: degradation and "the request did not carry propose_memory" share it, so the fallback runs at most once per message;
/// `settled` records whether the post-send suggestion-bar decision has already run (when the fallback ran first, that decision is no longer overridden by tool).
@MainActor
final class ProposeFallbackOnce {
    private(set) var ran = false
    private(set) var settled = false

    /// Returns true on the first call.
    func begin() -> Bool {
        guard !ran else { return false }
        ran = true
        return true
    }

    /// The post-send decision starts: returns false when the fallback has already run.
    func markSettled() -> Bool {
        settled = true
        return !ran
    }
}

private extension Conversation {
    /// Summary form of the cold-start mirror (the shape `fetchConversationSummaryProjection` reads back): no bodies, the count is the override.
    var coldStartSummary: Conversation {
        guard messagesAreLoaded else { return self }
        var summary = self
        summary.messageCountOverride = displayMessageCount
        summary.messages = []
        summary.messagesAreLoaded = false
        return summary
    }
}

/// One result from the persist queue, handed back to the main thread for wrap-up: enqueueing happens synchronously on the
/// caller's thread (keeping the order with other writes) and the main thread suspends for the result.
nonisolated final class ConversationPersistOutcome<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Result<Value, Error>, Never>?

    func fulfill(_ result: Result<Value, Error>) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            self.result = result
            lock.unlock()
        }
    }

    var value: Result<Value, Error> {
        get async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }
    }
}
