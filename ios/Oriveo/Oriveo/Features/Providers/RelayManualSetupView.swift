import SwiftUI

// MARK: - Add relay > Manual setup (ManualSetup board)
//
// Renders only the sections and rows given by `RelayManualSetupBoardModel`; all input goes back to `RelayManualSetupFlow`, and no decisions are made here.
// The address block and key block are the same subview as in step 1; the protocol card and collapsed group use the edit-connection page's row views.

/// The form page of manual setup (the scrolling content; the page shell, top bar and bottom primary button live in `RelaySetupView`).
struct RelayManualSetupFormView: View {
    typealias Board = RelayManualSetupBoardModel

    let flow: RelayManualSetupFlow
    let board: Board
    /// "Save anyway (unverified)" on the failure card.
    let onSaveUnverified: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xl) {
            SetupBoardHero(
                icon: board.hero.icon,
                labelKey: board.hero.labelKey,
                titleKey: board.hero.titleKey,
                subtitleKey: board.hero.subtitleKey,
                trailingKey: board.hero.trailingKey
            )

            ForEach(board.sections, id: \.self) { section in
                sectionView(section)
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: Board.Section) -> some View {
        switch section {
        case .requestURL:
            RelaySetupAddressBlock(
                endpoint: Binding(get: { flow.quick.endpoint }, set: { flow.setEndpoint($0) }),
                previewLine: flow.quick.previewLine,
                highlightToken: flow.endpointWritebackToken,
                isEnabled: !flow.isValidating
            )
        case .apiKeys:
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
                RelaySetupKeysBlock(
                    keys: flow.quick.keys,
                    showsKeyNames: board.keySlots.contains(.keyName),
                    isEnabled: !flow.isValidating,
                    setSecret: { flow.setSecret($0, for: $1) },
                    setName: { flow.setKeyName($0, for: $1) },
                    addKey: { _ = flow.addKey() },
                    removeKey: { flow.removeKey($0) }
                )
                // The one-line hint for wrong input sits right under the address and keys, using the same hint component and the same verdict as the edit-connection page.
                // The header / query parameter hints are not here: they go with the collapsed group, under the matching rows inside it.
                RelayFormIssueNotes(issues: board.keyIssues)
            }
        case .model:
            RelaySetupField(
                title: L10n.tr(board.model.titleKey, table: .providers),
                text: Binding(get: { flow.modelID }, set: { flow.setModelID($0) }),
                placeholder: board.model.placeholder,
                footnote: board.model.footnote.map { RelayEditBoardModel.string($0) },
                isSecure: false,
                isEnabled: !flow.isValidating,
                leadingSystemImage: nil,
                usesQuickSetupStyle: true,
                // A model ID is a technical value: keep it left-to-right in Arabic too.
                forcesLeftToRightValue: true,
                leadingPhosphor: board.model.icon
            )
        case .connectionName:
            connectionNameField(board.connectionName)
        case .protocolCard:
            editRows([board.protocolGroup])
        case .advanced:
            editRows([advancedGroup])
        case .failure:
            if let failure = board.failure {
                // A verification failure is not stored: reason + technical details + "Save anyway (unverified)", the only exit that stores an unverified connection.
                OriveoErrorCard(
                    error: failure,
                    action: onSaveUnverified
                )
                // The page shell dismisses the keyboard and scrolls here when a new card appears (same approach as edit connection).
                .id(RelayFailureCardReveal.anchorID)
            }
        }
    }

    /// The summary on the right of the collapsed group title is given by the row model in segments; here they are joined into one sentence for the group header.
    private var advancedGroup: Board.Group {
        var group = board.advancedGroup
        group.trailing = .verbatim(Board.summaryString(board.advancedSummary))
        return group
    }

    /// Connection name: title row + name slot (the leading label in the slot is "Name (optional)", the placeholder is the domain from the address) + footnote.
    private func connectionNameField(_ field: Board.Field) -> some View {
        let title = L10n.tr(field.titleKey, table: .providers)
        return VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                field.icon.image(.regular)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(OriveoTheme.Palette.primary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(title)
                    .font(OriveoTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
            }
            .padding(.leading, 2)

            if let slotLabelKey = field.slotLabelKey {
                RelaySetupKeyNameSlot(
                    text: Binding(get: { flow.connectionName }, set: { flow.setConnectionName($0) }),
                    labelKey: slotLabelKey,
                    placeholder: field.placeholder,
                    accessibilityTitle: title,
                    isEnabled: !flow.isValidating
                )
            }

            if let footnote = field.footnote {
                Text(RelayEditBoardModel.string(footnote))
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }
        }
    }

    /// Protocol card and collapsed group: rows, group header, menu and header editing are all the edit-connection page's views.
    /// This page has no address row or compatibility items, so those bindings are unused and get constants.
    private func editRows(_ groups: [Board.Group]) -> some View {
        RelayEditBoardView(
            groups: groups,
            endpoint: .constant(""),
            transport: Binding(get: { flow.transport }, set: { flow.setTransport($0) }),
            authMode: Binding(get: { flow.authMode }, set: { flow.setAuthMode($0) }),
            customUserAgent: Binding(get: { flow.customUserAgent }, set: { flow.setCustomUserAgent($0) }),
            headers: Binding(get: { flow.headers }, set: { flow.setHeaders($0) }),
            queryParams: Binding(get: { flow.queryParams }, set: { flow.setQueryParams($0) }),
            serviceTier: .constant(""),
            stream: .constant(true),
            disableResponseStorage: .constant(false),
            securityMode: .remoteHTTPS,
            transportOptions: Board.transportOptions,
            issues: [],
            isBusy: flow.isValidating,
            onChangeSecurityMode: {}
        )
    }
}

/// The text button at the top left of the page, "Use quick setup": replaces the back button and returns to quick setup step 1.
struct RelayManualSetupQuickSetupButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // A plain text button on the board, no arrow; the tap area extends to 44pt.
            // French / German / Spanish / Portuguese / Russian translations are twice as long as English: try three tiers in order (tier selection: see RelayManualSetupQuickSetupLayout), never truncate.
            ViewThatFits(in: .horizontal) {
                label(.fullSingleLine)
                label(.reducedSingleLine)
                label(.reducedWrapped)
            }
            .foregroundStyle(OriveoTheme.Palette.primary)
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func label(_ tier: RelayManualSetupQuickSetupLayout.Tier) -> some View {
        Text(L10n.tr(RelayManualSetupBoardModel.quickSetupKey, table: .providers))
            .font(.system(size: RelayManualSetupQuickSetupLayout.baseFontSize * tier.scale, weight: .semibold))
            .lineLimit(tier.lineLimit)
            .multilineTextAlignment(.leading)
            // The single-line tier takes part in the ViewThatFits comparison by its ideal width; the wrapping tier only grows in height.
            .fixedSize(horizontal: tier.lineLimit == 1, vertical: true)
    }
}

/// The three tiers of "Use quick setup": 100% on one line -> 85% on one line -> 85% wrapping with no line limit; no tier truncates.
/// The view tries them with ViewThatFits in the order of `Tier.allCases`, using the same criterion as `tier(availableWidth:fullSizeSingleLineWidth:)`.
enum RelayManualSetupQuickSetupLayout {
    /// Same size as `OriveoTheme.Typography.footnote`; the 85% tier computes its font size from it, since a Font from the theme cannot yield a point size.
    static let baseFontSize: CGFloat = 12
    static let reducedScale: CGFloat = 0.85

    enum Tier: CaseIterable, Equatable {
        case fullSingleLine
        case reducedSingleLine
        case reducedWrapped

        var scale: CGFloat { self == .fullSingleLine ? 1 : RelayManualSetupQuickSetupLayout.reducedScale }
        /// nil = the wrapping tier has no line limit: it wraps as many lines as needed and never truncates.
        var lineLimit: Int? { self == .reducedWrapped ? nil : 1 }
    }

    static func tier(availableWidth: CGFloat, fullSizeSingleLineWidth: CGFloat) -> Tier {
        if fullSizeSingleLineWidth <= availableWidth { return .fullSingleLine }
        if fullSizeSingleLineWidth * reducedScale <= availableWidth { return .reducedSingleLine }
        return .reducedWrapped
    }
}
