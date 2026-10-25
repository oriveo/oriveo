import SwiftUI

// MARK: - Enabled Models Section

/// Any `appState.providers` write on the detail page (balance refresh, catalog sync, re-validation)
/// recomputes the page body, and this section renders every enabled model eagerly. Its closures are
/// fresh instances each time, so the default comparison can never tell that nothing changed; with
/// 150 models every write rebuilt capability projections, specs and sort order for all rows.
/// Compare by the inputs that actually drive rendering; the closures only capture those inputs, so
/// equal inputs mean equal behavior.
struct ProviderEnabledModelsSection: View, Equatable {
    let provider: Provider
    let highlightedModelID: String?
    let coordinateSpaceName: String
    let enabledModelsFrameBox: ProviderDetailFrameBox
    let onSetDefault: (AIModel) -> Void
    let onChat: (AIModel) -> Void
    let onRemove: (AIModel) -> Void
    /// Whole-row tap on a board row: opens "Model > Advanced". Appears only on model library board rows.
    var onOpenAdvanced: (AIModel) -> Void = { _ in }
    /// Passed only by the relay / local model library subpage; nil = the existing row look.
    var catalogBoard: RelayCatalogBoardContext? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State private var expandedGroupIDs: Set<String> = []

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.provider == rhs.provider &&
            lhs.highlightedModelID == rhs.highlightedModelID &&
            lhs.coordinateSpaceName == rhs.coordinateSpaceName &&
            lhs.enabledModelsFrameBox === rhs.enabledModelsFrameBox &&
            lhs.catalogBoard == rhs.catalogBoard
    }

    private var capabilityEvidenceRevision: UInt64 {
        CapabilityEvidenceObservationBridge.shared.contentRevision
    }

    private var usesManagedLibrary: Bool {
        provider.kind.isAggregatedProvider
    }

    private var detailGroups: [VendorGroup] {
        detailEnabledModelGroups(for: provider)
    }

    private var showsServerGroups: Bool {
        false
    }

    /// Hosts no container of its own: the group header and the rows are produced as siblings, placed lazily row by row by the single outer `LazyVStack` (spacing 0) of the detail page
    /// (on iOS 26 lazy allocation of nested lazy stacks has a race). Both the spacing above the section and the spacing inside it are given explicitly here.
    var body: some View {
        ProviderSectionHeader(
            title: catalogBoard == nil
                ? enabledModelsTitle(for: provider)
                : String(
                    format: L10n.tr(RelayCatalogBoardModel.enabledSectionKey, table: .providers),
                    Int64(provider.models.count)
                ),
            trailing: usesManagedLibrary ? L10n.format(L10n.tr("%lld models"), provider.enabledModelCount) : nil,
            helpMessage: L10n.tr("Added models appear in the model picker on the Home screen.", table: .providers)
        )
        .padding(.top, OriveoTheme.Spacing.lg)
        .padding(.bottom, OriveoTheme.Spacing.md)
        .recordsEnabledModelsFragment(Self.headerFragmentID, in: enabledModelsFrameBox, coordinateSpaceName: coordinateSpaceName)
        // Rows and the group header are siblings in the same lazy stack: the inserted first row carries a move(edge: .top) transition and must slide in from below the header, not over it.
        .zIndex(1)

        if provider.models.isEmpty {
            emptyStatePanel
                .recordsEnabledModelsFragment(Self.panelFragmentID, in: enabledModelsFrameBox, coordinateSpaceName: coordinateSpaceName)
        } else if showsServerGroups {
            serverGroupedModelsPanel
                .recordsEnabledModelsFragment(Self.panelFragmentID, in: enabledModelsFrameBox, coordinateSpaceName: coordinateSpaceName)
        } else {
            groupedModelsPanel
        }
    }

    private static let headerFragmentID = "__enabled_header__"
    private static let panelFragmentID = "__enabled_panel__"

    // MARK: - Subviews

    private var emptyStatePanel: some View {
        Text(
            provider.kind == .relay
                ? L10n.tr("No models added yet. Use the button below to add model IDs.", table: .providers)
                : L10n.tr("No models added yet. Add models from the catalog below.", table: .providers)
        )
        .font(OriveoTheme.Typography.body)
        .foregroundStyle(OriveoTheme.Palette.textSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .padding(.vertical, OriveoTheme.Spacing.xl)
        .background(panelBackground)
        .overlay(panelBorder.opacity(usesFlatPanel ? 0 : 1))
    }

    /// A single grouped panel: all rows share one outer surface and one soft shadow;
    /// rows are separated by a thin divider, in the iOS Settings.app style, which looks better and scrolls more smoothly than separate cards with multiple shadows.
    /// Rows are produced as siblings and each reports only the bounds of the whole panel (`ProviderPanelSlice`); the panel look is drawn once for the whole block by the outer lazy container of the detail page.
    @ViewBuilder
    private var groupedModelsPanel: some View {
        let enabledModels = sortedEnabledModels(for: provider).filter { model in
            // The model library subpage's protocol filter applies to this section as well as the catalog section.
            catalogBoard.map { RelayCatalogBoardModel.matches($0.filter, provider: provider, model: model) } ?? true
        }
        let catalogMembership = RelayCatalogMembership.Index(provider: provider)
        // The identity cannot be model.id directly: rows and the model library catalog rows are produced as siblings in the same lazy stack, and the catalog ForEach also uses model.id as identity.
        // A model added from the catalog would collide with that catalog row's identity, the lazy stack would keep reusing the old catalog row view, and the new row in the added section could not be built.
        ForEach(Array(enabledModels.enumerated()), id: \.element.enabledRowIdentity) { index, model in
            let slice = ProviderPanelSlice(index: index, count: enabledModels.count)
            ProviderEnabledModelRow(
                model: model,
                provider: provider,
                capabilityEvidenceRevision: capabilityEvidenceRevision,
                isHighlighted: highlightedModelID == model.id,
                isMissingFromCatalog: catalogMembership.isMissingEnabledModel(model),
                isLast: index == enabledModels.count - 1,
                canSetDefault: ProviderEnabledModelRow.allowsSetDefault(provider: provider, model: model),
                canRemove: (usesManagedLibrary || provider.kind == .relay) && provider.models.count > 1,
                setDefaultAction: { onSetDefault(model) },
                chatAction: { onChat(model) },
                removeAction: { onRemove(model) },
                advancedAction: { onOpenAdvanced(model) },
                catalogBoard: catalogBoard
            )
            .equatable()
            .clipShape(ProviderPanelSliceShape(slice: slice, radius: OriveoTheme.Radius.lg))
            .providerPanelSlice(index: index, count: enabledModels.count, group: "enabled-models", style: .enabledPanel(flat: usesFlatPanel))
            .recordsEnabledModelsFragment(model.id, in: enabledModelsFrameBox, coordinateSpaceName: coordinateSpaceName)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .top)),
                removal: .opacity
            ))
        }
    }

    private var serverGroupedModelsPanel: some View {
        let catalogMembership = RelayCatalogMembership.Index(provider: provider)
        return VStack(spacing: 10) {
            ForEach(detailGroups) { group in
                let isExpanded = expandedGroupIDs.contains(group.id)

                VStack(spacing: 0) {
                    Button {
                        withAnimation(.snappy(duration: 0.24)) {
                            if isExpanded {
                                expandedGroupIDs.remove(group.id)
                            } else {
                                expandedGroupIDs.insert(group.id)
                            }
                        }
                    } label: {
                        HStack(spacing: OriveoTheme.Spacing.md) {
                            ModelVendorIcon(
                                groupKey: group.groupKey,
                                groupName: group.groupName ?? provider.displayName,
                                size: 36
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.groupName ?? provider.displayName)
                                    .font(OriveoTheme.Typography.title3.weight(.semibold))
                                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                                    .lineLimit(1)

                                Text(L10n.format(L10n.tr("%lld models"), Int64(group.models.count)))
                                    .font(OriveoTheme.Typography.footnote)
                                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            }

                            Spacer(minLength: 8)

                            Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(OriveoTheme.Palette.surfaceInset.opacity(0.7)))
                        }
                        .padding(.horizontal, OriveoTheme.Spacing.md)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if isExpanded {
                        Rectangle()
                            .fill(OriveoTheme.Palette.border.opacity(0.45))
                            .frame(height: 0.5)

                        ForEach(Array(group.models.enumerated()), id: \.element.id) { index, model in
                            ProviderEnabledModelRow(
                                model: model,
                                provider: provider,
                                capabilityEvidenceRevision: capabilityEvidenceRevision,
                                isHighlighted: highlightedModelID == model.id,
                                isMissingFromCatalog: catalogMembership.isMissingEnabledModel(model),
                                isLast: index == group.models.count - 1,
                                canSetDefault: ProviderEnabledModelRow.allowsSetDefault(provider: provider, model: model),
                                canRemove: (usesManagedLibrary || provider.kind == .relay) && provider.models.count > 1,
                                setDefaultAction: { onSetDefault(model) },
                                chatAction: { onChat(model) },
                                removeAction: { onRemove(model) }
                            )
                            .equatable()
                        }
                    }
                }
                .background(panelBackground)
                .overlay(panelBorder)
                .clipShape(RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous))
                .shadow(
                    color: OriveoTheme.Palette.shadow.opacity(colorScheme == .dark ? 0.34 : 0.42),
                    radius: 8,
                    x: 0,
                    y: 4
                )
            }
        }
    }

    /// On the relay / local model library page the card is drawn like the detail page: no outline, no shadow. Official providers are unchanged.
    private var usesFlatPanel: Bool {
        catalogBoard != nil
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous)
            .fill(OriveoTheme.Palette.surfaceElevated)
    }

    private var panelBorder: some View {
        RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous)
            .stroke(OriveoTheme.Palette.border.opacity(0.72), lineWidth: 1)
    }

    // MARK: - Private Logic

    private func enabledModelsTitle(for provider: Provider) -> String {
        switch provider.kind {
        case .relay:
            return L10n.tr("Models", table: .providers)
        default:
            return L10n.tr("Added Models", table: .providers)
        }
    }
}

// MARK: - Enabled Model Row

struct ProviderEnabledModelRow: View, Equatable {
    let model: AIModel
    let provider: Provider
    let capabilityEvidenceRevision: UInt64
    let isHighlighted: Bool
    let isMissingFromCatalog: Bool
    let isLast: Bool
    let canSetDefault: Bool
    let canRemove: Bool
    var setDefaultAction: () -> Void
    var chatAction: () -> Void
    var removeAction: () -> Void
    /// Where a whole-row tap on a board row goes: "Model > Advanced".
    var advancedAction: () -> Void = {}
    /// Board row of the relay / local model library subpage; nil = the existing row look.
    var catalogBoard: RelayCatalogBoardContext? = nil
    /// Generation of the shared metadata snapshot: when the catalog rolls over the unit price label is re-selected, so equality cannot look at model / provider alone.
    var metadataGeneration: UInt64 = MetadataClient.sharedSnapshotGeneration()

    /// The row menu keeps only set-as-default and remove; capability testing and auto-recovery moved to the advanced page. A board row's "..." is `boardMenu`.
    enum MenuItem: Equatable {
        case setDefault, remove
    }

    static func menuItems(canSetDefault: Bool, canRemove: Bool) -> [MenuItem] {
        (canSetDefault ? [.setDefault] : []) + (canRemove ? [.remove] : [])
    }

    /// The two tap areas of a board row: the row itself opens "Model > Advanced", and the trailing chat button starts a new chat.
    /// Jumping into a chat from a whole row is unexpected on a page for managing models, so starting a chat is an explicit button in the same place as for official providers.
    enum Tap {
        case row, trailing
    }

    /// Where a row tap goes follows the row model's `tapTarget`; a non-board row has no row model and the whole row starts a chat (the same button as on official rows).
    func perform(_ tap: Tap) {
        switch tap {
        case .row:
            let target = catalogBoard.map { boardRowModel($0).tapTarget }
            switch target {
            case .advanced?, .readOnlyAdvanced?: advancedAction()
            case nil: chatAction()
            }
        case .trailing: chatAction()
        }
    }

    private func boardRowModel(_ catalogBoard: RelayCatalogBoardContext) -> RelayCatalogBoardModel.Row {
        RelayCatalogBoardModel.row(
            provider: provider, model: model, section: .enabled,
            isMissingFromCatalog: isMissingFromCatalog, partitionID: catalogBoard.partitionID,
            probeState: catalogBoard.probeStates[model.id]
        )
    }

    /// Hit area of a board row's trailing buttons; the circle stays 36.
    private static let boardHitSize: CGFloat = 44

    /// "Set as default" in the model row menu. A relay / local connection's default model is changed only on the model card of the detail page.
    static func allowsSetDefault(provider: Provider, model: AIModel) -> Bool {
        !model.isDefault && ProviderForm.of(provider) != .relay
    }

    @Environment(\.colorScheme) private var colorScheme
    /// The reason shown by "Unreachable - view reason".
    @State private var unreachableReason: RelayModelProbeFailure?

    /// Updates that touch one or two rows (such as moving the highlight) should not make every other
    /// row redo its capability projection and specs.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model &&
            lhs.provider == rhs.provider &&
            lhs.capabilityEvidenceRevision == rhs.capabilityEvidenceRevision &&
            lhs.isHighlighted == rhs.isHighlighted &&
            lhs.isMissingFromCatalog == rhs.isMissingFromCatalog &&
            lhs.isLast == rhs.isLast &&
            lhs.canSetDefault == rhs.canSetDefault &&
            lhs.canRemove == rhs.canRemove &&
            lhs.catalogBoard == rhs.catalogBoard &&
            lhs.metadataGeneration == rhs.metadataGeneration
    }

    private var rowBackgroundTint: Color {
        if isHighlighted {
            return OriveoTheme.Palette.primary.opacity(colorScheme == .dark ? 0.12 : 0.07)
        }
        return Color.clear
    }

    #if DEBUG
    private static let debugBodyEvaluationLock = NSLock()
    nonisolated(unsafe) private static var debugBodyEvaluationStorage = 0

    /// DEBUG only: how many times a row body was actually evaluated. Hang regression tests use it to
    /// pin "a providers write recomputes no rows" and "first appearance builds only visible rows".
    static var debugBodyEvaluationCount: Int {
        get {
            debugBodyEvaluationLock.lock()
            defer { debugBodyEvaluationLock.unlock() }
            return debugBodyEvaluationStorage
        }
        set {
            debugBodyEvaluationLock.lock()
            defer { debugBodyEvaluationLock.unlock() }
            debugBodyEvaluationStorage = newValue
        }
    }
    #endif

    var body: some View {
        #if DEBUG
        let _ = Self.debugBodyEvaluationCount += 1
        #endif
        // A board row draws no capability badges or specifications, so it needs no projection.
        let visibleMetadataCapabilities = catalogBoard == nil ? model.visibleMetadataCapabilities(provider: provider) : []
        let pricedModel = catalogBoard == nil ? CatalogModelBuilder.connectionPriced(model, provider: provider) : model
        let specifications = catalogBoard == nil ? providerModelSpecifications(for: pricedModel) : []
        let hasDetailedSpecifications = !specifications.isEmpty
        ZStack(alignment: .leading) {
            rowBackgroundTint

            HStack(alignment: .center, spacing: OriveoTheme.Spacing.sm) {
                if let catalogBoard {
                    let boardRow = boardRowModel(catalogBoard)
                    // The whole row opens "Model > Advanced", and unavailable models can be opened too; starting a new chat goes through the trailing button.
                    Button { perform(.row) } label: {
                        RelayCatalogRowContent(row: boardRow, onShowUnreachableReason: { unreachableReason = $0 })
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(model.isAvailable ? 1 : 0.72)
                    .accessibilityValue(RelayCatalogRowContent.accessibilityValue(boardRow))
                    .accessibilityHint(L10n.tr(RelayModelAdvancedBoard.titleKey))

                    boardActions(boardRow)
                } else {
                    Button(action: chatAction) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.name)
                                .font(OriveoTheme.Typography.title3)
                                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if isMissingFromCatalog {
                                StatusPill(title: L10n.tr("No longer in the catalog", table: .providers), tone: .neutral, compact: true)
                            }

                            LocalModelRuntimeLabel(model: model)

                            if !visibleMetadataCapabilities.isEmpty {
                                ModelListMetadataRow(
                                    model: model,
                                    provider: provider,
                                    capabilityEvidenceRevision: capabilityEvidenceRevision,
                                    projectedCapabilities: visibleMetadataCapabilities,
                                    compact: true,
                                    showPrice: false
                                )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            if hasDetailedSpecifications {
                                ProviderModelSpecInline(specifications: specifications)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.isAvailable)
                    .opacity(model.isAvailable ? 1 : 0.72)

                    if !hasDetailedSpecifications && !pricedModel.normalizedPriceTier.isEmpty {
                        Text(pricedModel.normalizedPriceTier)
                            .font(OriveoTheme.Typography.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(OriveoTheme.Palette.textTertiary)
                            .fixedSize()
                    }

                    modelActions
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 12)
        }
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(OriveoTheme.Palette.border.opacity(0.45))
                    .frame(height: 0.5)
                    .padding(.leading, 14)
            }
        }
        .animation(.easeOut(duration: 0.2), value: isHighlighted)
        .alert(
            L10n.tr(RelayCatalogBoardModel.unreachableTitleKey, table: .providers),
            isPresented: Binding(
                get: { unreachableReason != nil },
                set: { if !$0 { unreachableReason = nil } }
            ),
            presenting: unreachableReason
        ) { _ in
            Button(L10n.tr("OK"), role: .cancel) {}
        } message: { failure in
            Text(RelayUnreachableReasonText.message(failure))
        }
    }

    private var modelActions: some View {
        HStack(alignment: .center, spacing: OriveoTheme.Spacing.xs) {
            chatButton(hitSize: nil, action: chatAction)

            actionsMenu
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// The new-chat button: an enabled row of an official provider and a board row share the same icon and the same circle.
    /// `hitSize` is passed only by board rows: the circle stays the same and the hit area grows to 44; nil = the official row as before.
    private func chatButton(hitSize: CGFloat?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if let hitSize {
                chatGlyph
                    .frame(width: hitSize, height: hitSize)
                    .contentShape(Rectangle())
            } else {
                chatGlyph
            }
        }
        .accessibilityLabel(L10n.tr("New Chat"))
        .buttonStyle(.plain)
        .disabled(!model.isAvailable)
        .opacity(model.isAvailable ? 1 : 0.72)
    }

    private var chatGlyph: some View {
        Image(systemName: "bubble.left.and.bubble.right.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(model.isAvailable ? OriveoTheme.Palette.primary : OriveoTheme.Palette.textTertiary)
            .frame(width: 36, height: 36)
            .background(
                Circle()
                    .fill(model.isAvailable ? OriveoTheme.Palette.primarySoft : OriveoTheme.Palette.surfaceInset.opacity(0.6))
            )
    }

    private var moreGlyph: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .frame(width: 36, height: 36)
            .background(
                Circle()
                    .fill(OriveoTheme.Palette.surfaceInset.opacity(0.6))
            )
    }

    private var removeMenuButton: some View {
        Button(role: .destructive, action: removeAction) {
            Label(L10n.tr("Remove", table: .providers), systemImage: "trash")
        }
    }

    @ViewBuilder
    private var actionsMenu: some View {
        let items = Self.menuItems(canSetDefault: canSetDefault, canRemove: canRemove)
        if !items.isEmpty {
            Menu {
                if items.contains(.setDefault) {
                    Button(action: setDefaultAction) {
                        Label(L10n.tr("Set as Default", table: .providers), systemImage: "star")
                    }
                }

                if items.contains(.remove) {
                    removeMenuButton
                }
            } label: {
                moreGlyph
            }
            .accessibilityLabel(L10n.tr("More", table: .chat))
            .buttonStyle(.plain)
        }
    }

    // MARK: Trailing actions of a board row

    /// Trailing actions are drawn in the order the row model gives: new chat, then "...". Each of the two tap areas is 44;
    /// a negative padding gives back the extra 4pt so the circles sit where they do on official rows.
    private func boardActions(_ row: RelayCatalogBoardModel.Row) -> some View {
        HStack(alignment: .center, spacing: 0) {
            ForEach(row.trailing, id: \.self) { action in
                switch action {
                case .newChat:
                    chatButton(hitSize: Self.boardHitSize) { perform(.trailing) }
                case .more:
                    if let removeItem = row.removeItem {
                        boardMenu(removeItem)
                    }
                case .add, .unavailable:
                    EmptyView()
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, -(Self.boardHitSize - 36) / 2)
    }

    /// The "..." of a board row holds only Remove (the default model is changed on the detail page). With a single model left the menu
    /// stays, Remove is greyed out, and the reason is written in the section title, because a disabled item cannot say why itself.
    private func boardMenu(_ removeItem: RelayCatalogBoardModel.RemoveItem) -> some View {
        Menu {
            if let reasonKey = removeItem.disabledReasonKey {
                Section(L10n.tr(reasonKey, table: .providers)) {
                    removeMenuButton.disabled(!removeItem.isEnabled)
                }
            } else {
                removeMenuButton.disabled(!removeItem.isEnabled)
            }
        } label: {
            moreGlyph
                .frame(width: Self.boardHitSize, height: Self.boardHitSize)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(L10n.tr("More", table: .chat))
        .buttonStyle(.plain)
    }
}

extension View {
    /// Records this fragment's frame in the box, and counts it in or out of the union as it appears and disappears.
    func recordsEnabledModelsFragment(
        _ id: String,
        in box: ProviderDetailFrameBox,
        coordinateSpaceName: String
    ) -> some View {
        onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(coordinateSpaceName))
        } action: { frame in
            box.record(frame, for: id)
        }
        .onAppear { box.activate(id) }
        .onDisappear { box.deactivate(id) }
    }
}

private extension AIModel {
    /// See the comment on `groupedModelsPanel`: the identity of an added row must differ from that of a catalog row with the same model.id.
    var enabledRowIdentity: String { "enabled:" + id }
}
