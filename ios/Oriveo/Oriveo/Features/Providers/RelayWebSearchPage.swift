import SwiftUI

// MARK: - Relay web search settings page
//
// One JSON editor per protocol. Saving writes the on-device store `relay_web_fragments.v1` (an empty section deletes that
// section) and clears the two legacy web-search fields on the connection through the decoding-point function.
// The route for this page hides the system navigation bar entirely: the title, back button and save action are all drawn
// inside the page (a custom header plus a bottom action bar), and layout and verdicts come from `RelayWebSearchBoardModel`.

/// The draft and save logic of the settings page; the view only renders the results from here.
struct RelayWebSearchDraft: Equatable {
    static let introKey = "Optional. Each protocol already has default web search settings; what you enter here replaces them. Either way, they’re sent only when web search is on in chat."
    static let useTemplateKey = "Use template"
    static let clearKey = "Clear"
    static let chatNoteKey = "Chat Completions has no standard web search field. The template only works with search models; check the service’s docs."
    static let footerKey = "Saved only on this device"

    /// Key = the protocol's wire value, value = the raw text of its editor.
    var texts: [String: String]

    /// The initial value is the raw text of that section in the store; with no stored section but a legacy-field mapping, the mapped result is shown.
    static func initial(provider: Provider, store: RelayWebFragmentStore = .shared) -> Self {
        Self(texts: store.effective(provider: provider).raw)
    }

    func text(_ transport: RelayTransport) -> String { texts[transport.rawValue] ?? "" }

    mutating func setText(_ value: String, for transport: RelayTransport) {
        texts[transport.rawValue] = value
    }

    mutating func useTemplate(_ transport: RelayTransport) {
        texts[transport.rawValue] = RelayWebFragments.template(for: transport) ?? ""
    }

    mutating func clear(_ transport: RelayTransport) {
        texts[transport.rawValue] = ""
    }

    /// An empty section is not an error (saving deletes that section).
    func error(_ transport: RelayTransport) -> RelayWebFragments.ValidationError? {
        let raw = text(transport)
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if case let .failure(error) = RelayWebFragments.validate(raw) { return error }
        return nil
    }

    var canSave: Bool { RelayWebFragments.transports.allSatisfy { error($0) == nil } }

    /// Writes the store and returns the connection with the legacy fields cleared (the caller persists it). Returns nil without writing when there is an error.
    func save(provider: Provider, store: RelayWebFragmentStore = .shared) -> Provider? {
        guard canSave else { return nil }
        for transport in RelayWebFragments.transports {
            let raw = text(transport)
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.clear(connectionID: provider.id, transport: transport)
            } else {
                store.save(connectionID: provider.id, transport: transport, raw: raw)
            }
        }
        var out = provider
        out.relayRequested = provider.relayRequested?.clearingLegacyWebSearch()
        return out
    }

    /// The error text under the editor (`not_json`, `not_object` and `empty` share one message).
    static func message(_ error: RelayWebFragments.ValidationError) -> String {
        switch error {
        case .notJSON, .notObject, .empty:
            return L10n.tr("Enter a JSON object", table: .providers)
        case let .forbiddenKey(key):
            return String(format: L10n.tr("“%@” can’t be set here", table: .providers), key)
        case .invalidTools:
            return L10n.tr("“tools” must be a list of objects", table: .providers)
        case .functionTool:
            return L10n.tr("Function tools can’t be added here", table: .providers)
        case .tooLarge:
            return L10n.tr("Keep it under 8 KB", table: .providers)
        }
    }
}

struct RelayWebSearchPage: View {
    typealias Board = RelayWebSearchBoardModel

    let providerID: UUID

    @Environment(AppState.self) private var appState
    @State private var draft: RelayWebSearchDraft?
    /// The content when the page was entered: the baseline for deciding whether there are unsaved changes.
    @State private var saved: RelayWebSearchDraft?
    /// The protocols this connection uses, computed once when the page is entered.
    @State private var used: [RelayTransport]?
    /// Collapse state the user has toggled; groups never toggled use the default from the row model.
    @State private var expansion: [Board.GroupID: Bool] = [:]
    @State private var showDiscardAlert = false
    /// The protocol awaiting confirmation of "replace with template".
    @State private var templateTarget: RelayTransport?
    /// The model being retested; only one runs at a time.
    @State private var retestingModelID: String?

    var body: some View {
        Group {
            if let provider = appState.provider(for: providerID),
               let usedTransports = used ?? Board.usedTransports(provider) {
                let baseline = saved ?? RelayWebSearchDraft.initial(provider: provider)
                let current = draft ?? baseline
                let probeContext = appState.providerManager.relayWebProbeAutoContext
                let board = Board.make(
                    subtitle: provider.displayName,
                    used: usedTransports,
                    draft: current,
                    saved: baseline,
                    // The rejected section is computed from the saved fragments and the on-device probe records, not from the draft.
                    rejected: Board.rejectedModels(
                        provider: provider, fragments: probeContext.fragments, records: probeContext.records
                    )
                )
                page(board, provider: provider, current: current)
                    .onAppear {
                        if used == nil { used = usedTransports }
                        if saved == nil { saved = baseline }
                        if draft == nil { draft = current }
                        #if DEBUG
                        // Sample pages only: stage the "has unsaved changes" state.
                        if let edited = RelayFamilyDebugShots.takeWebSearchEdit(from: current) { draft = edited }
                        #endif
                    }
            } else {
                // The connection is gone, or it has no such page: keep only the header so the user can still go back.
                VStack(alignment: .leading, spacing: 0) {
                    header(
                        title: L10n.tr(Board.titleKey, table: .chat),
                        subtitle: "",
                        onBack: { appState.pop() }
                    )
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, OriveoTheme.Spacing.xl)
                .padding(.top, OriveoTheme.Spacing.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .oriveoScreenBackground()
            }
        }
    }

    private func page(_ board: Board, provider: Provider, current: RelayWebSearchDraft) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
                header(
                    title: L10n.tr(board.header.titleKey, table: board.header.titleTable),
                    subtitle: board.header.subtitle,
                    onBack: { attemptBack(board) }
                )
                Text(L10n.tr(board.introKey, table: .providers))
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(board.groups, id: \.id) { group in
                    groupView(group, current: current)
                }
                rejectedSection(board)
                Text(L10n.tr(board.footerKey, table: .providers))
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                // Disclosure: after saving, a web-search probe is sent with the user's key and may incur charges. It is the last item of the scrolling content, not part of the fixed save bar, so it cannot overlap the content text.
                Text(L10n.tr(board.actionBar.disclosureKey, table: .providers))
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: OriveoTheme.Layout.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, OriveoTheme.Spacing.xl)
            .padding(.top, OriveoTheme.Spacing.lg)
            .padding(.bottom, OriveoTheme.Spacing.xxl)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            actionBar(board.actionBar) { save(current, provider: provider) }
        }
        .oriveoScreenBackground()
        .alert(L10n.tr(Board.discardTitleKey, table: .providers), isPresented: $showDiscardAlert) {
            Button(L10n.tr(Board.discardKey), role: .destructive) {
                discardAndPop()
            }
            Button(
                L10n.tr(Board.keepEditingKey, table: .providers),
                role: .cancel
            ) {}
        } message: {
            Text(L10n.tr(Board.discardMessageKey, table: .providers))
        }
        .alert(
            L10n.tr(Board.replaceTitleKey, table: .chat),
            isPresented: templateTargetPresented,
            presenting: templateTarget
        ) { transport in
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(
                L10n.tr(Board.replaceKey, table: .chat),
                role: .destructive
            ) {
                fillTemplate(transport, current: current)
            }
        } message: { _ in
            Text(L10n.tr(Board.replaceMessageKey, table: .providers))
        }
        // With unsaved changes the swipe-back gesture is disabled; this only recognizes that swipe and shows the same unsaved-changes prompt.
        .simultaneousGesture(backSwipeProbe, including: board.isDirty ? .all : .subviews)
        .onAppear { SwipeBackCoordinator.shared.isBackSwipeEnabled = board.allowsBackSwipe }
        .onChange(of: board.allowsBackSwipe) { _, allows in
            SwipeBackCoordinator.shared.isBackSwipeEnabled = allows
        }
        .onDisappear { SwipeBackCoordinator.shared.isBackSwipeEnabled = Board.allowsBackSwipeAfterLeaving }
        .onChange(of: board.groupsPinnedOpen, initial: true) { _, pinned in
            // A group opened by an error stays open after the error clears: the user is editing inside it, and it should not collapse in their face once the input is fixed.
            for id in pinned { expansion[id] = true }
        }
    }

    // MARK: Header

    /// Same shape as the keys page: back button plus title, with a subtitle on the next line.
    private func header(title: String, subtitle: String, onBack: @escaping @MainActor () -> Void) -> some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xs) {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                OriveoBackButton(action: onBack)
                    .padding(.leading, -OriveoBackButton.edgeInset)
                Text(title)
                    .font(OriveoTheme.Typography.title2)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            if !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: Groups

    private func groupView(_ group: Board.Group, current: RelayWebSearchDraft) -> some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
            if group.isCollapsible {
                groupHeader(group)
            }
            if group.isExpanded(userChoice: expansion[group.id]) {
                ForEach(group.sections, id: \.transport) { section in
                    sectionView(section, current: current)
                }
            }
        }
    }

    /// The collapsible group header is drawn the same way as the collapsible groups of the edit-connection page: title, filled count, and a down-pointing arrow.
    private func groupHeader(_ group: Board.Group) -> some View {
        let expanded = group.isExpanded(userChoice: expansion[group.id])
        return Button {
            let next = group.userChoiceAfterTap(expansion[group.id])
            withAnimation(.snappy(duration: 0.18)) { expansion[group.id] = next }
        } label: {
            HStack(spacing: 6) {
                if let titleKey = group.titleKey {
                    sectionTitle(L10n.tr(titleKey, table: .providers))
                }
                Spacer(minLength: OriveoTheme.Spacing.sm)
                if group.filledCount > 0 {
                    Text(String(
                        format: L10n.tr(RelayEditBoardModel.filledCountKey, table: .providers),
                        Int64(group.filledCount)
                    ))
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                }
                // Collapse indicator: collapsed points in the reading direction (flipped under RTL), expanded points down.
                (expanded ? PhosphorIcon.caretDown : PhosphorIcon.caretRight).image(.regular)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 12, height: 12)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .flipsForRightToLeftLayoutDirection(true)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        // The group header must announce expanded / collapsed; the arrow direction alone is not enough.
        .accessibilityValue(L10n.tr(expanded ? "Expanded" : "Collapsed", table: .chat))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(OriveoTheme.Typography.footnote.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .multilineTextAlignment(.leading)
    }

    // MARK: Protocol cards

    private func sectionView(_ section: Board.Section, current: RelayWebSearchDraft) -> some View {
        let transport = section.transport
        return VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            sectionTitle(relayTransportLabel(transport))
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                TextEditor(text: Binding(
                    get: { (draft ?? current).text(transport) },
                    set: { next in
                        var updated = draft ?? current
                        updated.setText(next, for: transport)
                        draft = updated
                    }
                ))
                .font(.system(size: 13, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .scrollContentBackground(.hidden)
                // JSON does not switch sides with the interface direction (`Board.forcesLeftToRightEditor`).
                .environment(\.layoutDirection, .leftToRight)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(minHeight: 110)
                .accessibilityLabel(Text(relayTransportLabel(transport)))

                Rectangle()
                    .fill(OriveoTheme.Palette.border.opacity(0.6))
                    .frame(height: 1)
                    .padding(.horizontal, 14)

                HStack(spacing: OriveoTheme.Spacing.lg) {
                    Button {
                        useTemplate(transport, current: current)
                    } label: {
                        cardAction(RelayWebSearchDraft.useTemplateKey, color: OriveoTheme.Palette.primary)
                    }
                    .buttonStyle(.plain)
                    Button {
                        var updated = draft ?? current
                        updated.clear(transport)
                        draft = updated
                    } label: {
                        cardAction(RelayWebSearchDraft.clearKey, color: OriveoTheme.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
            }
            .background(
                RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous)
                    .fill(OriveoTheme.Palette.surfaceElevated)
            )

            if let error = section.error {
                Text(RelayWebSearchDraft.message(error))
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let noteKey = section.noteKey {
                Text(L10n.tr(noteKey, table: .providers))
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Models that reject these settings

    /// Same card surface as the protocol cards: one row per model name plus "Test again". The row being retested shows a spinner and the other buttons are disabled.
    @ViewBuilder
    private func rejectedSection(_ board: Board) -> some View {
        if !board.rejected.isEmpty {
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
                sectionTitle(L10n.tr(Board.rejectedTitleKey, table: .providers))
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(Array(board.rejected.enumerated()), id: \.element.modelID) { index, model in
                        if index > 0 {
                            Rectangle()
                                .fill(OriveoTheme.Palette.border.opacity(0.6))
                                .frame(height: 1)
                                .padding(.horizontal, 14)
                        }
                        rejectedRow(model)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous)
                        .fill(OriveoTheme.Palette.surfaceElevated)
                )
            }
        }
    }

    private func rejectedRow(_ model: Board.RejectedModel) -> some View {
        HStack(spacing: OriveoTheme.Spacing.sm) {
            Text(verbatim: model.name)
                .font(OriveoTheme.Typography.body.weight(.medium))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: OriveoTheme.Spacing.sm)
            if retestingModelID == model.modelID {
                ProgressView()
                    .frame(minWidth: 44, minHeight: 44)
            } else {
                Button {
                    retest(model.modelID)
                } label: {
                    cardAction(Board.retestKey, color: OriveoTheme.Palette.primary)
                }
                .buttonStyle(.plain)
                .disabled(retestingModelID != nil)
                .opacity(retestingModelID == nil ? 1 : 0.55)
            }
        }
        .padding(.horizontal, 14)
    }

    private func cardAction(_ key: String, color: Color) -> some View {
        Text(L10n.tr(key, table: .providers))
            .font(OriveoTheme.Typography.footnote.weight(.semibold))
            .foregroundStyle(color)
            // When the text is narrower than 44pt ("Clear"), pad the tap target to 44pt; it is aligned to the leading side so the text does not move.
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
    }

    // MARK: Bottom action bar

    /// Drawn the same way as the bottom action bar of the edit-connection page and holds only the button (the disclosure line is at the end of the scrolling content). The primary button is disabled when nothing changed or a section is invalid.
    private func actionBar(_ bar: Board.ActionBar, onSave: @escaping @MainActor () -> Void) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(OriveoTheme.Palette.border)
                .frame(height: 0.6)
            Button(L10n.tr(bar.primaryKey), action: onSave)
                .buttonStyle(OriveoPrimaryButtonStyle())
                .disabled(!bar.isPrimaryEnabled)
                .opacity(bar.isPrimaryEnabled ? 1 : 0.55)
                .frame(maxWidth: OriveoTheme.Layout.contentMaxWidth)
                .padding(.horizontal, OriveoTheme.Spacing.xl)
                .padding(.top, OriveoTheme.Spacing.md)
                .padding(.bottom, OriveoTheme.Spacing.lg)
        }
        .frame(maxWidth: .infinity)
        // surfaceChrome has alpha: put an opaque page-background color underneath so text scrolled under the bar does not show through the dimmed button (consistent with Android / Web).
        .background(OriveoTheme.Palette.surfaceChrome)
        .background(OriveoTheme.Palette.background)
    }

    // MARK: Actions

    private func save(_ current: RelayWebSearchDraft, provider: Provider) {
        let before = appState.providerManager.relayWebFragmentsBeforeSave(provider)
        guard let baseline = Board.commit(current, provider: provider, persist: {
            appState.providerManager.updateProvider($0)
        }) else { return }
        // A successful save counts as one automatic web-probe event; probes run serially in the background and are not cancelled when the page is left.
        appState.providerManager.relayWebFragmentsSaved(providerID: provider.id, before: before)
        // What was saved is the new baseline: return to "no unsaved changes" before leaving, which also re-enables swipe-back.
        saved = baseline
        appState.pop()
    }

    /// Manual retest: the production manual probe (uncapped and not added to the automatic history), using the saved fragments. When it finishes the rejected section is recomputed, and rows that came back searched / silent disappear.
    private func retest(_ modelID: String) {
        guard retestingModelID == nil else { return }
        retestingModelID = modelID
        Task {
            _ = await appState.providerManager.retestRelayWebProbe(providerID: providerID, modelID: modelID)
            retestingModelID = nil
        }
    }

    private func attemptBack(_ board: Board) {
        switch board.backAction {
        case .pop: appState.pop()
        case .confirmDiscard: showDiscardAlert = true
        }
    }

    private func discardAndPop() {
        draft = saved
        appState.pop()
    }

    private func useTemplate(_ transport: RelayTransport, current: RelayWebSearchDraft) {
        switch Board.templateAction(for: transport, draft: draft ?? current) {
        case .fill: fillTemplate(transport, current: current)
        case .confirmReplace: templateTarget = transport
        }
    }

    private func fillTemplate(_ transport: RelayTransport, current: RelayWebSearchDraft) {
        var updated = draft ?? current
        updated.useTemplate(transport)
        draft = updated
    }

    private var templateTargetPresented: Binding<Bool> {
        Binding(get: { templateTarget != nil }, set: { if !$0 { templateTarget = nil } })
    }

    private var backSwipeProbe: some Gesture {
        // swipe-back-exempt: this is itself the probe that detects the swipe-back, so it must not yield
        DragGesture(minimumDistance: 24, coordinateSpace: .global)
            .onEnded { value in
                guard Board.isBackSwipe(
                    startX: value.startLocation.x,
                    dx: value.translation.width,
                    dy: value.translation.height
                ) else { return }
                showDiscardAlert = true
            }
    }
}
