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
    @Binding var modelSearchText: String
    @Binding var expandedLibraryGroups: Set<String>
    let coordinateSpaceName: String
    let viewportSize: CGSize
    let onAddCatalogModel: (AIModel, CGRect) -> Void
    let onRetryCatalog: () -> Void
    let onAddManualModel: () -> Void
    let isCatalogRefreshing: Bool

    @State private var librarySignature: ProviderCatalogExpansionSignature?
    @State private var projectedGroups: [ProviderCatalogGroup] = []
    @State private var projectedRequest: ProviderCatalogProjectionRequestIdentity?

    private var capabilityEvidenceRevision: UInt64 {
        CapabilityEvidenceObservationBridge.shared.contentRevision
    }

    private var projectionSnapshot: ProviderCatalogSnapshotIdentity {
        ProviderCatalogSnapshotIdentity(
            providerID: provider.id,
            providersVersion: providersVersion,
            metadataContentRevision: capabilityEvidenceRevision,
            metadataETag: MetadataClient.shared.syncMetadataETag()
        )
    }

    private var projectionRequest: ProviderCatalogProjectionRequestIdentity {
        ProviderCatalogProjectionRequestIdentity(
            snapshot: projectionSnapshot,
            searchText: modelSearchText
        )
    }

    var body: some View {
        Group {
            switch relayCatalogState {
            case .loading:
                catalogLoadingState
            case .failed:
                catalogFailureState
            case .content:
                searchableModelsField
                libraryContent()
            }
        }
        .task(id: projectionRequest) {
            let request = projectionRequest
            if !modelSearchText.isEmpty {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            let groups = await ProviderCatalogProjectionMemo.shared.groups(
                for: provider,
                searchText: modelSearchText,
                snapshot: request.snapshot
            )
            guard !Task.isCancelled, request == projectionRequest else { return }
            projectedGroups = groups
            projectedRequest = request
            configureLibraryExpansion(using: groups, projection: request)
        }
    }

    private var relayCatalogState: RelayCatalogPresentationState {
        RelayCatalogPresentationState.resolve(for: provider, isRefreshing: isCatalogRefreshing)
    }

    private var catalogLoadingState: some View {
        OriveoCard {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                ProgressView()
                Text(L10n.tr("Loading model list...", table: .providers))
                    .font(OriveoTheme.Typography.body)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var catalogFailureDetail: String {
        let reason = (provider.lastError ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty, reason != ProviderIssueMessage.catalogUnavailableKey else {
            return L10n.tr("You can also add a model ID manually.", table: .providers)
        }
        return ProviderIssueMessage.localized(reason)
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
        }
    }

    // MARK: - Search Field

    private var searchableModelsField: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
            ProviderSectionHeader(title: L10n.tr("Model Library", table: .providers))

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

    @ViewBuilder
    private func libraryContent() -> some View {
        if projectedRequest != projectionRequest {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 72)
        } else if projectedGroups.isEmpty {
            OriveoCard {
                Text(L10n.tr("No matching models found"))
                    .font(OriveoTheme.Typography.body)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        } else {
            ProviderCatalogGroupList(
                provider: provider,
                capabilityEvidenceRevision: capabilityEvidenceRevision,
                groups: projectedGroups,
                searchText: modelSearchText,
                expandedGroupIDs: expandedLibraryGroups,
                coordinateSpaceName: coordinateSpaceName,
                onToggleGroup: toggleLibraryGroup,
                onAddModel: onAddCatalogModel
            )
        }
    }

    private func configureLibraryExpansion(
        using groups: [ProviderCatalogGroup],
        projection: ProviderCatalogProjectionRequestIdentity
    ) {
        let update = ProviderCatalogExpansionPolicy.reconcile(
            expandedGroupIDs: expandedLibraryGroups,
            previousSignature: librarySignature,
            projection: projection,
            groups: groups
        )
        expandedLibraryGroups = update.expandedGroupIDs
        librarySignature = update.signature
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

// MARK: - Catalog Model Row

struct ProviderCatalogModelRow: View {
    let model: AIModel
    let provider: Provider
    let capabilityEvidenceRevision: UInt64
    var nested: Bool = false
    var addAction: () -> Void

    var body: some View {
        let specifications = providerModelSpecifications(for: model)
        let hasDetailedSpecifications = !specifications.isEmpty
        let visibleMetadataCapabilities = model.visibleMetadataCapabilities(provider: provider)

        Button(action: addAction) {
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

                if !hasDetailedSpecifications && !model.normalizedPriceTier.isEmpty {
                    Text(model.normalizedPriceTier)
                        .font(OriveoTheme.Typography.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .fixedSize()
                }

                if model.isAvailable {
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
