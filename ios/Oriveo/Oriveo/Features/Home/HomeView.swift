import SwiftUI

let homeEarlierPageSize = 10
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    @Environment(\.homeDebugSnapshotSeed) private var debugSnapshotSeed
    #endif

    @State private var isSearching = false
    @State private var searchText = ""
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
    @State private var earlierDisplayCount = homeEarlierPageSize
    @State private var cachedConversationModelLookup = ModelDisplayLookup.empty
    @State private var cachedConversationModelLookupVersion: UInt = .max
    @State private var cachedConversationModelLookupFingerprint: Int?
    @State private var heroText = ""
    @FocusState private var heroFocused: Bool
    @State private var isSendingFromHero = false
    @State private var heroDisclosureProvider: ProviderKind?
    @State private var pendingHeroSend: HeroPendingSend?
    @State private var showsHeroMissingProviderKeyPrompt = false
    @State private var isPreparingHeroSend = false


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

    private var conversationModelLookup: ModelDisplayLookup {
        cachedConversationModelLookup
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
                // The list sits 26 below Notes; while editing, the hero and Notes collapse and the list follows the greeting
                conversationContent
                    .padding(.top, 26)
                    .padding(.horizontal, OriveoTheme.V2.Sp.s20)
                    .opacity(contentAppeared ? 1 : 0)
                    .offset(y: contentAppeared ? 0 : 8)

            }
            .padding(.top, OriveoTheme.V2.Sp.s16)
            .padding(.bottom, isEditing ? 80 : OriveoTheme.V2.Sp.s32)
        }
        .auroraBackground()
        .animation(preferredAnimation, value: heroState)
        .animation(preferredAnimation, value: isEditing)
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
        .alert(
            L10n.tr("Delete this conversation?"),
            isPresented: Binding(
                get: { conversationToDelete != nil },
                set: { if !$0 { conversationToDelete = nil } }
            ),
            presenting: conversationToDelete
        ) { conv in
            Button(L10n.tr("Cancel"), role: .cancel) {
                conversationToDelete = nil
            }
            Button(L10n.tr("Delete"), role: .destructive) {
                let id = conv.id
                conversationToDelete = nil
                withAnimation(preferredAnimation) {
                    appState.deleteConversation(id: id)
                }
            }
        } message: { conv in
            let refCount = appState.noteManager.referenceCount(conversationID: conv.id)
            if refCount > 0 {
                Text(L10n.tr("This conversation and all its messages will be permanently deleted.")
                    + "\n\n" + String(format: L10n.tr("This conversation is referenced by %d notes.", table: .notes), refCount))
            } else {
                Text(L10n.tr("This conversation and all its messages will be permanently deleted."))
            }
        }
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
                onAccept: { Task { await acknowledgeHeroPrivacyAndSend() } },
                onCancel: { pendingHeroSend = nil }
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

    /// Centred greeting: date eyebrow / 30pt greeting / tagline (one of four per time of day, changing daily)
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
        auroraComposerCard
            .padding(.horizontal, OriveoTheme.V2.Sp.s20)
    }

    // MARK: - Aurora Composer

    private var composerPlaceholder: String {
        L10n.tr(AuroraGreeting.placeholderKey())
    }

    /// The composer card: purely flat while idle (no aurora ring, no divider), the ring lights up on focus;
    /// model pill plus a solid send button
    private var auroraComposerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // A real TextField plus the decorative blinking cursor (shown while unfocused and empty)
            heroComposerInput

            // Model pill (tonal, no stroke) plus the send button (solid violet circle); no attachment button
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

                auroraSendButton
            }
        }
        // The design is a 1px border plus padding 18/18/14 (border-box), so content sits 1pt further from each edge
        .padding(.horizontal, 19)
        .padding(.top, 19)
        .padding(.bottom, 15)
        .auroraGlassCard(cornerRadius: 26, focused: heroFocused)
    }

    private var heroComposerInput: some View {
        ZStack(alignment: .leading) {
            TextField("", text: $heroText, axis: .vertical)
                .focused($heroFocused)
                .font(AuroraTheme.Typography.composerPlaceholder)
                .foregroundStyle(AuroraTheme.Colors.textPrimary)
                // The system caret uses the same colour as the decorative cursor (dark #C4B5FD / light #8B5CF6)
                .tint(AuroraTheme.Colors.accentGlow)
                .lineLimit(1...5)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .submitLabel(.return)
                // The TextField prompt is empty (the placeholder is drawn by the decorative layer below), so VoiceOver
                // needs an explicit name
                .accessibilityLabel(Text(composerPlaceholder))

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
                    ProviderBadgeIcon(
                        kind: active.provider.kind,
                        size: 24,
                        relayKind: active.provider.relayKind
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
    }

    @MainActor
    private func sendFromHero() async {
        guard !isSendingFromHero, !isPreparingHeroSend else { return }
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

            if !searchText.isEmpty {
                if conversations.isEmpty && folders.isEmpty && !searchInFlight {
                    HomeConversationEmptyState()
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        v2SectionHeader(title: L10n.tr("Search Results", table: .home), count: conversations.count)
                            .modifier(HomeSectionHeaderInsets())
                        conversationGroupCard(conversations, showFolderTag: true)
                    }
                }
            } else if groups.isEmpty && folders.isEmpty && appState.conversationManager.pinnedConversations.isEmpty {
                HomeConversationEmptyState()
            } else {
                // 22 between groups. Title and card share one VStack: a Section nested in a plain VStack is split
                // into two sibling nodes, title and content, and the outer spacing lands between them (the
                // previous title-to-card gap was 30+).
                VStack(alignment: .leading, spacing: 22) {
                    if !folders.isEmpty {
                        folderSection(folders: folders)
                    }

                    let pinnedConversations = appState.conversationManager.pinnedConversations
                    if !pinnedConversations.isEmpty {
                        pinnedSection(pinnedConversations)
                    }

                    ForEach(groups, id: \.section) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            Group {
                                if isEditing {
                                    sectionHeaderWithSelect(title: title(for: group.section), conversations: group.conversations)
                                } else {
                                    v2SectionHeader(title: title(for: group.section), count: group.conversations.count)
                                }
                            }
                            .modifier(HomeSectionHeaderInsets())

                            VStack(alignment: .leading, spacing: OriveoTheme.V2.Sp.s8) {
                                conversationGroupCard(group.conversations)
                                if group.section == .earlier && group.remainingCount > 0 {
                                    earlierShowMoreButton(remainingCount: group.remainingCount)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// One card per group with no separators inside: rows are kept apart by their own padding, and each row's
    /// contentShape covers the whole row
    private func conversationGroupCard(_ conversations: [Conversation], showFolderTag: Bool = false) -> some View {
        AuroraGroupedCard {
            VStack(spacing: 0) {
                ForEach(conversations) { conversation in
                    conversationButton(for: conversation, showFolderTag: showFolderTag, grouped: true)
                }
            }
        }
    }

    /// Group header: 3×18 glowing bar + 17/bold title + 13 mono count (spacing 10)
    private func v2SectionHeader(title: String, count: Int? = nil) -> some View {
        HStack(alignment: .center, spacing: 10) {
            AuroraSectionRule()

            Text(title)
                .font(AuroraTheme.Typography.section)
                .foregroundStyle(AuroraTheme.Colors.textPrimary)
                .tracking(-0.3)

            if let count, count > 0 {
                Text("\(count)")
                    .font(AuroraTheme.Typography.countMono)
                    .foregroundStyle(AuroraTheme.Colors.accent)
                    .baselineOffset(1)
            }

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

    // MARK: - Pinned Section

    private func pinnedSection(_ conversations: [Conversation]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            v2SectionHeader(title: L10n.tr("Pinned", table: .home), count: conversations.count)
                .modifier(HomeSectionHeaderInsets())
            conversationGroupCard(conversations, showFolderTag: true)
        }
    }

    // MARK: - Folder Section

    private func folderSection(folders: [Folder]) -> some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            ForEach(folders) { folder in
                FolderRow(
                    folder: folder,
                    isEditing: isEditing,
                    selectedIDs: $selectedIDs
                )
            }
        }
    }

    private func conversationButton(for conversation: Conversation, showFolderTag: Bool = false, grouped: Bool = false) -> some View {
        let provider = appState.provider(for: conversation.providerID)
        let resolvedModelName = ConversationRow.resolveModelName(
            for: conversation,
            provider: provider,
            lookup: conversationModelLookup
        )

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
            }
            .padding(.leading, isEditing ? 14 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !isEditing {
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

                if let lastMessage = conversation.messages.last {
                    Button {
                        UIPasteboard.general.string = lastMessage.text
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
        let fingerprint = ModelDisplayLookup.fingerprint(providers: appState.providers)
        if fingerprint == cachedConversationModelLookupFingerprint {
            cachedConversationModelLookupVersion = appState.providersVersion
            return
        }
        cachedConversationModelLookup = ModelDisplayLookup(providers: appState.providers)
        cachedConversationModelLookupVersion = appState.providersVersion
        cachedConversationModelLookupFingerprint = fingerprint
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
