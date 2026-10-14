import SwiftUI

// MARK: - Edit connection board
//
// Renders only the groups and rows produced by `RelayEditBoardModel`; rows, group titles and cards share one style with the detail page (`RelayDetailBoardView`):
// 56pt row height, `surfaceElevated` with no stroke at `Radius.lg`, footnote-semibold group titles with 0.6 tracking as plain text, and a 22pt two-tone leading icon with no backing plate.
// State, saving and connection-security switching live in `RelayEditView`; this view only takes bindings.

struct RelayEditBoardView: View {
    typealias Board = RelayEditBoardModel

    /// The groups to render. The edit page passes the whole page's groups; the add page's "Manual setup" passes only the protocol card and the collapsible group, and both pages use the same rows.
    let groups: [Board.Group]
    @Binding var endpoint: String
    @Binding var transport: RelayTransport
    @Binding var authMode: RelayAuthMode
    @Binding var customUserAgent: String
    @Binding var headers: [RelayKeyValue]
    @Binding var queryParams: [RelayKeyValue]
    @Binding var serviceTier: String
    @Binding var stream: Bool
    @Binding var disableResponseStorage: Bool
    let securityMode: RelayConnectionSecurityMode
    /// Candidates for the default protocol menu (local engines: channel).
    let transportOptions: [RelayTransport]
    /// The validation hint under the connection card; the ones in the headers group arrive with that group (`Board.Group.issues`).
    let issues: [RelayFormValidation.FieldIssue]
    let isBusy: Bool
    var endpointHighlightToken = 0
    let onChangeSecurityMode: () -> Void

    private enum FocusField: Hashable {
        case endpoint
        case value(Board.RowID)
        case entryName(Board.RowID, Int)
        case entryValue(Board.RowID, Int)
    }

    /// Collapse state the user has toggled; groups never toggled use the default given by the row model.
    @State private var expansion: [Board.GroupID: Bool] = [:]
    /// Indexes of headers whose eye button was tapped open.
    @State private var revealedHeaders: Set<Int> = []
    @State private var isEndpointHighlighted = false
    @FocusState private var focus: FocusField?

    /// Leading icon 22pt plus its gap to the text: footnotes under a row and the address slot are indented to line up with the title.
    private static let iconSize: CGFloat = 22
    private static var textInset: CGFloat { iconSize + OriveoTheme.Spacing.md }
    private static let endpointPlaceholder = "https://api.example.com/v1"

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
            ForEach(groups, id: \.id) { group in
                groupView(group)
                if group.id == .connection {
                    // The one-line hint for a wrong entry sits right under the connection card, using the same hint component and the same verdict as the add page.
                    RelayFormIssueNotes(issues: issues)
                }
            }
        }
        .onChange(of: endpointHighlightToken) { _, _ in
            isEndpointHighlighted = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                isEndpointHighlighted = false
            }
        }
        .onChange(of: groupsHoldingIssues, initial: true) { _, held in
            // A group that a validation hint forced open stays expanded after the hint disappears: the user is editing inside it, and it should not collapse in their face once they get it right.
            for id in held { expansion[id] = true }
        }
    }

    // MARK: Groups

    private var groupsHoldingIssues: [Board.GroupID] {
        groups.filter { !$0.issues.isEmpty }.map(\.id)
    }

    private func isExpanded(_ group: Board.Group) -> Bool {
        group.isExpanded(userChoice: expansion[group.id])
    }

    private func groupView(_ group: Board.Group) -> some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            groupHeader(group)

            if isExpanded(group) {
                VStack(spacing: 0) {
                    ForEach(Array(group.rows.enumerated()), id: \.offset) { index, row in
                        rowView(row)
                        // The sentence for a wrong header / query-parameter entry follows directly under its row, using the same component as the hint under the connection card.
                        let notes = group.notes(belowRowAt: index)
                        if !notes.isEmpty {
                            RelayFormIssueNotes(issues: notes)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 10)
                        }
                        if index < group.rows.count - 1 {
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
    }

    private func groupTitle(_ group: Board.Group) -> some View {
        Text(L10n.tr(group.titleKey, table: .providers))
            .font(OriveoTheme.Typography.footnote.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .multilineTextAlignment(.leading)
    }

    @ViewBuilder
    private func groupHeader(_ group: Board.Group) -> some View {
        if group.isCollapsible {
            let expanded = isExpanded(group)
            Button {
                // Tapping the group header while a hint holds it open is not recorded as a collapse: once the entry is fixed and the hint goes away, the group must stay as the user sees it, expanded.
                let next = group.userChoiceAfterTap(expansion[group.id])
                withAnimation(.snappy(duration: 0.18)) { expansion[group.id] = next }
            } label: {
                HStack(spacing: 6) {
                    groupTitle(group)
                    Spacer(minLength: OriveoTheme.Spacing.sm)
                    if let trailing = group.trailing {
                        Text(text(trailing))
                            .font(OriveoTheme.Typography.footnote)
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    }
                    // Collapse indicator: collapsed points along the reading direction (mirrored in RTL), expanded points down; do not use the down/up pair, which carries menu semantics.
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
            // A collapsible group header must announce expanded / collapsed, not rely on the arrow direction alone.
            .accessibilityValue(L10n.tr(expanded ? "Expanded" : "Collapsed", table: .chat))
        } else {
            groupTitle(group)
                .accessibilityAddTraits(.isHeader)
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func rowView(_ row: Board.Row) -> some View {
        switch row.control {
        case .addressInput:
            addressRow(row)
        case .change:
            Button(action: onChangeSecurityMode) {
                rowBody(row) {
                    Text(L10n.tr("Change", table: .providers))
                        .font(OriveoTheme.Typography.footnote.weight(.semibold))
                        .foregroundStyle(OriveoTheme.Palette.primary)
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
            .buttonStyle(.plain)
            .disabled(isBusy)
        case .menu:
            menuRow(row)
        case .readOnly:
            rowBody(row) { EmptyView() }
                .accessibilityElement(children: .combine)
        case .valueInput:
            valueInputRow(row)
        case let .keyValue(masked):
            if let index = row.index {
                keyValueRow(row, index: index, masked: masked)
            }
        case .add:
            addRow(row)
        case .toggle:
            toggleRow(row)
        }
    }

    @ViewBuilder
    private func leadingIcon(_ row: Board.Row) -> some View {
        if let icon = row.icon, let tint = row.tint {
            icon.image(.duotone)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: Self.iconSize, height: Self.iconSize)
                .foregroundStyle(Self.iconColor(tint))
                .accessibilityHidden(true)
        }
    }

    private static func iconColor(_ tint: Board.RowIconTint) -> Color {
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

    private func rowTitle(_ row: Board.Row) -> String {
        L10n.tr(row.titleKey, table: Board.titleTable(for: row))
    }

    private func rowFootnote(_ footnote: Board.Text, inset: CGFloat) -> some View {
        Text(text(footnote))
            .font(OriveoTheme.Typography.footnote)
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, inset)
    }

    /// Left column: icon in its own column + a title / footnote column; right column: the current value and the trailing control.
    /// The icon and the right column are both vertically centered on the whole row: pinned to the title line, a row with a footnote would leave its lower part empty and out of step with the row height.
    private func rowBody<Trailing: View>(
        _ row: Board.Row,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: OriveoTheme.Spacing.md) {
            // The value column takes at most 45%, so the title + footnote column is not squeezed to a sliver by a long value.
            RelayMenuRowColumns(spacing: OriveoTheme.Spacing.md) {
                // The icon is its own column, vertically centered on the whole title + footnote block rather than pinned to the title line (layout rule: multi-line rows center as a whole).
                HStack(alignment: .center, spacing: OriveoTheme.Spacing.md) {
                    leadingIcon(row)
                    VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xs) {
                        Text(rowTitle(row))
                            .font(OriveoTheme.Typography.body)
                            .foregroundStyle(OriveoTheme.Palette.textPrimary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if let footnote = row.footnote {
                            rowFootnote(footnote, inset: 0)
                        }
                    }
                }
                if let value = row.value {
                    Text(text(value))
                        .font(OriveoTheme.Typography.body)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: Address row

    private var addressBodyBinding: Binding<String> {
        Binding(
            get: { Board.addressBody(endpoint) },
            set: { endpoint = Board.address(endpoint, replacingBodyWith: $0) }
        )
    }

    private func addressRow(_ row: Board.Row) -> some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            HStack(alignment: .center, spacing: OriveoTheme.Spacing.md) {
                leadingIcon(row)
                Text(rowTitle(row))
                    .font(OriveoTheme.Typography.body)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
            }

            HStack(spacing: OriveoTheme.Spacing.sm) {
                Text(verbatim: Board.explicitScheme(in: endpoint) ?? Board.defaultScheme(for: securityMode))
                    .font(OriveoTheme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: OriveoTheme.Radius.sm, style: .continuous)
                            .fill(OriveoTheme.Palette.primarySoft)
                    )
                    .accessibilityHidden(true)

                TextField(
                    "",
                    text: addressBodyBinding,
                    prompt: Text(verbatim: Board.addressBody(Self.endpointPlaceholder))
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                )
                .font(OriveoTheme.Typography.body)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(isBusy)
                .focused($focus, equals: .endpoint)
                .accessibilityLabel(rowTitle(row))
                // The scheme chip is hidden from VoiceOver: the value carries it, so the full address is read out (http / https are audible).
                .accessibilityValue(Board.spokenAddress(endpoint, securityMode: securityMode))
            }
            // The address is a technical value: keep it left-to-right even in Arabic.
            .environment(\.layoutDirection, .leftToRight)
            .padding(.leading, OriveoTheme.Spacing.sm)
            .padding(.trailing, OriveoTheme.Spacing.md)
            .frame(minHeight: 48)
            .relayFillSlot(isFocused: focus == .endpoint, isHighlighted: isEndpointHighlighted)
            .contentShape(Rectangle())
            .onTapGesture { focus = .endpoint }
            // row-lead: top. The input sits below the endpoint row, the icon follows the title line, and the input is indented by the icon width to line up with the title.
            .padding(.leading, Self.textInset)

            if let footnote = row.footnote {
                // row-lead: top, same as above: the footnote sits below the input, indented like the input, and does not center on the icon.
                rowFootnote(footnote, inset: Self.textInset)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    }

    // MARK: Menu rows

    @ViewBuilder
    private func menuRow(_ row: Board.Row) -> some View {
        let title = rowTitle(row)
        Menu {
            switch row.id {
            case .authentication:
                Picker(title, selection: $authMode) {
                    ForEach(RelayAuthMode.allUICases, id: \.self) { option in
                        Text(relayAuthLabel(option)).tag(option)
                    }
                }
            case .channel:
                Picker(title, selection: $transport) {
                    ForEach(transportOptions, id: \.self) { option in
                        Text(relayTransportLabel(option)).tag(option)
                    }
                }
            default:
                Picker(title, selection: $transport) {
                    ForEach(transportOptions, id: \.self) { option in
                        Text(relayTransportLabel(option)).tag(option)
                    }
                }
            }
        } label: {
            rowBody(row) {
                PhosphorIcon.caretDown.image(.regular)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        // A menu row must read out its current value, not only its title.
        .accessibilityLabel(title)
        .accessibilityValue(row.value.map(text) ?? "")
        .accessibilityHint(row.footnote.map(text) ?? "")
    }

    // MARK: Value slot rows (User-Agent / service tier)

    private func valueBinding(_ id: Board.RowID) -> Binding<String> {
        id == .serviceTier ? $serviceTier : $customUserAgent
    }

    private func slotField(
        _ text: Binding<String>,
        placeholder: String,
        label: String,
        focusField: FocusField,
        isSecure: Bool = false
    ) -> some View {
        Group {
            if isSecure {
                SecureField("", text: text, prompt: Text(placeholder).foregroundStyle(OriveoTheme.Palette.textTertiary))
            } else {
                TextField("", text: text, prompt: Text(placeholder).foregroundStyle(OriveoTheme.Palette.textTertiary))
            }
        }
        .font(OriveoTheme.Typography.footnote.monospaced())
        .foregroundStyle(OriveoTheme.Palette.textPrimary)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .disabled(isBusy)
        .focused($focus, equals: focusField)
        // A placeholder is not a label: VoiceOver must still be able to say which field this is.
        .accessibilityLabel(label)
    }

    private func valueInputRow(_ row: Board.Row) -> some View {
        let title = rowTitle(row)
        let field = FocusField.value(row.id)
        return HStack(alignment: .center, spacing: OriveoTheme.Spacing.md) {
            Text(title)
                .font(OriveoTheme.Typography.body)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            slotField(
                valueBinding(row.id),
                placeholder: L10n.tr(
                    row.id == .serviceTier ? "auto / default / flex / …" : "auto / leave blank",
                    table: .providers
                ),
                label: title,
                focusField: field
            )
            .padding(.horizontal, OriveoTheme.Spacing.md)
            .frame(minHeight: 44)
            .relayFillSlot(isFocused: focus == field)
            .contentShape(Rectangle())
            .onTapGesture { focus = field }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    }

    // MARK: Key-value rows

    private func entriesBinding(_ id: Board.RowID) -> Binding<[RelayKeyValue]> {
        id == .header ? $headers : $queryParams
    }

    private func entryBinding(_ id: Board.RowID, index: Int, _ keyPath: WritableKeyPath<RelayKeyValue, String>) -> Binding<String> {
        let entries = entriesBinding(id)
        return Binding(
            // During the delete animation the row model may still carry an index that no longer exists.
            get: { entries.wrappedValue.indices.contains(index) ? entries.wrappedValue[index][keyPath: keyPath] : "" },
            set: { next in
                guard entries.wrappedValue.indices.contains(index) else { return }
                entries.wrappedValue[index][keyPath: keyPath] = next
            }
        )
    }

    private func keyValueRow(_ row: Board.Row, index: Int, masked: Bool) -> some View {
        let category = rowTitle(row)
        let nameField = FocusField.entryName(row.id, index)
        let valueField = FocusField.entryValue(row.id, index)
        let isRevealed = !masked || revealedHeaders.contains(index)

        let categoryLabel = Text(category)
            .font(OriveoTheme.Typography.footnote)
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .lineLimit(1)

        let slots = HStack(spacing: OriveoTheme.Spacing.sm) {
            slotField(
                entryBinding(row.id, index: index, \.key),
                placeholder: row.id == .header ? "X-Internal-Token" : "tenant",
                label: "\(category) · \(L10n.tr("Name", table: .providers))",
                focusField: nameField
            )
            .padding(.horizontal, 10)
            .frame(minWidth: 72, minHeight: 44)
            .relayFillSlot(isFocused: focus == nameField)

            HStack(spacing: 0) {
                slotField(
                    entryBinding(row.id, index: index, \.value),
                    placeholder: L10n.tr("value", table: .providers),
                    label: "\(category) · \(L10n.tr("value", table: .providers))",
                    focusField: valueField,
                    isSecure: !isRevealed
                )
                if masked {
                    Button {
                        if isRevealed { revealedHeaders.remove(index) } else { revealedHeaders.insert(index) }
                    } label: {
                        // The icon set has no registered struck-through eye: once opened, switch to the two-tone weight to mean "currently shown".
                        PhosphorIcon.eye.image(isRevealed ? .duotone : .regular)
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .frame(width: 18, height: 18)
                            .foregroundStyle(OriveoTheme.Palette.textTertiary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isRevealed ? L10n.tr("Hide characters") : L10n.tr("Show characters"))
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, masked ? 0 : 10)
            .frame(minWidth: 96, minHeight: 44)
            .relayFillSlot(isFocused: focus == valueField)

            Button {
                removeEntry(row.id, at: index)
            } label: {
                PhosphorIcon.trash.image(.regular)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityLabel("\(L10n.tr("Remove", table: .providers)) · \(category)")
        }

        // Category + name slot + value slot sit on one row; when the category name is too long or the text size too large to fit, the category moves to the line above the slots.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                categoryLabel.fixedSize()
                slots
            }
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xs) {
                categoryLabel
                slots
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 2)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    }

    private func removeEntry(_ id: Board.RowID, at index: Int) {
        let entries = entriesBinding(id)
        guard entries.wrappedValue.indices.contains(index) else { return }
        entries.wrappedValue.remove(at: index)
        if id == .header {
            // The eye button's state is keyed by index: after a row is deleted, the rows behind it shift forward by one.
            revealedHeaders = Set(revealedHeaders.compactMap { $0 == index ? nil : ($0 > index ? $0 - 1 : $0) })
        }
    }

    private func addRow(_ row: Board.Row) -> some View {
        Menu {
            Button(L10n.tr(Board.headersKey, table: .providers)) {
                headers.append(RelayKeyValue(key: "", value: ""))
            }
            Button(L10n.tr(Board.queryParamsKey, table: .providers)) {
                queryParams.append(RelayKeyValue(key: "", value: ""))
            }
        } label: {
            HStack(spacing: 6) {
                PhosphorIcon.plus.image(.regular)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
                Text(rowTitle(row))
                    .font(OriveoTheme.Typography.footnote.weight(.semibold))
            }
            .foregroundStyle(OriveoTheme.Palette.primary)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    // MARK: Toggle rows

    private func toggleRow(_ row: Board.Row) -> some View {
        rowBody(row) {
            Toggle(
                "",
                isOn: row.id == .stream ? $stream : $disableResponseStorage
            )
                .labelsHidden()
                .tint(OriveoTheme.Palette.primary)
                .disabled(isBusy)
                .accessibilityLabel(rowTitle(row))
        }
    }

    // MARK: Strings

    private func text(_ value: Board.Text) -> String {
        Board.string(value)
    }
}

/// The two columns of an edit / manual-setup menu row: the first child is the title + footnote column, the second (optional) is the value column.
/// The value column takes at most `trailingMaxFraction` of the total width of the two (45% for menu rows) and everything else goes to the title column; the two are centered on the row height and the value column hugs the row end.
/// The status column of key rows uses it too (50%).
struct RelayMenuRowColumns: Layout {
    static let valueMaxFraction: CGFloat = 0.45
    var spacing: CGFloat
    var trailingMaxFraction: CGFloat = Self.valueMaxFraction

    /// Given the total width and the value column's ideal width, returns (title column width, value column width).
    static func columnWidths(
        total: CGFloat,
        valueIdeal: CGFloat,
        spacing: CGFloat,
        maxFraction: CGFloat = valueMaxFraction
    ) -> (title: CGFloat, value: CGFloat) {
        let value = min(valueIdeal, total * maxFraction)
        return (max(0, total - value - spacing), value)
    }

    private func measure(_ subviews: Subviews, width: CGFloat?) -> (title: CGSize, value: CGSize?, titleWidth: CGFloat) {
        guard let first = subviews.first else { return (.zero, nil, 0) }
        guard subviews.count > 1 else {
            let size = first.sizeThatFits(ProposedViewSize(width: width, height: nil))
            return (size, nil, width ?? size.width)
        }
        let valueIdeal = subviews[1].sizeThatFits(.unspecified).width
        let total = width ?? (first.sizeThatFits(.unspecified).width + spacing + valueIdeal)
        let widths = Self.columnWidths(total: total, valueIdeal: valueIdeal, spacing: spacing, maxFraction: trailingMaxFraction)
        let title = first.sizeThatFits(ProposedViewSize(width: widths.title, height: nil))
        let value = subviews[1].sizeThatFits(ProposedViewSize(width: widths.value, height: nil))
        return (title, value, widths.title)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let measured = measure(subviews, width: proposal.width)
        let height = max(measured.title.height, measured.value?.height ?? 0)
        let width = proposal.width
            ?? (measured.title.width + (measured.value.map { $0.width + spacing } ?? 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let first = subviews.first else { return }
        let measured = measure(subviews, width: bounds.width)
        first.place(
            at: CGPoint(x: bounds.minX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: measured.titleWidth, height: measured.title.height)
        )
        if subviews.count > 1, let value = measured.value {
            subviews[1].place(
                at: CGPoint(x: bounds.maxX, y: bounds.midY),
                anchor: .trailing,
                proposal: ProposedViewSize(value)
            )
        }
    }
}
