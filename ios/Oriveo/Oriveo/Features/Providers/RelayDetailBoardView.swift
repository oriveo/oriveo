import SwiftUI

// MARK: - Detail page board (RelayDetail / LocalDetail)
//
// Renders only the rows and keys produced by `RelayDetailBoardModel`; rename / change key / default model / delete live only here.

struct RelayDetailBoardView: View {
    let provider: Provider
    let board: RelayDetailBoardModel
    let isDetecting: Bool
    let onRename: () -> Void
    let onEditConnection: () -> Void
    /// The key row (single key or several) always opens the keys page.
    let onOpenKeys: () -> Void
    var onRemoveResidualAPIKey: (() -> Void)? = nil
    let onOpenModelLibrary: () -> Void
    /// The "Web Search" row opens the connection's web-search settings page.
    let onOpenWebSearch: () -> Void
    /// The "Parameters" row opens the connection-level parameters page.
    let onOpenParameters: () -> Void
    let onDetectAgain: () -> Void
    let onDelete: () -> Void

    @ScaledMetric(relativeTo: .title) private var heroIconSize: CGFloat = 40
    @State private var showAvatarPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
            header
            section(RelayDetailBoardModel.connectionSectionKey, rows: board.connectionRows)
            section(RelayDetailBoardModel.modelsSectionKey, rows: board.modelRows)
            bottomButtons
        }
    }

    // MARK: Header

    private var statusLine: String {
        // "%lld models" from the default table (the same-named key in the Providers table counts catalog models on the add page).
        let models = L10n.format(
            L10n.tr(RelayDetailBoardModel.modelsCountKey),
            Int64(board.modelCount)
        )
        // State only known facts: model count + time of the last check; without a time, state just the model count.
        guard let checkedAt = board.checkedAt else { return models }
        let checked = String(
            format: L10n.tr(RelayDetailBoardModel.checkedAtKey, table: .providers),
            relativeTimeText(from: checkedAt)
        )
        return "\(models) · \(checked)"
    }

    private var header: some View {
        HStack(alignment: .top, spacing: OriveoTheme.Spacing.md) {
            if let avatar = board.avatar, board.canChangeAvatar {
                // The avatar itself is a button: it opens the "Change icon" sheet, and a pick takes effect immediately.
                Button(action: { showAvatarPicker = true }) {
                    RelayAvatarView(avatar: avatar, size: heroIconSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr(RelayDetailBoardModel.changeIconKey, table: .providers))
                .sheet(isPresented: $showAvatarPicker) {
                    RelayAvatarPickerSheet(provider: provider)
                }
            } else {
                PhosphorIcon.hardDrives.image(.duotone)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: heroIconSize, height: heroIconSize)
                    .foregroundStyle(board.form == .local ? OriveoTheme.Palette.success : OriveoTheme.Palette.primary)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Button(action: onRename) {
                    HStack(alignment: .firstTextBaseline, spacing: OriveoTheme.Spacing.sm) {
                        Text(provider.displayName)
                            .font(OriveoTheme.Typography.title1)
                            .foregroundStyle(OriveoTheme.Palette.textPrimary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                            .multilineTextAlignment(.leading)
                        // A visible entry point for renaming.
                        RelayDetailBoardModel.renameIcon.image(.regular)
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .frame(width: 18, height: 18)
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHint(L10n.tr("Rename"))

                Text(statusLine)
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button(action: onEditConnection) {
                PhosphorIcon.slidersHorizontal.image(.regular)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: OriveoTheme.Radius.md, style: .continuous)
                            .fill(OriveoTheme.Palette.surfaceElevated)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr(RelayDetailBoardModel.editConnectionKey, table: .providers))
        }
        .padding(.top, OriveoTheme.Spacing.xs)
    }

    // MARK: Cards

    private func section(_ titleKey: String, rows: [RelayDetailBoardModel.Row]) -> some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            Text(L10n.tr(titleKey, table: .providers))
                .font(OriveoTheme.Typography.footnote.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    rowView(row)
                    if index < rows.count - 1 {
                        Rectangle()
                            .fill(OriveoTheme.Palette.border.opacity(0.6))
                            .frame(height: 1)
                            .padding(.horizontal, 14)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous)
                    .fill(OriveoTheme.Palette.surfaceElevated)
            )
        }
    }

    @ViewBuilder
    private func rowView(_ row: RelayDetailBoardModel.Row) -> some View {
        switch row.destination {
        case .editConnection:
            Button(action: onEditConnection) { rowContent(row) }
                .buttonStyle(.plain)
        case .apiKeys:
            Button(action: onOpenKeys) { rowContent(row) }
                .buttonStyle(.plain)
        case .modelLibrary:
            Button(action: onOpenModelLibrary) { rowContent(row) }
                .buttonStyle(.plain)
        case .webSearch:
            Button(action: onOpenWebSearch) { rowContent(row) }
                .buttonStyle(.plain)
        case .parameters:
            Button(action: onOpenParameters) { rowContent(row) }
                .buttonStyle(.plain)
        case .none:
            rowContent(row)
        }
    }

    private static func iconColor(_ tint: RelayDetailBoardModel.RowIconTint) -> Color {
        switch tint {
        case .teal: return DetailRowPalette.teal
        case .cyan: return DetailRowPalette.cyan
        case .indigo: return DetailRowPalette.indigo
        case .orange: return DetailRowPalette.orange
        case .rose: return DetailRowPalette.rose
        case .capabilityWebSearch: return CapabilityPalette.webSearch
        case .capabilityReasoning: return CapabilityPalette.reasoning
        }
    }

    /// Left column: icon + text, with the inline keys and the remove entry below; right column: trailing hint and chevron, vertically centered on the whole row.
    /// Pinned to the title row, a row with inline keys would leave empty space at its bottom right and misalign with the row height.
    private func rowContent(_ row: RelayDetailBoardModel.Row) -> some View {
        HStack(alignment: .center, spacing: OriveoTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xs) {
                HStack(alignment: .center, spacing: OriveoTheme.Spacing.md) {
                    if let tint = RelayDetailBoardModel.iconTint(for: row.id) {
                        row.icon.image(.duotone)
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                            .foregroundStyle(Self.iconColor(tint))
                            .accessibilityHidden(true)
                    }

                    if row.id == .basePaths {
                        basePathsLine(row)
                    } else {
                        rowTexts(row)
                    }
                }

                if !row.keys.isEmpty {
                    inlineKeys(row)
                }

                if row.id == .apiKey, residualKeyRemovable, let onRemoveResidualAPIKey {
                    Button(action: onRemoveResidualAPIKey) {
                        Text(L10n.tr("Remove stored key", table: .providers))
                            .font(OriveoTheme.Typography.footnote.weight(.semibold))
                            .foregroundStyle(OriveoTheme.Palette.warning)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 24 + OriveoTheme.Spacing.md)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if row.id == .webSearch, let trailingKey = row.trailingKey {
                // Not configured is not "saved": no checkmark and no success color.
                let isSet = trailingKey == RelayDetailBoardModel.webSearchSetKey
                HStack(spacing: 4) {
                    if isSet {
                        PhosphorIcon.check.image(.regular)
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                            .accessibilityHidden(true)
                    }
                    Text(L10n.tr(trailingKey, table: .providers))
                        .font(OriveoTheme.Typography.footnote)
                }
                .foregroundStyle(isSet ? OriveoTheme.Palette.success : OriveoTheme.Palette.textSecondary)
            } else if let trailingKey = row.trailingKey {
                // Only two kinds of trailing hint remain: the read-only lock on the thinking row and "Add more keys" on the key row. Both are explanations rather than states, so they use the secondary text color.
                HStack(spacing: 4) {
                    (row.id == .thinking ? PhosphorIcon.lockSimple : PhosphorIcon.plus).image(.regular)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                    Text(L10n.tr(trailingKey, table: .providers))
                        .font(OriveoTheme.Typography.footnote)
                }
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
            }

            if row.destination != nil {
                PhosphorIcon.caretRight.image(.regular)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .flipsForRightToLeftLayoutDirection(true)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// With 2 or more keys: inline the first 3 (name or mask / mask / catalog count / status word) + "N more".
    private func inlineKeys(_ row: RelayDetailBoardModel.Row) -> some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            ForEach(row.keys, id: \.id) { key in
                RelayKeyRowView(row: key)
            }
            if row.moreKeysCount > 0 {
                Text(String(format: L10n.tr(RelayDetailBoardModel.moreKeysKey, table: .providers), Int64(row.moreKeysCount)))
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
            }
        }
        .padding(.leading, 24 + OriveoTheme.Spacing.md)
    }

    /// The connection needs no auth yet still stores a key: reuse the existing "Remove stored key" exit.
    private var residualKeyRemovable: Bool {
        RelayCredentialPolicy.editAction(
            authMode: provider.relayRequested?.authMode,
            hasStoredKey: RelayCredentialPolicy.hasStoredKey(ProviderCredentialResolver.apiKey(provider: provider, modelID: nil))
        ) == .removeResidual
    }

    private func rowTexts(_ row: RelayDetailBoardModel.Row) -> some View {
        let isTitleOnly = row.id == .modelLibrary || row.id == .thinking || row.id == .webSearch
            || row.id == .parameters || !row.keys.isEmpty
        return VStack(alignment: .leading, spacing: 2) {
            // The "Web Search" title reuses the same string from the Chat table.
            Text(L10n.tr(row.titleKey, table: row.id == .webSearch ? .chat : .providers))
                .font(isTitleOnly ? OriveoTheme.Typography.body.weight(.semibold) : OriveoTheme.Typography.footnote)
                .foregroundStyle(isTitleOnly ? OriveoTheme.Palette.textPrimary : OriveoTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let value = row.value {
                Text(text(value))
                    .font(isTitleOnly ? OriveoTheme.Typography.footnote : OriveoTheme.Typography.body.weight(.medium))
                    .foregroundStyle(isTitleOnly ? OriveoTheme.Palette.textSecondary : OriveoTheme.Palette.textPrimary)
                    .lineLimit(isTitleOnly ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func basePathsLine(_ row: RelayDetailBoardModel.Row) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: OriveoTheme.Spacing.md) { basePathItems(row) }
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xs) { basePathItems(row) }
        }
    }

    @ViewBuilder
    private func basePathItems(_ row: RelayDetailBoardModel.Row) -> some View {
        Text(L10n.tr(row.titleKey, table: .providers))
            .font(OriveoTheme.Typography.footnote)
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
        ForEach(row.basePaths, id: \.transport) { path in
            HStack(spacing: 6) {
                Circle()
                    .fill(RelayProtocolMixBar.color(for: path.transport))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(verbatim: "\(path.name) \(path.path)")
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
    }

    private func text(_ value: RelayDetailBoardModel.Text) -> String {
        switch value {
        case let .key(key): L10n.tr(key, table: .providers)
        case let .verbatim(text): text
        case let .counts(key, first, second): String(format: L10n.tr(key, table: .providers), Int64(first), Int64(second))
        case let .count(key, value): String(format: L10n.tr(key, table: .providers), Int64(value))
        case let .format(key, argument): String(format: L10n.tr(key, table: .providers), argument)
        case let .transport(transport): relayTransportLabel(transport)
        }
    }

    // MARK: Footer

    private var bottomButtons: some View {
        let detect = RelayDetailBoardModel.detectButton(isRunning: isDetecting)
        return VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
            Button(action: onDetectAgain) {
                HStack(spacing: OriveoTheme.Spacing.sm) {
                    if isDetecting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(OriveoTheme.Palette.primary)
                    } else {
                        PhosphorIcon.scan.image(.regular)
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                            .accessibilityHidden(true)
                    }
                    Text(L10n.tr(detect.titleKey, table: .providers))
                        .font(OriveoTheme.Typography.body.weight(.semibold))
                }
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(
                    RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous)
                        .fill(OriveoTheme.Palette.surfaceElevated)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!detect.isEnabled)

            Button(action: onDelete) {
                HStack(spacing: OriveoTheme.Spacing.sm) {
                    PhosphorIcon.x.image(.regular)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                    Text(L10n.tr(board.deleteKey, table: .providers))
                        .font(OriveoTheme.Typography.body.weight(.semibold))
                }
                .foregroundStyle(OriveoTheme.Palette.danger)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(
                    RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous)
                        .fill(OriveoTheme.Palette.dangerSoft)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(L10n.tr(board.footnoteKey, table: .providers))
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Connection problem recovery card (the abnormal-state section of the RelayDetail board)
//
// Drawn like the cards above (card background, 56pt rows, Phosphor icons, trailing chevrons); actions and copy are read only from `RecoveryCard`.

struct RelayDetailRecoveryCard: View {
    /// The single mapping from action id to callback; both the first row and the action rows read from here, so a swapped mapping turns tests red.
    struct Handlers {
        let editConnection: () -> Void
        let apiKeys: () -> Void
        let reverify: () -> Void

        func handler(for id: RelayDetailBoardModel.RecoveryCard.ActionID) -> () -> Void {
            switch id {
            case .editConnection: editConnection
            case .apiKeys: apiKeys
            case .reverify: reverify
            }
        }
    }

    let card: RelayDetailBoardModel.RecoveryCard
    let handlers: Handlers
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            summary
            ForEach(card.actions, id: \.id) { action in
                Rectangle()
                    .fill(OriveoTheme.Palette.border.opacity(0.6))
                    .frame(height: 1)
                    .padding(.horizontal, 14)
                actionRow(action)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous)
                .fill(OriveoTheme.Palette.surfaceElevated)
        )
    }

    private var summary: some View {
        HStack(alignment: .center, spacing: OriveoTheme.Spacing.md) {
            if let destination = card.headlineDestination {
                // The title says "Tap to add", so the whole row is tappable and shares one tag with the action row that has the same destination.
                Button(action: handlers.handler(for: destination)) {
                    summaryTexts
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                summaryTexts
                Spacer(minLength: 0)
            }

            Button(action: onDismiss) {
                PhosphorIcon.x.image(.regular)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("Dismiss"))
        }
        .padding(.leading, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
    }

    private var summaryTexts: some View {
        HStack(alignment: .center, spacing: OriveoTheme.Spacing.md) {
            card.icon.image(.duotone)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 24, height: 24)
                .foregroundStyle(OriveoTheme.Palette.warning)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr(card.headlineKey, table: .providers))
                    .font(OriveoTheme.Typography.body.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = card.detailMessageKey {
                    Text(ProviderIssueMessage.localized(detail))
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func actionRow(_ action: RelayDetailBoardModel.RecoveryCard.Action) -> some View {
        switch action.id {
        case .editConnection:
            Button(action: handlers.handler(for: action.id)) {
                actionContent(action)
            }
            .buttonStyle(.plain)
        case .apiKeys:
            Button(action: handlers.handler(for: action.id)) {
                actionContent(action)
            }
            .buttonStyle(.plain)
        case .reverify:
            Button(action: handlers.handler(for: action.id)) {
                actionContent(action)
            }
            .buttonStyle(.plain)
            .disabled(!action.isEnabled)
        }
    }

    private func actionContent(_ action: RelayDetailBoardModel.RecoveryCard.Action) -> some View {
        HStack(alignment: .center, spacing: OriveoTheme.Spacing.md) {
            if action.isRunning {
                ProgressView()
                    .controlSize(.small)
                    .tint(OriveoTheme.Palette.primary)
                    .frame(width: 24, height: 24)
            } else {
                // An action row is neither a capability nor a connection field, so its icon uses the neutral color and the warning icon is the only colored mark on the card.
                action.icon.image(.regular)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .accessibilityHidden(true)
            }

            Text(L10n.tr(action.titleKey, table: .providers))
                .font(OriveoTheme.Typography.body.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if action.opensPage {
                PhosphorIcon.caretRight.image(.regular)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .flipsForRightToLeftLayoutDirection(true)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}
