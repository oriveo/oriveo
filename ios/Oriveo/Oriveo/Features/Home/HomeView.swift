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

/// A send the hero gate held back, snapshotted together with the model in use at that moment, so the
/// confirmation sheet can decide afterwards whether it may go straight out.
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
    @State private var heroDisclosureProvider: ProviderKind?
    @State private var pendingHeroSend: HeroPendingSend?
    @State private var showsHeroMissingProviderKeyPrompt = false
    @State private var isPreparingHeroSend = false
    @State private var heroVoiceFeeds = HomeVoiceBarFeedCache()
    @State private var pendingHeroVoiceStart = PendingVoiceEntry()
    @Namespace private var voiceOrbNamespace
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
        appState.setActiveModel(providerID: selection.providerID, modelID: selection.modelID)
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
                    .padding(.top, 14)
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
            canSend: { !isSendingFromHero },
            onInsert: { transcript in
                heroText = dictationProbe.insert(transcript: transcript, currentText: heroText)
            },
            onSend: { Task { await sendFromHero() } }
        ))
        // Voice conversation host: ending with zero turns leaves no trace; the first send creates the conversation
        // and hands over to the chat page.
        .onAppear { VoiceConversationSession.shared.hostAppeared(nil) }
        .onDisappear { VoiceConversationSession.shared.hostDisappeared(nil) }
        .onChange(of: VoiceConversationSession.shared.lastEnd) { _, end in
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
                    onCheckConnection: openDictationCheckConnection
                )
            }

            auroraComposerCard
        }
        .padding(.horizontal, OriveoTheme.V2.Sp.s20)
    }

    /// Check Connection on the dictation card: open that connection's details when there is one, otherwise provider setup.
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

    /// The composer card: purely flat while idle (no aurora ring, no divider), the ring lights up on focus;
    /// model pill plus a solid send button
    private var auroraComposerCard: some View {
        auroraComposerCardContent
            // The design is a 1px border plus padding 18/18/14 (border-box), so content sits 1pt further from each edge
            .padding(.horizontal, 19)
            .padding(.top, 19)
            .padding(.bottom, 15)
            .auroraGlassCard(cornerRadius: 26, focused: heroFocused)
            // One transition when entering or leaving a voice conversation (spring, or a short fade under Reduce Motion).
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
            VoiceConversationBar(surface: voiceSurface, page: .home, orbNamespace: voiceOrbNamespace) {
                VoiceConversationSession.shared.end(.user)
            }
            .transition(.opacity)
        } else if VoiceConversationDemo.status != nil {
            VoiceConversationDemo.bar
        } else if let controller = DictationHub.shared.controller {
            DictationInputSwitcher(controller: controller, canSend: !isSendingFromHero) {
                auroraComposerIdleContent
            }
        } else {
            auroraComposerIdleContent
        }
    }

    private var auroraComposerIdleContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The real input plus the decorative blinking cursor (shown while unfocused and empty)
            heroComposerInput

            // Model pill (tonal, no stroke), the voice button and the send button (solid violet circle); no attachment button
            let actions = heroComposerActions
            HStack(alignment: .center, spacing: 10) {
                Button {
                    let active = appState.activeModel
                    modelPickerPresentation = ModelPickerPresentationSnapshot(
                        context: .home,
                        providers: appState.providers,
                        providersVersion: appState.providersVersion,
                        currentProviderID: active?.provider.id,
                        currentModel: active?.model
                    )
                } label: {
                    modelSelectorPill
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                if actions.showsVoice {
                    heroVoiceButton
                        .transition(.opacity)
                }

                auroraSendButton
                    .disabled(!actions.sendEnabled)
            }
            .animation(.easeInOut(duration: 0.18), value: actions.showsVoice)
        }
    }

    // Same values as the old TextField's font(composerPlaceholder) / foregroundStyle(textPrimary) / tint(accentGlow),
    // cached as single instances because ComposerTextView compares styles by equality.
    private static let heroInputFont = UIFont.systemFont(ofSize: 18, weight: .medium)
    private static let heroInputTextColor = UIColor(AuroraTheme.Colors.textPrimary)
    private static let heroInputTint = UIColor(AuroraTheme.Colors.accentGlow)

    private var heroComposerInput: some View {
        ZStack(alignment: .leading) {
            // The same component as the chat composer: a SwiftUI TextField re-lays out a long single paragraph on
            // every layout pass.
            ComposerTextView(
                text: $heroText,
                isFocused: $heroFocused,
                font: Self.heroInputFont,
                textColor: Self.heroInputTextColor,
                // The system caret uses the same colour as the decorative cursor (dark #C4B5FD / light #8B5CF6)
                tintColor: Self.heroInputTint,
                // The placeholder is drawn by the decorative layer below, so VoiceOver needs an explicit name
                accessibilityLabel: composerPlaceholder,
                maxLength: ChatInputLimit.maxUTF16,
                onLengthLimitExceeded: ChatInputLimit.showLimitReachedToast,
                selectionProbe: dictationProbe
            )
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .accessibilityIdentifier("home_composer_input")

            if !heroFocused && heroText.isEmpty {
                HStack(spacing: 4) {
                    Text(composerPlaceholder)
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

    /// The model selector chip: the provider's colour logo plus model name and provider name, in a tonal
    /// capsule without a stroke (dark 6% white / light #F3F0FA), 40 tall, at most 230 wide (the model name
    /// truncates to one line).
    private var modelSelectorPill: some View {
        let active = appState.activeModel
        return HStack(spacing: 9) {
            Group {
                if let active {
                    ConnectionAvatarIcon(
                        provider: active.provider,
                        kind: active.provider.kind,
                        relayKind: active.provider.relayKind,
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
                Text(pillModelName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AuroraTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let active {
                    Text(active.provider.displayName)
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
        .frame(maxWidth: 230, alignment: .leading)
    }

    /// The send button: a 44pt solid violet circle with a white arrow.up, no gradient, no shadow, no highlight
    /// A voice conversation started from home that has not been handed over yet. The home bar gets a feed that
    /// freezes on handover; the chat page's bar owns the controller exclusively.
    private var heroVoiceConversationController: (any VoiceConversationSurface)? {
        heroVoiceFeeds.feed(for: VoiceConversationSession.shared)
    }

    /// State of the two keys on the home card: with no active model the voice button still shows (entering it
    /// resolves a model first); image-only models get no voice button.
    private var heroComposerActions: HomeComposerActions {
        VoiceConversationEntry.homeComposer(
            isSending: isSendingFromHero || isPreparingHeroSend,
            hasContent: !heroText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            voiceAvailable: DictationHub.shared.controller != nil,
            modelProducesText: appState.activeModel.map { VoiceConversationEntry.modelProducesText($0.model) } ?? true
        )
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
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(AuroraTheme.Colors.sendFill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
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
        await VoiceConversationSession.shared.start(
            origin: .home,
            conversationID: nil,
            host: appState
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
        isSendingFromHero = true
        let convID = await appState.sendMessage(trimmed, in: nil)
        isSendingFromHero = false
        if convID != nil, heroText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
            heroText = ""
        }
    }

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
                        .foregroundStyle(OriveoTheme.Palette.primary)
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
                        .foregroundStyle(selectedIDs.isEmpty ? OriveoTheme.Palette.textTertiary : OriveoTheme.Palette.primary)
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

    @ViewBuilder
    func body(content: Content) -> some View {
        if let controller {
            content.dictationHost(
                controller: controller,
                slotKey: RecordingStore.homeDraftKey,
                canSend: canSend,
                onInsert: onInsert,
                onSend: onSend
            )
        } else {
            content
        }
    }
}
