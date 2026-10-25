import SwiftUI

// MARK: - Model Library Section

enum RelayCatalogPresentationState: Equatable {
    case content
    case loading
    case failed

    static func resolve(for provider: Provider, isRefreshing: Bool) -> Self {
        if provider.authMode == .subscription {
            if isRefreshing { return .loading }
            let hasError = !(provider.lastError ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return provider.catalogModels.isEmpty && hasError ? .failed : .content
        }
        guard provider.kind == .relay else { return .content }
        if isRefreshing { return .loading }
        return provider.lastError == ProviderIssueMessage.catalogUnavailableKey ? .failed : .content
    }
}

struct ProviderModelLibrarySection: View {
    let provider: Provider
    let providersVersion: UInt
    /// The catalog projection is driven by the detail page's `ProviderCatalogLibraryProjectionDriver` and written here (see its comment).
    let projection: ProviderCatalogLibraryProjection
    @Binding var modelSearchText: String
    @Binding var expandedLibraryGroups: Set<String>
    let coordinateSpaceName: String
    let viewportSize: CGSize
    let onAddCatalogModel: (AIModel, CGRect) -> Void
    let onRetryCatalog: () -> Void
    let onAddManualModel: () -> Void
    let isCatalogRefreshing: Bool
    /// Passed only by the relay / local model library subpage; nil = the existing look.
    var catalogBoard: RelayCatalogBoardContext? = nil
    /// Retry on the key status bar: refreshes only that one key.
    var onRetryCatalogKey: (String) -> Void = { _ in }
    /// Tapping a board catalog row opens the read-only advanced page.
    var onOpenCatalogModel: ((AIModel) -> Void)? = nil

    /// Used only by the board group header's "Enable all": a bulk enable has no fly-in animation and does not need the detail page's coordinate space.
    @Environment(AppState.self) private var appState

    private var capabilityEvidenceRevision: UInt64 {
        CapabilityEvidenceObservationBridge.shared.contentRevision
    }

    private var projectionRequest: ProviderCatalogProjectionRequestIdentity {
        ProviderCatalogLibraryProjection.request(
            for: provider, providersVersion: providersVersion, searchText: modelSearchText
        )
    }

    private var projectedGroups: [ProviderCatalogGroup] { projection.groups }
    private var projectedRequest: ProviderCatalogProjectionRequestIdentity? { projection.request }

    /// Hosts no container of its own: the blocks are produced as siblings and placed by the single outer `LazyVStack` (spacing 0) of the detail page,
    /// and each block's spacing from above is given explicitly here.
    var body: some View {
        if catalogBoard != nil {
            boardBlocks
        } else {
            switch relayCatalogState {
            case .loading:
                catalogLoadingState
                    .padding(.top, OriveoTheme.Spacing.lg)
            case .failed:
                catalogFailureState
                    .padding(.top, OriveoTheme.Spacing.lg)
            case .content:
                searchableModelsField
                    .padding(.top, OriveoTheme.Spacing.lg)
                libraryContent()
            }
        }
    }

    private var relayCatalogState: RelayCatalogPresentationState {
        RelayCatalogPresentationState.resolve(for: provider, isRefreshing: isCatalogRefreshing)
    }

    private var catalogLoadingState: some View {
        OriveoCard {
            catalogLoadingContent
        }
    }

    private var catalogLoadingContent: some View {
        HStack(spacing: OriveoTheme.Spacing.sm) {
            ProgressView()
            Text(L10n.tr("Loading model list...", table: .providers))
                .font(OriveoTheme.Typography.body)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var catalogFailureDetail: String {
        let reason = (provider.lastError ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty, reason != ProviderIssueMessage.catalogUnavailableKey else {
            return L10n.tr("You can also add a model ID manually.", table: .providers)
        }
        return ProviderIssueMessage.localized(reason)
    }

    /// The catalog area of the relay / local model library page: status bar, then the failure card (full width, Retry only), then the existing catalog. A successful but empty result draws nothing.
    @ViewBuilder
    private var boardBlocks: some View {
        ForEach(
            RelayCatalogBoardModel.libraryBlocks(provider: provider, isRefreshing: isCatalogRefreshing),
            id: \.self
        ) { block in
            switch block {
            case .loading:
                catalogLoadingContent
                    .padding(OriveoTheme.Spacing.lg)
                    .relayCatalogCardSurface()
                    .padding(.top, OriveoTheme.Spacing.lg)
            case .keyStatusBar:
                if let items = RelayCatalogBoardModel.keyStatusBar(provider) {
                    RelayCatalogKeyStatusBar(items: items, onRetry: onRetryCatalogKey)
                        .padding(.top, OriveoTheme.Spacing.lg)
                }
            case .failureCard:
                boardFailureCard
                    .padding(.top, OriveoTheme.Spacing.lg)
            case .catalog:
                searchableModelsField
                    .padding(.top, OriveoTheme.Spacing.lg)
                libraryContent()
                if let enableHintKey = RelayCatalogBoardModel.enableHint(for: provider) {
                    Text(L10n.tr(enableHintKey, table: .providers))
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, OriveoTheme.Spacing.lg)
                }
            }
        }
    }

    /// Same card surface as the detail page. Retry is a text button with its own 44pt hit area, so the card's bottom padding is trimmed.
    private var boardFailureCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
                Text(L10n.tr(RelayCatalogBoardModel.failureCardTitleKey, table: .providers))
                    .font(OriveoTheme.Typography.body.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                Text(catalogFailureDetail)
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: onRetryCatalog) {
                RelayCatalogTextButtonLabel(
                    title: L10n.tr("Retry"),
                    font: OriveoTheme.Typography.body.weight(.semibold),
                    alignment: .leading
                )
            }
            .buttonStyle(OriveoTextButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .padding(.top, OriveoTheme.Spacing.lg)
        .padding(.bottom, OriveoTheme.Spacing.xs)
        .relayCatalogCardSurface()
    }

    private var catalogFailureState: some View {
        OriveoCard {
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
                Text(L10n.tr("Couldn't load the model list", table: .providers))
                    .font(OriveoTheme.Typography.body.weight(.semibold))
                Text(catalogFailureDetail)
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                HStack(spacing: OriveoTheme.Spacing.sm) {
                    Button(L10n.tr("Retry"), action: onRetryCatalog)
                        .buttonStyle(.bordered)
                    Button(L10n.tr("+ Add model ID manually", table: .providers), action: onAddManualModel)
                        .buttonStyle(.bordered)
                }
            }
            // OriveoCard does not stretch by itself; without this the card width follows the button and covers only half the screen (the loading and empty-result cards on this page have it too).
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Search Field

    private var searchableModelsField: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
            ProviderSectionHeader(title: catalogBoard == nil
                ? L10n.tr("Model Library", table: .providers)
                : String(
                    format: L10n.tr(RelayCatalogBoardModel.librarySectionKey, table: .providers),
                    Int64(RelayCatalogBoardModel.libraryCount(
                        enabledModels: provider.models, catalogModels: provider.catalogModels
                    ))
                ))

            HStack(spacing: OriveoTheme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)

                TextField(L10n.tr("Search models..."), text: $modelSearchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if !modelSearchText.isEmpty {
                    Button {
                        modelSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(OriveoTheme.Palette.textTertiary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("Clear"))
                }
            }
            .padding(.horizontal, OriveoTheme.Spacing.md)
            .padding(.vertical, 11)
            .background(
                Capsule(style: .continuous)
                    .fill(OriveoTheme.Palette.surfaceElevated)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(OriveoTheme.Palette.border, lineWidth: 1)
            )
        }
    }

    // MARK: - Library Groups

    private var showsPreviousProjectionWhileRefreshing: Bool {
        projectedRequest?.canStandIn(for: projectionRequest) ?? false
    }

    /// Protocol filter of the model library subpage: only matching rows stay in a group, and empty groups are dropped.
    private var visibleGroups: [ProviderCatalogGroup] {
        guard let catalogBoard, catalogBoard.filter != .all else { return projectedGroups }
        return projectedGroups.compactMap { group in
            let models = group.models.filter {
                RelayCatalogBoardModel.matches(catalogBoard.filter, provider: provider, model: $0)
            }
            return models.isEmpty ? nil : ProviderCatalogGroup(id: group.id, title: group.title, models: models)
        }
    }

    @ViewBuilder
    private func libraryContent() -> some View {
        let groups = visibleGroups
        if projectedRequest != projectionRequest && !showsPreviousProjectionWhileRefreshing {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 72)
                .padding(.top, OriveoTheme.Spacing.lg)
        } else if groups.isEmpty {
            OriveoCard {
                Text(L10n.tr("No matching models found"))
                    .font(OriveoTheme.Typography.body)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.top, OriveoTheme.Spacing.lg)
        } else {
            ProviderCatalogGroupList(
                provider: provider,
                capabilityEvidenceRevision: capabilityEvidenceRevision,
                groups: groups,
                searchText: modelSearchText,
                expandedGroupIDs: expandedLibraryGroups,
                coordinateSpaceName: coordinateSpaceName,
                catalogBoard: catalogBoard,
                leadingSpacing: OriveoTheme.Spacing.lg,
                onToggleGroup: toggleLibraryGroup,
                onAddModel: onAddCatalogModel,
                onOpenModel: onOpenCatalogModel,
                onEnableAllInGroup: catalogBoard == nil ? nil : { group in
                    var added = 0
                    withAnimation(.snappy) {
                        added = RelayCatalogEnableAll.perform(
                            groupModels: group.models, providerID: provider.id, appState: appState
                        )
                    }
                    if let message = RelayCatalogEnableAll.feedbackMessage(added: added) {
                        ToastManager.shared.show(message, style: .success)
                    }
                }
            )
        }
    }

    private func toggleLibraryGroup(_ groupID: String) {
        guard !shouldAutoExpandProviderCatalogGroups(searchText: modelSearchText) else { return }

        if expandedLibraryGroups.contains(groupID) {
            expandedLibraryGroups.remove(groupID)
        } else {
            expandedLibraryGroups.insert(groupID)
        }
    }
}

// MARK: - Library Projection

/// The catalog projection state of the model library. Held by the detail page, written by `ProviderCatalogLibraryProjectionDriver`,
/// and read by `ProviderModelLibrarySection`.
///
/// Why it does not live in the library block's own `@State` + `.task`: the block's rows share one lazy stack with the outer scroll axis,
/// so the block is no longer a single view and a `.task` can only hang on some child view - when it scrolls out of the viewport and is recycled the task is cancelled and
/// does not rerun when the request changes; hanging it on every child would start one task per row. The driver sits outside the lazy stack and is always in the tree.
@MainActor
@Observable
final class ProviderCatalogLibraryProjection {
    var groups: [ProviderCatalogGroup] = []
    var request: ProviderCatalogProjectionRequestIdentity?
    var signature: ProviderCatalogExpansionSignature?

    static func request(
        for provider: Provider,
        providersVersion: UInt,
        searchText: String
    ) -> ProviderCatalogProjectionRequestIdentity {
        ProviderCatalogProjectionRequestIdentity(
            snapshot: ProviderCatalogSnapshotIdentity(
                providerID: provider.id,
                providersVersion: providersVersion,
                metadataContentRevision: CapabilityEvidenceObservationBridge.shared.contentRevision,
                metadataETag: MetadataClient.shared.syncMetadataETag()
            ),
            searchText: searchText
        )
    }
}

/// Drives the model library catalog projection: attached outside the detail page's outer lazy stack (`.background`), and in the tree only while the library block is shown.
struct ProviderCatalogLibraryProjectionDriver: View {
    let provider: Provider
    let providersVersion: UInt
    let searchText: String
    let projection: ProviderCatalogLibraryProjection
    @Binding var expandedLibraryGroups: Set<String>

    private var projectionRequest: ProviderCatalogProjectionRequestIdentity {
        ProviderCatalogLibraryProjection.request(
            for: provider, providersVersion: providersVersion, searchText: searchText
        )
    }

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .task(id: projectionRequest) {
                let request = projectionRequest
                // Search debounce: the TextField drives projectionRequest directly, so each character would trigger a full-catalog projection.
                // The same tier as the main list (the searchText task in HomeModelPickerSheet).
                if !searchText.isEmpty {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                }
                let groups = await ProviderCatalogProjectionMemo.shared.groups(
                    for: provider,
                    searchText: searchText,
                    snapshot: request.snapshot
                )
                guard !Task.isCancelled, request == projectionRequest else { return }
                projection.groups = groups
                projection.request = request
                let update = ProviderCatalogExpansionPolicy.reconcile(
                    expandedGroupIDs: expandedLibraryGroups,
                    previousSignature: projection.signature,
                    projection: request,
                    groups: groups
                )
                expandedLibraryGroups = update.expandedGroupIDs
                projection.signature = update.signature
            }
    }
}

// MARK: - Enable All

/// "Enable all" for a catalog group. A bulk action does not probe (lazy verification is triggered only by enabling a single model);
/// the whole group goes through one batched write-back, because enabling one by one would trigger N full cloud overwrites
/// and N background catalog resolutions for N models. Which key each model lands on still follows the single-enable rule.
enum RelayCatalogEnableAll {
    /// Returns how many models were actually newly enabled.
    @discardableResult
    static func perform(groupModels: [AIModel], providerID: UUID, appState: AppState) -> Int {
        guard let provider = appState.provider(for: providerID) else { return 0 }
        return appState.enableModels(
            modelIDs: RelayCatalogBoardModel.enableAllModelIDs(provider: provider, groupModels: groupModels),
            for: providerID
        )
    }

    /// A bulk enable has no per-model fly-in animation, so this message is the only way the user learns how many were added; nothing is shown for 0 (the button is not shown then anyway).
    static func feedbackMessage(added: Int) -> String? {
        guard added > 0 else { return nil }
        return String(format: L10n.tr("Added %lld models", table: .providers), added)
    }
}

// MARK: - Catalog Model Row

struct ProviderCatalogModelRow: View, Equatable {
    let model: AIModel
    let provider: Provider
    let capabilityEvidenceRevision: UInt64
    var nested: Bool = false
    /// Board row of the relay / local model library subpage; nil = the existing row look.
    var catalogBoard: RelayCatalogBoardContext? = nil
    /// Generation of the shared metadata snapshot: when the catalog rolls over the unit price label is re-selected, so equality cannot look at model / provider alone.
    var metadataGeneration: UInt64 = MetadataClient.sharedSnapshotGeneration()
    /// Tapping a board row opens the read-only "Advanced" page (no request is made); enabling goes only through the trailing plus.
    var openAdvancedAction: () -> Void = {}
    var addAction: () -> Void

    /// The two tap areas of a board row: the row itself opens read-only advanced, the trailing plus enables; on a non-board row the whole row enables.
    enum Tap {
        case row, trailing
    }

    /// Where a row tap goes follows the row model's `tapTarget`; a non-board row has no row model and the whole row enables.
    func perform(_ tap: Tap) {
        switch tap {
        case .row:
            let target = catalogBoard.map { boardRowModel($0).tapTarget }
            switch target {
            case .advanced?, .readOnlyAdvanced?: openAdvancedAction()
            case nil: addAction()
            }
        case .trailing: addAction()
        }
    }

    private func boardRowModel(_ catalogBoard: RelayCatalogBoardContext) -> RelayCatalogBoardModel.Row {
        RelayCatalogBoardModel.row(
            provider: provider, model: model, section: .library,
            isMissingFromCatalog: false, partitionID: catalogBoard.partitionID
        )
    }

    /// Every providers write recomputes the catalog section, and the closure is a new instance each
    /// time; comparing by rendering inputs lets unchanged visible rows be skipped.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model &&
            lhs.provider == rhs.provider &&
            lhs.capabilityEvidenceRevision == rhs.capabilityEvidenceRevision &&
            lhs.nested == rhs.nested &&
            lhs.catalogBoard == rhs.catalogBoard &&
            lhs.metadataGeneration == rhs.metadataGeneration
    }

    #if DEBUG
    private static let debugBodyEvaluationLock = NSLock()
    nonisolated(unsafe) private static var debugBodyEvaluationStorage = 0

    /// DEBUG only: how many times a catalog row body is actually evaluated; the scroll-hang regression tests use it to pin that an expanded group builds only its visible rows.
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
        // A board row draws no capability badges, specifications or price tier, so it needs no projection.
        let pricedModel = catalogBoard == nil ? CatalogModelBuilder.connectionPriced(model, provider: provider) : model
        let specifications = catalogBoard == nil ? providerModelSpecifications(for: pricedModel) : []
        let visibleMetadataCapabilities = catalogBoard == nil ? model.visibleMetadataCapabilities(provider: provider) : []

        if let catalogBoard {
            boardRow(catalogBoard)
        } else {
            plainRow(
                specifications: specifications,
                visibleMetadataCapabilities: visibleMetadataCapabilities,
                priceTier: pricedModel.normalizedPriceTier
            )
        }
    }

    /// Board row: the row opens read-only advanced and the plus enables (two independent tap areas, not nested).
    private func boardRow(_ catalogBoard: RelayCatalogBoardContext) -> some View {
        let row = boardRowModel(catalogBoard)
        return HStack(spacing: OriveoTheme.Spacing.md) {
            Button { perform(.row) } label: {
                RelayCatalogRowContent(row: row)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(RelayCatalogRowContent.accessibilityValue(row))
            .accessibilityHint(L10n.tr(RelayModelAdvancedBoard.titleKey))

            if model.isAvailable {
                Button { perform(.trailing) } label: {
                    boardAddBadge
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("Add"))
                // The hit area is 44 while the circle stays 30: the extra 7pt on each side is given back so the plus does not move.
                .padding(.horizontal, -(Self.boardAddHitSize - 30) / 2)
            } else {
                StatusPill(title: L10n.tr("Unavailable"), tone: .warning)
                    .fixedSize()
            }
        }
        .padding(.horizontal, OriveoTheme.Spacing.md)
        .padding(.vertical, nested ? 10 : 12)
        .frame(maxWidth: .infinity, minHeight: nested ? 62 : 74, alignment: .leading)
        .opacity(model.isAvailable ? 1 : 0.6)
    }

    private static let boardAddHitSize: CGFloat = 44

    /// The plus of a board row: the circle is drawn like on a plain row, the icon is Phosphor, and the hit area is stretched to 44.
    private var boardAddBadge: some View {
        PhosphorIcon.plus.image(.regular)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: 13, height: 13)
            .foregroundStyle(OriveoTheme.Palette.primary)
            .frame(width: 30, height: 30)
            .background(
                Circle()
                    .fill(OriveoTheme.Palette.primarySoft)
            )
            .overlay(
                Circle()
                    .stroke(OriveoTheme.Palette.primary.opacity(0.16), lineWidth: 1)
            )
            .frame(width: Self.boardAddHitSize, height: Self.boardAddHitSize)
            .contentShape(Rectangle())
    }

    private var addBadge: some View {
        Image(systemName: "plus")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(OriveoTheme.Palette.primary)
            .frame(width: 30, height: 30)
            .background(
                Circle()
                    .fill(OriveoTheme.Palette.primarySoft)
            )
            .overlay(
                Circle()
                    .stroke(OriveoTheme.Palette.primary.opacity(0.16), lineWidth: 1)
            )
            .fixedSize()
    }

    private func plainRow(
        specifications: [ProviderModelSpecification],
        visibleMetadataCapabilities: [ModelCapability],
        priceTier: String
    ) -> some View {
        let hasDetailedSpecifications = !specifications.isEmpty
        return Button { perform(.row) } label: {
            HStack(spacing: OriveoTheme.Spacing.md) {
                if !nested {
                    ModelVendorIcon(model: model, size: 32)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name)
                        .font(nested
                              ? OriveoTheme.Typography.body.weight(.semibold)
                              : OriveoTheme.Typography.title3)
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !hasDetailedSpecifications && !priceTier.isEmpty {
                    Text(priceTier)
                        .font(OriveoTheme.Typography.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .fixedSize()
                }

                if model.isAvailable {
                    addBadge
                } else {
                    StatusPill(title: L10n.tr("Unavailable"), tone: .warning)
                        .fixedSize()
                }
            }
            .padding(.horizontal, OriveoTheme.Spacing.md)
            .padding(.vertical, nested ? 10 : 12)
            .frame(maxWidth: .infinity, minHeight: nested ? 62 : 74, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.isAvailable)
        .opacity(model.isAvailable ? 1 : 0.6)
    }
}
