import Foundation

// MARK: - Manual setup board (ManualSetup)
//
// "Add relay > Manual setup" is a single page: the same page shell as quick setup step 1, plus three things: models, default protocol, and the collapsed authentication and headers group.
// The view renders exactly the section order, rows, footnotes and primary button produced here; structural tests assert on this model instead of image snapshots.
// Rows in the protocol card and the collapsed group are taken directly from the edit-connection board, so the same row looks the same on both pages.

struct RelayManualSetupBoardModel: Equatable {
    typealias Text = RelayDetailBoardModel.Text
    typealias Group = RelayEditBoardModel.Group
    typealias Row = RelayEditBoardModel.Row

    /// The sections of the page from top to bottom; `failure` appears at the end of the form only after a verification failure.
    enum Section: String, Equatable, Sendable {
        case requestURL, apiKeys, model, connectionName, protocolCard, advanced, failure
    }

    struct Hero: Equatable {
        let icon: PhosphorIcon
        let labelKey: String
        let titleKey: String
        let subtitleKey: String
        /// Trailing label: tells the user they are on the manual path.
        let trailingKey: String
    }

    /// An input block on the page background: title row (icon + title) -> input slot -> footnote.
    struct Field: Equatable {
        let titleKey: String
        let icon: PhosphorIcon
        /// Placeholder label on the leading side of the slot ("Name (optional)" in the connection name slot).
        var slotLabelKey: String? = nil
        var placeholder = ""
        var footnote: Text? = nil
    }

    struct Primary: Equatable {
        let titleKey: String
        let showsProgress: Bool
        let isEnabled: Bool
    }

    struct Input {
        var endpoint = ""
        /// The line below the address slot, the same value as in step 1 (`RelayQuickSetupFlow.previewLine`).
        var previewLine: String? = nil
        var keyCount = 1
        var modelID = ""
        var transport: RelayTransport = .auto
        var authMode: RelayAuthMode = .auto
        var customUserAgent = ""
        var headers: [RelayKeyValue] = []
        var queryParams: [RelayKeyValue] = []
        /// Whether the shared form validation or the character set of the extra keys blocked anything.
        var hasFormIssues = false
        /// The verdict of the shared form validation, used only to decide where each hint appears.
        var issues: [RelayFormValidation.FieldIssue] = []
        var isValidating = false
        var failure: OriveoError? = nil
    }

    static let heroTrailingKey = "Manual setup"
    static let heroSubtitleKey = "Fill in the address, key, model and protocol yourself. One tiny request is sent before saving to confirm it works."
    static let modelNoteKey = "Enter the model ID exactly as your Custom Relay lists it. You can add more from the model library later."
    static let connectionNameKey = "Connection name"
    static let connectionNameNoteKey = "Leave it empty to use the domain from the address."
    static let protocolGroupKey = "Protocol"
    static let advancedGroupKey = "Authentication, headers & query params"
    static let notSetKey = "Not set"
    static let quickSetupKey = "Use quick setup"
    static let validateAndSaveKey = "Validate and save"
    static let validateAgainKey = "Validate again"
    static let notSavedKey = "The connection hasn’t been saved yet."
    static let saveAnywayKey = "Save anyway (unverified)"
    static let addressPlaceholder = "https://api.example.com"

    /// Candidates of the default protocol menu: the same set as the edit-connection page.
    static var transportOptions: [RelayTransport] {
        LocalEngineChannelCandidates.transportOptions(engineProfile: nil)
    }

    let hero: Hero
    let sections: [Section]
    let address: Field
    /// Slots in the key block: the same set as step 1 (a name slot appears only with two or more keys).
    let keySlots: [SetupInputSlot]
    let keysNoteKey: String
    /// Validation hints below the key block: everything except those already placed in the collapsed group.
    let keyIssues: [RelayFormValidation.FieldIssue]
    let model: Field
    let connectionName: Field
    let protocolGroup: Group
    let advancedGroup: Group
    /// Summary on the right of the collapsed group title: current authentication method · filled count. The view joins them into one sentence with `summaryString`.
    let advancedSummary: [Text]
    /// The failure card; nil = no failure (or the input changed after the failure).
    let failure: OriveoError?
    let primary: Primary

    static func make(_ input: Input) -> Self {
        // The protocol card and the header rows both come from the edit-connection board: give it an editor draft carrying only these items.
        var editor = RelayEditView.Editor.empty
        editor.transport = input.transport
        editor.authMode = input.authMode
        editor.customUserAgent = input.customUserAgent
        editor.headers = input.headers
        editor.queryParams = input.queryParams

        let filled = RelayEditBoardModel.filledEntryCount(editor)
        // The edit page's "manage keys on the connection page" footnote does not apply here (the connection does not exist yet), so the authentication row carries no footnote.
        let authRow = Row(
            id: .authentication,
            icon: .key,
            tint: .orange,
            titleKey: "Auth Mode",
            value: .verbatim(relayAuthLabel(input.authMode)),
            control: .menu
        )
        let modelIsEmpty = input.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        var sections: [Section] = [.requestURL, .apiKeys, .model, .connectionName, .protocolCard, .advanced]
        if input.failure != nil { sections.append(.failure) }

        return Self(
            hero: Hero(
                icon: .hardDrives,
                labelKey: RelaySetupBoardModel.heroLabelKey,
                titleKey: RelaySetupBoardModel.heroTitleKey,
                subtitleKey: heroSubtitleKey,
                trailingKey: heroTrailingKey
            ),
            sections: sections,
            address: Field(
                titleKey: "Request URL",
                icon: .link,
                placeholder: addressPlaceholder,
                footnote: input.previewLine.map { .format(RelaySetupBoardModel.willRequestKey, $0) }
            ),
            keySlots: RelaySetupBoardModel.slots(keyCount: input.keyCount).filter { $0 != .address },
            keysNoteKey: RelaySetupBoardModel.keysLocalKey,
            keyIssues: RelayEditBoardModel.issuesOutsideHeadersGroup(input.issues),
            model: Field(
                titleKey: "Model",
                icon: .squaresFour,
                // Give a real model ID as the placeholder: it explains the expected format better than "Enter model ID".
                placeholder: RelayModelPlaceholder.current,
                footnote: .key(modelNoteKey)
            ),
            connectionName: Field(
                titleKey: connectionNameKey,
                icon: .pencilSimple,
                slotLabelKey: RelaySetupBoardModel.keyNameKey,
                // This is the domain that gets stored when the field is left empty (the fallback in `registerRelay`); the placeholder lets the user see the result up front.
                placeholder: ProviderManager.relayDomainName(from: input.endpoint) ?? "",
                footnote: .key(connectionNameNoteKey)
            ),
            protocolGroup: Group(
                id: .protocolAuth,
                titleKey: protocolGroupKey,
                rows: [RelayEditBoardModel.defaultProtocolRow(input.transport)]
            ),
            advancedGroup: Group(
                id: .headers,
                titleKey: advancedGroupKey,
                isCollapsible: true,
                // Collapsed by default: the summary in the header is meant for the collapsed state.
                startsExpanded: false,
                rows: [authRow] + RelayEditBoardModel.headerRows(editor),
                // Hints for wrong headers / query parameters appear below the matching row inside the group and force the group open (same rule as edit connection).
                issues: RelayEditBoardModel.issuesInHeadersGroup(input.issues)
            ),
            advancedSummary: [
                .verbatim(relayAuthLabel(input.authMode)),
                filled > 0 ? .count(RelayEditBoardModel.filledCountKey, filled) : .key(notSetKey),
            ],
            failure: input.failure,
            primary: Primary(
                // After a failure the primary button changes its wording: tapping again re-verifies instead of saving.
                titleKey: input.failure != nil ? validateAgainKey : validateAndSaveKey,
                showsProgress: input.isValidating,
                // Without a model there is no verification request to send.
                isEnabled: !input.isValidating && !input.hasFormIssues && !modelIsEmpty
            )
        )
    }

    /// Joins the summary segments into one sentence ("Auto · Not set"). `tr` exists only so tests can switch language.
    static func summaryString(
        _ parts: [Text],
        tr: (String, L10n.Table) -> String = { L10n.tr($0, table: $1) }
    ) -> String {
        parts.map { RelayEditBoardModel.string($0, tr: tr) }.joined(separator: " · ")
    }
}
