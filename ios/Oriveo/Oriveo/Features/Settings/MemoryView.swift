import OriveoProviderKit
import SwiftUI

enum MemoryViewAction: Equatable, Sendable {
    case generateDraft
    case addItem
}

enum MemoryHeroStyle: Equatable, Sendable {
    case draftStarter
    case manualStarter
    case activeMemory
}

enum MemoryDetailPanelStyle: Equatable, Sendable {
    case none
}

struct MemoryViewPresentation: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case starter
        case editor
    }

    let mode: Mode
    let heroStyle: MemoryHeroStyle
    let detailPanelStyle: MemoryDetailPanelStyle
    let primaryAction: MemoryViewAction?
    let secondaryAction: MemoryViewAction?
    let showsExampleCard: Bool
    let showsSupportCards: Bool

    /// - Parameters:
    ///   - hasItems: there are displayable items in the list (including conflict groups); when none, show the empty starter state with the primary action "Add".
    static func resolve(
        hasItems: Bool,
        hasRecentConversations: Bool
    ) -> Self {
        if !hasItems {
            return .init(
                mode: .starter,
                heroStyle: hasRecentConversations ? .draftStarter : .manualStarter,
                detailPanelStyle: .none,
                primaryAction: .addItem,
                secondaryAction: hasRecentConversations ? .generateDraft : nil,
                showsExampleCard: false,
                showsSupportCards: false
            )
        }

        return .init(
            mode: .editor,
            heroStyle: .activeMemory,
            detailPanelStyle: .none,
            primaryAction: hasRecentConversations ? .generateDraft : nil,
            secondaryAction: nil,
            showsExampleCard: false,
            showsSupportCards: true
        )
    }
}

struct MemoryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowNavigation) private var windowNavigation
    /// Navigation state of this window (one per window); hosts without injection (tests) fall back to the active window.
    private var navigation: NavigationManager { windowNavigation ?? appState.navigation }

    @State private var isGeneratingDraft: Bool = false
    /// If the editor is open when a draft arrives, wait for it to close and then open a new pre-filled editor.
    @State private var pendingGeneratedDraft: String? = nil
    @State private var activeDraftRequestID: UUID? = nil
    @State private var hasRecentConversations: Bool = false
    @State private var heroAppeared: Bool = false
    /// The top bar only shows its material and title after the list scrolls past the page header.
    @State private var isScrolled: Bool = false
    /// Measured width of each constellation label: anchors are clamped to the container by it so long (localized) labels stay inside.
    @State private var starChipWidths: [Int: CGFloat] = [:]
    @State private var draftErrorTitle: String = ""
    @State private var draftErrorMessage: String = ""
    @State private var showDraftErrorAlert: Bool = false
    /// Pre-run disclosure for AI drafting / organizing into items: the pending provider + model + scope.
    @State private var extractionFlow = MemoryExtractionFlow()
    @State private var editor: MemoryItemEditorState? = nil
    /// ID of the item to edit that came from "This is wrong": the item cache may arrive after the page, so open it once available.
    @State private var pendingEditItemID: String? = nil
    @State private var pendingDeletion: MemoryItem? = nil
    @State private var rawEditor: MemoryRawEditorState? = nil
    @State private var organizeTarget: MemoryOrganizeTarget? = nil
    /// The provider + model confirmed in the disclosure alert; nil = no model available (the sheet shows no_model).
    @State private var organizeCandidate: MemoryOrganizer.Candidate? = nil
    @State private var deviceId: String = Self.initialDeviceId
    /// Count for the "Memory suggestions" entry row: reloaded when entering the page and when returning from the candidate inbox.
    @State private var inbox = MemoryInboxModel()

    /// The list reads from the in-memory item cache (no tombstones, list order) and never reads the database on the main thread.
    private var listPresentation: MemoryItemListPresentation {
        MemoryItemListPresentation.resolve(
            items: appState.memoryItemsCache.items,
            deviceId: deviceId,
            folderNames: folderNames
        )
    }

    private var folderNames: [String: String] {
        var names = Dictionary(
            appState.folders.map { ($0.id.uuidString.lowercased(), $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        #if DEBUG
        // Screenshots only: folder ids in the fixture are not UUIDs and cannot enter appState.folders
        names.merge(MemoryShots.folderNames) { current, _ in current }
        #endif
        return names
    }

    private static var initialDeviceId: String {
        #if DEBUG
        // Screenshots only: conflict pairs decide "this device's version" by the fixture's deviceId
        if let deviceId = MemoryShots.deviceId { return deviceId }
        #endif
        return AppPreferencesStore.memoryDeviceId
    }

    private var presentation: MemoryViewPresentation {
        MemoryViewPresentation.resolve(
            hasItems: !listPresentation.isEmpty,
            hasRecentConversations: hasRecentConversations
        )
    }

    /// Item to edit that came from "This is wrong": opens that item's editor directly.
    private func takePendingMemoryEdit() {
        guard let itemID = appState.consumePendingMemoryEditItemID() else { return }
        Task { @MainActor in
            // Wait for the navigation transition to settle before presenting the sheet; a sheet presented mid-transition is swallowed by the system
            try? await Task.sleep(nanoseconds: 350_000_000)
            pendingEditItemID = itemID
            openPendingEditIfReady()
        }
    }

    private func openPendingEditIfReady() {
        guard let itemID = pendingEditItemID, editor == nil,
              let state = MemoryItemEditorState.edit(itemId: itemID, in: appState.memoryItemsCache.items)
        else { return }
        pendingEditItemID = nil
        editor = state
    }

    var body: some View {
        let list = listPresentation
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                pageHeader
                    .opacity(heroAppeared ? 1 : 0)
                    .offset(y: heroAppeared ? 0 : 12)

                if presentation.mode == .starter {
                    starterConstellation
                        .padding(.top, 8)
                    starterCard
                        .padding(.top, 14)
                    inboxEntry
                        .padding(.top, 12)
                    // The starter state also shows the privacy footnote; it does not go through showsSupportCards, and the list state is unchanged
                    privacyFootnote
                        .padding(.top, 12)
                } else {
                    MemorySpectrum(sections: list.sections, episodicCount: list.episodic.rows.count)
                        .padding(.horizontal, 4)
                        .padding(.top, 20)
                    inboxEntry
                        .padding(.top, 24)
                    MemoryItemListView(presentation: list) { action in
                        handleListAction(action)
                    }
                    .padding(.top, 28)
                    .transition(.opacity)
                    if let action = presentation.primaryAction {
                        draftRow(for: action)
                            .padding(.top, 32)
                    }
                }

                // The anti-forget toggle is hidden because reminders are no longer injected into requests;
                // the preference fields are still saved and synced so existing values survive.
                if presentation.showsSupportCards {
                    privacyFootnote
                        .padding(.top, 12)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 56)
            .oriveoContentWidth()
            .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86), value: presentation.mode)
        }
        .background(MemoryAtlasBackdrop(height: presentation.mode == .starter ? 420 : 360))
        .safeAreaInset(edge: .top) { toolbar }
        // The top bar is transparent at rest (dot matrix and large title beneath); material and title only appear once it really scrolls.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 12
        } action: { _, scrolled in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                isScrolled = scrolled
            }
        }
        .onAppear {
            FeatureBadges.shared.markSeen(FeatureBadges.settingsMemory)
            inbox.reloadTask(appState: appState)
            takePendingMemoryEdit()
            #if DEBUG
            // Screenshots only: preset an over-long paragraph on the raw page (production prepareSave decides tooLong; no item is written)
            if let raw = MemoryShots.takeRawEditor() { rawEditor = raw }
            #endif
            withAnimation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.85).delay(0.04)) {
                heroAppeared = true
            }
        }
        .onDisappear { activeDraftRequestID = nil }
        .onChange(of: appState.pendingMemoryEditItemID) { _, itemID in
            if itemID != nil { takePendingMemoryEdit() }
        }
        .onChange(of: appState.memoryItemsCache.items) { _, _ in
            openPendingEditIfReady()
        }
        .sheet(item: $editor, onDismiss: presentQueuedDraft) { state in
            MemoryItemEditorSheet(state: state) { saved in
                saveEditor(saved)
            }
        }
        .sheet(item: $rawEditor) { state in
            MemoryRawView(state: state) { ops in
                writeItems { try MemoryRawEditorState.apply(ops, writer: $0) }
            }
        }
        .sheet(item: $organizeTarget) { target in
            MemoryOrganizeSheet(
                target: target,
                organizer: MemoryOrganizer(candidates: organizeCandidate.map { [$0] } ?? [])
            ) { selection in
                writeItems { try selection.save($0) }
            }
        }
        .alert(
            L10n.tr("memory_delete_confirm_title", table: .chat),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { item in
            Button(L10n.tr("memory_action_delete", table: .chat), role: .destructive) {
                pendingDeletion = nil
                writeItems { try $0.remove(id: item.id) }
            }
            Button(L10n.tr("Cancel"), role: .cancel) {
                pendingDeletion = nil
            }
        } message: { _ in
            Text(L10n.tr("memory_delete_confirm_body", table: .chat))
        }
        .alert(
            extractionFlow.disclosure?.title ?? "",
            isPresented: Binding(
                get: { extractionFlow.disclosure != nil },
                set: { if !$0 { extractionFlow.dismissDisclosure() } }
            ),
            presenting: extractionFlow.disclosure
        ) { _ in
            Button(L10n.tr("Cancel"), role: .cancel) {
                extractionFlow.cancel()
            }
            Button(L10n.tr("memory_extraction_send", table: .chat)) {
                confirmDisclosure()
            }
        } message: { disclosure in
            Text(disclosure.message)
        }
        .alert(draftErrorTitle, isPresented: $showDraftErrorAlert) {
            Button(L10n.tr("OK"), role: .cancel) { }
        } message: {
            Text(draftErrorMessage)
        }
        .task { await computeHasRecentConversations() }
    }

    // MARK: - Backdrop (page + hero aurora)

    // MARK: - Toolbar

    /// Back on the left; in editor mode, a "Raw" text button + a "+" icon button on the top right.
    private var toolbar: some View {
        HStack(spacing: 0) {
            OriveoBackButton {
                appState.pop()
            }
            .padding(.leading, -OriveoBackButton.edgeInset)

            Spacer(minLength: 8)

            if presentation.mode == .editor {
                Button {
                    rawEditor = MemoryRawEditorState(items: appState.memoryItemsCache.items)
                } label: {
                    Text(L10n.tr("memory_raw_view", table: .chat))
                        .font(.system(size: 17))
                        .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                        .padding(.horizontal, 8)
                        .frame(minHeight: OriveoBackButton.hitSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    editor = .create()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                        .frame(width: OriveoBackButton.hitSize, height: OriveoBackButton.hitSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("memory_add_item", table: .chat))
                .padding(.trailing, -OriveoBackButton.edgeInset)
            }
        }
        .overlay {
            Text(L10n.tr("Memory"))
                .font(OriveoTheme.Typography.title3)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .opacity(isScrolled ? 1 : 0)
                .accessibilityHidden(!isScrolled)
                .allowsHitTesting(false)
        }
        // The wide-screen right column root page has no back button; the top bar still keeps the back button's height
        .frame(minHeight: OriveoBackButton.hitSize)
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .background {
            Rectangle()
                .fill(.bar)
                .opacity(isScrolled ? 1 : 0)
                .ignoresSafeArea(edges: .top)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(OriveoTheme.Palette.border)
                .frame(height: 0.5)
                .opacity(isScrolled ? 1 : 0)
        }
    }

    private var privacyFootnote: some View {
        MemoryFootnote(
            systemImage: "shield",
            text: L10n.tr("Memory content is sent with every AI request to your chosen provider. Do not enter passwords or other sensitive information.", table: .settings)
        )
    }

    // MARK: - Header

    /// Large page title (34 / 41, 700); in editor mode, a small "Available" tag and a one-line description on the right.
    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Text(L10n.tr("Memory"))
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if presentation.heroStyle == .activeMemory {
                    readyChip
                }
            }
            if presentation.mode == .editor {
                Text(overviewDescription)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
    }

    private var readyChip: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(OriveoTheme.Palette.success)
                .frame(width: 7, height: 7)
                .background(Circle().fill(OriveoTheme.Palette.success.opacity(0.22)).frame(width: 13, height: 13))
            Text(L10n.tr("Ready"))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
        }
        .padding(.leading, 9)
        .padding(.trailing, 10)
        .frame(height: 26)
        .memoryCard(radius: 13, ring: true)
    }

    // MARK: - Starter (constellation replaces the old orb)

    /// Starter constellation: a brand-purple core + two dashed orbit rings, with the five memory types scattered around as small labeled tags (decorative, hidden from VoiceOver).
    private var starterConstellation: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / 358
            let center = CGPoint(x: geometry.size.width / 2, y: 98)
            let stars = Self.constellationStars.map { star in
                let half = (starChipWidths[star.id] ?? 0) / 2
                let x = min(max(star.x * scale, half), max(half, geometry.size.width - half))
                return (star, CGPoint(x: x, y: star.y))
            }
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    var inner = Path()
                    inner.addEllipse(in: CGRect(x: center.x - 54, y: center.y - 54, width: 108, height: 108))
                    var outer = Path()
                    outer.addEllipse(in: CGRect(x: center.x - 90, y: center.y - 90, width: 180, height: 180))
                    let dashed = StrokeStyle(lineWidth: 1, dash: [2, 5])
                    context.stroke(inner, with: .color(OriveoTheme.Palette.borderStrong), style: dashed)
                    context.stroke(outer, with: .color(OriveoTheme.Palette.border), style: dashed)
                    var spokes = Path()
                    for (_, point) in stars {
                        spokes.move(to: center)
                        spokes.addLine(to: point)
                    }
                    context.stroke(spokes, with: .color(OriveoTheme.Palette.borderStrong), lineWidth: 1)
                }

                Circle()
                    .fill(OriveoTheme.Palette.primary)
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(OriveoTheme.Palette.primary.opacity(0.16)).frame(width: 28, height: 28))
                    .background(Circle().fill(OriveoTheme.Palette.primary.opacity(0.07)).frame(width: 46, height: 46))
                    .position(center)

                ForEach(stars, id: \.0.id) { star, point in
                    constellationChip(star)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                            starChipWidths[star.id] = width
                        }
                        .position(point)
                }
            }
        }
        .frame(height: 196)
        .accessibilityHidden(true)
    }

    private struct ConstellationStar: Identifiable {
        let id: Int
        let glyph: MemoryGlyph.Kind
        let hue: Color
        let title: String
        /// Position in the 358pt-wide artboard coordinate system; x scales proportionally with the actual width.
        let x: CGFloat
        let y: CGFloat
    }

    private static var constellationStars: [ConstellationStar] {
        [
            .init(id: 0, glyph: .about, hue: MemoryItemGroup.about.hue, title: MemoryItemGroup.about.title, x: 78, y: 34),
            .init(id: 1, glyph: .preferences, hue: MemoryItemGroup.preferences.hue, title: MemoryItemGroup.preferences.title, x: 282, y: 28),
            .init(id: 2, glyph: .instructions, hue: MemoryItemGroup.instructions.hue, title: MemoryItemGroup.instructions.title, x: 296, y: 132),
            .init(id: 3, glyph: .workingOn, hue: MemoryItemGroup.projects.hue, title: MemoryItemGroup.projects.title, x: 190, y: 178),
            .init(id: 4, glyph: .episodic, hue: OriveoTheme.Palette.memoryHue.episodic,
                  title: L10n.tr("memory_group_episodic", table: .chat), x: 68, y: 150)
        ]
    }

    private func constellationChip(_ star: ConstellationStar) -> some View {
        HStack(spacing: 6) {
            MemoryGlyph(kind: star.glyph, size: 14)
                .foregroundStyle(star.hue)
            Text(star.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .lineLimit(1)
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(height: 30)
        .memoryCard(radius: 15, ring: true)
        .fixedSize()
    }

    private var starterCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(overviewTitle)
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.3)
                .lineSpacing(4)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(overviewDescription)
                .font(.system(size: 15))
                .lineSpacing(4)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            // Sample quote block: the decorative large quotation mark is a graphic; the body text does not wrap in quotes
            HStack(alignment: .top, spacing: 10) {
                Text(verbatim: "\u{201C}")
                    .font(.custom("Georgia-Bold", size: 26))
                    .foregroundStyle(OriveoTheme.Palette.primary)
                    .frame(height: 22, alignment: .top)
                    .accessibilityHidden(true)
                Text(L10n.tr("e.g.: I'm a backend engineer, mainly using Go. Keep replies concise, in Chinese, give code not long explanations.", table: .settings))
                    .font(.system(size: 13.5))
                    .lineSpacing(5)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MemoryTag.fill))
            .padding(.top, 16)

            if let primaryAction = presentation.primaryAction {
                actionButton(for: primaryAction)
                    .padding(.top, 18)
            }
            if let secondaryAction = presentation.secondaryAction {
                secondaryActionLink(for: secondaryAction)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .memoryCard(radius: OriveoTheme.Radius.hero, ring: true)
    }

    // MARK: - Inbox entry (suggestion stack)

    /// "Memory suggestions" entry (both states): with pending items it is a stack of three cards, the main card previews the first one on its second line, and the count uses a solid capsule.
    private var inboxEntry: some View {
        let count = inbox.candidates.count
        let preview = inbox.candidates.first?.content
        return Button {
            navigation.attemptNavigate(to: .memoryInbox)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(.system(size: 19))
                    .foregroundStyle(OriveoTheme.Palette.primary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("memory_inbox_title", table: .chat))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    if count > 0, let preview {
                        Text(preview)
                            .font(.system(size: 13.5))
                            .foregroundStyle(OriveoTheme.Palette.textTertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if count > 0 {
                    Text(verbatim: "\(count)")
                        .font(OriveoTheme.Typography.brandDigits(12.5))
                        .foregroundStyle(OriveoTheme.Palette.onPrimary)
                        .padding(.horizontal, 8)
                        .frame(minWidth: 24, minHeight: 24)
                        .background(Capsule(style: .continuous).fill(OriveoTheme.Palette.primaryTextSafe))
                }
                Image(systemName: "chevron.forward")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.leading, 16)
            .padding(.trailing, 14)
            .padding(.vertical, 14)
            .frame(minHeight: 52)
            .memoryCard(ring: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, count > 0 ? 12 : 0)
        .background(alignment: .bottom) {
            if count > 0 {
                ZStack(alignment: .bottom) {
                    Color.clear
                        .frame(height: 40)
                        .memoryCard(radius: 18, ring: true)
                        .opacity(0.5)
                        .padding(.horizontal, 24)
                    Color.clear
                        .frame(height: 40)
                        .memoryCard(radius: 18, ring: true)
                        .opacity(0.8)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                }
                .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func actionButton(for action: MemoryViewAction) -> some View {
        Button {
            handleAction(action)
        } label: {
            Group {
                if action == .generateDraft && isGeneratingDraft {
                    ProgressView()
                        .controlSize(.small)
                        .tint(OriveoTheme.Palette.onPrimary)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: action == .addItem ? "plus" : "sparkles")
                            .font(.system(size: 16, weight: .semibold))
                        Text(actionTitle(for: action))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
            }
        }
        .buttonStyle(MemoryStarterButtonStyle())
        .disabled(action == .generateDraft && isGeneratingDraft)
    }

    @ViewBuilder
    private func secondaryActionLink(for action: MemoryViewAction) -> some View {
        Button {
            handleAction(action)
        } label: {
            HStack(spacing: 6) {
                if action == .generateDraft && isGeneratingDraft {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(actionTitle(for: action))
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == .generateDraft && isGeneratingDraft)
    }

    /// Bottom row card in editor mode: "Generate a draft from recent conversations".
    private func draftRow(for action: MemoryViewAction) -> some View {
        Button {
            handleAction(action)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.primary)
                    .accessibilityHidden(true)
                Text(actionTitle(for: action))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if action == .generateDraft && isGeneratingDraft {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .memoryCard(ring: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == .generateDraft && isGeneratingDraft)
    }

    // MARK: - Copy

    private var overviewTitle: String {
        switch presentation.mode {
        case .starter:
            return L10n.tr("Let AI know you from the first message", table: .settings)
        case .editor:
            return L10n.tr("Memory")
        }
    }

    private var overviewDescription: String {
        switch presentation.mode {
        case .starter:
            return L10n.tr("Write your background and preferences. AI will automatically know this in every conversation — no need to repeat yourself.", table: .settings)
        case .editor:
            return L10n.tr("Tell AI about yourself. It will automatically know this at the start of every conversation.", table: .settings)
        }
    }

    private func actionTitle(for action: MemoryViewAction) -> String {
        switch action {
        case .generateDraft:
            return L10n.tr("Generate draft from recent chats", table: .settings)
        case .addItem:
            return L10n.tr("memory_add_item", table: .chat)
        }
    }
    private func handleAction(_ action: MemoryViewAction) {
        switch action {
        case .generateDraft:
            generateDraft()
        case .addItem:
            editor = .create()
        }
    }

    private func handleListAction(_ action: MemoryItemListAction) {
        switch action {
        case .add(let group):
            editor = .create(category: group)
        case .edit(let item):
            editor = MemoryItemEditorState.edit(itemId: item.id, in: appState.memoryItemsCache.items)
        case .setPinned(let item, let pinned):
            writeItems { try $0.setPinned(id: item.id, pinned: pinned) }
        case .setPaused(let item, let paused):
            writeItems { try $0.setStatus(id: item.id, status: paused ? .paused : .active) }
        case .delete(let item):
            pendingDeletion = item
        case .keepConflict(let item):
            writeItems { try $0.resolveConflict(keepId: item.id) }
        case .resolveL3Conflict(let pair, let choice):
            writeItems { try pair.apply(choice, writer: $0) }
        case .addEpisodic:
            editor = .createEpisodic()
        case .organize(let item):
            // Show the disclosure first; the organize sheet only opens after tapping Send. With no usable model, skip the disclosure and give the sheet its no_model state directly
            let candidates = Self.draftCandidateModels(
                providers: appState.providers,
                lastUsedModelRef: appState.lastUsedModelRef
            )
            if extractionFlow.prepareOrganize(item: item, candidates: candidates) == .noModel {
                organizeCandidate = nil
                organizeTarget = MemoryOrganizeTarget(item: item)
            }
        }
    }

    // MARK: - State / IO

    private func computeHasRecentConversations() async {
        #if DEBUG
        // Screenshots only: the fixture decides whether there are recent conversations (whether the draft row / button appears)
        if let fixed = MemoryShots.hasRecentConversations {
            hasRecentConversations = fixed
            return
        }
        #endif
        let conversations = appState.conversations
        let result = conversations.contains(where: { $0.displayMessageCount > 0 })
        await MainActor.run { hasRecentConversations = result }
    }

    /// Writes go through the repository (legacy fields are dual-written automatically and sync is woken); database reads and writes run in the background.
    private func writeItems<T: Sendable>(_ write: @escaping @Sendable (MemoryItemWriter) throws -> T) {
        guard let repository = appState.memoryItemRepository() else { return }
        Task {
            do {
                try await repository.perform(write)
            } catch {
                #if DEBUG
                print("[Memory] item write failed: \(error)")
                #endif
            }
        }
    }

    private func saveEditor(_ state: MemoryItemEditorState) {
        guard state.canSave else { return }
        let content = state.trimmedText
        let kind = state.kind
        let layer = state.layer
        let occurredAt = state.occurredAt
        switch state.mode {
        case .create:
            writeItems { try $0.create(kind: kind, content: content, layer: layer, occurredAt: occurredAt) }
        case .edit(let id):
            writeItems { try $0.update(id: id, content: content, kind: kind, occurredAt: occurredAt) }
        }
    }

    /// AI draft result: open a pre-filled new editor (category "About me"); if the editor is open, wait for it to close.
    private func presentGeneratedDraft(_ draft: String) {
        if editor == nil {
            editor = .create(category: .about, text: draft)
        } else {
            pendingGeneratedDraft = draft
        }
    }

    private func presentQueuedDraft() {
        guard let draft = pendingGeneratedDraft else {
            openPendingEditIfReady()
            return
        }
        pendingGeneratedDraft = nil
        editor = .create(category: .about, text: draft)
    }

    /// Memory draft candidates: the last-used model comes first if still valid; every other connection takes its fallback model --
    /// relays (including local) = the first enabled one, not excluded for lacking a key; the official provider still takes the default model, then the first enabled one.
    static func draftCandidateModels(
        providers: [Provider],
        lastUsedModelRef: LastUsedModelRef?
    ) -> [(provider: Provider, model: AIModel)] {
        let eligibleProviders = providers.filter {
            $0.kind == .relay || !ProviderCredentialResolver.apiKey(provider: $0, modelID: nil).isEmpty
        }
        let lastUsed: (provider: Provider, model: AIModel)? = lastUsedModelRef.flatMap { ref in
            guard let provider = eligibleProviders.first(where: { $0.id == ref.providerID }),
                  let model = ModelResolver.resolveStoredModel(
                    ref.modelID,
                    in: provider.models,
                    providerKind: provider.kind
                  ) else { return nil }
            return (provider, model)
        }
        // `defaultModel` already branches by kind: relays do not read the legacy isDefault.
        let others = eligibleProviders
            .filter { $0.id != lastUsed?.provider.id }
            .compactMap { provider -> (provider: Provider, model: AIModel)? in
                guard let model = provider.defaultModel ?? provider.models.first else { return nil }
                return (provider, model)
            }
        return (lastUsed.map { [$0] } ?? []) + others
    }

    private func generateDraft() {
        let requestID = UUID()
        activeDraftRequestID = requestID

        // Collect candidates, with the last-used model first (see `draftCandidateModels`).
        let candidates = Self.draftCandidateModels(
            providers: appState.providers,
            lastUsedModelRef: appState.lastUsedModelRef
        )

        guard !candidates.isEmpty else {
            let hasAnyKey = appState.providers.contains { !ProviderCredentialResolver.apiKey(provider: $0, modelID: nil).isEmpty }
            if hasAnyKey {
                presentDraftError(
                    title: L10n.tr("No model available", table: .settings),
                    message: L10n.tr("This provider has no models configured. Add at least one model first.", table: .settings)
                )
            } else {
                presentDraftError(
                    title: L10n.tr("No provider configured", table: .settings),
                    message: L10n.tr("Add a provider with an API key first, then come back to generate a draft.", table: .settings)
                )
            }
            return
        }

        let candidateIDs = recentConversationIDsForDraft(limit: 5)
        guard !candidateIDs.isEmpty else {
            presentDraftError(
                title: L10n.tr("Not enough conversation content", table: .settings),
                message: L10n.tr("Have a few chats first, then come back to generate a draft from them.", table: .settings)
            )
            return
        }

        isGeneratingDraft = true

        let uid = appState.sessionPartitionUID
        let bridge = appState.conversationRuntimeBridge

        Task {
            // Hydrate proactively: messages in AppState.conversations are [] in memory (cold-start optimization),
            // so the full thread must really be fetched from the DB by ID through conversationRuntimeBridge.
            let hydrated: [Conversation]
            do {
                hydrated = try await Task.detached(priority: .userInitiated) {
                    try bridge.fetchConversationProjections(
                        ids: candidateIDs,
                        uid: uid,
                        hydrateFilePayloads: false
                    )
                }.value
            } catch {
                #if DEBUG
                AppLog.error(error, module: "Memory", context: ["op": "generateDraft.hydrate"])
                #endif
                guard activeDraftRequestID == requestID else { return }
                isGeneratingDraft = false
                presentDraftError(
                    title: L10n.tr("Could not load recent conversations", table: .settings),
                    message: L10n.tr("Please try again later or write manually.", table: .settings)
                )
                return
            }

            guard activeDraftRequestID == requestID else { return }
            isGeneratingDraft = false

            // Compute the scope first (only the first candidate, only its user messages), then show the disclosure; no request is sent before tapping Send
            switch extractionFlow.prepareDraft(conversations: hydrated, candidates: candidates) {
            case .awaitingConfirmation:
                break
            case .noModel:
                presentDraftError(
                    title: L10n.tr("No model available", table: .settings),
                    message: L10n.tr("This provider has no models configured. Add at least one model first.", table: .settings)
                )
            case .notEnough:
                presentDraftError(
                    title: L10n.tr("Not enough conversation content", table: .settings),
                    message: L10n.tr("Have a few chats first, then come back to generate a draft from them.", table: .settings)
                )
            }
        }
    }

    /// Tapping Send in the disclosure: send only to the one provider + model shown there; on failure report the error directly without switching providers.
    private func confirmDisclosure() {
        if extractionFlow.isOrganizePending {
            Task {
                guard case let .organize(item, provider, model) = await extractionFlow.confirm() else { return }
                organizeCandidate = (provider, model)
                organizeTarget = MemoryOrganizeTarget(item: item)
            }
            return
        }
        let requestID = UUID()
        activeDraftRequestID = requestID
        isGeneratingDraft = true
        Task {
            let outcome = await extractionFlow.confirm()
            guard activeDraftRequestID == requestID else { return }
            isGeneratingDraft = false
            switch outcome {
            case .draft(let draft):
                presentGeneratedDraft(draft)
            case let .failed(title, message):
                presentDraftError(title: title, message: message)
            case .organize, nil:
                break
            }
        }
    }

    private func recentConversationIDsForDraft(limit: Int) -> [UUID] {
        appState.conversations
            .filter { $0.displayMessageCount > 0 }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map(\.id)
    }

    @MainActor
    private func presentDraftError(title: String, message: String) {
        draftErrorTitle = title
        draftErrorMessage = message
        showDraftErrorAlert = true
    }

    /// Draft instructions; sent as the purpose system of memoryExtraction.
    static let draftInstructions = """
    Based on the following conversation excerpts, write a concise personal profile in the same language the user is using (under 400 words).
    Include: their role/expertise, current projects or tech stack, preferred response style and language.
    Only include information clearly evident from the conversations. Do not invent or assume.
    Write in first person, as if the user is describing themselves.
    """

    /// Memory draft request: purpose memoryExtraction,
    /// the instructions go into purposeSystem, and the excerpt is the only user message, verbatim.
    static func draftRequest(
        excerpts: String,
        providerKind: ProviderKind,
        providerName: String = "",
        model: AIModel
    ) -> PlannedChatRequest {
        let message = ChatMessage(
            id: UUID(),
            role: .user,
            text: excerpts,
            providerKind: providerKind,
            providerName: providerName,
            modelName: model.name,
            state: .delivered
        )
        return ChatRequestBuilder.purposeRequest(
            purpose: .memoryExtraction,
            purposeSystem: draftInstructions,
            history: [message],
            window: ChatRequestBuilder.contextWindowInput(providerKind: providerKind, model: model)
        )
    }

    /// Send scope of a draft: the 5 most recent conversations that have messages, keeping per conversation only the
    /// user messages sent to the selected provider (empty providerID excluded), truncated to the first 500 characters; conversations that end up empty are dropped.
    static func buildExcerpts(from conversations: [Conversation], providerID: UUID) -> String {
        conversations
            .filter { !$0.messages.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(5)
            .map { conv in
                String(
                    conv.messages
                        .filter { $0.role == .user && $0.providerID == providerID }
                        .map { "\($0.role.rawValue): \($0.text)" }
                        .joined(separator: "\n")
                        .prefix(500)
                )
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n---\n")
    }
}

/// Starter primary button: 50pt tall, 14pt corner radius, primaryTextSafe fill, with a soft brand-purple glow (starter state only).
private struct MemoryStarterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(OriveoTheme.Palette.onPrimary)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(OriveoTheme.Palette.primaryTextSafe)
            )
            .shadow(color: OriveoTheme.Palette.primary.opacity(0.26), radius: 8, y: 6)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
