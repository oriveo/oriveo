import SwiftUI

let homeEarlierPageSize = 10
let homeHeaderActionSpacing: CGFloat = 8
let homeHeaderActionButtonSize: CGFloat = 38
let homeHeaderActionIconSize: CGFloat = 16
let homeHeroCursorBlinkInterval: TimeInterval = 0.55

struct HeroPendingSend {
    let text: String
    let providerID: UUID
    let modelID: String
}

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    @State private var showFolderLimitSheet = false
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
            LazyVStack(alignment: .leading, spacing: OriveoTheme.V2.Sp.s16, pinnedViews: [.sectionHeaders]) {
                header
                    .padding(.horizontal, OriveoTheme.V2.Sp.s20)
                if !isEditing {
                    heroSection
                    HomeNotesEntryCard(
                        count: appState.noteSummaries.count,
                        latestTitle: appState.noteSummaries.first.map { NoteText.displayTitle($0.title) }
                    ) {
                        appState.openNotes()
                    }
                    .padding(.horizontal, OriveoTheme.V2.Sp.s20)
                    .padding(.vertical, OriveoTheme.Spacing.md)
                }
                conversationContent
                    .padding(.horizontal, OriveoTheme.V2.Sp.s20)
                    .opacity(contentAppeared ? 1 : 0)
                    .offset(y: contentAppeared ? 0 : 8)

            }
            .padding(.top, 4)
            .padding(.bottom, isEditing ? 80 : OriveoTheme.V2.Sp.s32)
        }
        .auroraBackground()
        .animation(preferredAnimation, value: heroState)
        .animation(preferredAnimation, value: isEditing)
        .onAppear {
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
        .sheet(isPresented: $showFolderLimitSheet) {
            EmptyView()
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

    private var isCJKLocale: Bool {
        isHomeHeaderCJKLocale(AppLocalization.currentLocale)
    }

    private var headerDateText: String {
        formatHomeHeaderDate(.now, locale: AppLocalization.currentLocale)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 8) {
                Text(headerDateText)
                    .font(.system(size: isCJKLocale ? 13 : 12, weight: .medium))
                    .foregroundStyle(AuroraTheme.Colors.textTertiary)
                    .textCase(isCJKLocale ? nil : .uppercase)
                    .tracking(isCJKLocale ? 0 : 1.2)

                Spacer(minLength: 0)

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
                        }
                        .buttonStyle(.plain)
                    } else {
                        HStack(spacing: homeHeaderActionSpacing) {
                            headerIconButton(systemImage: "folder.badge.plus") {
                                newFolderName = ""
                                showCreateFolderAlert = true
                            }
                            headerIconButton(systemImage: "magnifyingglass") {
                                withAnimation(.snappy) {
                                    isSearching.toggle()
                                    if !isSearching { searchText = "" }
                                }
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 28)

            if !isSearching {
                heroGreeting
            }

            if isSearching {
                searchBar
            }
        }
    }

    private var heroGreeting: some View {
        let line = L10n.tr(AuroraGreeting.currentKey())
        let tagline = L10n.tr(AuroraGreeting.taglineKey())

        return VStack(alignment: .leading, spacing: 6) {
            heroGreetingLine(line)

            Text(tagline)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(AuroraTheme.Colors.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.top, 2)
    }

    private func heroGreetingLine(_ line: String) -> some View {
        Text(line)
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(heroTextGradient)
            .tracking(-0.4)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    private var heroTextGradient: LinearGradient {
        LinearGradient(
            colors: [
                OriveoTheme.Palette.textPrimary,
                OriveoTheme.Palette.primary
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    @ViewBuilder
    private func headerIconButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: homeHeaderActionIconSize, weight: .medium))
                .foregroundStyle(AuroraTheme.Colors.textSecondary)
                .frame(width: homeHeaderActionButtonSize, height: homeHeaderActionButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            .padding(.top, 10)
    }

    // MARK: - Aurora Composer

    private var composerPlaceholder: String {
        L10n.tr(AuroraGreeting.placeholderKey())
    }

    private var auroraComposerCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroComposerInput

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.clear, AuroraTheme.Colors.hairline, Color.clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 0.6)
                .padding(.top, 10)
                .padding(.bottom, 12)

            HStack(alignment: .center, spacing: 12) {
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

                Spacer(minLength: 8)

                auroraSendButton
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .auroraGlassCard(cornerRadius: 28, focused: heroFocused)
    }

    private var heroComposerInput: some View {
        ZStack(alignment: .leading) {
            TextField("", text: $heroText, axis: .vertical)
                .focused($heroFocused)
                .font(AuroraTheme.Typography.composerPlaceholder)
                .foregroundStyle(AuroraTheme.Colors.textPrimary)
                .tint(AuroraTheme.Colors.accent)
                .lineLimit(1...5)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .submitLabel(.return)

            if !heroFocused && heroText.isEmpty {
                HStack(spacing: 2) {
                    Text(composerPlaceholder)
                        .font(AuroraTheme.Typography.composerPlaceholder)
                        .foregroundStyle(AuroraTheme.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !isSearching {
                        blinkingCursor
                            .padding(.leading, 4)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .clipped()
                .allowsHitTesting(false)
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
                        .foregroundStyle(AuroraTheme.Colors.textTertiary)
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
                        .foregroundStyle(AuroraTheme.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AuroraTheme.Colors.textTertiary)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: 250, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var auroraSendButton: some View {
        Button {
            Task { await sendFromHero() }
        } label: {
            ZStack {
                Circle()
                    .fill(OriveoTheme.Palette.primaryGradient)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Circle().fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.28), Color.clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                    )

                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            .shadow(color: OriveoTheme.Palette.shadow, radius: 6, y: 3)
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
                    VStack(alignment: .leading, spacing: OriveoTheme.V2.Sp.s12) {
                        v2SectionHeader(title: L10n.tr("Search Results", table: .home), count: conversations.count)
                        GroupedCard {
                            VStack(spacing: 0) {
                                ForEach(Array(conversations.enumerated()), id: \.element.id) { index, conversation in
                                    conversationButton(for: conversation, showFolderTag: true, grouped: true)
                                    if index < conversations.count - 1 {
                                        Divider().foregroundStyle(OriveoTheme.V2.Colors.borderDefault.opacity(0.5)).padding(.horizontal, 16)
                                    }
                                }
                            }
                        }
                    }
                }
            } else if groups.isEmpty && folders.isEmpty && appState.conversationManager.pinnedConversations.isEmpty {
                HomeConversationEmptyState()
            } else {
                VStack(alignment: .leading, spacing: OriveoTheme.V2.Sp.s24) {
                    if !folders.isEmpty {
                        folderSection(folders: folders)
                    }

                    let pinnedConversations = appState.conversationManager.pinnedConversations
                    if !pinnedConversations.isEmpty {
                        pinnedSection(pinnedConversations)
                    }

                    ForEach(groups, id: \.section) { group in
                        Section {
                            VStack(alignment: .leading, spacing: OriveoTheme.V2.Sp.s8) {
                                GroupedCard {
                                    VStack(spacing: 0) {
                                        ForEach(Array(group.conversations.enumerated()), id: \.element.id) { index, conversation in
                                            conversationButton(for: conversation, grouped: true)
                                            if index < group.conversations.count - 1 {
                                                Divider().foregroundStyle(OriveoTheme.V2.Colors.borderDefault.opacity(0.5)).padding(.horizontal, 16)
                                            }
                                        }
                                    }
                                }
                                if group.section == .earlier && group.remainingCount > 0 {
                                    earlierShowMoreButton(remainingCount: group.remainingCount)
                                }
                            }
                        } header: {
                            if isEditing {
                                sectionHeaderWithSelect(title: title(for: group.section), conversations: group.conversations)
                                    .padding(.bottom, 4)
                            } else {
                                v2SectionHeader(title: title(for: group.section), count: group.conversations.count)
                                    .padding(.bottom, 4)
                            }
                        }
                    }
                }
            }
        }
    }

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
        .padding(.bottom, 4)
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
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pinned Section

    @ViewBuilder
    private func pinnedSection(_ conversations: [Conversation]) -> some View {
        Section {
            VStack(alignment: .leading, spacing: OriveoTheme.V2.Sp.s8) {
                GroupedCard {
                    VStack(spacing: 0) {
                        ForEach(Array(conversations.enumerated()), id: \.element.id) { index, conversation in
                            conversationButton(for: conversation, showFolderTag: true, grouped: true)
                            if index < conversations.count - 1 {
                                Divider().foregroundStyle(OriveoTheme.V2.Colors.borderDefault.opacity(0.5)).padding(.horizontal, 16)
                            }
                        }
                    }
                }
            }
        } header: {
            v2SectionHeader(title: L10n.tr("Pinned", table: .home), count: conversations.count)
                .padding(.bottom, 4)
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

                //     seedTestMessages(into: conversation, count: 200)
                //     Label("Seed 200 Test Messages", systemImage: "doc.badge.plus")

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


    // private func seedTestMessages(into conversation: Conversation, count: Int) {
    //     let baseTime = conversation.messages.last?.createdAt ?? conversation.createdAt
    //     let startOrder = seeded.messages.count
    //         let createdAt = baseTime.addingTimeInterval(TimeInterval(i + 1))
    //         seeded.messages.append(message)
    //     appState.upsertConversationProjection(seeded)

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
            }
            .buttonStyle(.plain)
        }
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
        Rectangle()
            .fill(AuroraTheme.Colors.accent)
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
