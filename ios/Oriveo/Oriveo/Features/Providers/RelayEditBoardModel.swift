import Foundation

// MARK: - Edit-connection board (EditConnection)
//
// Covers only the "Edit connection" modal of the custom LLM family: four groups for a relay, two to three for a local engine.
// The view renders exactly the groups, row order, icons, row colors, footnotes and action bar produced here; structural tests assert on this model instead of image snapshots.
// There is no kind layer: rows depend only on "is local", "default protocol" and "is the connection encrypted", never on a stored relayKind.

struct RelayEditBoardModel: Equatable, Sendable {
    /// Row colors and copy follow the detail page so that the same row has the same color on both pages.
    typealias RowIconTint = RelayDetailBoardModel.RowIconTint
    typealias Text = RelayDetailBoardModel.Text

    enum Form: Equatable, Sendable {
        case relay
        case local
    }

    enum GroupID: String, Equatable, Sendable {
        case connection, protocolAuth, channel, headers, compatibility
    }

    enum RowID: String, Equatable, Sendable {
        case requestURL, engineAddress, connectionSecurity
        case defaultProtocol, channel, authentication
        case userAgent, header, queryParam, addEntry
        case stream, serviceTier, disableResponseStorage
    }

    /// Control shape on the trailing side of a row or inside it.
    enum Control: Equatable, Sendable {
        /// scheme prefix chip + lightly filled input slot (the next line is the "Will request ..." preview).
        case addressInput
        /// Current value + "Change"; a selection takes effect immediately, without waiting for Save.
        case change
        /// System menu with a trailing arrow.
        case menu
        /// Read-only value, no arrow.
        case readOnly
        /// Value slot only.
        case valueInput
        /// Name slot + value slot + trailing delete; `masked` = value is hidden by default, with an eye button.
        case keyValue(masked: Bool)
        case add
        case toggle
    }

    struct Row: Equatable, Sendable {
        let id: RowID
        var icon: PhosphorIcon? = nil
        var tint: RowIconTint? = nil
        let titleKey: String
        var value: Text? = nil
        var footnote: Text? = nil
        let control: Control
        /// Index of the key-value row in its own table.
        var index: Int? = nil
    }

    struct Group: Equatable, Sendable {
        let id: GroupID
        let titleKey: String
        var isCollapsible = false
        var startsExpanded = true
        /// Description on the trailing side of the group title (the filled count of the headers group).
        var trailing: Text? = nil
        let rows: [Row]
        /// Validation hints that appear inside this group (the header / query parameter ones).
        var issues: [RelayFormValidation.FieldIssue] = []

        /// Whether the collapsible group is expanded right now. `userChoice` is the state the user toggled; nil if never toggled.
        /// A group with validation hints is always expanded: otherwise the primary button stays disabled while the reason hides in a collapsed group where the user cannot find it.
        func isExpanded(userChoice: Bool?) -> Bool {
            !isCollapsible || !issues.isEmpty || (userChoice ?? startsExpanded)
        }

        /// Expansion state to remember after the group header is tapped. While a hint is forcing the group open, tapping the header is not recorded as "collapse";
        /// otherwise fixing the input would make the hint vanish and the whole group would collapse in front of the user (same approach as the web search page).
        func userChoiceAfterTap(_ userChoice: Bool?) -> Bool {
            !issues.isEmpty ? true : !isExpanded(userChoice: userChoice)
        }

        /// Hint to show below row `index`: it goes below the last row of that field (for headers, under the last header; same for query parameters).
        func notes(belowRowAt index: Int) -> [RelayFormValidation.FieldIssue] {
            issues.filter { issue in
                let target = RelayEditBoardModel.issueRowID(for: issue.field)
                return (rows.lastIndex { $0.id == target } ?? rows.startIndex) == index
            }
        }
    }

    /// Fixed bottom action bar: the secondary button is an in-place action and draws no arrow.
    struct ActionBar: Equatable, Sendable {
        let secondaryKey: String
        let primary: RelayEditPrimaryAction
        var isSecondaryEnabled = true
        var isPrimaryEnabled = true
    }

    /// The status entry at the end of the content, shared by the connection test and the reconnect after switching connection security.
    enum Status: Equatable, Sendable {
        case testing
        /// Connection security is already persisted and the reconnect is in progress.
        case reconnecting
        case verified
        case failed(String)
    }

    struct StatusRow: Equatable, Sendable {
        let tone: RelaySetupStatusRow.Tone
        let message: Text
        let showsProgress: Bool
        /// Icon for the result state (a Phosphor icon registered in the icon set); the in-progress state shows a spinner and no icon.
        var icon: PhosphorIcon? = nil
    }

    static let titleKey = "Edit connection"
    static let connectionGroupKey = "Connection"
    static let protocolAuthGroupKey = "Protocol & authentication"
    static let channelGroupKey = "Channel"
    static let headersGroupKey = "Headers & query params"
    static let compatibilityGroupKey = "Compatibility"
    static let testConnectionKey = "Test connection"
    static let securityNoteKey = "Changes apply right away and the connection is verified again."
    static let protocolAutoNoteKey = "Each model's protocol is detected on its own. Models that can't be detected use Chat Completions."
    static let protocolFixedNoteKey = "Every model uses %@ unless you set a protocol on that model."
    static let authNoteKey = "Manage keys under “%@” on the connection page."
    static let filledCountKey = "%lld set"
    static let headersKey = "Headers"
    static let queryParamsKey = "Query params"
    /// "Add" in the default string table (Localizable).
    static let addKey = "Add"
    static let discardMessageKey = "Your changes to this connection have not been saved."

    let form: Form
    /// Page header subtitle: the connection name.
    let subtitle: String
    let groups: [Group]
    /// Validation hints below the connection card: everything except those already placed in the headers group.
    let connectionIssues: [RelayFormValidation.FieldIssue]
    let actionBar: ActionBar

    /// - status: the entry at the end of the content (whether a test / reconnect is in flight).
    /// - isSaving: a save (including verification) is in flight.
    /// - hasFormIssues: whether the shared form validation blocked anything.
    /// - issues: the verdict of the shared form validation, used only to decide where each hint appears.
    /// - shownCompatibilityRows: compatibility items the draft opened during this edit session (the union of `draftCompatibilityRows`).
    ///   Rows that appear only while the draft has them on stay visible after the user turns them off or clears them on this page, until the page is left; otherwise one tap on the switch would make the whole row disappear.
    static func make(
        provider: Provider,
        editor: RelayEditView.Editor,
        status: Status? = nil,
        isSaving: Bool = false,
        hasFormIssues: Bool = false,
        issues: [RelayFormValidation.FieldIssue] = [],
        shownCompatibilityRows: Set<RowID> = [],
        baseline: RelayEditView.Editor? = nil
    ) -> Self {
        let engineProfile = provider.relayRequested?.engineProfile?.trimmingCharacters(in: .whitespacesAndNewlines)
        let form: Form = (engineProfile?.isEmpty == false) ? .local : .relay
        // Same criterion as the "encrypted" check and the rule that a plaintext connection cannot carry a key.
        let isEncrypted = !RelayCredentialPolicy.isCleartext(editor.securityMode)

        var groups: [Group] = []
        switch form {
        case .relay:
            groups.append(Group(
                id: .connection,
                titleKey: connectionGroupKey,
                rows: [addressRow(.requestURL, editor: editor, showsPreview: true), securityRow(editor)]
            ))
            groups.append(Group(
                id: .protocolAuth,
                titleKey: protocolAuthGroupKey,
                rows: [
                    defaultProtocolRow(editor.transport),
                    authRow(provider: provider, editor: editor),
                ]
            ))
            groups.append(headersGroup(editor, issues: issues))
            groups.append(Group(
                id: .compatibility,
                titleKey: compatibilityGroupKey,
                isCollapsible: true,
                startsExpanded: false,
                rows: compatibilityRows(
                    for: editor.transport,
                    serviceTierInEffect: isSet(provider.relayRequested?.serviceTier) || isSet(editor.serviceTier),
                    responseStorageDisabled: provider.relayRequested?.disableResponseStorage == true
                        || editor.disableResponseStorage,
                    alreadyShown: shownCompatibilityRows
                ).map(compatibilityRow)
            ))
        case .local:
            groups.append(Group(
                id: .connection,
                titleKey: connectionGroupKey,
                rows: [addressRow(.engineAddress, editor: editor, showsPreview: false), securityRow(editor)]
            ))
            var channelRows = [channelRow(engineProfile: engineProfile, editor: editor)]
            if isEncrypted { channelRows.append(authRow(provider: provider, editor: editor)) }
            groups.append(Group(id: .channel, titleKey: channelGroupKey, rows: channelRows))
            if isEncrypted { groups.append(headersGroup(editor, issues: issues)) }
        }

        // With no headers group on the page (local plaintext connection), those hints stay under the connection card and must not vanish with the group.
        let hasHeadersGroup = groups.contains { $0.id == .headers }
        return Self(
            form: form,
            subtitle: provider.displayName,
            groups: groups,
            connectionIssues: hasHeadersGroup ? issuesOutsideHeadersGroup(issues) : issues,
            actionBar: actionBar(
                provider: provider,
                editor: editor,
                status: status,
                isSaving: isSaving,
                hasFormIssues: hasFormIssues,
                baseline: baseline
            )
        )
    }

    private static func actionBar(
        provider: Provider,
        editor: RelayEditView.Editor,
        status: Status?,
        isSaving: Bool,
        hasFormIssues: Bool,
        baseline: RelayEditView.Editor?
    ) -> ActionBar {
        let endpointIsEmpty = editor.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // After a connection-security switch, the reconnect writes the probed root address back to the store when it finishes. Saving is blocked meanwhile,
        // because the two writes would overwrite each other; the connection test would also only test a connection that is being replaced. Both buttons wait for it to finish.
        let isReconnecting = status == .reconnecting
        return ActionBar(
            secondaryKey: testConnectionKey,
            // With an open-page baseline, judge the live record by "live record + fields changed on this page", the same criterion as the save path.
            primary: baseline.map { RelayEditSavePolicy.primaryAction(live: provider, draft: editor, baseline: $0) }
                ?? RelayEditSavePolicy.primaryAction(from: provider, editor: editor),
            isSecondaryEnabled: !isReconnecting && status != .testing && !isSaving && !endpointIsEmpty,
            isPrimaryEnabled: !isReconnecting && !isSaving && !hasFormIssues
        )
    }

    // MARK: Where validation hints land

    /// Hints that appear inside the headers group: only the "filled in but wrong" kind. Required-field hints show nothing (and so do not force the collapsed group open).
    static func issuesInHeadersGroup(_ issues: [RelayFormValidation.FieldIssue]) -> [RelayFormValidation.FieldIssue] {
        RelayFormValidation.displayableIssues(issues).filter { issueRowID(for: $0.field) != nil }
    }

    /// The remaining hints (address, connection security, key, ...) stay outside the group.
    static func issuesOutsideHeadersGroup(_ issues: [RelayFormValidation.FieldIssue]) -> [RelayFormValidation.FieldIssue] {
        issues.filter { issueRowID(for: $0.field) == nil }
    }

    /// Which kind of row a validation field maps to inside the headers group; nil for fields outside this group.
    static func issueRowID(for field: RelayFormValidation.Field) -> RowID? {
        switch field {
        case .headers: return .header
        case .queryParams: return .queryParam
        default: return nil
        }
    }

    /// The table holding the row title: "Add" is in the default table, everything else is in the Providers table. The view and the structural tests both read it from here instead of keeping separate copies.
    static func titleTable(for row: Row) -> L10n.Table {
        row.id == .addEntry ? .localizable : .providers
    }

    /// The compatibility group lists only items related to the default protocol; auto is treated as possibly using both OpenAI protocols.
    /// Exception: items that are on in the store or in the draft are shown regardless. The protocol is model-level, and these two items go along with the connection config into every model's request
    /// (the Responses / Chat request bodies of `OpenAIService` ignore the connection default protocol). When the connection's default protocol is Messages
    /// but a model on it uses Responses, the setting still takes effect, so a setting that is in effect must be visible and switchable off.
    /// `alreadyShown`: rows that already appeared during this edit session are shown without trimming.
    static func compatibilityRows(
        for transport: RelayTransport,
        serviceTierInEffect: Bool = false,
        responseStorageDisabled: Bool = false,
        alreadyShown: Set<RowID> = []
    ) -> [RowID] {
        var showsServiceTier = serviceTierInEffect || alreadyShown.contains(.serviceTier)
        var showsResponseStorage = responseStorageDisabled || alreadyShown.contains(.disableResponseStorage)
        switch transport {
        case .auto, .openaiResponses:
            showsServiceTier = true
            showsResponseStorage = true
        case .openaiChatCompletions:
            showsServiceTier = true
        case .anthropicMessages, .geminiGenerateContent, .llamacppNative:
            break
        }
        var rows: [RowID] = [.stream]
        if showsServiceTier { rows.append(.serviceTier) }
        if showsResponseStorage { rows.append(.disableResponseStorage) }
        return rows
    }

    private static func isSet(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// Filled count on the right of the headers group title: User-Agent plus headers and query parameters with a non-empty name (same counting as the entries kept on save).
    static func filledEntryCount(_ editor: RelayEditView.Editor) -> Int {
        let isBlank: (String) -> Bool = { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return (isBlank(editor.customUserAgent) ? 0 : 1)
            + editor.headers.filter { !isBlank($0.key) }.count
            + editor.queryParams.filter { !isBlank($0.key) }.count
    }

    /// Default scheme chip of the address slot: http in plaintext mode, https otherwise; if the user wrote a scheme, the user's wins.
    static func defaultScheme(for securityMode: RelayConnectionSecurityMode) -> String {
        RelayCredentialPolicy.isCleartext(securityMode) ? "http" : "https"
    }

    // MARK: Scheme split of the address slot (same rule as the add page's address slot)

    private static let schemePattern = #"^[A-Za-z][A-Za-z0-9+.-]*://"#

    /// The scheme the user wrote in the address text; nil if none.
    static func explicitScheme(in address: String) -> String? {
        guard let range = address.range(of: schemePattern, options: .regularExpression) else { return nil }
        return String(address[range].dropLast(3)).lowercased()
    }

    /// The part shown inside the slot: everything after the scheme.
    static func addressBody(_ address: String) -> String {
        guard let range = address.range(of: schemePattern, options: .regularExpression) else { return address }
        return String(address[range.upperBound...])
    }

    /// The full address after the slot content becomes `body`: pasting a full URL replaces the whole string, clearing empties the whole string, otherwise the scheme the user already wrote is kept;
    /// an address without a scheme stays as is, and normalization before saving fills it in.
    static func address(_ address: String, replacingBodyWith body: String) -> String {
        // When the slot is cleared, clear the whole string: do not leave a dangling "https://".
        if body.isEmpty { return "" }
        if body.contains("://") { return body }
        if let scheme = explicitScheme(in: address) { return "\(scheme)://\(body)" }
        return body
    }

    /// The value the address slot reports to the screen reader: the scheme chip is hidden decoration for VoiceOver, so it is joined back here and the spoken text is the full address actually requested.
    static func spokenAddress(_ address: String, securityMode: RelayConnectionSecurityMode) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if explicitScheme(in: trimmed) != nil { return trimmed }
        return "\(defaultScheme(for: securityMode))://\(trimmed)"
    }

    /// Row-model copy to UI string (the only way the view obtains it). Keys with a count are plural variants in the string table:
    /// the format string looked up is handed straight to `String(format:)`, which picks the variant by count (same approach as the repo's other plural keys).
    /// `tr` exists only so tests can switch language; production always goes through `L10n.tr`.
    static func string(
        _ text: Text,
        tr: (String, L10n.Table) -> String = { L10n.tr($0, table: $1) }
    ) -> String {
        switch text {
        case let .key(key): tr(key, .providers)
        case let .verbatim(text): text
        case let .counts(key, first, second): String(format: tr(key, .providers), Int64(first), Int64(second))
        case let .count(key, value): String(format: tr(key, .providers), Int64(value))
        case let .format(key, argument): String(format: tr(key, .providers), argument)
        case let .transport(transport): relayTransportLabel(transport)
        }
    }

    /// Compatibility items that are on / filled in the draft; the page merges them into `shownCompatibilityRows`, and the next `make` keeps showing them.
    /// Only draft values count, not the default protocol: trimming caused by switching protocol stays as before, but a row the user turned on by hand does not vanish in front of them.
    static func draftCompatibilityRows(_ editor: RelayEditView.Editor) -> Set<RowID> {
        var rows: Set<RowID> = []
        if isSet(editor.serviceTier) { rows.insert(.serviceTier) }
        if editor.disableResponseStorage { rows.insert(.disableResponseStorage) }
        return rows
    }

    /// Whether a status-row change should dismiss the keyboard and scroll to it. Only the entry that appears because the user tapped (starting a test / reconnect, a failure judged at tap time) needs it;
    /// when the in-flight entry is replaced in place by its result, it does not: it was already revealed at the start, and by the time the result arrives
    /// the user may be typing in another slot, so dismissing the keyboard would interrupt what they are typing.
    static func revealsStatusRow(previous: Status?, current: Status?) -> Bool {
        guard RelayFailureCardReveal.shouldReveal(previous: previous, current: current) else { return false }
        switch previous {
        case .testing?, .reconnecting?:
            return current == .testing || current == .reconnecting
        default:
            return true
        }
    }

    static func statusRow(_ status: Status) -> StatusRow {
        switch status {
        case .testing:
            StatusRow(tone: .progress, message: .key("Testing..."), showsProgress: true)
        case .reconnecting:
            StatusRow(tone: .progress, message: .key("Validating connection and syncing models..."), showsProgress: true)
        case .verified:
            StatusRow(tone: .success, message: .key("Connection verified."), showsProgress: false, icon: .checkCircle)
        case let .failed(message):
            StatusRow(tone: .warning, message: .verbatim(message), showsProgress: false, icon: .warning)
        }
    }

    // MARK: Rows

    private static func addressRow(_ id: RowID, editor: RelayEditView.Editor, showsPreview: Bool) -> Row {
        // "Will request ..." uses the same function as the add page; when the address cannot become a request-safe one, this row is omitted.
        let preview = showsPreview ? RelaySetupBoardModel.previewLine(detectedRoot: nil, input: editor.endpoint) : nil
        return Row(
            id: id,
            icon: .link,
            tint: RelayDetailBoardModel.iconTint(for: id == .requestURL ? .requestURL : .engineAddress),
            titleKey: id == .requestURL ? "Request URL" : "Engine address",
            footnote: preview.map { Text.format(RelaySetupBoardModel.willRequestKey, $0) },
            control: .addressInput
        )
    }

    /// Default protocol row. The protocol card of the add page's "Manual setup" uses the same row (icon, row color and the two-state footnote are not duplicated).
    static func defaultProtocolRow(_ transport: RelayTransport) -> Row {
        Row(
            id: .defaultProtocol,
            icon: .hardDrives,
            tint: RelayDetailBoardModel.iconTint(for: .defaultProtocol),
            titleKey: "Default protocol",
            value: .transport(transport),
            footnote: transport == .auto
                ? .key(protocolAutoNoteKey)
                : .format(protocolFixedNoteKey, relayTransportLabel(transport)),
            control: .menu
        )
    }

    private static func securityRow(_ editor: RelayEditView.Editor) -> Row {
        Row(
            id: .connectionSecurity,
            icon: .shieldCheck,
            tint: .teal,
            titleKey: "Connection security",
            value: .verbatim(RelaySecurityModeSummaryRow.title(for: editor.securityMode)),
            footnote: .key(securityNoteKey),
            control: .change
        )
    }

    private static func authRow(provider: Provider, editor: RelayEditView.Editor) -> Row {
        // %@ takes the title of the detail page's key row: use that row's own key instead of keeping a copy.
        let keyRowTitleKey = RelayDetailBoardModel.apiKeyRow(provider).titleKey
        return Row(
            id: .authentication,
            icon: .key,
            tint: .orange,
            titleKey: "Auth Mode",
            value: .verbatim(relayAuthLabel(editor.authMode)),
            footnote: .format(authNoteKey, L10n.tr(keyRowTitleKey, table: .providers)),
            control: .menu
        )
    }

    private static func channelRow(engineProfile: String?, editor: RelayEditView.Editor) -> Row {
        let isSelectable: Bool
        switch LocalEngineChannelCandidates.section(engineProfile: engineProfile) {
        case .selectable: isSelectable = true
        case .readOnly, nil: isSelectable = false
        }
        return Row(
            id: .channel,
            icon: .hardDrives,
            tint: RelayDetailBoardModel.iconTint(for: .channel),
            titleKey: "Channel",
            value: .transport(editor.transport),
            control: isSelectable ? .menu : .readOnly
        )
    }

    /// User-Agent, headers, query parameters, then "Add". The collapsible group of the add page's "Manual setup" uses the same set of rows.
    static func headerRows(_ editor: RelayEditView.Editor) -> [Row] {
        var rows = [Row(id: .userAgent, titleKey: "User-Agent", control: .valueInput)]
        rows += editor.headers.indices.map {
            Row(id: .header, titleKey: headersKey, control: .keyValue(masked: true), index: $0)
        }
        rows += editor.queryParams.indices.map {
            Row(id: .queryParam, titleKey: queryParamsKey, control: .keyValue(masked: false), index: $0)
        }
        rows.append(Row(id: .addEntry, titleKey: addKey, control: .add))
        return rows
    }

    private static func headersGroup(
        _ editor: RelayEditView.Editor,
        issues: [RelayFormValidation.FieldIssue]
    ) -> Group {
        let rows = headerRows(editor)
        let filled = filledEntryCount(editor)
        return Group(
            id: .headers,
            titleKey: headersGroupKey,
            isCollapsible: true,
            // Collapsed by default: the filled count in the header is meant for the collapsed state.
            startsExpanded: false,
            trailing: filled > 0 ? .count(filledCountKey, filled) : nil,
            rows: rows,
            issues: issuesInHeadersGroup(issues)
        )
    }

    private static func compatibilityRow(_ id: RowID) -> Row {
        switch id {
        case .serviceTier:
            Row(id: id, titleKey: "Service Tier", control: .valueInput)
        case .disableResponseStorage:
            Row(
                id: id,
                titleKey: "Don't keep responses in the cloud",
                footnote: .key("OpenAI Responses only · sets store: false"),
                control: .toggle
            )
        default:
            Row(id: id, titleKey: "Stream", control: .toggle)
        }
    }
}
