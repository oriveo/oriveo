import SwiftUI

/// Model > Advanced: reached by tapping an enabled row in the model library sub-page; a catalog row opens it read-only; back returns to the model library.
/// The board is computed by `RelayModelAdvancedBoard`; all writes go through `ProviderManager`, and probe results stay only in this page's memory.
/// `readOnly` (a not-enabled model reached from a catalog row): one sentence at the top, all controls inoperable, no request sent on open.
struct RelayModelAdvancedPage: View {
    typealias Board = RelayModelAdvancedBoard

    let provider: Provider
    let model: AIModel
    let partitionID: String
    let onBack: () -> Void
    let onTestCapabilities: () -> Void
    var readOnly = false

    @Environment(AppState.self) private var appState
    @State private var probe: Board.Probe?
    @State private var probeTask: Task<Void, Never>?

    /// The capsule looks about 30pt tall while the tappable area is padded to 44pt; the extra height is given back with negative padding so row height and spacing do not change.
    private static let minHit: CGFloat = 44
    private static let hitOverflow: CGFloat = 7

    private var board: Board {
        Board.make(provider: provider, model: model, partitionID: partitionID, probe: probe, readOnly: readOnly)
    }

    var body: some View {
        let board = board
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
            header(board)
            if board.isReadOnly {
                Text(L10n.tr(Board.readOnlyNoteKey, table: .providers))
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Group {
                ForEach(board.cards, id: \.self) { card in
                    switch card {
                    case .protocolOrChannel:
                        protocolSection(board.protocolRow)
                    case .key:
                        if let keySection = board.keySection {
                            keySectionView(keySection)
                        }
                    case .capabilities:
                        capabilitiesSection(board)
                    case .thinking:
                        if let thinking = board.thinking {
                            thinkingSection(thinking)
                        }
                    }
                }
            }
            .disabled(!board.controlsEnabled)
            legend(board.legend)
            if board.showsFooter {
                Text(L10n.tr(Board.footerKey, table: .providers))
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { probeTask?.cancel() }
    }

    // MARK: Page header

    private func header(_ board: Board) -> some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xs) {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                OriveoBackButton(action: onBack)
                    .padding(.leading, -OriveoBackButton.edgeInset)
                Text(L10n.tr(Board.titleKey))
                    .font(OriveoTheme.Typography.title2)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button {
                    probeTask?.cancel()
                    probe = nil
                    guard !readOnly else { return }
                    appState.providerManager.restoreRelayModelAllAutomatic(providerID: provider.id, modelID: model.id)
                } label: {
                    HStack(spacing: 4) {
                        icon(.arrowCounterClockwise, size: 14)
                        Text(L10n.tr(Board.restoreAllKey, table: .providers))
                            .font(OriveoTheme.Typography.footnote.weight(.medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(board.restoreAllEnabled ? OriveoTheme.Palette.primary : OriveoTheme.Palette.textTertiary)
                    .frame(minHeight: Self.minHit)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!board.restoreAllEnabled)
            }
            Text(board.modelName)
                .font(OriveoTheme.Typography.title3.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let host = board.host {
                Text(verbatim: host)
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
    }

    // MARK: Protocol / channel

    @ViewBuilder
    private func protocolSection(_ row: Board.ProtocolRow) -> some View {
        switch row {
        case let .relay(selected, _, status, _):
            section(.hardDrives, title: L10n.tr("Protocol", table: .providers)) {
                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Board.segments, id: \.self) { transport in
                                segment(transport, isSelected: transport == selected)
                            }
                        }
                    }
                    .padding(.vertical, -Self.hitOverflow)
                    if let explain = row.explain {
                        VStack(alignment: .leading, spacing: 2) {
                            if let autoLine = explain.autoLine {
                                Text(text(autoLine))
                                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text(explain.detailLine.map(text).joined(separator: " · "))
                                .foregroundStyle(status == .notReachable ? OriveoTheme.Palette.warningText : OriveoTheme.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(OriveoTheme.Typography.footnote)
                    }
                }
            }
        case let .local(channel, showsChannelHint):
            section(.hardDrives, title: L10n.tr("Channel", table: .providers)) {
                // Vertically center the channel name against the whole row: pinned to the title row, a row with a hint would leave the lower right empty.
                HStack(alignment: .center, spacing: OriveoTheme.Spacing.sm) {
                    VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xs) {
                        Text(L10n.tr("Channel", table: .providers))
                            .font(OriveoTheme.Typography.body)
                            .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        if showsChannelHint {
                            Text(L10n.tr(Board.channelHintKey, table: .providers))
                                .font(OriveoTheme.Typography.footnote)
                                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(relayTransportLabel(channel))
                        .font(OriveoTheme.Typography.body)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func text(_ part: Board.ExplainPart) -> String {
        let format = L10n.tr(part.key, table: part.table)
        guard let argument = part.argument else { return format }
        return String(format: format, argument)
    }

    private func segment(_ transport: RelayTransport, isSelected: Bool) -> some View {
        Button {
            selectProtocol(transport)
        } label: {
            HStack(spacing: 6) {
                if transport != .auto {
                    Circle()
                        .fill(RelayProtocolMixBar.color(for: transport))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
                Text(transport == .auto ? L10n.tr("Auto") : RelayProtocolMix.legendName(transport))
                    .font(OriveoTheme.Typography.footnote.weight(.medium))
                    .foregroundStyle(isSelected ? OriveoTheme.Palette.primary : OriveoTheme.Palette.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, OriveoTheme.Spacing.md)
            .padding(.vertical, 6)
            .background(Capsule().fill(isSelected ? OriveoTheme.Palette.primarySoft : OriveoTheme.Palette.surfaceElevated))
            .overlay(
                Capsule().stroke(isSelected ? OriveoTheme.Palette.primary.opacity(0.3) : OriveoTheme.Palette.border, lineWidth: 1)
            )
            .frame(minHeight: Self.minHit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Pick a protocol -> write user and probe only that protocol (the result is shown only, the source is unchanged); pick Auto -> clear the model-level protocol.
    private func selectProtocol(_ transport: RelayTransport) {
        // Read-only advanced neither writes nor probes (not relying only on the outer .disabled).
        guard !readOnly else { return }
        probeTask?.cancel()
        let manager = appState.providerManager
        guard transport != .auto else {
            probe = nil
            manager.setRelayModelTransport(providerID: provider.id, modelID: model.id, transport: nil)
            return
        }
        manager.setRelayModelTransport(providerID: provider.id, modelID: model.id, transport: transport)
        probe = .init(transport: transport, state: .testing)
        let providerID = provider.id
        let modelID = model.id
        probeTask = Task { @MainActor in
            let passed = await manager.probeRelayModelTransportOnce(
                providerID: providerID, modelID: modelID, transport: transport
            )
            guard !Task.isCancelled, probe?.transport == transport else { return }
            switch passed {
            case true?: probe = .init(transport: transport, state: .reachable)
            case false?: probe = .init(transport: transport, state: .notReachable)
            case nil: probe = nil
            }
        }
    }

    // MARK: Keys

    private func keySectionView(_ section: Board.KeySection) -> some View {
        self.section(.key, title: L10n.tr(Board.keySectionKey, table: .providers)) {
            // Vertically center the picker menu against the whole row: aligning only name and mask would leave the right of the hint below empty and misaligned with the row height.
            HStack(alignment: .center, spacing: OriveoTheme.Spacing.sm) {
                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xs) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: section.current.title)
                            .font(OriveoTheme.Typography.body)
                            .foregroundStyle(OriveoTheme.Palette.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if section.current.title != section.current.maskedSecret {
                            Text(verbatim: section.current.maskedSecret)
                                .font(OriveoTheme.Typography.footnote.monospaced())
                                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                                .lineLimit(1)
                                .environment(\.layoutDirection, .leftToRight)
                        }
                    }
                    Text(L10n.tr(Board.keyAutoHintKey, table: .providers))
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                keyMenu(section)
            }
        }
    }

    private func keyMenu(_ section: Board.KeySection) -> some View {
        Menu {
            Button {
                selectKey(.auto, section: section)
            } label: {
                if section.isAuto {
                    Label(L10n.tr("Auto"), systemImage: "checkmark")
                } else {
                    Text(L10n.tr("Auto"))
                }
            }
            ForEach(section.options, id: \.id) { option in
                let title = option.title == option.maskedSecret ? option.title : "\(option.title) · \(option.maskedSecret)"
                Button {
                    selectKey(.key(option.id), section: section)
                } label: {
                    if !section.isAuto && option.id == section.current.id {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(verbatim: title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(section.isAuto ? L10n.tr("Auto") : section.current.title)
                    .font(OriveoTheme.Typography.footnote.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                icon(.caretDown, size: 12)
            }
            .foregroundStyle(section.isAuto ? OriveoTheme.Palette.textSecondary : OriveoTheme.Palette.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(OriveoTheme.Palette.surfaceInset.opacity(0.8)))
            .frame(minHeight: Self.minHit)
            .contentShape(Rectangle())
        }
        .padding(.vertical, -Self.hitOverflow)
        .accessibilityLabel(L10n.tr(Board.keySectionKey, table: .providers))
    }

    /// Pick a key -> rebind; pick Auto -> rebind to the key the rule picks; picking the current key writes nothing.
    private func selectKey(_ choice: Board.KeyChoice, section: Board.KeySection) {
        guard let operation = Board.keyOperation(choice, section: section, modelID: model.id, readOnly: readOnly) else { return }
        let manager = appState.providerManager
        let providerID = provider.id
        Task { _ = await manager.applyRelayKeyOperation(providerID: providerID, operation) }
    }

    // MARK: Capabilities

    private func capabilitiesSection(_ board: Board) -> some View {
        section(.lightning, title: L10n.tr(Board.capabilitiesHeaderKey, table: .providers)) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(board.capabilityRows.enumerated()), id: \.offset) { index, row in
                    capabilityRow(row)
                    if index < board.capabilityRows.count - 1 {
                        Rectangle()
                            .fill(OriveoTheme.Palette.border.opacity(0.45))
                            .frame(height: 0.5)
                    }
                }
                if board.showsTestEntry {
                    Button(action: onTestCapabilities) {
                        Text(L10n.tr("Test capabilities", table: .providers))
                            .font(OriveoTheme.Typography.body.weight(.medium))
                            .foregroundStyle(OriveoTheme.Palette.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, OriveoTheme.Spacing.md)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func capabilityRow(_ row: Board.CapabilityRow) -> some View {
        HStack(spacing: OriveoTheme.Spacing.md) {
            icon(row.capability.icon, size: 18, weight: row.state == .supported ? .duotone : .regular)
                .foregroundStyle(tint(row))
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr(row.capability.titleKey, table: row.capability.titleTable))
                    .font(OriveoTheme.Typography.body)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                HStack(spacing: 4) {
                    Text(stateText(row))
                    if let source = row.source {
                        Text(verbatim: "·")
                        sourceBadge(source)
                    }
                }
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            controlMenu(row)
        }
        .padding(.vertical, 10)
    }

    private func tint(_ row: Board.CapabilityRow) -> Color {
        guard row.state == .supported else {
            return row.state == .unknown ? OriveoTheme.Palette.textSecondary.opacity(0.6) : OriveoTheme.Palette.borderStrong
        }
        switch row.capability {
        case .image: return CapabilityPalette.vision
        case .file: return CapabilityPalette.attachment
        case .imageGeneration: return OriveoTheme.Palette.primary
        case .toolCall: return CapabilityPalette.tools
        case .web: return CapabilityPalette.webSearch
        }
    }

    private func stateText(_ row: Board.CapabilityRow) -> String {
        // Web row: the status line shares its copy with the model options panel.
        if let webStatus = row.webStatus { return ModelOptionCapabilityShape.relayWebStatusText(webStatus) }
        return switch row.state {
        case .supported: L10n.tr("Supported", table: .providers)
        case .unsupported: L10n.tr("Not supported", table: .providers)
        case .unknown: L10n.tr(row.capability.unknownKey, table: row.capability.unknownTable)
        }
    }

    private func controlLabel(_ control: Board.Control) -> String {
        switch control {
        case .auto: L10n.tr("Auto")
        case .on: L10n.tr("On", table: .chat)
        case .off: L10n.tr("Off", table: .chat)
        }
    }

    private func controlMenu(_ row: Board.CapabilityRow) -> some View {
        Menu {
            ForEach(Board.Control.allCases, id: \.self) { control in
                Button {
                    guard !readOnly else { return }
                    appState.providerManager.setRelayCapabilityOverride(
                        providerID: provider.id, modelID: model.id, key: row.capability.overrideKey, value: control.value
                    )
                } label: {
                    if control == row.control {
                        Label(controlLabel(control), systemImage: "checkmark")
                    } else {
                        Text(controlLabel(control))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(controlLabel(row.control))
                    .font(OriveoTheme.Typography.footnote.weight(.medium))
                    .lineLimit(1)
                icon(.caretDown, size: 12)
            }
            .foregroundStyle(row.control == .auto ? OriveoTheme.Palette.textSecondary : OriveoTheme.Palette.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(OriveoTheme.Palette.surfaceInset.opacity(0.8)))
            .frame(minHeight: Self.minHit)
            .contentShape(Rectangle())
        }
        .padding(.vertical, -Self.hitOverflow)
        .accessibilityLabel(L10n.tr(row.capability.titleKey, table: row.capability.titleTable))
    }

    private func sourceBadge(_ source: Board.Source) -> some View {
        HStack(spacing: 3) {
            icon(source.icon, size: 12)
            Text(L10n.tr(source.key, table: .providers))
                .lineLimit(1)
        }
    }

    // MARK: Thinking

    private func thinkingSection(_ thinking: Board.Thinking) -> some View {
        section(.brain, title: L10n.tr(Board.thinkingHeaderKey, table: .providers)) {
            switch thinking {
            case let .cells(cells):
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(cells, id: \.mode) { cell in
                            thinkingCell(cell, cells: cells)
                        }
                    }
                }
                .padding(.vertical, -Self.hitOverflow)
            }
        }
    }

    private func thinkingCell(_ cell: Board.ThinkingCell, cells: [Board.ThinkingCell]) -> some View {
        Button {
            guard let levels = Board.levelsAfterToggling(cell.mode, cells: cells) else { return }
            guard !readOnly else { return }
            appState.providerManager.setRelayReasoningLevels(providerID: provider.id, modelID: model.id, levels: levels)
        } label: {
            Text(cell.mode.title)
                .font(OriveoTheme.Typography.footnote.weight(.medium))
                .strikethrough(!cell.isAvailable)
                .foregroundStyle(
                    !cell.isAvailable ? OriveoTheme.Palette.textTertiary
                        : (cell.isSelected ? CapabilityPalette.reasoning : OriveoTheme.Palette.textSecondary)
                )
                .lineLimit(1)
                .padding(.horizontal, OriveoTheme.Spacing.md)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(cell.isSelected ? CapabilityPalette.reasoning.opacity(0.12) : OriveoTheme.Palette.surfaceElevated)
                )
                .overlay(
                    Capsule().stroke(cell.isSelected ? CapabilityPalette.reasoning.opacity(0.35) : OriveoTheme.Palette.border, lineWidth: 1)
                )
                .frame(minHeight: Self.minHit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!cell.isToggleable)
        .accessibilityAddTraits(cell.isSelected ? .isSelected : [])
    }

    // MARK: Legend and shared parts

    private func legend(_ sources: [Board.Source]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: OriveoTheme.Spacing.md) { legendItems(sources) }
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xs) { legendItems(sources) }
        }
        .font(OriveoTheme.Typography.footnote)
        .foregroundStyle(OriveoTheme.Palette.textSecondary)
    }

    @ViewBuilder
    private func legendItems(_ sources: [Board.Source]) -> some View {
        ForEach(sources, id: \.self) { source in
            sourceBadge(source)
        }
    }

    private func section<Content: View>(
        _ symbol: PhosphorIcon,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            HStack(spacing: 6) {
                icon(symbol, size: 14)
                Text(title)
                    .font(OriveoTheme.Typography.footnote.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            content()
                .padding(.horizontal, OriveoTheme.Spacing.lg)
                .padding(.vertical, OriveoTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Same kind of card as the detail page: background fill only, no stroke, no shadow.
                .background(
                    RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous)
                        .fill(OriveoTheme.Palette.surfaceElevated)
                )
        }
    }

    private func icon(_ symbol: PhosphorIcon, size: CGFloat, weight: PhosphorIcon.Weight = .regular) -> some View {
        symbol.image(weight)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
