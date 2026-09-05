import SwiftUI

// MARK: - Enabled Models Section

struct ProviderEnabledModelsSection: View {
    let provider: Provider
    let highlightedModelID: String?
    let coordinateSpaceName: String
    let enabledModelsFrameBox: ProviderDetailFrameBox
    let onSetDefault: (AIModel) -> Void
    let onChat: (AIModel) -> Void
    let onRemove: (AIModel) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var expandedGroupIDs: Set<String> = []

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

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
            ProviderSectionHeader(
                title: enabledModelsTitle(for: provider),
                trailing: usesManagedLibrary ? String(format: L10n.tr("%lld models"), provider.enabledModelCount) : nil,
                helpMessage: L10n.tr("Added models appear in the model picker on the Home screen.", table: .providers)
            )

            if provider.models.isEmpty {
                emptyStatePanel
            } else if showsServerGroups {
                serverGroupedModelsPanel
            } else {
                groupedModelsPanel
            }
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(coordinateSpaceName))
        } action: { frame in
            enabledModelsFrameBox.frame = frame
        }
    }

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
        .overlay(panelBorder)
    }

    private var groupedModelsPanel: some View {
        let enabledModels = sortedEnabledModels(for: provider)
        return VStack(spacing: 0) {
            ForEach(Array(enabledModels.enumerated()), id: \.element.id) { index, model in
                ProviderEnabledModelRow(
                    model: model,
                    provider: provider,
                    capabilityEvidenceRevision: capabilityEvidenceRevision,
                    isHighlighted: highlightedModelID == model.id,
                    isMissingFromCatalog: RelayCatalogMembership.isMissingEnabledModel(model, from: provider),
                    isLast: index == enabledModels.count - 1,
                    canSetDefault: !model.isDefault,
                    canRemove: (usesManagedLibrary || provider.kind == .relay) && provider.models.count > 1,
                    setDefaultAction: { onSetDefault(model) },
                    chatAction: { onChat(model) },
                    removeAction: { onRemove(model) }
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity
                ))
            }
        }
        .background(panelBackground)
        .overlay(panelBorder)
        .clipShape(RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous))
        .shadow(
            color: OriveoTheme.Palette.shadow.opacity(colorScheme == .dark ? 0.45 : 0.55),
            radius: 12,
            x: 0,
            y: 6
        )
    }

    private var serverGroupedModelsPanel: some View {
        VStack(spacing: 10) {
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

                                Text(String(format: L10n.tr("%lld models"), Int64(group.models.count)))
                                    .font(OriveoTheme.Typography.footnote)
                                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            }

                            Spacer(minLength: 8)

                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
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
                                isMissingFromCatalog: RelayCatalogMembership.isMissingEnabledModel(model, from: provider),
                                isLast: index == group.models.count - 1,
                                canSetDefault: !model.isDefault,
                                canRemove: (usesManagedLibrary || provider.kind == .relay) && provider.models.count > 1,
                                setDefaultAction: { onSetDefault(model) },
                                chatAction: { onChat(model) },
                                removeAction: { onRemove(model) }
                            )
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
            return L10n.tr("Models", table: .providers)
        default:
            return L10n.tr("Added Models", table: .providers)
        }
    }
}

// MARK: - Enabled Model Row

struct ProviderEnabledModelRow: View {
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

    @Environment(\.colorScheme) private var colorScheme

    private var rowBackgroundTint: Color {
        if isHighlighted {
            return OriveoTheme.Palette.primary.opacity(colorScheme == .dark ? 0.12 : 0.07)
        }
        return Color.clear
    }

    var body: some View {
        let visibleMetadataCapabilities = model.visibleMetadataCapabilities(provider: provider)
        let specifications = providerModelSpecifications(for: model)
        let hasDetailedSpecifications = !specifications.isEmpty
        ZStack(alignment: .leading) {
            rowBackgroundTint

            HStack(alignment: .center, spacing: OriveoTheme.Spacing.sm) {
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

                if !hasDetailedSpecifications && !model.normalizedPriceTier.isEmpty {
                    Text(model.normalizedPriceTier)
                        .font(OriveoTheme.Typography.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .fixedSize()
                }

                modelActions
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
    }

    private var modelActions: some View {
        HStack(alignment: .center, spacing: OriveoTheme.Spacing.xs) {
            Button(action: chatAction) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.isAvailable ? OriveoTheme.Palette.primary : OriveoTheme.Palette.textTertiary)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(model.isAvailable ? OriveoTheme.Palette.primarySoft : OriveoTheme.Palette.surfaceInset.opacity(0.6))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!model.isAvailable)
            .opacity(model.isAvailable ? 1 : 0.72)

            if canSetDefault || canRemove {
                Menu {
                    if canSetDefault {
                        Button(action: setDefaultAction) {
                            Label(L10n.tr("Set as Default", table: .providers), systemImage: "star")
                        }
                    }

                    if canRemove {
                        Button(role: .destructive, action: removeAction) {
                            Label(L10n.tr("Remove", table: .providers), systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(OriveoTheme.Palette.surfaceInset.opacity(0.6))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
