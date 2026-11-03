import Combine
import OriveoProviderKit
import SwiftUI

let homeEarlierPageSize = 10
/// Inline conversation cap after a folder expands; anything past it goes to FolderDetail, where ForEach is a direct LazyVStack child.
let homeFolderInlineLimit = 10
/// Spacing from the greeting / Notes to the first conversation block
let homeListFirstBlockTopSpacing: CGFloat = 26
/// Spacing between the folder block, Pinned, and date groups
let homeListGroupSpacing: CGFloat = 22
/// Spacing between two folder rows
let homeFolderRowSpacing: CGFloat = 8
/// Gap between Earlier "Show More" and the bottom of the group card (the old conversationGroupCard outer VStack spacing of 8)
let homeListShowMoreTopSpacing: CGFloat = 8
let homeTopBarHeight: CGFloat = 40
let homeHeaderCapsuleHeight: CGFloat = 38
/// Visual width of each button in the capsule. The hit area is 44pt tall (the HIG minimum) and does not
/// shrink with the 38pt capsule.
let homeHeaderActionHitWidth: CGFloat = 36
let homeHeaderActionHitHeight: CGFloat = 44
/// The design uses Lucide icons in an 18px box (about two units of padding on the 24 grid, so the visible
/// glyph is roughly 13–16px). An SF Symbol's point size is the glyph size itself, so 14pt matches that.
let homeHeaderActionIconSize: CGFloat = 14
let homeHeroCursorBlinkInterval: TimeInterval = 0.55

/// Flat rows of the home conversation timeline. Must be a direct child of `LazyVStack`:
/// wrapping them in `VStack { ForEach }` makes ScrollView's sizeThatFits measure the whole group
/// on the main thread, which hangs when the table is large.
enum HomeConversationListItem: Identifiable, Equatable {
    case folder(Folder, topSpacing: CGFloat)
    case sectionHeader(kind: HomeConversationHeaderKind, conversations: [Conversation], topSpacing: CGFloat)
    case conversation(Conversation, showFolderTag: Bool, isFirst: Bool, isLast: Bool)
    case showMore(remaining: Int)

    var id: String {
        switch self {
        case .folder(let folder, _):
            "folder-\(folder.id.uuidString)"
        case .sectionHeader(let kind, _, _):
            "header-\(kind.id)"
        case .conversation(let conversation, let showFolderTag, _, _):
            // Pinned rows carry a folder tag; the timeline does not. Production strips pinned from
            // the timeline, but the builder can still receive overlapping input, so ForEach ids
            // must distinguish the two.
            "conv-\(showFolderTag ? "tagged" : "plain")-\(conversation.id.uuidString)"
        case .showMore:
            "show-more-earlier"
        }
    }

    var topSpacing: CGFloat {
        switch self {
        case .folder(_, let topSpacing), .sectionHeader(_, _, let topSpacing):
            topSpacing
        case .showMore:
            homeListShowMoreTopSpacing
        case .conversation:
            0
        }
    }
}

enum HomeConversationHeaderKind: Equatable {
    case search
    case pinned
    case timeline(ConversationManager.ConversationSection)

    var id: String {
        switch self {
        case .search: "search"
        case .pinned: "pinned"
        case .timeline(let section):
            switch section {
            case .pinned: "timeline-pinned"
            case .today: "today"
            case .yesterday: "yesterday"
            case .past7Days: "past7"
            case .earlier: "earlier"
            }
        }
    }
}

/// Flatten folders, Pinned, and date groups into LazyVStack rows. Search hits are flattened the same
/// way so sizeThatFits does not measure every match at once.
func makeHomeConversationListItems(
    isSearching: Bool,
    searchConversations: [Conversation],
    searchInFlight: Bool = false,
    folders: [Folder],
    pinned: [Conversation],
    groups: [HomeConversationSectionState],
    firstBlockTopSpacing: CGFloat = homeListFirstBlockTopSpacing,
    groupSpacing: CGFloat = homeListGroupSpacing,
    folderRowSpacing: CGFloat = homeFolderRowSpacing
) -> [HomeConversationListItem] {
    if isSearching {
        if searchConversations.isEmpty && folders.isEmpty && !searchInFlight {
            return []
        }
        var items: [HomeConversationListItem] = [
            .sectionHeader(kind: .search, conversations: searchConversations, topSpacing: firstBlockTopSpacing)
        ]
        appendConversationRows(
            searchConversations,
            showFolderTag: true,
            to: &items
        )
        return items
    }

    var items: [HomeConversationListItem] = []
    var isFirstBlock = true
    var previousWasFolder = false

    for folder in folders {
        let spacing: CGFloat
        if isFirstBlock {
            spacing = firstBlockTopSpacing
        } else if previousWasFolder {
            spacing = folderRowSpacing
        } else {
            spacing = groupSpacing
        }
        items.append(.folder(folder, topSpacing: spacing))
        isFirstBlock = false
        previousWasFolder = true
    }

    if !pinned.isEmpty {
        items.append(.sectionHeader(
            kind: .pinned,
            conversations: pinned,
            topSpacing: isFirstBlock ? firstBlockTopSpacing : groupSpacing
        ))
        isFirstBlock = false
        previousWasFolder = false
        appendConversationRows(pinned, showFolderTag: true, to: &items)
    }

    for group in groups {
        items.append(.sectionHeader(
            kind: .timeline(group.section),
            conversations: group.conversations,
            topSpacing: isFirstBlock ? firstBlockTopSpacing : groupSpacing
        ))
        isFirstBlock = false
        previousWasFolder = false
        appendConversationRows(group.conversations, showFolderTag: false, to: &items)
        if group.section == .earlier, group.remainingCount > 0 {
            items.append(.showMore(remaining: group.remainingCount))
        }
    }

    return items
}

private func appendConversationRows(
    _ conversations: [Conversation],
    showFolderTag: Bool,
    to items: inout [HomeConversationListItem]
) {
    let lastIndex = conversations.count - 1
    for (index, conversation) in conversations.enumerated() {
        items.append(.conversation(
            conversation,
            showFolderTag: showFolderTag,
            isFirst: index == 0,
            isLast: index == lastIndex
        ))
    }
}

#if DEBUG
/// Seed for the visual snapshot tests: the editing and search states can only be entered through the
/// context menu and a tap, which a test host cannot drive. Exists in DEBUG builds only.
struct HomeDebugSnapshotSeed: Equatable {
    var isEditing = false
    var searchText: String?
}

extension EnvironmentValues {
    @Entry var homeDebugSnapshotSeed: HomeDebugSnapshotSeed? = nil
}
#endif

/// Held-back hero content caught by the gate, snapshotted with the model at that time; after the confirmation sheet returns, it decides whether the send can resume directly
/// Home realtime typed send: like the home ≋ button, opens a realtime session with session id nil and hands this sentence over (cold start only plays, no microphone request),
/// no conversation is pre-created: after ready this sentence is actually sent, and the sink creates the conversation on the first persisted row and enters the chat page; the home selection follows the conversation.
@MainActor
enum HomeRealtimeTypedSend {
    enum Outcome: Equatable {
        /// Realtime session already handed over to the home page (the conversation is created when the first row is persisted).
        case sent
        /// Home selection not yet acknowledged for disclosure: no conversation created; the page shows the disclosure first.
        case needsDisclosure(RealtimeModelSelection)
        /// Not handed over (no realtime selection on home, already conversing elsewhere, or no realtime session could be opened).
        case notSent
    }

    static func send(
        _ text: String,
        host: AppState,
        session: VoiceConversationSession = .shared,
        disclosures: VoiceDisclosureStore = VoiceDisclosureStore()
    ) async -> Outcome {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !session.isActive, let selection = host.realtimeModelSelection(for: nil) else {
            return .notSent
        }
        // Decide the disclosure before opening the connection: do not jump pages first.
        guard disclosures.hasAccepted(selection.providerKind, direction: .realtime) else {
            return .needsDisclosure(selection)
        }
        // origin .home: the home voice dock observes this session (connecting / failed); handed over when the first persisted row creates the conversation.
        let sent = await session.sendRealtimeTyped(typed, conversationID: nil, host: host, origin: .home)
        return sent ? .sent : .notSent
    }

    /// Whether home can hand over another sentence: not while sending; also not before the handed-over sentence is settled (persisted or ended), so an in-flight sentence is not overwritten by a new one;
    /// the send key and dictation "transcribe and send" share this gate.
    static func canHandOff(isSending: Bool, inFlight: String?) -> Bool {
        !isSending && inFlight == nil
    }

    /// Outcome of the handed-over sentence when this session ends: if the conversation was created (the sentence is persisted) it is persisted; if it ends before the conversation is created
    /// (catalog timeout, model_gone, connection failure, etc.) it is endedBeforePersist.
    static func outcome(after end: VoiceConversationSession.EndDelivery) -> RealtimeModelPolicy.TypedSendOutcomeKind {
        end.conversationID == nil ? .endedBeforePersist : .persisted
    }

    /// Home input text after the handed-over sentence has an outcome: not cleared on send, the original text stays in the box;
    /// cleared only when persisted, and only if the box still holds this sentence (edits made while waiting are left alone); if it ends before persisting, it is kept as is and not concatenated.
    static func inputText(
        _ current: String, sent: String, outcome: RealtimeModelPolicy.TypedSendOutcomeKind
    ) -> String {
        guard !RealtimeModelPolicy.typedSendOutcome(context: .home, outcome: outcome).inputKeepsText else { return current }
        return current.trimmingCharacters(in: .whitespacesAndNewlines) == sent ? "" : current
    }
}

struct HeroPendingSend {
    let text: String
    let providerID: UUID
    let modelID: String
}

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    /// "Open in New Window" is offered only where several windows are possible (iPad, Duo).
    @Environment(\.canOpenConversationWindow) private var canOpenConversationWindow
    @Environment(\.windowNavigation) private var windowNavigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    @Environment(\.homeDebugSnapshotSeed) private var debugSnapshotSeed
    #endif

    /// Data source for the home voice dock: after handover it freezes at the home state from before the handover and no longer subscribes to the controller.
    @State private var heroVoiceFeeds = HomeVoiceBarFeedCache()
    @State private var isSearching = false
    @State private var searchText = ""
    /// Search field focus (after ⌘F expands it, typing works right away).
    @FocusState private var isSearchFieldFocused: Bool
    /// ⌘F expanded search before the field was mounted: focus it once it appears.
    @State private var focusSearchFieldOnAppear = false

    /// This window's navigation; falls back to the active window when nil.
    private var navigation: NavigationManager { windowNavigation ?? appState.navigation }
    @State private var searchResults: [Conversation] = []
    @State private var searchInFlight = false
    @State private var modelPickerPresentation: ModelPickerPresentationSnapshot?
    @State private var pendingModelSelection: ModelPickerSelection?
    /// Realtime-model disclosure being shown; `realtimeDisclosurePending` keeps it (with its single origin)
    /// until answered, so a swipe-down (which clears the item first) still resolves as a decline.
    @State private var realtimeDisclosure: RealtimeModelDisclosureRequest?
    @State private var realtimeDisclosurePending = RealtimeDisclosurePending()
    /// Migration sheet on the first ≋ tap for existing users (card G2b); before answering, ≋ does not enter; if interrupted by the system without an answer, the old key is kept and it shows again next time.
    @State private var realtimeMigrationPrompt: RealtimeMigrationPrompt?
    /// Home realtime typed state (switched from the idle voice dock to the input card): memory only; any change to the home realtime selection (model change / cancel / moved away with the conversation) resets it.
    @State private var heroRealtimeTyping = false
    /// Voice catalog state: distinguishes "loading" from "failed" (failure does not push the catalog revision number), same as the chat page's voiceCatalogState.
    @State private var heroVoiceCatalogState: VoiceCatalogState? = ReadAloudCatalogSnapshot.shared.state
    /// The answerer changed mid-voice-session and the previous session was ended with ✕: after collapsing, the same conversation reopens with the new engine.
    @State private var heroVoiceEngineRestartPending = false
    @State private var conversationToDelete: Conversation?
    @State private var conversationToRename: Conversation?
    @State private var renameText = ""
    @State private var isEditing = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var showBatchDeleteConfirmation = false
    @State private var showCreateFolderAlert = false
    @State private var newFolderName = ""
    @State private var showMoveToFolderSheet = false
    @State private var pendingMoveConversationID: UUID?
    @State private var contentAppeared = false
    /// Whether the conversation section is visible. `contentAppeared` only drives **this**
    /// entrance animation; once it has played, `appState.hasPlayedHomeIntro` takes over, so a
    /// rebuild (folding/unfolding swaps the view tree, switching tabs, popping back) can never
    /// leave the whole section at opacity 0. This fallback depends on no post-rebuild callback.
    private var showsConversationContent: Bool {
        contentAppeared || appState.hasPlayedHomeIntro
    }
    @State private var earlierDisplayCount = homeEarlierPageSize
    @State private var heroText = ""
    /// The input is a UIKit view (ComposerTextView) that bridges focus to first responder by hand, not through FocusState.
    @State private var heroFocused = false
    @State private var isSendingFromHero = false
    /// Realtime typed has been handed over, and the sentence from that session's end has not been seen yet: if the session ends before the conversation is created, backfill the input box.
    @State private var heroRealtimeTypedInFlight: String?
    // Hero managed-send gate: shares the same judgement as the ChatView composer (sign-in + server privacy ack)
    @State private var heroDisclosureProvider: ProviderKind?
    @State private var pendingHeroSend: HeroPendingSend?
    @State private var showsHeroMissingProviderKeyPrompt = false
    @State private var isPreparingHeroSend = false
    @State private var pendingHeroVoiceStart = PendingVoiceEntry()
    @Namespace private var voiceOrbNamespace
    /// Recognition language sheet inside the voice stage.
    @State private var showsRecognitionLanguageSheet = false
    @State private var isAcknowledgingHeroPrivacy = false
    @State private var dictationProbe = ComposerSelectionProbe()


    private var conversations: [Conversation] {
        if searchText.isEmpty {
            return appState.filteredConversations(matching: "")
        }
        return searchResults
    }

    private var searchTaskKey: String {
        "\(appState.conversationsVersion)|\(searchText)"
    }

    private var conversationIDSet: Set<UUID> {
        Set(conversations.map(\.id))
    }

    private var preferredAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.38, dampingFraction: 0.82)
    }

    private func commitPendingModelSelection() {
        guard let selection = pendingModelSelection else { return }
        pendingModelSelection = nil
        if selection.modelKind == .realtime {
            commitRealtimeModelSelection(selection, conversationID: nil)
            return
        }
        appState.setActiveModel(providerID: selection.providerID, modelID: selection.modelID)
        appState.clearRealtimeModelSelection(for: nil)
    }

    private func presentModelPicker() {
        let active = appState.activeModel
        modelPickerPresentation = ModelPickerPresentationSnapshot(
            context: .home,
            providers: appState.providers,
            providersVersion: appState.providersVersion,
            currentProviderID: active?.provider.id,
            currentModel: active?.model,
            // Read the voice catalog already cached in memory (no disk read, no request) so realtime rows show on the first frame
            realtimeCatalog: AppState.realtimeVoiceCatalog(from: ReadAloudCatalogSnapshot.shared.state),
            realtimeSelection: appState.realtimeModelSelection(for: nil)
        )
    }

    /// Realtime row picked: takes effect only once the provider's realtime disclosure is accepted.
    private func commitRealtimeModelSelection(_ selection: ModelPickerSelection, conversationID: UUID?) {
        switch appState.selectRealtimeModel(providerID: selection.providerID, model: selection.modelID, for: conversationID) {
        case .applied, .pending:
            return
        case .unavailable:
            showRealtimeModelGoneToast(selection.modelID)
        case .needsDisclosure(let realtime):
            let request = RealtimeModelDisclosureRequest(selection: realtime, conversationID: conversationID)
            presentRealtimeDisclosure(request, origin: .picker)
        }
    }

    /// Realtime selection the catalog does not recognize (or no longer has): the copy matches the realtime model_gone failure.
    private func showRealtimeModelGoneToast(_ model: String) {
        ToastManager.shared.show(
            L10n.format(L10n.tr("%1$@ is no longer available.", table: .voice), model),
            style: .warning
        )
    }

    /// Show disclosure: the single writer overrides the previous source (the old source is void); consumed by answerRealtimeDisclosure when answered.
    private func presentRealtimeDisclosure(_ request: RealtimeModelDisclosureRequest, origin: RealtimeDisclosureOrigin) {
        realtimeDisclosurePending.present(request, origin: origin)
        realtimeDisclosure = request
    }

    private func answerRealtimeDisclosure(accepted: Bool) {
        guard let (request, action) = realtimeDisclosurePending.take(accepted: accepted) else { return }
        switch action {
        case .resolve(let accepted):
            appState.resolveRealtimeModelDisclosure(request.selection, for: request.conversationID, accepted: accepted)
        case .resolveThenSendTyped(let typed):
            if appState.resolveRealtimeModelDisclosure(request.selection, for: request.conversationID, accepted: true) {
                Task { await performHeroSend(typed) }
            }
        case .resolveThenStartVoice:
            if appState.resolveRealtimeModelDisclosure(request.selection, for: request.conversationID, accepted: true) {
                Task { await openHeroVoiceConversation() }
            }
        case .resolveMigration(let accepted, _):
            if !RealtimeMigration.resolveDisclosure(request, accepted: accepted, appState: appState) {
                Task { await openHeroVoiceConversation() }
            }
        }
    }

    private func realtimeDisclosureDismissed() {
        answerRealtimeDisclosure(accepted: false)
    }

    @discardableResult
    private func createFolderWithGate(name: String) -> Folder? {
        appState.folderManager.createFolder(name: name)
    }

    private var conversationModelLookupStore: ConversationModelLookupStore {
        appState.conversationModelLookupStore
    }

    private var groupedConversations: [HomeConversationSectionState] {
        appState.homeConversationSections(earlierLimit: earlierDisplayCount)
    }

    private func title(for section: ConversationManager.ConversationSection) -> String {
        switch section {
        case .pinned:
            L10n.tr("Pinned", table: .home)
        case .today:
            L10n.tr("Today")
        case .yesterday:
            L10n.tr("Yesterday")
        case .past7Days:
            L10n.tr("Past 7 Days", table: .home)
        case .earlier:
            L10n.tr("Earlier", table: .home)
        }
    }

    // MARK: - Hero State

    private enum HeroState: Equatable {
        case empty
        case normal
    }

    private var heroState: HeroState {
        if appState.providers.isEmpty {
            return .empty
        }
        return .normal
    }

    // MARK: - Body

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            // Block spacing is set per section (greeting → hero is 22) rather than one uniform spacing
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                header
                if !isEditing {
                    heroSection
                        .padding(.top, 22)
                    HomeNotesEntryCard(
                        count: appState.noteSummaries.count,
                        latestTitle: appState.noteSummaries.first.map { NoteText.displayTitle($0.title) }
                    ) {
                        appState.openNotes()
                    }
                    .padding(.horizontal, OriveoTheme.V2.Sp.s20)
                    .padding(.top, HomeEntryCardStyle.spacing)
                }
                // The list sits 26 below Notes; while editing, the hero and Notes collapse and the list follows the greeting.
                // ForEach must be a direct LazyVStack child — wrapping it in a VStack then padding would force
                // sizeThatFits to measure the whole table on the main thread.
                conversationContent

            }
            .padding(.top, OriveoTheme.V2.Sp.s16)
            .padding(.bottom, isEditing ? 80 : OriveoTheme.V2.Sp.s32)
            .oriveoContentWidth()
        }
        .auroraBackground()
        // Dictation host: the home draft slot. It stays mounted even without a mic on this page, because the slot
        // `draft:home` is shared with the new-conversation composer (ChatComposerBar): a recording started there
        // can finish transcribing after the user returns home, and the text must land in the home draft.
        .modifier(HomeDictationHost(
            controller: DictationHub.shared.controller,
            canSend: { canHandOffFromHero },
            onInsert: { transcript in
                heroText = dictationProbe.insert(transcript: transcript, currentText: heroText)
            },
            onSend: { Task { await sendFromHero() } },
            live: .probe(dictationProbe, text: $heroText)
        ))
        // Voice conversation host: ending with zero turns leaves no trace; the first send creates the conversation
        // and hands over to the chat page.
        .onAppear { VoiceConversationSession.shared.hostAppeared(nil) }
        .onDisappear { VoiceConversationSession.shared.hostDisappeared(nil) }
        // Clear the input box at the same moment the handed-over sentence's first persisted row creates the conversation (handed to the chat page).
        .onChange(of: VoiceConversationSession.shared.homeHandedOff) { _, handedOff in
            guard handedOff, let typed = heroRealtimeTypedInFlight else { return }
            heroRealtimeTypedInFlight = nil
            heroText = HomeRealtimeTypedSend.inputText(heroText, sent: typed, outcome: .persisted)
        }
        .onChange(of: VoiceConversationSession.shared.lastEnd) { _, end in
            if let end, let typed = heroRealtimeTypedInFlight {
                heroRealtimeTypedInFlight = nil
                heroText = HomeRealtimeTypedSend.inputText(heroText, sent: typed, outcome: HomeRealtimeTypedSend.outcome(after: end))
            }
            guard let end, let draft = VoiceConversationSession.shared.consumeEndDraft(end, host: nil) else { return }
            heroText = heroText.isEmpty ? draft : heroText + " " + draft
        }
        .animation(preferredAnimation, value: heroState)
        .animation(preferredAnimation, value: isEditing)
        // ⌘F: this window's pending request (also caught right after Home mounts) → expand and focus search
        .onChange(of: navigation.pendingSearchReveal, initial: true) { _, pending in
            guard pending else { return }
            navigation.pendingSearchReveal = false
            if isSearching {
                isSearchFieldFocused = true
            } else {
                focusSearchFieldOnAppear = true
                withAnimation(.snappy) { isSearching = true }
            }
        }
        .onAppear {
            #if DEBUG
            if let seed = debugSnapshotSeed {
                isEditing = seed.isEditing
                if seed.isEditing, let first = appState.recentConversations.first {
                    selectedIDs = [first.id]
                }
                if let query = seed.searchText {
                    isSearching = true
                    searchText = query
                }
            }
            #endif
            guard !contentAppeared else { return }
            refreshConversationModelLookup()
            withAnimation(preferredAnimation.delay(0.15)) {
                contentAppeared = true
            }
        }
        .onChange(of: contentAppeared) { _, appeared in
            // Record only after the animation has actually started; otherwise the first visit would skip the fade-in.
            guard appeared else { return }
            appState.hasPlayedHomeIntro = true
        }
        .onChange(of: appState.providersVersion) { _, _ in
            refreshConversationModelLookup()
        }
        .overlay(alignment: .bottom) {
            if isEditing {
                editingToolbar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task {
            await appState.refreshActiveProviderIfNeeded()

            await appState.skillManager.refreshAll()
        }
        .task(id: searchTaskKey) {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                searchResults = []
                searchInFlight = false
                return
            }
            searchInFlight = true
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let results = await appState.searchConversations(matching: query)
            guard !Task.isCancelled else { return }
            searchResults = results
            searchInFlight = false
        }
        .sheet(item: $modelPickerPresentation, onDismiss: commitPendingModelSelection) { presentation in
            ModelPickerSheet(
                context: .home,
                presentation: presentation,
                onSelect: { pendingModelSelection = $0 }
            )
                .presentationDragIndicator(.visible)
                .environment(appState)
        }
        .sheet(item: $realtimeDisclosure, onDismiss: realtimeDisclosureDismissed) { request in
            VoiceDisclosureSheet(
                provider: request.selection.providerKind,
                direction: .realtime,
                onAnswer: { accepted in answerRealtimeDisclosure(accepted: accepted) }
            )
                .environment(appState)
        }
        .realtimeMigrationAlert($realtimeMigrationPrompt, onAnswer: answerRealtimeMigration)
        // Re-read when the catalog revision changes (catalog arrives / content changes); on the first page entry the refresh that is in flight with the snapshot draws the conclusion (same as the chat page).
        .task(id: appState.realtimeVoiceCatalogRevision) {
            let snapshot = ReadAloudCatalogSnapshot.shared
            _ = snapshot.current()
            await snapshot.settle()
            heroVoiceCatalogState = snapshot.state
        }
        // When the home realtime selection changes (model change, cancel, moved away with a new conversation), the typed state resets; the next realtime selection returns to the voice dock; catalog arrival does not reset it.
        .onChange(of: appState.realtimeModelSelections[nil]) { before, after in
            if HomeHeroStage.resetsRealtimeTyping(storedBefore: before, storedAfter: after) { heroRealtimeTyping = false }
        }
        .onChange(of: appState.realtimeModelSelection(for: nil)) { _, selection in
            // The home answerer changed during a voice session: end the old session, and after collapsing reopen with the new engine.
            if VoiceConversationSession.shared.endForEngineChange(
                in: nil, newSelection: selection, newModelName: selection?.model ?? pillModelName
            ) {
                heroVoiceEngineRestartPending = true
            }
        }
        // The staged realtime selection is re-judged after the catalog arrives: the page shows a toast, not AppState.
        .onChange(of: appState.realtimeSelectionGoneNotice) { _, notice in
            guard let notice, notice.conversationID == nil else { return }
            appState.consumeRealtimeSelectionGoneNotice(notice)
            showRealtimeModelGoneToast(notice.model)
        }
        .onChange(of: VoiceConversationSession.shared.isActive) { _, active in
            guard !active, heroVoiceEngineRestartPending else { return }
            heroVoiceEngineRestartPending = false
            Task { await openHeroVoiceConversation() }
        }
        .conversationDeleteConfirmation($conversationToDelete, animation: preferredAnimation)
        .alert(
            L10n.tr("Rename Conversation", table: .home),
            isPresented: Binding(
                get: { conversationToRename != nil },
                set: { if !$0 { conversationToRename = nil } }
            )
        ) {
            TextField(L10n.tr("Conversation title", table: .home), text: $renameText)
            Button(L10n.tr("Cancel"), role: .cancel) { conversationToRename = nil }
            Button(L10n.tr("Save")) {
                if let conv = conversationToRename {
                    appState.renameConversation(id: conv.id, newTitle: renameText)
                    conversationToRename = nil
                }
            }
        }
        .alert(
            L10n.tr("Delete selected conversations?", table: .home),
            isPresented: $showBatchDeleteConfirmation
        ) {
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Delete"), role: .destructive) {
                withAnimation(preferredAnimation) {
                    appState.deleteConversations(ids: selectedIDs)
                    selectedIDs.removeAll()
                    isEditing = false
                }
            }
        } message: {
            let refCount = appState.noteManager.referenceCount(conversationIDs: Array(selectedIDs))
            let base = String(format: L10n.tr("%d conversations will be permanently deleted.", table: .home), selectedIDs.count)
            if refCount > 0 {
                Text(base + "\n\n" + String(format: L10n.tr("These conversations are referenced by %d notes.", table: .notes), refCount))
            } else {
                Text(base)
            }
        }
        .alert(L10n.tr("New Folder", table: .home), isPresented: $showCreateFolderAlert) {
            TextField(L10n.tr("Folder name", table: .home), text: $newFolderName)
            Button(L10n.tr("Cancel"), role: .cancel) {
                pendingMoveConversationID = nil
            }
            Button(L10n.tr("Create", table: .home)) {
                guard !newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                guard let folder = createFolderWithGate(name: newFolderName) else { return }
                if let convID = pendingMoveConversationID {
                    appState.folderManager.moveConversation(convID, to: folder.id)
                    ToastManager.shared.show(
                        String(format: L10n.tr("Moved to folder \"%@\"", table: .home), folder.name)
                    )
                    pendingMoveConversationID = nil
                }
            }
        }
        .sheet(isPresented: $showMoveToFolderSheet) {
            MoveToFolderSheet(
                convIDs: Array(selectedIDs),
                onComplete: {
                    selectedIDs.removeAll()
                    isEditing = false
                }
            )
            .presentationDetents([.medium])
            .environment(appState)
        }
        .sheet(item: $heroDisclosureProvider) { kind in
            ProviderDisclosureSheet(
                provider: kind,
                onAccept: {
                    // First-use disclosure reached from the voice entry: record the acceptance, then start the conversation.
                    if pendingHeroSend == nil {
                        if pendingHeroVoiceStart.accept(kind, markAccepted: ProviderDisclosureStore.markAccepted) {
                            Task { await beginHeroVoiceConversation() }
                        }
                        return
                    }
                    Task { await acknowledgeHeroPrivacyAndSend() }
                },
                onCancel: {
                    pendingHeroSend = nil
                    pendingHeroVoiceStart.decline()
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.hidden)
        }
        .alert(
            L10n.tr("Add an API Key"),
            isPresented: $showsHeroMissingProviderKeyPrompt
        ) {
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Add Provider")) {
                appState.openProviderSetup(from: .providers)
            }
        } message: {
            Text(L10n.tr("Add a provider API key to send messages."))
        }
    }

    // MARK: - Header

    /// Whether the date eyebrow uses the 11pt, all-caps, tracked style. Only scripts with letter case
    /// get it (see homeHeaderUsesCasedEyebrow).
    private var usesCasedEyebrow: Bool {
        homeHeaderUsesCasedEyebrow(AppLocalization.currentLocale)
    }

    private var headerDateText: String {
        formatHomeHeaderDate(.now, locale: AppLocalization.currentLocale)
    }

    /// The masthead: the centred brand mark with the "search | new folder" capsule on the right, followed by the
    /// centred greeting (replaced by the search bar while searching).
    private var header: some View {
        VStack(spacing: 0) {
            topBar

            if isSearching {
                searchBar
                    .padding(.horizontal, OriveoTheme.V2.Sp.s20)
                    .padding(.top, 18)
            } else {
                heroGreeting
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
            }
        }
    }

    /// Top bar: both sides are equally flexible, so the brand mark stays dead centre and is never pushed around
    /// when the trailing capsule appears, disappears or turns into Done.
    /// The trailing half must be an always-present container: `topBarTrailing` is an empty branch when there
    /// are no conversations, so a frame attached to it directly would take no space and the brand would slide right.
    private var topBar: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: 1)
                .accessibilityHidden(true)

            brandMark

            Color.clear
                .frame(maxWidth: .infinity, maxHeight: 1)
                .overlay(alignment: .trailing) { topBarTrailing }
        }
        .frame(height: homeTopBarHeight)
        .padding(.horizontal, OriveoTheme.V2.Sp.s16)
    }

    private var brandMark: some View {
        HStack(spacing: 8) {
            Image("OriveoLogo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            Text(L10n.tr("Oriveo"))
                .font(.system(size: 17, weight: .bold))
                .tracking(-0.3)
                .foregroundStyle(AuroraTheme.Colors.textPrimary)
                .lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var topBarTrailing: some View {
        if !appState.recentConversations.isEmpty {
            if isEditing {
                Button {
                    withAnimation(preferredAnimation) {
                        isEditing = false
                        selectedIDs.removeAll()
                    }
                } label: {
                    Text(L10n.tr("Done"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AuroraTheme.Colors.accent)
                        .frame(minWidth: homeHeaderActionHitHeight, minHeight: homeHeaderActionHitHeight, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityShowsLargeContentViewer()
            } else {
                headerActionCapsule
            }
        }
    }

    /// The "search | new folder" capsule: liquid glass from iOS 26 on (the same material as the system tab bar);
    /// earlier systems keep a solid fill without a stroke (dark 5% white / light 78% white plus two very faint shadows).
    @ViewBuilder
    private var headerActionCapsule: some View {
        if #available(iOS 26, *) {
            // The glass goes on the button group itself, not on a placeholder layer in the background; only then
            // does the foreground get the glass's adaptive treatment
            headerActionButtons
                .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
        } else {
            headerActionButtons
                .background {
                    Capsule(style: .continuous)
                        .fill(AuroraTheme.Colors.chromeFill)
                        .shadow(color: colorScheme == .dark ? .clear : Color(hex: 0x0F172A).opacity(0.05), radius: 1, y: 1)
                        .shadow(color: colorScheme == .dark ? .clear : Color(hex: 0x0F172A).opacity(0.04), radius: 6, y: 4)
                }
        }
    }

    private var headerActionButtons: some View {
        HStack(spacing: 0) {
            // The search key is a toggle: tapping it while the search is open collapses it and clears the query,
            // and VoiceOver needs to know it is selected
            headerCapsuleButton(
                systemImage: "magnifyingglass",
                accessibilityLabel: L10n.tr("Search"),
                isSelected: isSearching
            ) {
                withAnimation(.snappy) {
                    isSearching.toggle()
                    if !isSearching { searchText = "" }
                }
            }

            Rectangle()
                .fill(AuroraTheme.Colors.chromeDivider)
                .frame(width: 1, height: 16)
                .accessibilityHidden(true)

            headerCapsuleButton(
                systemImage: "folder.badge.plus",
                accessibilityLabel: L10n.tr("New Folder", table: .home)
            ) {
                newFolderName = ""
                showCreateFolderAlert = true
            }
        }
        .padding(.horizontal, 2)
    }

    private func headerCapsuleButton(
        systemImage: String,
        accessibilityLabel: String,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: homeHeaderActionIconSize, weight: .medium))
                .foregroundStyle(AuroraTheme.Colors.textSecondary)
                // Visually 36×38 to match the capsule (the glass shape follows the button group); the hit area
                // extends 3pt above and below to reach 44 without changing layout
                .frame(width: homeHeaderActionHitWidth, height: homeHeaderCapsuleHeight)
                // The pointer hover highlight covers only the visible 36×38 cell, not the enlarged hit area
                .contentShape(.hoverEffect, Capsule(style: .continuous))
                .hoverEffect(.highlight)
                .padding(.vertical, (homeHeaderActionHitHeight - homeHeaderCapsuleHeight) / 2)
                .contentShape(Rectangle())
                .padding(.vertical, -(homeHeaderActionHitHeight - homeHeaderCapsuleHeight) / 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // Home keeps a fixed type size regardless of Dynamic Type; like the system bar buttons, a long press
        // shows the large content viewer at accessibility sizes
        .accessibilityShowsLargeContentViewer()
    }

    /// Centred greeting: date eyebrow / 30pt greeting / tagline (one line per time of day, changing daily)
    private var heroGreeting: some View {
        VStack(spacing: 6) {
            dateRow

            heroGreetingLine(L10n.tr(AuroraGreeting.currentKey()))
                .padding(.top, 2)

            Text(L10n.tr(AuroraGreeting.taglineKey()))
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(AuroraTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
    }

    /// The date row carries only the date.
    private var dateRow: some View {
        Text(headerDateText)
            .font(.system(size: usesCasedEyebrow ? 11 : 13, weight: .semibold))
            .foregroundStyle(AuroraTheme.Colors.textTertiary)
            .textCase(usesCasedEyebrow ? .uppercase : nil)
            .tracking(usesCasedEyebrow ? 1.3 : 0)
            .lineLimit(1)
    }

    private func heroGreetingLine(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 30, weight: .bold))
            .tracking(-0.7)
            .foregroundStyle(AuroraTheme.Colors.textPrimary)
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AuroraTheme.Colors.textTertiary)
                TextField(L10n.tr("Search conversations...", table: .home), text: $searchText)
                    .font(.system(size: 15))
                    .focused($isSearchFieldFocused)
                    .onAppear {
                        guard focusSearchFieldOnAppear else { return }
                        focusSearchFieldOnAppear = false
                        isSearchFieldFocused = true
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(AuroraTheme.Colors.textPrimary)
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(
                Capsule(style: .continuous)
                    .fill(AuroraTheme.Colors.cardFill)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(AuroraTheme.Colors.cardBorder, lineWidth: 0.8)
            )

            Button {
                withAnimation(.snappy) { isSearching = false; searchText = "" }
            } label: {
                Text(L10n.tr("Cancel"))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AuroraTheme.Colors.accent)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Hero Section

    @ViewBuilder
    private var heroSection: some View {
        switch heroState {
        case .empty:
            OriveoEmptyState(
                systemImage: "tray",
                title: L10n.tr("No provider available yet", table: .home),
                description: L10n.tr("Add a provider first to start chatting and switch models later.", table: .home),
                actionTitle: L10n.tr("Add Provider")
            ) {
                appState.openProviderSetup(from: .welcome)
            }
            .padding(.horizontal, OriveoTheme.V2.Sp.s20)
            .transition(.opacity.combined(with: .move(edge: .top)))

        case .normal:
            composerSection
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - Hero / Composer

    private var composerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let dictationController = DictationHub.shared.controller {
                DictationPromptSlot(
                    controller: dictationController,
                    onCheckConnection: openDictationCheckConnection,
                    onOpenVoiceSettings: openDictationVoiceSettings
                )
            }

            auroraComposerCard
        }
        .padding(.horizontal, OriveoTheme.V2.Sp.s20)
    }

    /// Dictation card Change Language / Change Dictation Engine: opens the voice settings page.
    private func openDictationVoiceSettings() {
        navigation.attemptNavigate(to: .voiceSettings)
    }

    /// Dictation card Check Connection: with a connection ID opens that connection's detail, otherwise opens provider setup.
    private func openDictationCheckConnection(_ providerID: UUID?) {
        if let providerID {
            appState.openProviderDetail(providerID: providerID)
        } else {
            appState.openProviderSetup(from: .providers)
        }
    }

    // MARK: - Aurora Composer

    private var composerPlaceholder: String {
        L10n.tr(AuroraGreeting.placeholderKey())
    }

    /// Composer card: flat when idle (no aurora ring, no divider); the aurora ring lights up only when focused; model pill + solid send button.
    @ViewBuilder
    private var auroraComposerCard: some View {
        // Do not wrap the voice stage in a glass card: the panel takes the original card's position and the full screen width (cancels the page margin; the fog bleeds to both sides).
        let showsVoiceStage = heroVoiceConversationController != nil || VoiceConversationDemo.status != nil
        Group {
            if showsVoiceStage {
                auroraComposerCardContent
                    .padding(.horizontal, -OriveoTheme.V2.Sp.s20)
            } else {
                auroraComposerCardContent
                    // The draft box is a 1px stroke with padding 18/18/14 (border-box), so content sits 1pt further from each outer edge.
                    .padding(.horizontal, 19)
                    .padding(.top, 19)
                    .padding(.bottom, 15)
                    .auroraGlassCard(cornerRadius: 26, focused: heroFocused)
                    // While dictation records, the glass card's outer edge draws a flowing light border (the phase is reported upward by the switching container).
                    .overlayPreferenceValue(DictationInputPhaseKey.self) { phase in
                        if phase == .recording {
                            DictationFlowBorder(cornerRadius: 26)
                        }
                    }
            }
        }
        // Transition for entering / exiting a voice conversation (spring 0.35 / 0.85; under Reduce Motion, a 200 ms fade in and out).
        .animation(
            VoiceConversationBar.transitionAnimation(reduceMotion: reduceMotion),
            value: heroVoiceConversationController != nil
        )
    }

    /// Card content: while dictating the whole block becomes the recording bar; during a voice conversation it
    /// becomes the voice bar. The send gate itself stays in sendFromHero.
    @ViewBuilder
    private var auroraComposerCardContent: some View {
        if let voiceSurface = heroVoiceConversationController {
            VStack(spacing: HomeHeroStageLayout.pillSpacing) {
                // When realtime is selected, the voice dock shows the home model pill centered at the top (with the cyan dot, tap to open the picker); the chat page top bar already shows the model, so none is added.
                if heroRealtimeStage.showsModelPill {
                    heroStageModelPill
                        // Negative spacing lets the pill's hit area reach into the whitespace above the orb: the pill is on the upper layer, so tapping it does not fall through to the orb.
                        .zIndex(1)
                        .transition(.opacity)
                }
                // In a voice conversation: the input box, the mic and the model row are replaced by the voice bar.
                VoiceConversationBar(
                    surface: voiceSurface,
                    page: .home,
                    orbNamespace: voiceOrbNamespace,
                    languageChip: .recognitionLanguage { showsRecognitionLanguageSheet = true }
                ) {
                    // The idle dock shows no ✕ (the "Switch to typing" capsule at the bottom center switches to typing); ✕ only ends an ongoing conversation.
                    VoiceConversationSession.shared.end(.user)
                }
                .recognitionLanguageSheet(isPresented: $showsRecognitionLanguageSheet)
            }
            .transition(.opacity)
        } else if VoiceConversationDemo.status != nil {
            VoiceConversationDemo.bar(page: .home)
        } else if let controller = DictationHub.shared.controller {
            // While dictating, the input box stays on screen (not editable); the button row below is replaced by the recording bar.
            DictationInputSwitcher(controller: controller, canSend: canHandOffFromHero) { phase in
                heroComposerInput(editable: !phase.isDictating, phase: phase)
            } buttons: {
                heroComposerButtonRow
            }
        } else {
            auroraComposerIdleContent
        }
    }

    private var auroraComposerIdleContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The real input plus the decorative blinking cursor (shown while unfocused and empty)
            heroComposerInput(editable: true)
            heroComposerButtonRow
        }
    }

    /// Model pill (no stroke, tonal) + ≋ secondary button + send key (solid purple circle), no attachment button, no microphone.
    private var heroComposerButtonRow: some View {
        let actions = heroComposerActions
        return HStack(alignment: .center, spacing: 10) {
            Button {
                presentModelPicker()
            } label: {
                modelSelectorPill
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            if actions.showsBackToStage {
                heroBackToStageButton
                    .transition(.opacity)
            } else if actions.showsVoice {
                heroVoiceButton
                    .transition(.opacity)
            }

            // A sentence in flight is unsettled: the send key is grayed out in the sending style.
            auroraSendButton
                .disabled(!actions.sendEnabled || heroRealtimeTypedInFlight != nil)
        }
        .animation(.easeInOut(duration: 0.18), value: actions.showsVoice)
        .animation(.easeInOut(duration: 0.18), value: actions.showsBackToStage)
    }

    // Same values as the old TextField's font(composerPlaceholder) / foregroundStyle(textPrimary) / tint(accentGlow),
    // cached as single instances because ComposerTextView compares styles by equality.
    private static let heroInputFont = UIFont.systemFont(ofSize: 18, weight: .medium)
    private static let heroInputTextColor = UIColor(AuroraTheme.Colors.textPrimary)
    private static let heroInputTint = UIColor(AuroraTheme.Colors.accentGlow)

    /// Hero input box: multi-line input; an undecorated blinking cursor overlays it when unfocused; while dictating editable = false (not editable, keyboard dismissed).
    /// While recording, the empty-draft placeholder becomes "Listening…" (same approach as the chat input box).
    private func heroComposerInput(editable: Bool, phase: DictationInputPhase = .normal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            heroComposerTextField(editable: editable, phase: phase)
        }
    }

    private func heroComposerTextField(editable: Bool, phase: DictationInputPhase) -> some View {
        let placeholder = ChatComposerBar.listeningPlaceholder(phase: phase) ?? composerPlaceholder
        return ZStack(alignment: .leading) {
            // Same component as the chat input bar: SwiftUI TextField re-lays out the whole text on every layout when a very long single-paragraph paste happens.
            ComposerTextView(
                text: $heroText,
                isFocused: $heroFocused,
                font: Self.heroInputFont,
                textColor: Self.heroInputTextColor,
                // The system caret uses the same colour as the decorative cursor (AuroraTheme.Colors.accentGlow: the current palette's light ink in light mode, the current palette accent in dark mode)
                tintColor: Self.heroInputTint,
                isEnabled: editable,
                // The placeholder is drawn by the decorative layer below; VoiceOver needs an explicit name.
                accessibilityLabel: placeholder,
                maxLength: ChatInputLimit.maxUTF16,
                onLengthLimitExceeded: ChatInputLimit.showLimitReachedToast,
                selectionProbe: dictationProbe
            )
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .accessibilityIdentifier("home_composer_input")

            if !heroFocused && heroText.isEmpty {
                HStack(spacing: 4) {
                    Text(placeholder)
                        .font(AuroraTheme.Typography.composerPlaceholder)
                        .tracking(-0.2)
                        .foregroundStyle(AuroraTheme.Colors.heroTextTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !isSearching {
                        blinkingCursor
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .clipped()
                .allowsHitTesting(false)
                // Purely decorative: otherwise VoiceOver reads the placeholder as a second element outside the field
                .accessibilityHidden(true)
                // The system caret appears the moment the field is focused; the decorative layer must go at the same
                // time rather than fade out on top of it.
                .transition(.identity)
                .transaction { transaction in
                    transaction.animation = nil
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            heroFocused = true
        }
    }

    private var blinkingCursor: some View {
        HomeHeroBlinkingCursor(reduceMotion: reduceMotion)
    }

    /// Model selection chip: provider colored brand logo + model name + provider name,
    /// borderless tonal capsule (6% white in dark / #F3F0FA in light), 40 high, widest 230 (model name truncated to one line).
    private var modelSelectorPill: some View { modelSelectorPill(alignment: .leading) }

    /// Alignment: which side of the widest-230 frame the capsule sits on (the input area sits left, the voice dock top centers).
    private func modelSelectorPill(alignment: Alignment) -> some View {
        // The connection shown by the pill: the voice dock takes the connection of the realtime selection, the typed card takes the text model's connection.
        let active = HomeHeroStage.pillProvider(
            stage: heroRealtimeStage,
            storedSelection: appState.realtimeModelSelections[nil],
            provider: appState.provider(for:),
            textProvider: appState.activeModel?.provider
        )
        let realtimeSelected = appState.realtimeModelSelection(for: nil) != nil || heroRealtimeStage.showsRealtimeDot
        return HStack(spacing: 9) {
            Group {
                if let active {
                    ConnectionAvatarIcon(
                        provider: active,
                        kind: active.kind,
                        relayKind: active.relayKind,
                        size: 24
                    )
                } else {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(AuroraTheme.Colors.heroTextTertiary)
                        .frame(width: 24, height: 24)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if realtimeSelected {
                        RealtimeModelDot()
                    }
                    Text(pillModelName)
                        .accessibilityValue(ChatToolbar.modelNameAccessibilityValue(realtime: realtimeSelected))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AuroraTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let active {
                    Text(active.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AuroraTheme.Colors.heroTextTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            // The design uses Lucide chevrons in a 12px box (visible glyph about 6×10). An SF Symbol's point size
            // is the glyph size, so 9pt matches, while the slot stays 12
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(AuroraTheme.Colors.heroTextTertiary)
                .frame(width: 12, height: 12)
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 40)
        .background(Capsule(style: .continuous).fill(AuroraTheme.Colors.pillFill))
        // Visually 40 tall, hit area 44 (the control row is already 44 tall because of the send button, so
        // layout is unchanged)
        .frame(height: 44)
        .contentShape(Rectangle())
        .frame(maxWidth: 230, alignment: alignment)
    }

    /// Model pill at the top of the voice dock: the same modelSelectorPill as the input area; tapping opens the home model picker.
    private var heroStageModelPill: some View {
        Button {
            presentModelPicker()
        } label: {
            modelSelectorPill(alignment: .center)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Voice conversation started on home but not yet handed over; the home dock gets the frozen feed at handover, while the chat page dock owns the controller exclusively.
    /// Home voice dock: a conversation started on home and not yet handed over uses the feed; otherwise, when home has a realtime selection, the idle dock is shown (a tap uses the same entry path as ≋).
    private var heroVoiceConversationController: (any VoiceConversationSurface)? {
        if let feed = heroVoiceFeeds.feed(for: VoiceConversationSession.shared) { return feed }
        guard showsHeroRealtimeStage else { return nil }
        switch heroRealtimeStage {
        case .preparing:
            return HomeRealtimePreparingStageSurface(onSwitchToTyping: { heroRealtimeTyping = true })
        case .catalogFailed:
            return RealtimeIdleStageSurface(
                failure: .catalogUnavailable,
                onTap: retryHeroRealtimeCatalog,
                onSwitchToTyping: { heroRealtimeTyping = true }
            )
        case .composer, .ready:
            break
        }
        // The previous session failed on home: the idle dock carries the failure copy and recovery options (retry = tap the orb; go to connection page / switch model uses heroRealtimeFailureNavigation).
        let selection = appState.realtimeModelSelection(for: nil)
        let failure = VoiceConversationSession.shared.realtimeFailure(in: nil, selection: selection)
        let navigation = heroRealtimeFailureNavigation
        return RealtimeIdleStageSurface(
            failure: failure,
            onTap: { Task { await startVoiceFromHero() } },
            onFailureAction: { navigation.perform($0, failure: failure, selection: selection) },
            onSwitchToTyping: { heroRealtimeTyping = true }
        )
    }

    /// Home input area surface: in-memory selection + judged selection + catalog state .
    private var heroRealtimeStage: HomeHeroStage {
        HomeHeroStage.resolve(appState, catalogState: heroVoiceCatalogState)
    }

    /// Catalog failure card "Retry": re-fetches the voice catalog (same as the chat page's retryRealtimeCatalog); returns to preparing during the re-fetch.
    private func retryHeroRealtimeCatalog() {
        heroVoiceCatalogState = nil
        Task { @MainActor in
            heroVoiceCatalogState = await VoiceCatalogClient.shared.refresh()
        }
    }

    /// Navigation for home voice dock failure recovery: going to the connection page is the same as the dictation card's Check Connection; switching model opens the home model picker.
    private var heroRealtimeFailureNavigation: RealtimeFailureNavigation {
        RealtimeFailureNavigation(
            openConnection: openDictationCheckConnection,
            openModelPicker: presentModelPicker,
            clearRealtimeSelection: { [appState] in appState.clearRealtimeModelSelection(for: nil) }
        )
    }

    /// Home has a realtime selection and the primary button is judged as the voice dock (not in sending / privacy confirmation; home has no read-only state, realtime does not look at the dictation pipeline).
    private var showsHeroRealtimeStage: Bool {
        VoiceConversationEntry.primaryAction(
            isSending: isSendingFromHero || isAcknowledgingHeroPrivacy,
            hasContent: !heroText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            sendEnabled: true,
            voiceAvailable: DictationHub.shared.controller != nil,
            modelProducesText: appState.activeModel.map { VoiceConversationEntry.modelProducesText($0.model) } ?? true,
            realtimeSelected: heroRealtimeStage != .composer,
            realtimeTyping: heroRealtimeTyping,
            realtimeReadOnly: false
        ) == .voiceStage
    }

    /// Home can hand over a sentence now: not sending, and no handed-over realtime typed sentence is unsettled.
    private var canHandOffFromHero: Bool {
        HomeRealtimeTypedSend.canHandOff(isSending: isSendingFromHero, inFlight: heroRealtimeTypedInFlight)
    }

    /// Home is in the realtime typed state: has a realtime selection and the user switched from the voice dock to the input card.
    private var isHeroRealtimeTyping: Bool {
        heroRealtimeTyping && appState.realtimeModelSelection(for: nil) != nil
    }

    /// State of the two keys on the home card: with no active model the voice button still shows (entering it
    /// resolves a model first); image-only models get no voice button.
    private var heroComposerActions: HomeComposerActions {
        VoiceConversationEntry.homeComposer(
            isSending: isSendingFromHero || isPreparingHeroSend,
            hasContent: !heroText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            voiceAvailable: DictationHub.shared.controller != nil,
            modelProducesText: appState.activeModel.map { VoiceConversationEntry.modelProducesText($0.model) } ?? true,
            realtimeSelected: heroRealtimeStage != .composer,
            realtimeTyping: heroRealtimeTyping,
            realtimeReadOnly: false
        )
    }

    /// Back-to-stage button in the ≋ slot while realtime typing with an empty draft (shared with the chat page): a tap only returns to the idle voice stage, with no connect and no mic.
    private var heroBackToStageButton: some View {
        RealtimeBackToStageButton(
            accessibilityID: "home_voice_back_to_stage_button",
            hitSize: HeroVoiceButtonStyle.hitSize,
            namespace: voiceOrbNamespace,
            reduceMotion: reduceMotion
        ) {
            heroRealtimeTyping = false
        }
    }

    /// Style of the home voice button: accent waveform, no fill or stroke, 44x44 hit area.
    private enum HeroVoiceButtonStyle {
        static let symbol = "waveform"
        static let font = Font.system(size: 17, weight: .semibold)
        static let color = AuroraTheme.Colors.accent
        static let hitSize: CGFloat = 44
    }

    /// Secondary voice button left of the send key; shown only for an empty draft when a voice conversation can
    /// start. It morphs into the status orb when the voice bar appears.
    private var heroVoiceButton: some View {
        Button {
            Task { await startVoiceFromHero() }
        } label: {
            Image(systemName: HeroVoiceButtonStyle.symbol)
                .font(HeroVoiceButtonStyle.font)
                .foregroundStyle(HeroVoiceButtonStyle.color)
                .frame(width: HeroVoiceButtonStyle.hitSize, height: HeroVoiceButtonStyle.hitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .voiceOrbMatched(voiceOrbNamespace, reduceMotion: reduceMotion)
        .accessibilityLabel(Text(VoiceConversationCopy.startA11y))
        .accessibilityIdentifier("home_voice_conversation_button")
    }

    private var auroraSendButton: some View {
        Button {
            Task { await sendFromHero() }
        } label: {
            // The design uses a Lucide arrow in a 19px box (visible 13×13, stroke about 1.9); SF Symbol 16pt
            // semibold is the closest match in stroke weight and area
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AuroraTheme.Colors.onSendFill)
                .frame(width: 44, height: 44)
                .background(Circle().fill(AuroraTheme.Colors.sendFill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.tr("Send", table: .chat))
        .accessibilityIdentifier("home_send_button")
    }

    /// Voice entry on home: make sure a model exists, pass the same key and disclosure gates as sending, then
    /// start the conversation. Starting does not create a conversation.
    @MainActor
    private func startVoiceFromHero() async {
        guard !isSendingFromHero, !isPreparingHeroSend, !VoiceConversationSession.shared.isActive else { return }
        heroFocused = false
        pendingHeroVoiceStart.decline()
        guard await appState.ensureActiveModelWithProviderFallback(),
              let activeModel = appState.activeModel else { return }
        if shouldRequireBYOKKeyBeforeSend(
            providerKind: activeModel.provider.kind,
            hasConfiguredKey: appState.hasConfiguredProviderKey
        ) {
            showsHeroMissingProviderKeyPrompt = true
            return
        }
        switch ChatVoiceConversationGate.evaluate(
            providerKind: activeModel.provider.kind,
            // The voice entry passes the provider's first-use disclosure too, instead of asking only at the first
            // turn and leaving the bar stuck on "thinking".
            providerDisclosureAccepted: { ProviderDisclosureStore.hasAccepted($0) }
        ) {
        case .providerDisclosure(let kind):
            pendingHeroVoiceStart.hold(kind)
            heroDisclosureProvider = kind
        case .open:
            await beginHeroVoiceConversation()
        }
    }

    /// The conversation engine follows settings (realtime session or cascade); both create the conversation and
    /// open the chat page only on the first persisted message or first send.
    @MainActor
    private func beginHeroVoiceConversation() async {
        switch RealtimeMigration.evaluate(
            conversationID: nil,
            providers: appState.providers,
            catalog: ReadAloudCatalogSnapshot.shared.state?.catalog
        ) {
        case .enterCascade:
            await openHeroVoiceConversation()
        case .prompt(let prompt):
            realtimeMigrationPrompt = prompt
        }
    }

    @MainActor
    private func answerRealtimeMigration(_ prompt: RealtimeMigrationPrompt, switchModel: Bool) {
        realtimeMigrationPrompt = nil
        guard switchModel else {
            RealtimeMigration.keep(prompt)
            Task { await openHeroVoiceConversation() }
            return
        }
        switch RealtimeMigration.switchModel(prompt, appState: appState) {
        case .selected:
            return
        case .needsDisclosure(let request):
            presentRealtimeDisclosure(request, origin: .migration(nil))
        case .enterCascade:
            Task { await openHeroVoiceConversation() }
        }
    }

    @MainActor
    private func openHeroVoiceConversation() async {
        await VoiceConversationSession.shared.start(
            origin: .home,
            conversationID: nil,
            host: appState,
            onNeedsRealtimeDisclosure: { selection in
                // The realtime selection has not yet acknowledged the disclosure: show it first, and start this session after agreement.
                let request = RealtimeModelDisclosureRequest(selection: selection, conversationID: nil)
                presentRealtimeDisclosure(request, origin: .voiceStart(nil))
            }
        ) { [appState] text, conversationID in
            await appState.sendMessageOutcome(text, in: conversationID, delivery: .voice)
        }
    }

    @MainActor
    private func sendFromHero() async {
        guard !isSendingFromHero, !isPreparingHeroSend else { return }
        pendingHeroVoiceStart.decline()
        let trimmed = heroText.trimmingCharacters(in: .whitespacesAndNewlines)
        heroFocused = false

        if trimmed.isEmpty {
            await appState.startNewChatWithProviderFallback()
            return
        }

        guard await appState.ensureActiveModelWithProviderFallback() else { return }

        guard let activeModel = appState.activeModel else { return }
        let heroProviderKind = activeModel.provider.kind
        if shouldRequireBYOKKeyBeforeSend(
            providerKind: heroProviderKind,
            hasConfiguredKey: appState.hasConfiguredProviderKey
        ) {
            showsHeroMissingProviderKeyPrompt = true
            return
        }
        if heroProviderKind.requiresVendorDisclosure,
           !ProviderDisclosureStore.hasAccepted(heroProviderKind) {
            pendingHeroSend = HeroPendingSend(
                text: trimmed,
                providerID: activeModel.provider.id,
                modelID: activeModel.model.id
            )
            heroDisclosureProvider = heroProviderKind
            return
        }

        await performHeroSend(trimmed)
    }

    @MainActor
    private func performHeroSend(_ trimmed: String) async {
        guard !isSendingFromHero else { return }
        // Realtime typed state with the catalog not ready: wait for the catalog and do not change to the text model (the chat page rejects without a toast).
        if heroRealtimeTyping, heroRealtimeStage == .preparing || heroRealtimeStage == .catalogFailed { return }
        if isHeroRealtimeTyping {
            await performHeroRealtimeTypedSend(trimmed)
            return
        }
        isSendingFromHero = true
        let convID = await appState.sendMessage(trimmed, in: nil)
        isSendingFromHero = false
        if convID != nil, heroText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
            heroText = ""
        }
    }

    /// Realtime typed send: does not use the text API; hands this sentence over by opening a realtime session with home (nil); the conversation is created and enters the chat page on the first persisted row.
    /// For an unacknowledged realtime selection: show the disclosure, do not open the connection, and continue sending this sentence after agreement; if it was not handed over, the draft stays on home,
    /// after handover this sentence stays in the input box and is cleared only when the first persisted row creates the conversation; if it fails and ends before the conversation is created, the original text stays in the box (no empty conversation).
    @MainActor
    private func performHeroRealtimeTypedSend(_ trimmed: String) async {
        isSendingFromHero = true
        let outcome = await HomeRealtimeTypedSend.send(trimmed, host: appState)
        isSendingFromHero = false
        switch outcome {
        case .sent:
            // Not cleared on send: the original text stays until the first persisted row creates the conversation; if it ends before persisting, it stays in the box.
            heroRealtimeTypedInFlight = trimmed
        case .needsDisclosure(let selection):
            let request = RealtimeModelDisclosureRequest(selection: selection, conversationID: nil)
            presentRealtimeDisclosure(request, origin: .typedSend(trimmed))
        case .notSent:
            return
        }
    }

    /// Hero managed privacy confirmation: the payload snapshotted before the sheet re-presents after the Server records agreement
    @MainActor
    private func acknowledgeHeroPrivacyAndSend() async {
        guard !isPreparingHeroSend, let pending = pendingHeroSend else { return }
        isPreparingHeroSend = true
        defer { isPreparingHeroSend = false }
        pendingHeroSend = nil

        if let kind = appState.activeModel?.provider.kind {
            ProviderDisclosureStore.markAccepted(kind)
        }
        guard let activeModel = appState.activeModel,
              activeModel.provider.id == pending.providerID,
              activeModel.model.id == pending.modelID else {
            return
        }
        await performHeroSend(pending.text)
    }

    private var currentModelDisplayName: String {
        if let active = appState.activeModel {
            return active.model.name
        }
        return L10n.tr("Select Model", table: .home)
    }

    private var pillModelName: String {
        HomeHeroStage.pillModelName(
            stage: heroRealtimeStage,
            storedSelection: appState.realtimeModelSelections[nil],
            textModelName: textPillModelName
        )
    }

    /// Text model's pill name.
    private var textPillModelName: String {
        var name = currentModelDisplayName
        if let r = name.range(of: ": ") {
            let tail = name[r.upperBound...]
            if !tail.isEmpty { name = String(tail) }
        }
        if name.lowercased().hasSuffix(" (free)") {
            name = String(name.dropLast(" (free)".count))
        }
        return name
    }

    // MARK: - Conversation Content

    @ViewBuilder
    private var conversationContent: some View {
        if !appState.providers.isEmpty {
            let folders = appState.folderManager.sortedFolders
            let groups = groupedConversations
            let pinnedConversations = appState.conversationManager.pinnedConversations
            let items = makeHomeConversationListItems(
                isSearching: !searchText.isEmpty,
                searchConversations: conversations,
                searchInFlight: searchInFlight,
                folders: folders,
                pinned: searchText.isEmpty ? pinnedConversations : [],
                groups: searchText.isEmpty ? groups : []
            )

            if items.isEmpty {
                conversationEmptyPlaceholder(folders: folders, groups: groups, pinned: pinnedConversations)
                    .padding(.top, homeListFirstBlockTopSpacing)
                    .padding(.horizontal, OriveoTheme.V2.Sp.s20)
                    .opacity(showsConversationContent ? 1 : 0)
                    .offset(y: showsConversationContent ? 0 : 8)
            } else {
                ForEach(items) { item in
                    homeListItemView(item)
                        .padding(.horizontal, OriveoTheme.V2.Sp.s20)
                        .padding(.top, item.topSpacing)
                        .opacity(showsConversationContent ? 1 : 0)
                        .offset(y: showsConversationContent ? 0 : 8)
                }
            }
        }
    }

    @ViewBuilder
    private func conversationEmptyPlaceholder(
        folders: [Folder],
        groups: [HomeConversationSectionState],
        pinned: [Conversation]
    ) -> some View {
        if !searchText.isEmpty {
            if conversations.isEmpty && folders.isEmpty && !searchInFlight {
                HomeConversationEmptyState()
            }
        } else if groups.isEmpty && folders.isEmpty && pinned.isEmpty {
            HomeConversationEmptyState()
        }
    }

    @ViewBuilder
    private func homeListItemView(_ item: HomeConversationListItem) -> some View {
        switch item {
        case .folder(let folder, _):
            FolderRow(
                folder: folder,
                isEditing: isEditing,
                selectedIDs: $selectedIDs
            )
        case .sectionHeader(let kind, let conversations, _):
            Group {
                if isEditing, kind != .search {
                    sectionHeaderWithSelect(title: headerTitle(for: kind), conversations: conversations)
                } else {
                    v2SectionHeader(title: headerTitle(for: kind), count: conversations.count)
                }
            }
            .modifier(HomeSectionHeaderInsets())
        case .conversation(let conversation, let showFolderTag, let isFirst, let isLast):
            conversationButton(for: conversation, showFolderTag: showFolderTag, grouped: true)
                .modifier(AuroraGroupedRowSurface(isFirst: isFirst, isLast: isLast))
                .contentShape(.hoverEffect, AuroraGroupedRowSurface.shape(isFirst: isFirst, isLast: isLast))
                .hoverEffect(.highlight)
                .modifier(ConversationWindowDragSource(
                    conversationID: conversation.id,
                    isEnabled: ConversationWindowDrag.isAvailable(canOpenConversationWindow: canOpenConversationWindow)
                ))
        case .showMore(let remaining):
            earlierShowMoreButton(remainingCount: remaining)
        }
    }

    private func headerTitle(for kind: HomeConversationHeaderKind) -> String {
        switch kind {
        case .search:
            L10n.tr("Search Results", table: .home)
        case .pinned:
            L10n.tr("Pinned", table: .home)
        case .timeline(let section):
            title(for: section)
        }
    }

    /// Group header: 3×18 glowing bar + 17/bold title + 13 mono count (spacing 10)
    private func v2SectionHeader(title: String, count: Int? = nil) -> some View {
        HStack(alignment: .center, spacing: 10) {
            AuroraSectionRule()

            AuroraTitleCount(title: title, titleFont: AuroraTheme.Typography.section, count: count, spacing: 10)

            Spacer(minLength: 0)
        }
        // Title and count form one heading element ("Today, 3") so the VoiceOver headings rotor can jump
                // between groups
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func earlierShowMoreButton(remainingCount: Int) -> some View {
        Button {
            withAnimation(preferredAnimation) {
                earlierDisplayCount += homeEarlierPageSize
            }
        } label: {
            Text(String(format: L10n.tr("Show More (%d)", table: .home), remainingCount))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OriveoTheme.V2.Colors.textTertiary)
                .frame(maxWidth: .infinity)
                // An 11pt line is only about 13pt tall: the hit area extends 15 above and below (close to 44) without
                // changing the layout height
                .padding(.vertical, 15)
                .contentShape(Rectangle())
                .padding(.vertical, -15)
        }
        .buttonStyle(.plain)
    }

    private func conversationButton(for conversation: Conversation, showFolderTag: Bool = false, grouped: Bool = false) -> some View {
        let provider = appState.provider(for: conversation.providerID)
        // Show no model name until the background lookup is ready, so a fallback name never flashes before the real one
        let lookupStore = conversationModelLookupStore
        let resolvedModelName = lookupStore.isReady
            ? ConversationRow.resolveModelName(for: conversation, provider: provider, lookup: lookupStore.lookup)
            : nil

        return Button {
            if isEditing {
                withAnimation(preferredAnimation) {
                    if selectedIDs.contains(conversation.id) {
                        selectedIDs.remove(conversation.id)
                    } else {
                        selectedIDs.insert(conversation.id)
                    }
                }
            } else {
                if !searchText.isEmpty {
                    appState.pendingSearchScrollTarget = PendingSearchScrollTarget(
                        conversationID: conversation.id,
                        query: searchText
                    )
                }
                appState.openChat(conversationID: conversation.id)
            }
        } label: {
            HStack(spacing: isEditing ? 10 : 12) {
                if isEditing {
                    Image(systemName: selectedIDs.contains(conversation.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(
                            selectedIDs.contains(conversation.id)
                                ? OriveoTheme.V2.Colors.primary
                                : OriveoTheme.V2.Colors.textTertiary
                        )
                }

                ConversationRow(
                    conversation: conversation,
                    provider: provider,
                    resolvedModelName: resolvedModelName,
                    folderName: showFolderTag ? appState.folderManager.folderName(for: conversation.folderID) : nil,
                    skillIcon: conversation.skillId.flatMap { appState.skillManager.skill(by: $0)?.icon },
                    grouped: grouped,
                    isEditing: isEditing,
                    isStreaming: appState.streamingConversationIDs.contains(conversation.id),
                    isPinned: appState.conversationManager.isPinned(conversation.id)
                )
                .equatable()
            }
            .padding(.leading, isEditing ? 14 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home_conversation_item")
        .contextMenu {
            if !isEditing {
                if canOpenConversationWindow {
                    Button {
                        openWindow(value: WindowOpenRequest(conversationID: conversation.id))
                    } label: {
                        Label(L10n.tr("Open in New Window", table: .home), systemImage: "macwindow.badge.plus")
                    }
                }

                // Pin / unpin (same as Web and Android: first in the menu)
                let isPinned = appState.conversationManager.isPinned(conversation.id)
                Button {
                    appState.conversationManager.togglePin(conversationID: conversation.id)
                } label: {
                    Label(
                        isPinned ? L10n.tr("Unpin Conversation", table: .home) : L10n.tr("Pin Conversation", table: .home),
                        systemImage: isPinned ? "pin.slash" : "pin"
                    )
                }

                if !appState.folders.isEmpty || conversation.folderID != nil {
                    Menu {
                        ForEach(appState.folderManager.sortedFolders.filter { $0.id != conversation.folderID }) { folder in
                            Button(folder.name) {
                                appState.folderManager.moveConversation(conversation.id, to: folder.id)
                                ToastManager.shared.show(
                                    String(format: L10n.tr("Moved to folder \"%@\"", table: .home), folder.name)
                                )
                            }
                        }
                        if !appState.folders.isEmpty {
                            Divider()
                            Button("+ \(L10n.tr("New Folder", table: .home))") {
                                newFolderName = ""
                                pendingMoveConversationID = conversation.id
                                showCreateFolderAlert = true
                            }
                        }
                        if conversation.folderID != nil {
                            Divider()
                            Button(L10n.tr("Remove from Folder", table: .home)) {
                                appState.folderManager.moveConversation(conversation.id, to: nil)
                                ToastManager.shared.show(L10n.tr("Removed from folder", table: .home))
                            }
                        }
                    } label: {
                        Label(L10n.tr("Move to Folder", table: .home), systemImage: "folder")
                    }
                }

                Button {
                    renameText = conversation.title
                    conversationToRename = conversation
                } label: {
                    Label(L10n.tr("Rename"), systemImage: "pencil")
                }

                if conversation.displayMessageCount > 0 {
                    Button {
                        if let lastMessage = conversation.messages.last {
                            UIPasteboard.general.string = lastMessage.text
                        } else if let hydrated = try? appState.conversationRuntimeBridge.fetchConversationProjection(
                            id: conversation.id,
                            uid: appState.sessionPartitionUID
                        ), let lastMessage = hydrated.messages.last {
                            UIPasteboard.general.string = lastMessage.text
                        } else if !conversation.previewText.isEmpty {
                            UIPasteboard.general.string = conversation.previewText
                        }
                    } label: {
                        Label(L10n.tr("Copy Last Message", table: .home), systemImage: "doc.on.doc")
                    }
                }

                ShareLink(item: conversation.title) {
                    Label(L10n.tr("Share"), systemImage: "square.and.arrow.up")
                }

                Divider()

                Button {
                    withAnimation(preferredAnimation) {
                        isEditing = true
                        isSearching = false
                        searchText = ""
                        selectedIDs = [conversation.id]
                    }
                } label: {
                    Label(L10n.tr("Select", table: .home), systemImage: "checkmark.circle")
                }

                Button(role: .destructive) {
                    conversationToDelete = conversation
                } label: {
                    Label(L10n.tr("Delete"), systemImage: "trash")
                }
            }
        }
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .move(edge: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.9))
        ))
    }

    private func refreshConversationModelLookup() {
        // providersVersion also bumps for unrelated fields such as status and lastCheckedAt; fingerprinting and
        // rebuilding both run in the background, and nothing is rebuilt while the models and metadata are unchanged
        conversationModelLookupStore.refresh(providers: appState.providers)
    }

    // MARK: - Editing Toolbar

    private var editingToolbar: some View {
        let allIDs = conversationIDSet
        let allSelected = !allIDs.isEmpty && allIDs.isSubset(of: selectedIDs)

        return VStack(spacing: 0) {
            Divider()
            HStack {
                Button {
                    withAnimation(preferredAnimation) {
                        if allSelected {
                            selectedIDs.subtract(allIDs)
                        } else {
                            selectedIDs.formUnion(allIDs)
                        }
                    }
                } label: {
                    Text(allSelected ? L10n.tr("Deselect All", table: .home) : L10n.tr("Select All", table: .home))
                        .font(OriveoTheme.Typography.body)
                        .foregroundStyle(OriveoTheme.Palette.primaryTextOnSurface)
                }
                .buttonStyle(.plain)

                Spacer()

                if !selectedIDs.isEmpty {
                    Text(String(format: L10n.tr("%d selected"), selectedIDs.count))
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)

                    Spacer()
                }

                Button {
                    showMoveToFolderSheet = true
                } label: {
                    Label(L10n.tr("Move to", table: .home), systemImage: "folder")
                        .font(OriveoTheme.Typography.body.weight(.semibold))
                        .foregroundStyle(selectedIDs.isEmpty ? OriveoTheme.Palette.textTertiary : OriveoTheme.Palette.primaryTextOnSurface)
                }
                .buttonStyle(.plain)
                .disabled(selectedIDs.isEmpty)

                Button {
                    showBatchDeleteConfirmation = true
                } label: {
                    Label(L10n.tr("Delete"), systemImage: "trash")
                        .font(OriveoTheme.Typography.body.weight(.semibold))
                        .foregroundStyle(selectedIDs.isEmpty ? OriveoTheme.Palette.textTertiary : OriveoTheme.Palette.danger)
                }
                .buttonStyle(.plain)
                .disabled(selectedIDs.isEmpty)
            }
            .padding(.horizontal, OriveoTheme.V2.Sp.s20)
            .padding(.vertical, OriveoTheme.V2.Sp.s12)
            .oriveoContentWidth()
            .background(OriveoTheme.V2.Colors.surfaceElevated)
        }
    }

    // MARK: - Section Header with Select

    private func sectionHeaderWithSelect(title: String, conversations: [Conversation]) -> some View {
        let groupIDs = Set(conversations.map(\.id))
        let allSelected = groupIDs.isSubset(of: selectedIDs)

        return HStack {
            v2SectionHeader(title: title, count: conversations.count)
            Spacer()
            Button {
                withAnimation(preferredAnimation) {
                    if allSelected { selectedIDs.subtract(groupIDs) }
                    else { selectedIDs.formUnion(groupIDs) }
                }
            } label: {
                Text(allSelected ? L10n.tr("Deselect", table: .home) : L10n.tr("Select", table: .home))
                    .font(OriveoTheme.V2.Typography.footnote)
                    .foregroundStyle(OriveoTheme.V2.Colors.primary)
                    // 11pt text is too small to tap: the hit area grows to about 44×44 without changing the title row layout
                    .padding(.vertical, 15)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                    .padding(.vertical, -15)
                    .padding(.horizontal, -8)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Insets of the group header: 4 on each side, 10 to the card (`padding: 0 4px 10px`)
private struct HomeSectionHeaderInsets: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 4)
            .padding(.bottom, 10)
    }
}

private struct HomeHeroBlinkingCursor: View {
    let reduceMotion: Bool

    @State private var blinkStart = Date.now

    var body: some View {
        if reduceMotion {
            cursor
        } else {
            TimelineView(.periodic(from: blinkStart, by: homeHeroCursorBlinkInterval)) { timeline in
                cursor.opacity(isVisible(at: timeline.date) ? 1 : 0)
            }
        }
    }

    private var cursor: some View {
        Capsule(style: .continuous)
            .fill(AuroraTheme.Colors.accentGlow)
            .frame(width: 2, height: 22)
            .fixedSize()
    }

    private func isVisible(at date: Date) -> Bool {
        let elapsed = max(0, date.timeIntervalSince(blinkStart))
        let tick = Int((elapsed / homeHeroCursorBlinkInterval).rounded(.down))
        return tick.isMultiple(of: 2)
    }
}

private struct HomeConversationEmptyState: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                AuroraTheme.Colors.accent.opacity(colorScheme == .dark ? 0.32 : 0.18),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 50
                        )
                    )
                    .frame(width: 100, height: 100)
                    .blur(radius: 6)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                AuroraTheme.Colors.accent.opacity(colorScheme == .dark ? 0.45 : 0.20),
                                AuroraTheme.Colors.auroraBlue.opacity(colorScheme == .dark ? 0.28 : 0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 64, height: 64)
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        OriveoTheme.Palette.cardHighlight,
                                        Color.clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.8
                            )
                    )
                    .shadow(color: AuroraTheme.Colors.accent.opacity(colorScheme == .dark ? 0.4 : 0.18), radius: 16, y: 6)

                Image(systemName: "sparkles")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(AuroraTheme.Colors.accentGlow)
            }
            .padding(.bottom, 4)

            VStack(spacing: 6) {
                Text(L10n.tr("No conversations yet", table: .home))
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(AuroraTheme.Colors.textPrimary)
                    .tracking(-0.2)

                Text(L10n.tr("Start your first AI conversation", table: .home))
                    .font(.system(size: 14))
                    .foregroundStyle(AuroraTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

/// Dictation host for home: mounted only when there is a controller, with the slot fixed to the home draft;
/// "transcribe and send" is unavailable while sending (the gate itself stays in sendFromHero).
private struct HomeDictationHost: ViewModifier {
    let controller: DictationController?
    let canSend: () -> Bool
    let onInsert: (String) -> Void
    let onSend: () -> Void
    /// Realtime text is written into the home input box.
    let live: DictationLiveHooks

    @ViewBuilder
    func body(content: Content) -> some View {
        if let controller {
            content.dictationHost(
                controller: controller,
                slotKey: RecordingStore.homeDraftKey,
                canSend: canSend,
                onInsert: onInsert,
                onSend: onSend,
                live: live
            )
        } else {
            content
        }
    }
}

/// Vertical placement of the home voice dock's top model pill.
enum HomeHeroStageLayout {
    /// Distance from the pill's visual background (40-high capsule) to the orb box top.
    static let pillToOrbGap: CGFloat = 12
    /// Pill hit area: 44 is 2 more than the visual 40 on each side.
    static let pillHitInset: CGFloat = 2
    /// Gap from the pill hit frame's bottom to the top of the voice dock: the orb box already has orbTop whitespace above it, so it is negative.
    static let pillSpacing: CGFloat = pillToOrbGap - VoiceConversationBarContent.orbTop - pillHitInset
}

/// Whether the home input area is the typed card or the voice dock : the realtime selection in judgement → ready;
/// in-memory home realtime selection with the catalog not yet arrived → preparing; catalog load failure → failure card on the dock; otherwise the typed card.
enum HomeHeroStage: Equatable {
    case composer
    case preparing
    case ready
    case catalogFailed

    static func resolve(
        storedSelection: RealtimeModelSelection?,
        judgedSelection: RealtimeModelSelection?,
        catalogReady: Bool,
        catalogState: VoiceCatalogState?
    ) -> HomeHeroStage {
        if judgedSelection != nil { return .ready }
        // No realtime selection stored, or the catalog arrived and does not recognize it (the delisting banner is handled separately): the typed card.
        guard storedSelection != nil, !catalogReady else { return .composer }
        if case .loadFailed = catalogState { return .catalogFailed }
        return .preparing
    }

    @MainActor
    static func resolve(_ appState: AppState, catalogState: VoiceCatalogState?) -> HomeHeroStage {
        resolve(
            storedSelection: appState.realtimeModelSelections[nil],
            judgedSelection: appState.realtimeModelSelection(for: nil),
            catalogReady: appState.realtimeVoiceCatalog() != nil,
            catalogState: catalogState
        )
    }

    /// Model name for the pill : all three dock states show the stored realtime model id (the catalog has no display name, the id is the display name),
    /// not the text model name, to avoid "cyan dot + wrong name"; the typed card shows the text model.
    static func pillModelName(stage: HomeHeroStage, storedSelection: RealtimeModelSelection?, textModelName: String) -> String {
        guard stage != .composer, let storedSelection else { return textModelName }
        return storedSelection.model
    }

    /// Which connection the pill's vendor icon and subline vendor name come from : the three voice dock states take the connection of the stored realtime selection,
    /// the same source as the pill model name, to avoid "Gemini model name + OpenAI icon"; the typed card, or when that connection no longer exists, takes the text model's connection.
    static func pillProvider(
        stage: HomeHeroStage,
        storedSelection: RealtimeModelSelection?,
        provider: (UUID) -> Provider?,
        textProvider: Provider?
    ) -> Provider? {
        guard stage != .composer, let storedSelection, let realtime = provider(storedSelection.providerID) else {
            return textProvider
        }
        return realtime
    }

    /// When the home typed state resets : only when the stored home realtime selection in memory actually changes (model change / cancel / moved away with a new conversation);
    /// catalog arrival only changes the judged selection from nil to a value, a stored one does not change, so a typed state the user switched to is not pulled back to the voice dock.
    static func resetsRealtimeTyping(storedBefore: RealtimeModelSelection?, storedAfter: RealtimeModelSelection?) -> Bool {
        storedBefore != storedAfter
    }

    /// The voice dock shows a model pill at the top with a cyan dot: consistent across the three surfaces; the layout does not move once the catalog arrives.
    var showsModelPill: Bool { self != .composer }
    var showsRealtimeDot: Bool { self != .composer }
}

/// Home voice dock preparing (voice catalog not yet arrived): the orb is not tappable, the status line shows "Loading" (voice_realtime_model_loading), "Type instead" still works.
final class HomeRealtimePreparingStageSurface: VoiceConversationSurface {
    let objectWillChange = ObservableObjectPublisher()
    private let onSwitchToTyping: () -> Void

    init(onSwitchToTyping: @escaping () -> Void) {
        self.onSwitchToTyping = onSwitchToTyping
    }

    var showsTypingSwitch: Bool { true }
    var showsEndButton: Bool { false }
    var showsMuteButton: Bool { false }
    var statusKey: VoiceConversationLogic.StatusKey? { nil }
    var displayState: VoiceConversationLogic.DisplayState? { nil }
    var level: Double { 0 }
    var idleHint: String? { ChatModelRemovedBanner.voiceCatalogLoadingLabel }
    /// Catalog not yet arrived: a realtime session cannot be opened.
    func tapOrb() {}
    func toggleMute() {}
    func switchToTyping() { onSwitchToTyping() }
}

extension RealtimeVoiceFailure {
    /// Failure card on the dock for a home voice catalog load failure: "Voice model temporarily unavailable" + "Retry" (re-fetches the catalog).
    static let catalogUnavailable = RealtimeVoiceFailure(
        classification: RealtimeModelPolicy.FailureClassification(
            category: .network,
            copyKey: "voice_realtime_catalog_unavailable",
            copyArg: .none,
            actions: [.retry],
            actionCopyKeys: [RealtimeModelPolicy.copyKey(for: .retry)],
            buttonCopyKeys: RealtimeModelPolicy.buttonCopyKeys(for: [.retry])
        ),
        copyArgValue: nil
    )
}
