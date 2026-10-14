import SwiftUI

/// View input for the model-library subpage board: passed only by the relay / local model-library subpages; the official model library always gets nil (behavior and look unchanged).
struct RelayCatalogBoardContext: Equatable {
    let partitionID: String
    let filter: RelayCatalogBoardModel.Filter
    /// In-memory lazy-probe state of this connection's enabled models (`AppState.relayModelProbeStates`).
    var probeStates: [String: RelayModelProbeState] = [:]
}

/// Model-library row content: name + status text (trailing) / protocol chip + key chip (flowing wrap) / the five capability icons on a row of their own.
/// No vendor icon, specs or price; the source badge stays off the row.
struct RelayCatalogRowContent: View {
    typealias Board = RelayCatalogBoardModel
    static let statusMaxWidth: CGFloat = 84

    let row: Board.Row
    /// Taps "Not reachable · See why"; nil means the status text is not tappable.
    var onShowUnreachableReason: ((RelayModelProbeFailure) -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: OriveoTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: OriveoTheme.Spacing.sm) {
                    Text(row.name)
                        .font(OriveoTheme.Typography.body.weight(.semibold))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Chips wrap as a flow: a key chip that does not fit moves to the next line as a whole instead of shrinking to an ellipsis.
                if row.protocolTransport != nil || row.keyChip != nil {
                    RelayChipFlowLayout(spacing: 6) {
                        chips
                    }
                }
                // The capability icons always take their own line below the chips, instead of sharing the line when they happen to fit.
                capabilityIcons
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Shared by enabled rows and catalog rows: the status text is its own column, vertically centered on the whole row and on the same midline as the trailing buttons.
            // Pinned to the title row it would leave empty space below and misalign with the centered buttons. A width cap lets long text wrap so it takes less width from the name and chips.
            status
                .frame(maxWidth: Self.statusMaxWidth, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var chips: some View {
        if let transport = row.protocolTransport {
            RelayCatalogProtocolChip(transport: transport)
        }
        if let keyChip = row.keyChip {
            RelayCatalogKeyChip(title: keyChip)
        }
    }

    private var capabilityIcons: some View {
        HStack(spacing: 6) {
            ForEach(Array(zip(Board.Capability.allCases, row.caps)), id: \.0) { capability, support in
                RelayCatalogCapabilityIcon(capability: capability, support: support)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if case let .unreachable(failure)? = row.status, let onShowUnreachableReason {
            Button {
                onShowUnreachableReason(failure)
            } label: {
                statusText(row.status, tint: OriveoTheme.Palette.warningText)
            }
            .buttonStyle(.plain)
        } else if let status = row.status {
            statusText(status, tint: status == .deniedOnCurrentKey
                ? OriveoTheme.Palette.warningText
                : OriveoTheme.Palette.textSecondary)
        }
    }
}

extension RelayCatalogRowContent {
    /// The five capability icons are invisible to VoiceOver, so the row reads them out item by item as "capability name + state word", in icon order.
    static func accessibilityValue(_ row: Board.Row) -> String {
        zip(Board.Capability.allCases, row.caps)
            .map { capability, support in
                "\(L10n.tr(capability.titleKey, table: capability.titleTable)) \(L10n.tr(support.key, table: support.table))"
            }
            .joined(separator: ", ")
    }

    @ViewBuilder
    fileprivate func statusText(_ status: Board.Status?, tint: Color) -> some View {
        if let status {
            Text(L10n.tr(status.key, table: status.table))
                .font(OriveoTheme.Typography.caption)
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Flow layout for chips: a chip that does not fit on the line wraps to the next line as a whole;
/// only a chip wider than the whole column is given the column width (the key name is truncated in the middle).
struct RelayChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    /// Splits chips into lines by width and returns the chip indexes of each line; each width is capped at the column width first.
    static func rows(widths: [CGFloat], maxWidth: CGFloat, spacing: CGFloat) -> [[Int]] {
        var rows: [[Int]] = []
        var x: CGFloat = 0
        for (index, raw) in widths.enumerated() {
            let width = min(raw, maxWidth)
            if let last = rows.indices.last, !rows[last].isEmpty, x + spacing + width <= maxWidth {
                rows[last].append(index)
                x += spacing + width
            } else {
                rows.append([index])
                x = width
            }
        }
        return rows
    }

    private func sizes(_ subviews: Subviews, maxWidth: CGFloat) -> [CGSize] {
        subviews.map { subview in
            let ideal = subview.sizeThatFits(.unspecified)
            guard ideal.width > maxWidth else { return ideal }
            return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let sizes = sizes(subviews, maxWidth: maxWidth)
        let rows = Self.rows(widths: sizes.map(\.width), maxWidth: maxWidth, spacing: spacing)
        var width: CGFloat = 0
        var height: CGFloat = 0
        for row in rows {
            let rowWidth = row.map { sizes[$0].width }.reduce(0, +) + spacing * CGFloat(max(0, row.count - 1))
            width = max(width, rowWidth)
            height += row.map { sizes[$0].height }.max() ?? 0
        }
        height += spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = sizes(subviews, maxWidth: bounds.width)
        let rows = Self.rows(widths: sizes.map(\.width), maxWidth: bounds.width, spacing: spacing)
        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map { sizes[$0].height }.max() ?? 0
            var x = bounds.minX
            for index in row {
                let size = sizes[index]
                // Vertically centered within the line: the protocol chip and the key chip differ slightly in height.
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (rowHeight - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}

/// Key chip on enabled rows (2 or more keys): a key icon + the name or mask of the key it is bound to.
struct RelayCatalogKeyChip: View {
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            PhosphorIcon.key.image(.regular)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 11, height: 11)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(OriveoTheme.Typography.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(OriveoTheme.Palette.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(OriveoTheme.Palette.surfaceInset.opacity(0.8)))
    }
}

/// Body of the "Not reachable" reason dialog: one sentence of reason plus the status code when there is one.
enum RelayUnreachableReasonText {
    static func message(_ failure: RelayModelProbeFailure) -> String {
        guard let code = failure.httpStatus else { return failure.summary }
        return "HTTP \(code) · \(failure.summary)"
    }
}

/// Card background on the model-library page, drawn like the detail page (`surfaceElevated`, no border, no shadow).
/// Shared by the key status strip, the loading card and the failure card; each sets its own padding.
extension View {
    func relayCatalogCardSurface() -> some View {
        background(
            RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous)
                .fill(OriveoTheme.Palette.surfaceElevated)
        )
    }
}

/// Font of text buttons such as Retry on the model-library page: pairs with `OriveoTextButtonStyle` (brand purple, no fill, no border),
/// replacing the system `.bordered` capsule; the tap target is stretched to 44pt.
struct RelayCatalogTextButtonLabel: View {
    let title: String
    var font: Font = OriveoTheme.Typography.footnote.weight(.semibold)
    /// Which side the text sits on inside the 44pt tap target: leading with the body text inside cards, centered at the end of a row.
    var alignment: Alignment = .center

    var body: some View {
        Text(title)
            .font(font)
            .lineLimit(1)
            .frame(minWidth: 44, minHeight: 44, alignment: alignment)
            .contentShape(Rectangle())
    }
}

/// Per-key row at the top of the catalog section (2 or more keys): name or mask + catalog count + checkmark; on failure "<code> <status word>" + Retry (refreshes only this key).
struct RelayCatalogKeyStatusBar: View {
    /// Maximum share of the row width taken by the trailing status column (same rule as the keys page).
    static let statusMaxFraction: CGFloat = 0.5

    let items: [RelayCatalogBoardModel.KeyStatusItem]
    let onRetry: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                keyRow(item)
                if index < items.count - 1 {
                    Rectangle()
                        .fill(OriveoTheme.Palette.border.opacity(0.45))
                        .frame(height: 0.5)
                }
            }
        }
        .padding(.horizontal, OriveoTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .relayCatalogCardSurface()
    }

    /// Left column is two lines, "name / catalog"; the status column (checkmark on success, "<code> <status word>" on failure) takes at most 50% of the row width. Retry sits outside the columns at its intrinsic width and is never squeezed by the status.
    private func keyRow(_ item: RelayCatalogBoardModel.KeyStatusItem) -> some View {
        HStack(alignment: .center, spacing: OriveoTheme.Spacing.sm) {
            PhosphorIcon.key.image(.regular)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 14, height: 14)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .accessibilityHidden(true)
            RelayMenuRowColumns(spacing: OriveoTheme.Spacing.sm, trailingMaxFraction: Self.statusMaxFraction) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.title)
                        .font(OriveoTheme.Typography.footnote.weight(.medium))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(String(format: L10n.tr(RelayKeysBoardModel.catalogCountKey, table: .providers), Int64(item.catalogCount)))
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                statusLabel(item)
            }
            if case .failed = item.state {
                Button {
                    onRetry(item.id)
                } label: {
                    RelayCatalogTextButtonLabel(title: L10n.tr("Retry"))
                }
                .buttonStyle(OriveoTextButtonStyle())
                .fixedSize()
            }
        }
        // Give the row a full 44pt height so the Retry tap target of a failed row is not taller than the other rows.
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private func statusLabel(_ item: RelayCatalogBoardModel.KeyStatusItem) -> some View {
        switch item.state {
        case .ok:
            PhosphorIcon.checkCircle.image(.duotone)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 16, height: 16)
                .foregroundStyle(OriveoTheme.Palette.success)
                .accessibilityLabel(L10n.tr(RelayKeysBoardModel.statusKey(.ok), table: .providers))
        case let .failed(httpStatus, statusKey):
            let word = L10n.tr(statusKey, table: .providers)
            Text(verbatim: httpStatus.map { "\($0) \(word)" } ?? word)
                .font(OriveoTheme.Typography.caption)
                .foregroundStyle(OriveoTheme.Palette.warningText)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        case .unchecked:
            EmptyView()
        }
    }
}

/// Protocol chip: the dot reuses the protocol color of the add page, and the name is the protocol's short name (not translated).
struct RelayCatalogProtocolChip: View {
    let transport: RelayTransport

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(RelayProtocolMixBar.color(for: transport))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(verbatim: RelayProtocolMix.legendName(transport))
                .font(OriveoTheme.Typography.caption.weight(.medium))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(OriveoTheme.Palette.surfaceInset.opacity(0.8)))
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// Supported = duotone in the capability color; unknown = gray single tone at 60%; unsupported = dimmed.
struct RelayCatalogCapabilityIcon: View {
    let capability: RelayCatalogBoardModel.Capability
    let support: RelayCatalogBoardModel.Support

    static func tint(_ capability: RelayCatalogBoardModel.Capability) -> Color {
        switch capability {
        case .image: CapabilityPalette.vision
        case .file: CapabilityPalette.attachment
        case .thinking: CapabilityPalette.reasoning
        case .tool: CapabilityPalette.tools
        case .web: CapabilityPalette.webSearch
        }
    }

    var body: some View {
        let isSupported = support == .supported
        capability.icon.image(isSupported ? .duotone : .regular)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: 16, height: 16)
            .foregroundStyle(Self.color(capability, support))
            .accessibilityHidden(true)
    }

    static func color(_ capability: RelayCatalogBoardModel.Capability, _ support: RelayCatalogBoardModel.Support) -> Color {
        switch support {
        case .supported: tint(capability)
        case .unknown: OriveoTheme.Palette.textSecondary.opacity(0.6)
        case .unsupported: OriveoTheme.Palette.borderStrong
        }
    }
}

/// Filter chips: "All" + the protocols present in the rows; an empty array renders nothing.
struct RelayCatalogFilterChips: View {
    let filters: [RelayCatalogBoardModel.Filter]
    let selected: RelayCatalogBoardModel.Filter
    /// Display name of the key for the key chip (`RelayCatalogBoardModel.keyFilterTitle`).
    let keyTitle: (String) -> String
    let onSelect: (RelayCatalogBoardModel.Filter) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                ForEach(filters, id: \.self) { filter in
                    let isSelected = filter == selected
                    Button {
                        onSelect(filter)
                    } label: {
                        HStack(spacing: 6) {
                            if case let .transport(transport) = filter {
                                Circle()
                                    .fill(RelayProtocolMixBar.color(for: transport))
                                    .frame(width: 7, height: 7)
                                    .accessibilityHidden(true)
                            }
                            Text(label(filter))
                                .font(OriveoTheme.Typography.footnote.weight(.medium))
                                .foregroundStyle(isSelected ? OriveoTheme.Palette.primary : OriveoTheme.Palette.textSecondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, OriveoTheme.Spacing.md)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(isSelected ? OriveoTheme.Palette.primarySoft : OriveoTheme.Palette.surfaceElevated)
                        )
                        .overlay(
                            Capsule().stroke(isSelected ? OriveoTheme.Palette.primary.opacity(0.3) : OriveoTheme.Palette.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    private func label(_ filter: RelayCatalogBoardModel.Filter) -> String {
        switch filter {
        case .all: L10n.tr("All")
        case let .transport(transport): RelayProtocolMix.legendName(transport)
        case let .key(keyID):
            String(format: L10n.tr("Key: %@", table: .providers), keyTitle(keyID))
        }
    }
}

/// Three legend items at the bottom + a footnote.
struct RelayCatalogLegend: View {
    typealias Board = RelayCatalogBoardModel

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: OriveoTheme.Spacing.md) { items }
                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xs) { items }
            }
            Text(L10n.tr(Board.footnoteKey, table: .providers))
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var items: some View {
        ForEach(Board.legend, id: \.key) { item in
            HStack(spacing: 6) {
                Circle()
                    .fill(RelayCatalogCapabilityIcon.color(.image, item.support))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(L10n.tr(item.key, table: .providers))
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .lineLimit(1)
            }
        }
    }
}
