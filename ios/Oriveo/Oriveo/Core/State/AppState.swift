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

/// The realtime voice model selected in the picker: a conversation's comes from its model field, and the home one is kept in memory only.
struct RealtimeModelSelection: Hashable, Sendable {
    let providerID: UUID
    let providerKind: ProviderKind
    let model: String
}

/// Realtime model disclosure pending a reply: shown the first time a realtime row of a provider is picked in the picker (home conversationID is nil).
struct RealtimeModelDisclosureRequest: Identifiable, Hashable {
    let selection: RealtimeModelSelection
    let conversationID: UUID?

    var id: String {
        "\(selection.providerID.uuidString)|\(selection.model)|\(conversationID?.uuidString ?? "home")"
    }
}

/// Result of selecting a realtime model.
enum RealtimeModelSelectionOutcome: Hashable, Sendable {
    /// Applied.
    case applied(RealtimeModelSelection)
    /// The provider's (providerKind, realtime) has not accepted the disclosure yet: show it first and leave the selection unchanged.
    case needsDisclosure(RealtimeModelSelection)
    /// The voice catalog is not ready: stage the selection (only the latest is kept) and re-check when the catalog arrives; if it is not accepted, set realtimeSelectionGoneNotice.
    case pending(RealtimeModelSelection)
    /// The connection is no longer present.
    case unavailable
}

/// A staged realtime selection rejected on re-check: a one-shot signal taken by the page, which then shows a toast.
struct RealtimeSelectionGoneNotice: Identifiable, Hashable, Sendable {
    let id: UUID
    let conversationID: UUID?
    let model: String
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

    /// Route stack observer: once set, it is installed on every window's manager, and managers created later get it too.
    @ObservationIgnored var navigationPathObserver: ((_ old: [AppRoute], _ new: [AppRoute]) -> Void)? {
        didSet {
            for manager in allWindowNavigations {
                manager.onPathChange = navigationPathObserver
            }
        }
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
            manager.onPathChange = navigationPathObserver
            manager.onSelectedTabChange = { [weak self] in self?.selectedTabDidChange() }
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
    /// The memory candidate generation triggered by the latest new send (background); tests await it before reading the repository.
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
    /// Mirror of the active note list summaries (maintained by NoteManager).
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
    /// Realtime voice model selected on the home page (key nil), kept in memory only: a cold start returns to the text model.
    /// A conversation's realtime selection lives in its own providerID / providerKind / modelID and is not kept here.
    private(set) var realtimeModelSelections: [UUID?: RealtimeModelSelection] = [:]
    /// Voice catalog used to judge realtime selection: only what this process has cached (no disk read, no request); nil means the catalog is not ready.
    /// Replacing how the catalog is fetched (test injection) follows the same rule as pushes: the revision increments only when the fetched content changes.
    @ObservationIgnored var realtimeVoiceCatalog: () -> VoiceCatalog? = {
        AppState.realtimeVoiceCatalog(from: ReadAloudCatalogSnapshot.shared.state)
    } {
        didSet { bumpRealtimeVoiceCatalogRevision() }
    }
    /// Catalog state -> catalog used for judging: nil (loading) and load failure both count as not ready; a server with no catalog (unavailable / 404)
    /// is a ready, empty catalog: it no longer waits for the catalog and is handled by the delisting banner or realtime judgment (same as the Android empty state).
    nonisolated static func realtimeVoiceCatalog(from state: VoiceCatalogState?) -> VoiceCatalog? {
        if state == .unavailable { return .empty }
        return state?.catalog
    }
    /// Voice catalog revision: increments when catalog content changes. The catalog snapshot itself is not observable; realtimeModelSelection reads this,
    /// so when the catalog arrives after the UI, the conversation page and home re-judge at once (the voice panel appears and the capability projection changes with it).
    private(set) var realtimeVoiceCatalogRevision: UInt = 0
    /// Realtime row selected while the catalog was not ready (only the latest is kept; nil on home): re-checked when the catalog arrives, and a text model selection clears it.
    @ObservationIgnored private var pendingRealtimeSelection: (
        selection: RealtimeModelSelection,
        conversationID: UUID?
    )?
    /// A staged realtime selection rejected on re-check: the page observes it, shows a toast and takes it.
    private(set) var realtimeSelectionGoneNotice: RealtimeSelectionGoneNotice?
    /// Realtime catalog content seen at the last increment; outer nil = never seen, inner nil = catalog not ready.
    @ObservationIgnored private var lastSeenRealtimeCatalog: RealtimeModelPolicy.RealtimeCatalog??
    /// Task that creates the catalog subscription; holds this instance only weakly.
    @ObservationIgnored private var realtimeVoiceCatalogSubscription: Task<Void, Never>?
    /// Handle of the created catalog subscription; unsubscribed on resubscribe and in deinit.
    @ObservationIgnored private var realtimeVoiceCatalogHandle: VoiceCatalogSubscription?

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
    /// Session every provider request goes through (chat, catalog sync and one-shot sends such as skill drafts).
    @ObservationIgnored let providerSession: URLSession
    /// In-memory copy of the current partition's memory items: the request snapshot reads it, so the main thread never reads the database.
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
        self.mcpServerDirectory = mcpServerDirectory ?? McpServerDirectory()
        let requestedSessionUID = sessionUID
        providerManager = ProviderManager(session: providerSession)
        chatManager = ChatManager(providerSession: providerSession, toolCallMemory: toolCallMemory)
        self.providerSession = providerSession
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
        if seedDemoData {
            // Demo data is already in memory (no snapshot read): treat it as installed.
            sessionSnapshotApplied = true
            // Demo data lives in memory only, but the conversation mirror, notes and monthly totals still read and write the partition database: open it in the background as with a normal launch, never on the main thread.
            prepareDemoSessionStoreIfNeeded()
        }

        self.mcpServerDirectory.isSessionStoreReady = { [weak self] in self?.sessionStoreReady ?? true }
        primaryNavigation.onSelectedTabChange = { [weak self] in self?.selectedTabDidChange() }
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
        Self.liveInstancesForTesting.setObject(
            LiveInstanceRecordForTesting(
                initialUID: boundPartitionUID,
                creationLabel: Self.creationLabelProviderForTesting?() ?? "unlabeled"
            ),
            forKey: self
        )
        #endif
    }

    #if DEBUG
    /// Test seam: the AppStates still alive in the process (weak references) -> the partition each was bound to at construction. Before a test deletes a partition it finds them by partition and waits for their in-flight reads and writes to drain
    /// (see OriveoTests/Support/TestPartitionCleanup), so cases do not have to pass instances around.
    private static let liveInstancesForTesting = NSMapTable<AppState, LiveInstanceRecordForTesting>.weakToStrongObjects()

    /// Registry value for a live instance: the partition bound at construction and the label of the test that created it.
    private final class LiveInstanceRecordForTesting: NSObject {
        let initialUID: String
        let creationLabel: String

        init(initialUID: String, creationLabel: String) {
            self.initialUID = initialUID
            self.creationLabel = creationLabel
        }
    }

    /// Test seam: returns the label of the test creating an instance (installed by the test target; nil = "unlabeled").
    private static let creationLabelProviderLock = NSLock()
    nonisolated(unsafe) private static var creationLabelProvider: (@Sendable () -> String?)?

    nonisolated static var creationLabelProviderForTesting: (@Sendable () -> String?)? {
        get {
            creationLabelProviderLock.lock()
            defer { creationLabelProviderLock.unlock() }
            return creationLabelProvider
        }
        set {
            creationLabelProviderLock.lock()
            defer { creationLabelProviderLock.unlock() }
            creationLabelProvider = newValue
        }
    }

    /// Live instances built for, or currently bound to, one of the given partitions.
    static func liveInstancesForTesting(boundTo uids: Set<String>) -> [(state: AppState, uid: String, creationLabel: String)] {
        guard let states = liveInstancesForTesting.keyEnumerator().allObjects as? [AppState] else { return [] }
        return states.compactMap { state in
            let record = liveInstancesForTesting.object(forKey: state)
            let bound = uids.contains(state.boundPartitionUID) || record.map { uids.contains($0.initialUID) } == true
            guard bound else { return nil }
            return (state, state.boundPartitionUID, record?.creationLabel ?? "unlabeled")
        }
    }

    /// Test seam: work from released instances still in flight (partition -> the tasks that wait for them to drain). A case declares its local AppState after `defer`, so the instance is released first;
    /// the cold-start load, memory backfill and write-queue work it queued keep running. Cleanup waits per partition on those tasks and does not rely on the instance staying alive.
    private static let releasedDrainsLock = NSLock()
    nonisolated(unsafe) private static var releasedDrains: [String: [Task<Void, Never>]] = [:]

    /// Takes the drain tasks left by released instances on the given partitions.
    nonisolated static func takeReleasedDrainsForTesting(boundTo uids: Set<String>) -> [Task<Void, Never>] {
        releasedDrainsLock.lock()
        defer { releasedDrainsLock.unlock() }
        return uids.flatMap { releasedDrains.removeValue(forKey: $0) ?? [] }
    }
    #endif

    static let preview: AppState = {
        AppState(seedDemoData: true)
    }()

    nonisolated deinit {
        pendingWorkItems.cancelAll()
        #if DEBUG
        // Register the in-flight reads and writes of a released instance (see takeReleasedDrainsForTesting). Only the task handles and queues are captured, not the sub-managers:
        // a kept-alive manager would keep running its [weak self] callbacks and read the released unowned appState. Note reloads are registered per partition on NoteManager.
        let tails = [
            sessionStoreReadyTask, memoryReconcileTail, memoryItemUndoTail, useMemoryWriteTail,
            checkpointInvalidationTail,
        ]
        let queue = conversationPersistQueue
        let drain = Task { @MainActor in
            for tail in tails { await tail?.value }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async { continuation.resume() }
            }
        }
        Self.releasedDrainsLock.lock()
        Self.releasedDrains[boundPartitionUID, default: []].append(drain)
        Self.releasedDrainsLock.unlock()
        #endif
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
        // The session snapshot is still being read in the background (not yet loaded into memory): the in-memory providers and folders are empty, and writing them would overwrite the disk snapshot with empty data.
        guard persistsSession, sessionSnapshotApplied, !chatManager.isAnyStreaming else { return }

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
        conversationWriteGeneration[conversation.id, default: 0] += 1

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
        // Count deletions as writes so a read-back that started earlier cannot resurrect them.
        for id in ids {
            conversationWriteGeneration[id, default: 0] += 1
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
        conversationWriteGeneration[id, default: 0] += 1
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

    /// Whether a fallback may read `uid`'s store on the main thread: the store is open, the session persists to it and
    /// the file exists. The root's loading state does not guarantee the first condition on its own: the outgoing view
    /// tree still gets an update after the mirror is cleared and the store closed (and `.task` continuations land in
    /// that window), and an empty mirror is exactly what sends these fallbacks to the store.
    func canReadAuthoritativeConversationStore(uid: String) -> Bool {
        sessionStoreReady && prefersAuthoritativeConversationStore && DatabaseManager.shared.hasDatabase(for: uid)
    }

    func resetConversationProjectionMirror() {
        conversations = []
    }

    /// Test only: blocks until the background DB persist queue has drained.
    /// Do not use sync {}: when the main thread dispatch_syncs an idle serial queue, libdispatch lets the calling thread run the queued writes ahead of it itself,
    /// so the database write runs on the main thread (flagged by the main-thread write guard). Only signal and wait on the main thread; the earlier writes still run on the queue thread.
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
            in: provider,
            voiceCatalog: realtimeVoiceCatalog()
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

    /// When a conversation is opened, seeds the runtime mirror with its persisted pinnedNoteIds (first time only, so it does not overwrite pins already set at runtime).
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
        // Picking any text model exits realtime: the conversation's realtime selection ends along with the model field rewrite below, and the home page clears its memory.
        // A realtime row staged for the same conversation (or home) while the catalog was not ready is discarded as well.
        if let pending = pendingRealtimeSelection, pending.conversationID == conversationID {
            pendingRealtimeSelection = nil
        }
        if conversationID == nil {
            realtimeModelSelections[nil] = nil
        }
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
        // Queued checkpoint invalidations from the edit truncation are persisted first, then the checkpoints are read to assemble the context.
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
            // Before the first message of a new conversation is sent, tool-panel toggles are recorded under the draft id; when the conversation is created they move to the real id.
            // This must happen before sending: the tools available for this send are read by conversation id. If the move fails, only this send goes without tools.
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

        // The edit-resend flag is consumed by chatManager.sendMessage, so it is read first: an edit resend does not trigger suggestion judgment.
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
        guard case .sent(let userMessageID) = outcome else {
            return outcome
        }
        // Every actual send (a new conversation's first message and existing ones) records last-used with the connection and model that were sent.
        if let sentConversation = conversation(for: targetConversationID),
           let sentProvider = provider(for: sentConversation.providerID),
           let sentModel = sendableModel(for: sentConversation, provider: sentProvider) {
            setActiveModel(providerID: sentProvider.id, modelID: sentModel.id)
        }
        // Only newly sent messages are judged: edit resends and onboarding auto-sends are not; retry and regenerate do not go through this entry.
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

    /// Same judgment as injection: conversation ?? Skill ?? true.
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
        // Continuing does not truncate, and invalidation is only queued, not awaited: waiting would interleave badly with the managed recovery task (the ManagedChatManagerTests recovery case was observed stuck at .generating); ordering is covered by waitForCheckpointInvalidations before sends and the digest check on read.
        // .generating); ordering is covered by `waitForCheckpointInvalidations` before sends and the digest check on read.
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

    /// Voice conversation interjection continuation: see ChatManager.amendLastUserMessage; the truncation invalidation hook is the same as regenerateMessage's.
    func amendLastUserMessage(
        _ text: String, messageID: UUID? = nil, turnText: String? = nil, in conversationID: UUID
    ) async -> Bool {
        let historyIds = checkpointHistoryIds(of: conversationID)
        let sent = await chatManager.amendLastUserMessage(text, targetMessageID: messageID, turnText: turnText, in: conversationID)
        await invalidateCheckpointsAfterTruncation(conversationID: conversationID, historyIdsBefore: historyIds).value
        return sent
    }

    /// The full history ids before truncation (complete the summary projection first, otherwise the pre-change history is incomplete).
    private func checkpointHistoryIds(of conversationID: UUID) -> [String] {
        guard hydrateConversationMessagesIfNeeded(id: conversationID),
              let conversation = conversations.first(where: { $0.id == conversationID })
        else { return [] }
        return conversation.messages.map(\.id.uuidString)
    }

    /// Invalidation hook for edit and regenerate: messages in the pre-truncation history that are no longer present after truncation are affected;
    /// empty when the send was rejected or nothing was truncated, and invalidate does not delete. Deleted checkpoints are propagated to the remote as well.
    /// Database writes are not awaited synchronously on the main thread (the write lock can be held for seconds by a whole-table write): queued on the serial tail task,
    /// the async entry awaits the returned task, while the sync entry (edit) only queues; before sending, waitForCheckpointInvalidations waits for it to settle.
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

    /// Waits for queued checkpoint invalidations to land in the database (before a send reads checkpoints, and before test assertions).
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
        var conversation = conversationForFirstSend(provider: active.provider, modelID: active.model.id)
        // Do not write last-used: a realtime selection does not write it when the call opens; a non-realtime one was already written when the call started (recordLastUsedForRealtimeVoice).
        // The home page's realtime selection (key nil) follows the conversation: it is written into the new conversation's model field, and the home page returns to the text model.
        if let homeSelection = realtimeModelSelections.removeValue(forKey: nil),
           let provider = provider(for: homeSelection.providerID),
           isRealtimeSelection(provider: provider, model: homeSelection.model) {
            conversation.providerID = provider.id
            conversation.providerKind = provider.kind
            conversation.modelID = homeSelection.model
        }
        pendingDraftInstructions = ""
        upsertConversationProjection(conversation)
        presentChat(conversationID: conversation.id)
        return conversation.id
    }

    /// Records actual use when a realtime call starts: an existing conversation writes its sendable model, and an unsendable one is not written;
    /// the home page (conversation id nil) writes the model currently selected in the pill. When the selection is a realtime model, neither opening nor reopening writes.
    func recordLastUsedForRealtimeVoice(conversationID: UUID?) {
        guard realtimeModelSelection(for: conversationID) == nil else { return }
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

    /// The realtime voice model currently selected for a conversation (home is nil); nil when none was picked or the text model was restored.
    func realtimeModelSelection(for conversationID: UUID?) -> RealtimeModelSelection? {
        realtimeModelSelections[conversationID]
    }

    /// Whether the (provider, model) pair is a realtime selection under the cached voice catalog (synchronous read).
    private func isRealtimeSelection(provider: Provider, model: String) -> Bool {
        RealtimeModelPolicy.realtimeSelection(
            connection: provider.realtimePolicyConnection,
            model: model,
            realtimeCatalog: realtimeVoiceCatalog()?.realtimePolicyCatalog
        ).isRealtime
    }

    /// Applies a realtime selection: the home page keeps it in memory, a conversation writes it into its model fields.
    /// Returns false (no change) when the connection or conversation is gone, the catalog is not ready, or the catalog does not accept the model.
    /// Does not bump when the catalog content matches the previous one: a repeated push of the same catalog does not make readers re-evaluate.
    private func bumpRealtimeVoiceCatalogRevision() {
        let current = realtimeVoiceCatalog()?.realtimePolicyCatalog
        if let lastSeen = lastSeenRealtimeCatalog, lastSeen == current { return }
        lastSeenRealtimeCatalog = .some(current)
        realtimeVoiceCatalogRevision &+= 1
        resolvePendingRealtimeSelection()
    }

    /// Re-checks the staged realtime selection once the catalog arrives: apply it if accepted, otherwise raise a one-shot notice.
    private func resolvePendingRealtimeSelection() {
        guard let pending = pendingRealtimeSelection, realtimeVoiceCatalog() != nil else { return }
        pendingRealtimeSelection = nil
        guard !applyRealtimeModelSelection(pending.selection, for: pending.conversationID) else { return }
        realtimeSelectionGoneNotice = RealtimeSelectionGoneNotice(
            id: UUID(),
            conversationID: pending.conversationID,
            model: pending.selection.model
        )
    }

    /// The page takes the notice after showing its toast; leaves it alone if a newer notice replaced it.
    func consumeRealtimeSelectionGoneNotice(_ notice: RealtimeSelectionGoneNotice) {
        guard realtimeSelectionGoneNotice?.id == notice.id else { return }
        realtimeSelectionGoneNotice = nil
    }

    private func applyRealtimeModelSelection(_ selection: RealtimeModelSelection, for conversationID: UUID?) -> Bool {
        guard let provider = provider(for: selection.providerID),
              isRealtimeSelection(provider: provider, model: selection.model)
        else { return false }
        guard let conversationID else {
            realtimeModelSelections[nil] = selection
            return true
        }
        guard conversation(for: conversationID) != nil else { return false }
        return writeConversationModelFields(conversationID, provider: provider, modelID: selection.model)
    }

    /// Writes the conversation's providerID / providerKind / modelID; false when the conversation is gone, no write when unchanged.
    /// Does not write lastUsedModelRef.
    @discardableResult
    private func writeConversationModelFields(_ conversationID: UUID, provider: Provider, modelID: String) -> Bool {
        guard let current = conversation(for: conversationID) else { return false }
        guard current.providerID != provider.id || current.providerKind != provider.kind || current.modelID != modelID
        else { return true }
        updateConversationModelProjections([
            ConversationModelUpdate(
                conversationID: conversationID,
                providerID: provider.id,
                providerKind: provider.kind,
                modelID: modelID,
                metadataUpdatedAt: Date()
            )
        ])
        return true
    }

    /// Selects a realtime row in the picker: memory only; does not write lastUsedModelRef or change the conversation's modelID.
    /// Not applied when the provider's (providerKind, realtime) has not accepted the disclosure; returns .needsDisclosure, and resolveRealtimeModelDisclosure is called after the answer.
    @discardableResult
    func selectRealtimeModel(
        providerID: UUID,
        model: String,
        for conversationID: UUID?,
        disclosures: VoiceDisclosureStore = VoiceDisclosureStore()
    ) -> RealtimeModelSelectionOutcome {
        guard let provider = provider(for: providerID) else { return .unavailable }
        let selection = RealtimeModelSelection(providerID: provider.id, providerKind: provider.kind, model: model)
        guard disclosures.hasAccepted(provider.kind, direction: .realtime) else {
            return .needsDisclosure(selection)
        }
        if realtimeVoiceCatalog() == nil {
            pendingRealtimeSelection = (selection, conversationID)
            return .pending(selection)
        }
        guard applyRealtimeModelSelection(selection, for: conversationID) else { return .unavailable }
        return .applied(selection)
    }

    /// Reply to the realtime model disclosure: accept -> record consent for `(providerKind, realtime)` and apply; decline (including swipe-to-dismiss) -> no change.
    /// Returns whether the selection was applied; when accepted but the voice catalog is not ready, it is held pending and false is returned.
    @discardableResult
    func resolveRealtimeModelDisclosure(
        _ selection: RealtimeModelSelection,
        for conversationID: UUID?,
        accepted: Bool,
        disclosures: VoiceDisclosureStore = VoiceDisclosureStore()
    ) -> Bool {
        guard accepted else { return false }
        disclosures.markAccepted(selection.providerKind, direction: .realtime)
        // The realtime disclosure names this provider and links its privacy policy, so accepting counts as consent to that provider's disclosure.
        ProviderDisclosureStore.markAccepted(selection.providerKind)
        // Voice catalog still not ready on accept: hold pending just like selectRealtimeModel, return not applied, and re-check when the catalog arrives.
        if realtimeVoiceCatalog() == nil {
            pendingRealtimeSelection = (selection, conversationID)
            return false
        }
        return applyRealtimeModelSelection(selection, for: conversationID)
    }

    /// Cancel realtime: the home page clears the in-memory selection; the conversation switches back to the last-used text model (same as a new conversation's model). No-op when the selection is not realtime.
    func clearRealtimeModelSelection(for conversationID: UUID?) {
        guard let conversationID else {
            guard realtimeModelSelections[nil] != nil else { return }
            realtimeModelSelections[nil] = nil
            return
        }
        guard realtimeModelSelection(for: conversationID) != nil, let active = activeModel else { return }
        writeConversationModelFields(
            conversationID,
            provider: active.provider,
            modelID: Self.persistedConversationModelID(requestedModelID: active.model.id, in: active.provider)
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

    /// Load the current partition's data into memory
    /// - Parameter startsAttachmentCleanup: Whether to start this partition's attachment cleanup (sidecar + orphaned images). Cold start and logout back to guest pass true;
    ///   a partition switch on login passes false: after guest data (conversation upsert + image copy) is migrated, `AuthPartitionManager` starts it again
    ///   (contract: attachment cleanup, supplementary item 3).
    ///
    /// Production paths (cold start, partition switch, retry while the database is already open) do not read the snapshot or open the database on the main thread: the session snapshot is read in the background (decode + Keychain),
    /// then applied on the main thread with the non-database data; the database is pre-opened in the background (connect + migrate) meanwhile, during which `sessionStoreReady == false` and the home page shows the loading skeleton;
    /// once open, the session is loaded back on the main thread by reading the database (`loadSessionStore`). The test host (`allowsMainThreadFirstOpen`) runs the whole sequence synchronously.
    func loadSession(boundTo uid: String? = nil, startsAttachmentCleanup: Bool = true) {
        resetTransientNoteContext()
        preferences = AppPreferencesStore.load()
        let activeUID = uid ?? AppSessionStore.activeUID
        boundPartitionUID = activeUID
        sessionLoadGeneration &+= 1

        // Stop snapshot writes before clearing: the didSet fired by the clear must not write the empty providers back to the disk snapshot (writes resume only after the snapshot is applied in memory).
        sessionSnapshotApplied = false
        providers = []
        folders = []
        // Do not reset hasCompletedOnboarding: the user has already gone through onboarding and reached the main UI
        lastUsedModelRef = nil
        let accountGeneration = accountWriteGeneration
        let tabGeneration = selectedTabWriteGeneration

        if DatabaseManager.allowsMainThreadFirstOpen {
            // Test host: read the snapshot and open the database synchronously, applying the same `applySessionSnapshot` as the background path.
            #if DEBUG
            let (snapshot, readOnMain) = Self.readSessionSnapshot(for: activeUID)
            if readOnMain { debugSessionSnapshotReadsOnMain += 1 }
            #else
            let snapshot = Self.readSessionSnapshot(for: activeUID)
            #endif
            applySessionSnapshot(snapshot, accountGeneration: accountGeneration, tabGeneration: tabGeneration)
            sessionStoreReady = true
            sessionStoreReadyTask = nil
            loadSessionStore(uid: activeUID, snapshot: snapshot, startsAttachmentCleanup: startsAttachmentCleanup, writtenSince: nil)
            return
        }
        // Production path (cold start, partition switch, retry while the database is already open): the session snapshot (JSON decode + Keychain read of API keys) and the database open both run in the background.
        sessionStoreReady = false
        conversations = []
        let generation = sessionLoadGeneration
        let generations = conversationWriteGeneration
        // A snapshot write still pending on disk within the debounce window (0.3s): take it out and queue it on the write queue (in the background, behind the immediate writes already enqueued -
        // a live debounced item means it is later than those immediate writes), then drain before reading the snapshot below. A reload of the same uid (retry from the blocking page) must be able to read the just-added provider.
        if let pendingSnapshotWrite = pendingSessionPersistWorkItem {
            pendingSessionPersistWorkItem = nil
            conversationPersistQueue.async(qos: .userInitiated) {
                guard !pendingSnapshotWrite.isCancelled else { return }
                pendingSnapshotWrite.perform()
                // Already on disk: the trigger scheduled for 0.3s later is cancelled.
                pendingSnapshotWrite.cancel()
            }
        }
        sessionStoreReadyTask = Task { @MainActor [weak self] in
            // Drain the write queue first: pending disk writes from the previous partition (the logout snapshot, checkpoint) complete before the next partition's database is opened;
            // when reloading the same partition, snapshot writes still pending in the queue (and restore snapshot writes) must also finish first, so the read below sees them.
            await self?.drainConversationPersistQueue()
            #if DEBUG
            let (snapshot, readOnMain) = await Task.detached(priority: .userInitiated) { () -> (AppSessionSnapshot?, Bool) in
                if let delay = AppState.sessionSnapshotLoadDelayForTesting {
                    try? await Task.sleep(for: delay)
                }
                return AppState.readSessionSnapshot(for: activeUID)
            }.value
            #else
            let snapshot = await Task.detached(priority: .userInitiated) {
                AppState.readSessionSnapshot(for: activeUID)
            }.value
            #endif
            do {
                guard let self, self.sessionLoadGeneration == generation, self.partitionIsStillBound(activeUID) else { return }
                #if DEBUG
                if readOnMain { self.debugSessionSnapshotReadsOnMain += 1 }
                #endif
                self.applySessionSnapshot(snapshot, accountGeneration: accountGeneration, tabGeneration: tabGeneration)
            }
            let snapshotConversations = snapshot?.conversations
            // The restore snapshot's disk read and decode happen in the background after the drain, in parallel with the database open; when the snapshot carries its own conversations, no disk read occurs. Read it only once per load.
            async let recoveryRead: [Conversation] = snapshotConversations == nil
                ? Task.detached(priority: .userInitiated) {
                    ConversationRuntimeBridge.loadRecoveryProjection(snapshot: nil, uid: activeUID)
                }.value
                : []
            var openError: Error?
            do {
                _ = try await DatabaseManager.shared.prepare(for: activeUID)
            } catch {
                openError = error
            }
            let diskRecovered = await recoveryRead
            let recovered = snapshotConversations ?? diskRecovered
            guard let self, self.sessionLoadGeneration == generation, self.partitionIsStillBound(activeUID) else { return }
            // Mark ready first: the cache rebuild triggered by applying the session below (monthly totals etc.) needs to read the database.
            self.sessionStoreReady = true
            if let openError {
                // Cannot open: same as a database read failure - fall back to the restore snapshot and enter the blocking state (a real error, not "not pre-opened").
                self.databaseHealthProbe.recordFailure(openError)
                self.conversations = recovered
            } else {
                self.loadSessionStore(
                    uid: activeUID, snapshot: snapshot, recovered: recovered,
                    startsAttachmentCleanup: startsAttachmentCleanup, writtenSince: generations
                )
            }
        }
    }

    /// Read one partition's session snapshot (JSON decode + Keychain read of API keys). Pure file / Keychain IO; the production path calls it in the background.
    #if DEBUG
    /// Second item: whether this read happened on the main thread (tests assert the production path gives false).
    nonisolated static func readSessionSnapshot(for uid: String) -> (AppSessionSnapshot?, Bool) {
        let readOnMain = Thread.isMainThread
        return (AppSessionStore.load(for: uid), readOnMain)
    }
    #else
    nonisolated static func readSessionSnapshot(for uid: String) -> AppSessionSnapshot? {
        AppSessionStore.load(for: uid)
    }
    #endif

    /// Apply the session snapshot to memory (shared by the synchronous and background paths). Before this, `loadSession` has already cleared providers / folders / lastUsedModelRef.
    /// - Account / selected tab written while the snapshot was loading: memory wins.
    private func applySessionSnapshot(_ snapshot: AppSessionSnapshot?, accountGeneration: UInt, tabGeneration: UInt) {
        let accountWrittenDuringLoad = accountWriteGeneration != accountGeneration
        let tabWrittenDuringLoad = selectedTabWriteGeneration != tabGeneration
        if let snapshot {
            if !tabWrittenDuringLoad {
                selectedTab = snapshot.selectedTab
            }
            providers = snapshot.providers.map { $0.recoveredFromPersistence() }
            hasCompletedOnboarding = snapshot.hasCompletedOnboarding || !snapshot.providers.isEmpty || !(snapshot.conversations ?? []).isEmpty
            lastUsedModelRef = snapshot.lastUsedModelRef
            folders = snapshot.folders ?? []    // Backward compatibility: old snapshots lack this field
            // The color backfill in init runs before the snapshot is applied (background path): backfill once after applying (only assigns colors to folders without one; idempotent).
            if folderManager.isBound {
                folderManager.assignColorsIfNeeded()
            }
        }
        sessionSnapshotApplied = true
        // Writes made in the meantime were not persisted to the snapshot (the guard blocked them): write it once after applying.
        if accountWrittenDuringLoad || tabWrittenDuringLoad {
            persistSessionIfNeeded()
        }
    }

    private func selectedTabDidChange() {
        selectedTabWriteGeneration &+= 1
        persistSessionIfNeeded()
    }

    /// Demo data startup (sample / store-screenshot seed): memory state is already in place; only the database partition is moved to a background pre-open (following the end of `loadSession`).
    /// Until it is open `sessionStoreReady == false`; once open, mark ready and rebuild the derived caches that depend on the database (monthly totals etc.).
    private func prepareDemoSessionStoreIfNeeded() {
        let activeUID = boundPartitionUID
        sessionLoadGeneration &+= 1
        guard DatabaseManager.shared.openedPool(for: activeUID) == nil, !DatabaseManager.allowsMainThreadFirstOpen else {
            sessionStoreReady = true
            sessionStoreReadyTask = nil
            return
        }
        sessionStoreReady = false
        let generation = sessionLoadGeneration
        sessionStoreReadyTask = Task { @MainActor [weak self] in
            var openError: Error?
            do {
                await self?.drainConversationPersistQueue()
                _ = try await DatabaseManager.shared.prepare(for: activeUID)
            } catch {
                openError = error
            }
            guard let self, self.sessionLoadGeneration == generation, self.partitionIsStillBound(activeUID) else { return }
            self.sessionStoreReady = true
            if let openError {
                self.databaseHealthProbe.recordFailure(openError)
            }
            self.conversationsVersion &+= 1
        }
    }

    /// Load after the partition database is open: read the database to apply the session, memory items, startup reclamation, etc. (main thread read-only; all writes are queued).
    /// - Parameter recovered: the recovery projection already read in the background; when nil (synchronous branch of the test host) it is read once here. The normal and database-read-failure paths share this one.
    /// - Parameter writtenSince: the write generation when the background pre-open started loading; conversations written, created, or deleted in memory during the pre-open win in memory.
    private func loadSessionStore(
        uid activeUID: String,
        snapshot: AppSessionSnapshot?,
        recovered: [Conversation]? = nil,
        startsAttachmentCleanup: Bool,
        writtenSince generations: [UUID: Int]?
    ) {
        // Partition activation: migrate old fields into memory items / old client edits flow back
        reconcileMemoryItems()
        memoryItemsCache.bind(uid: activeUID)
        let mirrorWhileOpening = generations == nil ? nil : conversations
        let recoveredProjection = recovered ?? conversationRuntimeBridge.loadRecoveryProjection(
            snapshot: snapshot,
            uid: activeUID
        )

        do {
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
                // The full-table write is queued on the write queue (the main thread does not synchronously wait for the write lock); later enqueued writes queue behind it. Memory first uses the summary form of the merged result
                // (the cold-start mirror holds only summaries, the same form read back from the database); after the write lands, refresh once more from the database.
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
            if let generations, let mirrorWhileOpening {
                mergeConversationsWrittenWhileOpening(since: generations, mirror: mirrorWhileOpening)
            }
            // The local database read succeeded. In the blocking state this success means "the user cleared space and the retry worked"; the closed-loop analytics event is emitted inside.
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
            conversations = recoveredProjection
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

        // Legacy data migration: fill in missing model prices (providers are already applied at this point; demo data does not go through here).
        if AppStateLaunchPolicy.shouldRunProviderPriceMigration(
            seedDemoData: !persistsSession,
            isRunningTests: AppRuntime.isRunningTests,
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

    /// The partition database is open (the database phase of `loadSession` has run); when false the home page shows the loading skeleton, and database-related entry points wait for `sessionStoreReadyTask`.
    private(set) var sessionStoreReady = true
    /// Task that pre-opens the partition database in the background and loads the session; nil once ready.
    @ObservationIgnored private(set) var sessionStoreReadyTask: Task<Void, Never>?
    @ObservationIgnored private var sessionLoadGeneration: UInt = 0
    /// Write count per conversation (bumped on upsert and delete); a background pre-open compares it to
    /// keep conversations written or deleted while the database was opening.
    @ObservationIgnored private var conversationWriteGeneration: [UUID: Int] = [:]
    /// Whether this `loadSession`'s session snapshot is applied in memory. While false (snapshot being read in the background), all snapshot-writing entry points write no snapshot,
    /// so the cleared providers / folders state cannot overwrite the disk snapshot.
    /// Initial value false: writes before `loadSession` in init (didSet / method calls) also write no snapshot, otherwise a debounced write would persist empty providers before the background read,
    /// and the read-back would be an empty snapshot. Demo data is set to true after it is applied in init.
    @ObservationIgnored private(set) var sessionSnapshotApplied = false
    /// Account / selected-tab write generations: writes made while the snapshot was read in the background; memory wins when the snapshot is applied.
    @ObservationIgnored private var accountWriteGeneration: UInt = 0
    @ObservationIgnored private var selectedTabWriteGeneration: UInt = 0
    #if DEBUG
    /// Number of times this instance read the session snapshot on the main thread (tests assert the production path gives 0; counted per instance so parallel suites do not interfere).
    @ObservationIgnored private(set) var debugSessionSnapshotReadsOnMain = 0
    /// Test seam: wait this long before reading the session snapshot in the background (simulates a snapshot read slower than other writes).
    nonisolated(unsafe) static var sessionSnapshotLoadDelayForTesting: Duration?
    #endif

    /// Wait for the partition database to open and the session to finish applying (returns immediately if already ready).
    func waitForSessionStore() async {
        while !sessionStoreReady, let task = sessionStoreReadyTask {
            await task.value
            // This load was superseded by a newer loadSession with no new task (or was invalidated): do not spin.
            if sessionStoreReadyTask == task, !sessionStoreReady { return }
        }
    }

    /// Before switching partitions, close the current partition database: the checkpoint is queued on the write queue (behind the writes already enqueued), then immediately mark "database not ready" and release the singleton reference.
    /// From now until the next partition is opened (`loadSession` background pre-open), all UI and database-related entry points are treated as not ready, and the main thread never touches the closed database.
    func closeSessionStoreForPartitionSwitch() {
        enqueuePartitionCheckpoint()
        // The old partition's database is closed: the in-memory state no longer represents the snapshot of the bound partition. Logout then clears providers / folders / account,
        // and if snapshot writes were not turned off, those writes would land on the old partition as debounced snapshots, queued behind the logout snapshot and overwrite it empty (losing providers and keys).
        // Debounced snapshots already taken before closing are still written as usual; writes are re-enabled after the next loadSession applies the new partition's snapshot.
        sessionSnapshotApplied = false
        sessionStoreReady = false
        // The real close queues behind the checkpoint and every write already on the persist queue, and waits for the
        // local write tails captured right now (notes, memory items): only local writes, never sending / network.
        let noteTail = noteManager.pendingWriteTail
        let memoryItemTail = memoryItemUndoTail
        let barrier: (@Sendable () async -> Void)? = noteTail == nil && memoryItemTail == nil ? nil : {
            await noteTail?.value
            await memoryItemTail?.value
        }
        conversationRuntimeBridge.close(after: conversationPersistQueue, barrier: barrier)
    }

    /// While pre-opening (the mirror starts empty), conversations written in memory win: created or changed ones use the in-memory version, deleted ones are not resurrected.
    /// These writes are queued on the write queue after the database read, so the value read back from the database is still the old one.
    private func mergeConversationsWrittenWhileOpening(since generations: [UUID: Int], mirror: [Conversation]) {
        let written = Set(conversationWriteGeneration.filter { generations[$0.key, default: 0] != $0.value }.keys)
        guard !written.isEmpty else { return }
        let mirrorByID = Dictionary(mirror.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged = conversations.compactMap { loaded -> Conversation? in
            guard written.contains(loaded.id) else { return loaded }
            return mirrorByID[loaded.id]
        }
        let loadedIDs = Set(conversations.map(\.id))
        merged.insert(contentsOf: mirror.filter { written.contains($0.id) && !loadedIDs.contains($0.id) }, at: 0)
        conversations = merged
    }

    /// Classify unclassified official providers against the current metadata, then run the lazy migrations R1 / R2 over all official providers and write back locally.
    /// Mutates the array directly instead of going through updateProvider: updatedAt is not changed and no upload is triggered. When metadata is missing, providers stay unclassified,
    /// but R1 (retired region) still runs.
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

    /// Save the current data to the partition (not debounced; used to ensure no data is lost before a switch), without waiting: the snapshot is taken on the main thread at this moment, and encoding and disk write are queued
    /// on the session write queue (behind writes already enqueued, before any checkpoint enqueued later). The main thread does not synchronously wait for the write queue -
    /// a main-thread `dispatch_sync` onto a queue busy with a full-table write is the pattern that triggers App Hang and view hierarchy deadlocks.
    /// For synchronous callers (logout, provider migration); callers that need "finish writing before continuing" use `persistSessionNowOffMainThread()`.
    /// The background pre-open of the next partition first waits for this queue to drain (see `loadSession`), so the disk write before a switch always completes first.
    func enqueueSessionPersist(for persistedUID: String? = nil) {
        guard let work = makeImmediateSessionPersistWork(for: persistedUID) else { return }
        conversationPersistQueue.async(qos: .userInitiated, execute: work)
    }

    #if DEBUG
    /// For tests only: synchronous disk write (the main thread waits on the write queue; forbidden in production, the static gate only allows this test seam).
    func persistSessionNow(for persistedUID: String? = nil) {
        enqueueSessionPersist(for: persistedUID)
        flushConversationPersistQueue()
    }
    #endif

    /// Wait for the writes already enqueued on the session write queue to finish (does not block the main thread).
    func drainConversationPersistQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            conversationPersistQueue.async { continuation.resume() }
        }
    }

    /// Same disk write order as `enqueueSessionPersist`, and waits for it to finish (without blocking the main thread).
    ///
    /// The login flow (`AuthPartitionManager.handleLoginSuccess`) writes to disk three times in a row, and each pass is
    /// "main thread waits for the background queue to drain + full JSON encoding + per-provider Keychain writes". Those three synchronous waits
    /// fall right inside the App Hang window after cold start.
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
        let snapshot = currentSessionSnapshotIfApplied()
        let uid = persistedUID ?? boundPartitionUID
        let bridge = conversationRuntimeBridge
        return {
            Self.runConversationPersistWrite(op: "persist_recovery_projection_immediate") {
                try bridge.persistRecoveryProjectionFromDatabase(uid: uid, skipIfUnchanged: true)
            }
            if let snapshot {
                AppSessionStore.save(snapshot, for: uid)
            }
        }
    }

    /// WAL checkpoint before a partition switch (login / logout): the database instance is taken on the main thread (the database is not opened) and queued on the write queue,
    /// executed after the writes already enqueued for this partition. The main thread does not synchronously wait for the write lock; `close()` then only releases the singleton reference, and the queued
    /// checkpoint still lands on the old partition and never opens or swaps in the next partition's database.
    @discardableResult
    func enqueuePartitionCheckpoint() -> Task<Void, Never> {
        guard let pool = conversationRuntimeBridge.openedPool() else { return Task {} }
        // Enqueued synchronously: a close queued right after this call must run behind the checkpoint.
        let done = DispatchGroup()
        done.enter()
        conversationPersistQueue.async(qos: .userInitiated) {
            Self.runConversationPersistWrite(op: "partition_switch_checkpoint") {
                try DatabaseManager.checkpoint(pool)
            }
            done.leave()
        }
        return Task.detached(priority: .userInitiated) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                done.notify(queue: .global(qos: .userInitiated)) { continuation.resume() }
            }
        }
    }

    func persistLifecycleCriticalData(checkpoint: Bool) {
        guard persistsSession else { return }

        let persistedUID = boundPartitionUID
        // Snapshot not yet applied in memory: skip only the snapshot part; the recovery projection and checkpoint still run.
        let snapshot = currentSessionSnapshotIfApplied()
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
            if let snapshot {
                AppSessionStore.save(snapshot, for: persistedUID)
            }
            if let checkpointPool {
                Self.runConversationPersistWrite(op: "persist_lifecycle_checkpoint") {
                    try DatabaseManager.checkpoint(checkpointPool)
                }
            }
            holder.endOnMain()
        }
    }

    /// Pending snapshot taken on the main thread; nil (no write) while the session snapshot has not been applied in memory.
    private func currentSessionSnapshotIfApplied() -> AppSessionSnapshot? {
        guard sessionSnapshotApplied else { return nil }
        return AppSessionSnapshot(
            selectedTab: selectedTab,
            hasCompletedOnboarding: hasCompletedOnboarding || !persistableProviders.isEmpty || !conversations.isEmpty,
            providers: persistableProviders,
            conversations: nil,
            lastUsedModelRef: lastUsedModelRef,
            folders: folders
        )
    }

    private var persistableProviders: [Provider] { providers }

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

    /// Serial tail task for "undo save" of memory items (see `removeMemoryItemInBackground`).
    @ObservationIgnored private var memoryItemUndoTail: Task<Void, Never>?

    /// The toast "Undo" deletes the just-created memory item: the tombstone write goes to the background and does not synchronously wait for the write lock (queued behind the full-table write it would stall for seconds;
    /// measured as a hit from a synchronous main-thread database write); multiple undos queue on the same serial tail task and land in click order.
    func removeMemoryItemInBackground(id: String) {
        guard let repository = memoryItemRepository() else { return }
        let previous = memoryItemUndoTail
        memoryItemUndoTail = Task { @MainActor in
            await previous?.value
            _ = try? await repository.perform { try $0.remove(id: id) }
        }
    }

    /// Wait for writes queued in the memory-item serial tail task (undo save, guest item receive) to land in the database (tests only).
    func waitForMemoryItemWrites() async {
        await memoryItemUndoTail?.value
    }

    /// Wait for queued undo deletions to land in the database (tests only).
    func waitForMemoryItemUndo() async {
        await memoryItemUndoTail?.value
    }

    /// The memory candidate repository of the current partition; after confirmation, a new item is created through the same partition's item repository; nil when the database cannot be opened.
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

    /// On login, copy the guest partition's memory items into the current partition: the write lands in the background, queued on the memory-item serial tail task (same as undo save, landing in submission order),
    /// queued behind the already-enqueued legacy field flow-back (the login migration flows back first, then receives guest items).
    func adoptGuestMemoryItems(_ items: [MemoryItem]) {
        guard !items.isEmpty, let repository = memoryItemRepository() else { return }
        let previous = memoryItemUndoTail
        let reconcile = memoryReconcileTail
        memoryItemUndoTail = Task { @MainActor in
            await previous?.value
            await reconcile?.value
            do {
                try await repository.adoptGuestItems(items)
            } catch {
                #if DEBUG
                print("[AppState] adoptGuestMemoryItems failed: \(error)")
                #endif
            }
        }
    }

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

    /// Wait for queued memory-toggle database writes and their cleanup to finish (tests only).
    func waitForConversationUseMemoryWrites() async {
        await useMemoryWriteTail?.value
    }

    /// Wait for all of this partition's queued database writes to finish: the note write tail, memory item and memory toggle write tails, deletion log, checkpoint invalidation, context ledger,
    /// and the session write queue. This must complete before deleting the partition file (account deletion, demo partition reseed): in-flight writes hold the database instance captured at enqueue time;
    /// writing after the file is deleted gives a disk I/O error, and writes that resolve the database by uid through DatabaseManager would recreate the deleted partition.
    func drainPendingWrites() async {
        await noteManager.waitForPendingWrites()
        await memoryReconcileTail?.value
        await memoryItemUndoTail?.value
        await useMemoryWriteTail?.value
        await waitForCheckpointInvalidations()
        await chatManager.waitForContextLedgerWrites()
        // MCP tables live in the partition database: the endpoint relocation write must land before it is deleted.
        await mcpServerDirectory.waitForPendingRelocations()
        // The tail tasks above may have enqueued writes on the session write queue: drain it last.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            conversationPersistQueue.async { continuation.resume() }
        }
    }

    /// Open the settings memory page; when `editItemId` is non-empty, that item is edited directly once the memory page appears (the "this is wrong" action from "memory used").
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

    /// Create a new conversation via a Skill
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
        conversation.skillIds = [skill.id.uuidString]
        conversation.useMemory = skill.useMemory
        conversation.isDraft = true
        upsertConversationProjection(conversation)

        // The use is recorded when the first message is sent (contract item 16).
        presentChat(conversationID: conversation.id)
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

private extension Conversation {
    /// Summary form of the cold-start mirror (same form that `fetchConversationSummaryProjection` reads back): no body, counts use the overridden values.
    var coldStartSummary: Conversation {
        guard messagesAreLoaded else { return self }
        var summary = self
        summary.messageCountOverride = displayMessageCount
        summary.messages = []
        summary.messagesAreLoaded = false
        return summary
    }
}
