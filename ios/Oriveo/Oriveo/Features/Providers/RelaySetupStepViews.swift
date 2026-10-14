import SwiftUI

// MARK: - Views for the two-step relay setup (Setup / SetupModels boards)
//
// They only render the state provided by `RelayQuickSetupFlow` / `RelaySetupBoardModel` / `RelaySetupModelsBoard` and make no decisions.

/// Step 1 form: endpoint (preview row below) -> key -> name (optional) -> add another key; the detection card.
struct RelaySetupStepOneView: View {
    let flow: RelayQuickSetupFlow
    let board: RelaySetupBoardModel
    let endpointHighlightToken: Int

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xl) {
            RelaySetupAddressBlock(
                endpoint: Binding(get: { flow.endpoint }, set: { flow.setEndpoint($0) }),
                previewLine: flow.previewLine,
                highlightToken: endpointHighlightToken
            )

            RelaySetupKeysBlock(
                keys: flow.keys,
                showsKeyNames: flow.showsKeyNames,
                setSecret: { flow.setSecret($0, for: $1) },
                setName: { flow.setName($0, for: $1) },
                addKey: { _ = flow.addKey() },
                removeKey: { flow.removeKey($0) }
            )

            if let card = board.card {
                RelaySetupDetectionCard(card: card)
            }
        }
    }
}

/// Endpoint slot + the "Will request ..." preview row below it. Shared by step 1 and the manual setup page so both look the same.
struct RelaySetupAddressBlock: View {
    @Binding var endpoint: String
    let previewLine: String?
    let highlightToken: Int
    var isEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            RelaySetupField(
                title: L10n.tr("Request URL", table: .providers),
                text: $endpoint,
                placeholder: "https://api.example.com",
                footnote: nil,
                isSecure: false,
                isEnabled: isEnabled,
                leadingSystemImage: nil,
                usesQuickSetupStyle: true,
                highlightToken: highlightToken,
                keyboardType: .URL,
                leadingPhosphor: .link,
                schemePrefix: "https"
            )
            if let preview = previewLine {
                HStack(alignment: .firstTextBaseline, spacing: OriveoTheme.Spacing.xs) {
                    PhosphorIcon.arrowElbowDownRight.image(.regular)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 13, height: 13)
                        .flipsForRightToLeftLayoutDirection(true)
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .accessibilityHidden(true)
                    Text(String(format: L10n.tr(RelaySetupBoardModel.willRequestKey, table: .providers), preview))
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .padding(.leading, 2)
            }
        }
    }
}

/// Key block: each key = a key slot + (with two or more keys) a name slot; at the end the local-storage note and "Add another key".
/// Shared by step 1 and the manual setup page; changes go back to each flow through closures, and the flow decides what to invalidate.
struct RelaySetupKeysBlock: View {
    let keys: [RelaySetupKeyDraft]
    let showsKeyNames: Bool
    var isEnabled = true
    let setSecret: (String, String) -> Void
    let setName: (String, String) -> Void
    let addKey: () -> Void
    let removeKey: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            ForEach(keys) { key in
                keyBlock(key)
            }
            // The button is vertically centered against the whole note: when the note wraps to two lines it is not pinned to the first line, leaving the bottom right empty.
            HStack(alignment: .center, spacing: OriveoTheme.Spacing.md) {
                Text(L10n.tr(RelaySetupBoardModel.keysLocalKey, table: .providers))
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    withAnimation(.snappy(duration: 0.18)) { addKey() }
                } label: {
                    Label {
                        Text(L10n.tr(RelaySetupBoardModel.addKeyKey, table: .providers))
                    } icon: {
                        PhosphorIcon.plus.inline(14)
                    }
                        .font(OriveoTheme.Typography.footnote.weight(.semibold))
                        .foregroundStyle(OriveoTheme.Palette.primary)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
            }
        }
    }

    @ViewBuilder
    private func keyBlock(_ key: RelaySetupKeyDraft) -> some View {
        let isPrimary = key.id == RelayKeyBinding.implicitKeyID
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            RelaySetupField(
                title: L10n.tr("API Key", table: .providers),
                text: Binding(get: { key.secret }, set: { setSecret($0, key.id) }),
                placeholder: "sk-...",
                footnote: nil,
                isSecure: true,
                isEnabled: isEnabled,
                leadingSystemImage: nil,
                usesQuickSetupStyle: true,
                leadingPhosphor: .key,
                trailingActionTitle: isPrimary ? nil : L10n.tr(RelaySetupBoardModel.removeKeyKey, table: .providers),
                trailingActionPhosphor: isPrimary ? nil : .trash,
                onTrailingAction: isPrimary ? nil : { withAnimation(.snappy(duration: 0.18)) { removeKey(key.id) } }
            )
            if showsKeyNames {
                RelaySetupKeyNameSlot(
                    text: Binding(get: { key.name }, set: { setName($0, key.id) }),
                    labelKey: RelaySetupBoardModel.keyNameKey
                )
            }
        }
    }
}

/// Name slot: placeholder label on the leading side, input on the trailing side (the board's "Name (optional)" row). Shared by key names and the connection name on the manual setup page.
struct RelaySetupKeyNameSlot: View {
    @Binding var text: String
    let labelKey: String
    /// Placeholder of the trailing input (the connection name slot uses the domain from the endpoint).
    var placeholder = ""
    /// Name announced by VoiceOver; falls back to the slot label when not given.
    var accessibilityTitle: String? = nil
    var isEnabled = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: OriveoTheme.Spacing.md) {
            Text(L10n.tr(labelKey, table: .providers))
                .font(OriveoTheme.Typography.body)
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .lineLimit(1)
                .fixedSize()
            TextField(
                "",
                text: $text,
                prompt: Text(verbatim: placeholder).foregroundStyle(OriveoTheme.Palette.textTertiary)
            )
                .font(OriveoTheme.Typography.body)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(!isEnabled)
                .accessibilityLabel(accessibilityTitle ?? L10n.tr(labelKey, table: .providers))
        }
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .frame(minHeight: 50)
        .background {
            let shape = RoundedRectangle(cornerRadius: OriveoTheme.Radius.inset, style: .continuous)
            ZStack {
                shape.fill(OriveoTheme.Palette.surfaceInset)
                shape.fill(OriveoTheme.Palette.primarySoft.opacity(colorScheme == .dark ? 0.68 : 0.62))
            }
        }
    }
}

/// Detection card: title row (detection · note · n / 3), progress bar, three items (status + elapsed time for each), footnote.
struct RelaySetupDetectionCard: View {
    let card: RelaySetupBoardModel.Card

    var body: some View {
        let detection = card.detection
        SetupDetectionCardSurface(
            tone: detection.isFinished ? (detection.succeeded ? .success : .warning) : .progress,
            accessibilityChildren: .contain
        ) {
            HStack(alignment: .firstTextBaseline, spacing: OriveoTheme.Spacing.sm) {
                Text(L10n.tr(RelaySetupBoardModel.detectionTitleKey, table: .providers))
                    .font(OriveoTheme.Typography.body.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                Text(L10n.tr(RelaySetupBoardModel.detectionSubtitleKey, table: .providers))
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                Text(verbatim: "\(card.completedCount) / \(card.totalCount)")
                    .font(OriveoTheme.Typography.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(OriveoTheme.Palette.primary)
                    .environment(\.layoutDirection, .leftToRight)
            }
            ProgressView(value: Double(card.completedCount), total: Double(card.totalCount))
                .tint(OriveoTheme.Palette.primary)
                .accessibilityHidden(true)

            checkRow(
                titleKey: RelaySetupBoardModel.connectionCheckKey,
                check: detection.connection,
                detail: connectionDetail(detection)
            ) {
                if detection.connection.status == .failed {
                    failureDiagnostics(detection)
                }
            }
            checkRow(
                titleKey: RelaySetupBoardModel.catalogCheckKey,
                check: detection.catalog,
                detail: detection.catalog.status == .failed ? detection.failure?.text : skippedDetail(detection.catalog)
            ) {
                ForEach(detection.keyCatalogs, id: \.keyID) { row in
                    keyCatalogRow(row)
                }
            }
            checkRow(
                titleKey: RelaySetupBoardModel.protocolsCheckKey,
                check: detection.protocols,
                detail: protocolsDetail(detection.protocols)
            )

            Label {
                Text(L10n.tr(RelaySetupBoardModel.detectionNoteKey, table: .providers))
            } icon: {
                PhosphorIcon.info.image(.regular)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            }
            .font(OriveoTheme.Typography.caption)
            .foregroundStyle(OriveoTheme.Palette.textTertiary)
        }
    }

    private func connectionDetail(_ detection: RelaySetupDetection) -> String? {
        switch detection.connection.status {
        case .done:
            return detection.reachablePath.map {
                String(format: L10n.tr(RelaySetupBoardModel.reachableKey, table: .providers), $0)
            }
        case .failed:
            return detection.failure?.text
        default:
            return skippedDetail(detection.connection)
        }
    }

    private func protocolsDetail(_ check: RelaySetupDetection.Check) -> String? {
        switch check.status {
        case .running: L10n.tr(RelaySetupBoardModel.protocolsRunningKey, table: .providers)
        case .done: L10n.tr(RelaySetupBoardModel.protocolsDoneKey, table: .providers)
        default: skippedDetail(check)
        }
    }

    private func skippedDetail(_ check: RelaySetupDetection.Check) -> String? {
        check.status == .skipped ? L10n.tr(RelaySetupBoardModel.skippedKey, table: .providers) : nil
    }

    private func checkRow(
        titleKey: String,
        check: RelaySetupDetection.Check,
        detail: String?
    ) -> some View {
        checkRow(titleKey: titleKey, check: check, detail: detail) { EmptyView() }
    }

    private func checkRow<Extra: View>(
        titleKey: String,
        check: RelaySetupDetection.Check,
        detail: String?,
        @ViewBuilder extra: () -> Extra
    ) -> some View {
        // Elapsed time is its own column, vertically centered on the whole row: pinned to the title row, rows with a note / diagnosis would leave the bottom right empty and misalign with the row height.
        HStack(alignment: .center, spacing: OriveoTheme.Spacing.md) {
            HStack(alignment: .top, spacing: OriveoTheme.Spacing.md) {
                statusIcon(check.status)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr(titleKey, table: .providers))
                        .font(OriveoTheme.Typography.body.weight(.semibold))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    extra()
                    if let detail {
                        Text(detail)
                            .font(OriveoTheme.Typography.footnote)
                            .foregroundStyle(check.status == .failed ? OriveoTheme.Palette.warning : OriveoTheme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            elapsedLabel(check)
        }
        .accessibilityElement(children: .contain)
    }

    /// Below the one-line failure: the upstream's own words + "what was tried" (reuses the old failure card's component and copy).
    @ViewBuilder
    private func failureDiagnostics(_ detection: RelaySetupDetection) -> some View {
        if let upstream = detection.upstreamMessage {
            Text(upstream)
                .font(OriveoTheme.Typography.caption.monospaced())
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !detection.attemptLines.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(detection.attemptLines, id: \.self) { line in
                        Text(line)
                            .font(OriveoTheme.Typography.caption.monospaced())
                            .foregroundStyle(OriveoTheme.Palette.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            } label: {
                Text(L10n.tr("What Oriveo tried", table: .providers))
                    .font(OriveoTheme.Typography.caption.weight(.medium))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
            }
            .tint(OriveoTheme.Palette.textSecondary)
        }
    }

    private func keyCatalogRow(_ row: RelaySetupDetection.KeyCatalog) -> some View {
        HStack(spacing: OriveoTheme.Spacing.sm) {
            Label {
                Text(row.label)
            } icon: {
                PhosphorIcon.key.inline(13)
            }
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(OriveoTheme.Palette.surfaceInset.opacity(0.8)))
            switch row.status {
            case .done:
                Text(L10n.format(
                    L10n.tr(RelaySetupBoardModel.catalogCountKey, table: .providers),
                    row.modelCount ?? 0
                ))
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
            case .failed:
                if let failure = row.failure {
                    Text(failure.text)
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .running:
                ProgressView().controlSize(.mini)
            case .pending, .skipped:
                EmptyView()
            }
        }
    }

    /// The whole status-circle column uses Phosphor (including warning-circle); one column never mixes two icon sets.
    private func statusGlyph(_ icon: PhosphorIcon) -> some View {
        icon.image(.regular)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: 22, height: 22)
    }

    @ViewBuilder
    private func statusIcon(_ status: RelaySetupDetection.Status) -> some View {
        Group {
            switch status {
            case .running:
                ProgressView().controlSize(.small)
            case .done:
                statusGlyph(.checkCircle).foregroundStyle(OriveoTheme.Palette.success)
            case .failed:
                statusGlyph(.warningCircle).foregroundStyle(OriveoTheme.Palette.warning)
            case .skipped:
                statusGlyph(.minusCircle).foregroundStyle(OriveoTheme.Palette.textTertiary)
            case .pending:
                statusGlyph(.circle).foregroundStyle(OriveoTheme.Palette.textTertiary)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func elapsedLabel(_ check: RelaySetupDetection.Check) -> some View {
        if check.status == .running {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                elapsedText(check.elapsed(now: context.date))
            }
        } else {
            elapsedText(check.elapsed(now: Date()))
        }
    }

    @ViewBuilder
    private func elapsedText(_ seconds: TimeInterval?) -> some View {
        if let seconds {
            Text(RelaySetupBoardModel.elapsedText(seconds: seconds))
                .font(OriveoTheme.Typography.footnote.monospacedDigit())
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .environment(\.layoutDirection, .leftToRight)
        }
    }
}

/// Step 2 "Choose the models to use".
struct RelaySetupModelsView: View {
    let flow: RelayQuickSetupFlow
    let onBack: () -> Void

    #if DEBUG
    // Screenshots only: open the page with the "Add model ID manually" alert showing.
    @State private var showsManualAdd = RelayFamilyDebugShots.presentsManualModelAlert
    #else
    @State private var showsManualAdd = false
    #endif
    @State private var manualModelInput = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let board = flow.modelsBoard
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
            header(board)
            searchField(board)

            if board.showsEmptyNote {
                Text(L10n.tr(RelaySetupModelsBoard.emptyKey, table: .providers))
                    .font(OriveoTheme.Typography.body)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(board.groups, id: \.id) { group in
                groupSection(group, showsKeyChips: board.showsKeyChips)
            }

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    manualModelInput = ""
                    // When the alert opens again, the previous "already in the list" hint is not kept.
                    flow.clearManualModelDuplicateNote()
                    showsManualAdd = true
                } label: {
                    Label {
                        Text(L10n.tr(RelaySetupModelsBoard.addManualKey, table: .providers))
                    } icon: {
                        PhosphorIcon.plus.inline(16)
                    }
                    .font(OriveoTheme.Typography.body.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.primary)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)

                if flow.showsManualModelDuplicateNote {
                    Text(L10n.tr(RelaySetupModelsBoard.manualDuplicateNoteKey, table: .providers))
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let failure = flow.saveFailure {
                Label {
                    Text(failure).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    PhosphorIcon.warning.inline(16, .duotone)
                }
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.warning)
                .padding(OriveoTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .oriveoRoundedSurface(
                    fill: OriveoTheme.Palette.warningSoft,
                    border: OriveoTheme.Palette.warning.opacity(0.3),
                    radius: OriveoTheme.Radius.inset,
                    shadow: .none
                )
            }
        }
        .alert(L10n.tr(RelaySetupModelsBoard.addManualKey, table: .providers), isPresented: $showsManualAdd) {
            TextField(RelayModelPlaceholder.current, text: $manualModelInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Add")) {
                withAnimation(.snappy(duration: 0.18)) { _ = flow.addManualModel(manualModelInput) }
            }
            // Disabled when empty after trimming whitespace, so a tap never does nothing.
            .disabled(!RelayQuickSetupFlow.canAddManualModel(manualModelInput))
        }
    }

    private func header(_ board: RelaySetupModelsBoard) -> some View {
        HStack(alignment: .center, spacing: OriveoTheme.Spacing.md) {
            // Same back button as the other subpages: no backing plate, flips automatically under RTL.
            OriveoBackButton(action: onBack)
                .padding(.leading, -OriveoBackButton.edgeInset)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr(RelaySetupModelsBoard.titleKey, table: .providers))
                    .font(OriveoTheme.Typography.title2.weight(.bold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle(board))
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
    }

    private func subtitle(_ board: RelaySetupModelsBoard) -> String {
        var parts = [flow.host]
        if let count = board.subtitleKeyCount {
            parts.append(L10n.format(L10n.tr(RelaySetupModelsBoard.keyCountKey, table: .providers), count))
        }
        parts.append(L10n.format(L10n.tr(RelaySetupModelsBoard.stepOfKey, table: .providers), 2, 2))
        return parts.joined(separator: " · ")
    }

    private func searchField(_ board: RelaySetupModelsBoard) -> some View {
        HStack(spacing: OriveoTheme.Spacing.sm) {
            PhosphorIcon.magnifyingGlass.image(.regular)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .accessibilityHidden(true)
            TextField(
                L10n.format(
                    L10n.tr(RelaySetupModelsBoard.searchKey, table: .providers),
                    board.totalModelCount
                ),
                text: Binding(get: { flow.searchText }, set: { flow.searchText = $0 })
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .frame(minHeight: 50)
        .background(
            RoundedRectangle(cornerRadius: OriveoTheme.Radius.inset, style: .continuous)
                .fill(OriveoTheme.Palette.surfaceInset)
        )
    }

    @ViewBuilder
    private func groupSection(_ group: RelaySetupModelsBoard.GroupRow, showsKeyChips: Bool) -> some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                Button {
                    withAnimation(.snappy(duration: 0.18)) { flow.toggleGroup(group.id) }
                } label: {
                    HStack(spacing: OriveoTheme.Spacing.sm) {
                        (group.isExpanded ? PhosphorIcon.caretDown : PhosphorIcon.caretRight)
                            .inline(12)
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            // The collapsed arrow points in the reading direction and flips under RTL; the expanded arrow points down and is the same either way.
                            .flipsForRightToLeftLayoutDirection(true)
                            .frame(width: 14)
                        Text(group.title)
                            .font(OriveoTheme.Typography.body.weight(.semibold))
                            .foregroundStyle(OriveoTheme.Palette.textPrimary)
                            .lineLimit(1)
                        Text(verbatim: "· \(group.count)")
                            .font(OriveoTheme.Typography.footnote)
                            .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        if group.selectedCount > 0 {
                            Text(L10n.format(
                                L10n.tr(RelaySetupModelsBoard.groupSelectedKey, table: .providers),
                                group.selectedCount
                            ))
                            .font(OriveoTheme.Typography.footnote)
                            .foregroundStyle(OriveoTheme.Palette.primary)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    flow.selectAll(groupID: group.id)
                } label: {
                    Text(L10n.tr(RelaySetupModelsBoard.selectGroupKey, table: .providers))
                        .font(OriveoTheme.Typography.footnote.weight(.medium))
                        .foregroundStyle(OriveoTheme.Palette.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(OriveoTheme.Palette.primarySoft))
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(!group.canSelectAll)
                .opacity(group.canSelectAll ? 1 : 0.45)
            }

            if group.isExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider().padding(.leading, 48)
                        }
                        modelRow(row)
                    }
                }
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: OriveoTheme.Radius.inset, style: .continuous)
                        .fill(OriveoTheme.Palette.surfaceInset)
                )
            }
        }
    }

    private func modelRow(_ row: RelaySetupModelsBoard.Row) -> some View {
        Button {
            flow.toggle(modelID: row.id)
        } label: {
            HStack(alignment: .top, spacing: OriveoTheme.Spacing.md) {
                (row.isSelected ? PhosphorIcon.checkSquare.image(.duotone) : PhosphorIcon.square.image(.regular))
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(row.isSelected ? OriveoTheme.Palette.primary : OriveoTheme.Palette.textTertiary)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: OriveoTheme.Spacing.sm) {
                        Text(verbatim: row.id)
                            .font(OriveoTheme.Typography.body)
                            .foregroundStyle(OriveoTheme.Palette.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let transport = row.protocolTransport {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(RelayProtocolMixBar.color(for: transport))
                                    .frame(width: 7, height: 7)
                                Text(verbatim: RelayProtocolMix.legendName(transport))
                                    .font(OriveoTheme.Typography.caption)
                                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(OriveoTheme.Palette.surfaceElevated.opacity(0.8)))
                        }
                    }
                    .environment(\.layoutDirection, .leftToRight)
                    if let keyLabel = row.keyLabel {
                        Label {
                            Text(keyLabel)
                        } icon: {
                            PhosphorIcon.key.inline(12)
                        }
                            .font(OriveoTheme.Typography.caption)
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(OriveoTheme.Palette.surfaceElevated.opacity(0.8)))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, OriveoTheme.Spacing.md)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(row.isSelected ? .isSelected : [])
    }
}

private extension PhosphorIcon {
    /// Inline decorative icon: template rendering follows the foreground color, fixed size; not read by VoiceOver.
    func inline(_ size: CGFloat, _ weight: Weight = .regular) -> some View {
        image(weight)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
