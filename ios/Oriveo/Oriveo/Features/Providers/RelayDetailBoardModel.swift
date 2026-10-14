import Foundation
import Observation

// MARK: - Detail page board
//
// Covers only the custom LLM family (relay and local; a non-nil engineProfile means local); official provider detail pages do not use it.
// The view renders only the copy keys, row order and button states produced here; structure tests assert on this file instead of image snapshots.

struct RelayDetailBoardModel: Equatable, Sendable {
    enum Form: Equatable, Sendable {
        case relay
        case local
    }

    enum RowID: String, Equatable, Sendable {
        case requestURL, apiKey, defaultProtocol, basePaths
        case engineAddress, engine, channel
        case modelLibrary, thinking
        /// The "Web Search" row of the relay model card; local engines have none.
        case webSearch
        /// Last row of the model card, "Parameters": moved in from the "Settings" section at the bottom of the page.
        case parameters
    }

    /// Color token of a row's leading icon; the view maps it to a value from `DetailRowPalette` / `CapabilityPalette`.
    enum RowIconTint: Equatable, Sendable {
        case teal, cyan, indigo, orange, rose
        /// Web search and thinking keep the capability colors.
        case capabilityWebSearch, capabilityReasoning
    }

    /// Each row has one color; only the large icon in the page header carries the connection's identity color. The root-address row draws no icon and returns nil.
    static func iconTint(for id: RowID) -> RowIconTint? {
        switch id {
        case .modelLibrary: return .teal
        case .requestURL, .engineAddress: return .cyan
        case .defaultProtocol, .channel: return .indigo
        case .apiKey: return .orange
        // The parameters row shares the engine row's color: it is the only one on a relay page, while on a local page the two rows sit on separate cards.
        case .engine, .parameters: return .rose
        case .webSearch: return .capabilityWebSearch
        case .thinking: return .capabilityReasoning
        case .basePaths: return nil
        }
    }

    /// Where tapping the row goes; nil means it is not tappable.
    enum Destination: Equatable, Sendable {
        case editConnection
        /// The keys page; changing the key of an implicit single key goes through the existing change-key dialog on that page.
        case apiKeys
        case modelLibrary
        /// The connection's web-search settings page.
        case webSearch
        /// The connection-level parameters page (`GenerationParameterDefaultsSheet`).
        case parameters
    }

    /// Rename / change key / delete live only on the detail page; a relay has no default-model action.
    enum Action: Equatable, Sendable {
        case rename, editAPIKey, delete
    }

    enum Text: Equatable, Sendable {
        case key(String)
        case verbatim(String)
        /// A non-plural sentence with two integers.
        case counts(String, Int, Int)
        /// A plural sentence with one integer ("%lld keys").
        case count(String, Int)
        /// A sentence with one %@ placeholder ("The engine reports %@ doesn’t support thinking.").
        case format(String, String)
        /// Protocol / channel display name via `relayTransportLabel` (`auto` reads "Auto").
        case transport(RelayTransport)
    }

    struct BasePath: Equatable, Sendable {
        let transport: RelayTransport
        let name: String
        let path: String
    }

    struct Row: Equatable, Sendable {
        let id: RowID
        let icon: PhosphorIcon
        let titleKey: String
        var value: Text? = nil
        /// Status on the right side of the row (saved / read-only).
        var trailingKey: String? = nil
        var destination: Destination? = nil
        var basePaths: [BasePath] = []
        /// With 2 or more keys, the first 3 are inlined (same read model as the keys page).
        var keys: [RelayKeysBoardModel.Row] = []
        /// N in "%lld more" when there are more than 3 keys.
        var moreKeysCount = 0
    }

    struct DetectButton: Equatable, Sendable {
        let titleKey: String
        let isEnabled: Bool
    }

    /// Trailing hint when only one key is stored: the mask already shows a key is stored, so the end of the row says more can be added.
    static let addMoreKeysKey = "Add more keys"
    /// The "Web Search" row: the title reuses "Web Search" from the Chat table, and the rest of the copy is in the Providers table.
    static let webSearchTitleKey = "Web Search"
    static let webSearchSubtitleKey = "Set this up if the service behind this connection runs its own web search"
    static let webSearchNotSetKey = "Not set up"
    static let webSearchSetKey = "Set up"
    static let editConnectionKey = "Edit connection"
    static let parametersKey = "Parameters"
    /// The top-right "Edit connection" already uses slidersHorizontal, so the same screen does not get a second slider icon.
    static let parametersIcon: PhosphorIcon = .thermometerSimple
    /// Value shown when the default protocol is auto: a bare "Auto" does not say how it is decided.
    static let autoProtocolValueKey = "Auto · detected per model"
    /// "%lld models" from the default table (Localizable), not the same-named key in the Providers table, which counts catalog models on the add page.
    static let modelsCountKey = "%lld models"
    static let keysCountKey = "%lld keys"
    static let moreKeysKey = "%lld more"
    static let inlineKeyLimit = 3
    /// Rename pencil next to the name.
    static let renameIcon: PhosphorIcon = .pencilSimple
    /// Accessibility label of the detail header avatar button = title of the avatar picker sheet (Providers table).
    static let changeIconKey = "Change icon"
    static let checkedAtKey = "Checked %@"
    static let connectionSectionKey = "Connection"
    static let modelsSectionKey = "Models"
    static let detectAgainKey = "Detect again"
    static let detectingKey = "Detecting..."
    static let footnoteAutoKey = "Detect again refreshes the catalog and each model’s protocol. Enabled models are kept."
    /// Once a protocol is chosen for the connection it is no longer probed per model, so the footnote must not still say the protocol will be refreshed.
    static let footnoteFixedKey = "Detect again refreshes the catalog. Enabled models are kept."

    // MARK: Connection problem recovery card

    /// Recovery card at the top of the detail page when a relay / local connection has a problem; official providers keep using the original card.
    struct RecoveryCard: Equatable, Sendable {
        enum ActionID: String, Equatable, Sendable {
            case editConnection, apiKeys, reverify
        }

        struct Action: Equatable, Sendable {
            let id: ActionID
            let icon: PhosphorIcon
            let titleKey: String
            /// True only for re-verify: each run is a real 1-token request, so it cannot be tapped again while running.
            var isRunning = false

            /// Actions that open another page draw a trailing chevron; re-verify runs in place and draws none.
            var opensPage: Bool { id != .reverify }
            var isEnabled: Bool { !isRunning }
        }

        let icon: PhosphorIcon
        let headlineKey: String
        /// When a key is missing the title reads "Tap to add", so the first row must be tappable too, with the same destination as the "API Keys" action. nil in other states.
        let headlineDestination: ActionID?
        /// English message key stored with the connection; the view resolves the copy through `ProviderIssueMessage.localized`. When a key is missing on this device the title already says so, so it is not repeated here.
        let detailMessageKey: String?
        let actions: [Action]
    }

    static let recoveryIssueHeadlineKey = "This connection needs attention"
    static let recoveryMissingKeyHeadlineKey = "API key not saved on this device. Tap to add it."
    static let recoveryAPIKeysKey = "API Keys"
    static let recoveryReverifyKey = "Verify again"

    /// nil means the connection is healthy or is not a custom LLM family.
    /// `omitsDetail`: a one-time notice on the page already states the same thing (the banner title of a save-without-verifying is this reason and also carries the raw failure text), so the reason row yields.
    static func recoveryCard(
        for provider: Provider,
        isReverifying: Bool = false,
        omitsDetail: Bool = false
    ) -> RecoveryCard? {
        let status = provider.effectiveStatusKind
        guard ProviderForm.of(provider) == .relay, status.isWarning else { return nil }
        let needsKey = status == .needsKey
        let lastError = provider.lastError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // The most common cause of a failed connection is the address, so edit connection comes first.
        var actions = [RecoveryCard.Action(id: .editConnection, icon: .slidersHorizontal, titleKey: editConnectionKey)]
        // Changing the key goes to the keys page: with several keys the single-key dialog would only change the primary key. A connection that needs no credentials has no such item.
        if RelayCredentialPolicy.requiresCredential(provider.relayRequested) {
            actions.append(.init(id: .apiKeys, icon: .key, titleKey: recoveryAPIKeysKey))
        }
        actions.append(.init(id: .reverify, icon: .arrowClockwise, titleKey: recoveryReverifyKey, isRunning: isReverifying))
        return RecoveryCard(
            icon: needsKey ? .key : .warning,
            headlineKey: needsKey ? recoveryMissingKeyHeadlineKey : recoveryIssueHeadlineKey,
            headlineDestination: needsKey ? .apiKeys : nil,
            detailMessageKey: needsKey || omitsDetail || lastError.isEmpty ? nil : lastError,
            actions: actions
        )
    }

    let form: Form
    /// Avatar of a relay connection; nil for local, whose header is unchanged.
    let avatar: RelayAvatar?
    let modelCount: Int
    let checkedAt: Date?
    let connectionRows: [Row]
    let modelRows: [Row]
    let deleteKey: String
    let footnoteKey: String

    /// A relay connection's detail header avatar opens the "Change icon" sheet; a local connection's header shows the engine icon and cannot be changed.
    var canChangeAvatar: Bool { avatar != nil }

    /// Actions this detail page carries: rename in the header is always there, the rest derive from the rows and the bottom buttons.
    var actions: [Action] {
        var out: [Action] = [.rename]
        if connectionRows.contains(where: { $0.destination == .apiKeys }) { out.append(.editAPIKey) }
        if !deleteKey.isEmpty { out.append(.delete) }
        return out
    }

    static func detectButton(isRunning: Bool) -> DetectButton {
        isRunning
            ? DetectButton(titleKey: detectingKey, isEnabled: false)
            : DetectButton(titleKey: detectAgainKey, isEnabled: true)
    }

    /// nil means this is not a custom LLM family and the detail page keeps its original layout.
    /// `avatarChoice`: the on-device choice for the relay avatar (`RelayAvatarChoiceStore`).
    static func make(
        _ provider: Provider,
        lastUsedModelRef: LastUsedModelRef? = nil,
        avatarChoice: String? = nil
    ) -> Self? {
        guard ProviderForm.of(provider) == .relay else { return nil }
        let engineProfile = provider.relayRequested?.engineProfile?.trimmingCharacters(in: .whitespacesAndNewlines)
        let form: Form = (engineProfile?.isEmpty == false) ? .local : .relay
        let enabledIDs = Set(provider.models.map(\.id))
        let addable = Set(provider.catalogModels.map(\.id)).subtracting(enabledIDs).count
        let enabledCount = provider.models.count

        var modelRows = [
            Row(
                id: .modelLibrary,
                icon: .database,
                titleKey: "Model Library",
                value: .counts(
                    form == .local ? "%lld enabled · %lld more on the engine" : "%lld enabled · %lld more to add",
                    enabledCount,
                    addable
                ),
                destination: .modelLibrary
            ),
        ]

        let requestedTransport = RelayEndpointResolver.requestedConnectionTransport(of: provider)
        let connectionRows: [Row]
        switch form {
        case .relay:
            var rows = [
                // The address is the field people come back to change most often, so like the default-protocol row of the same card it opens edit connection.
                Row(
                    id: .requestURL,
                    icon: .link,
                    titleKey: "Request URL",
                    value: .verbatim(provider.baseURLText ?? ""),
                    destination: .editConnection
                ),
                apiKeyRow(provider),
                Row(
                    id: .defaultProtocol,
                    icon: .hardDrives,
                    titleKey: "Default protocol · used by models without their own",
                    value: requestedTransport == .auto ? .key(autoProtocolValueKey) : .transport(requestedTransport),
                    destination: .editConnection
                ),
            ]
            let paths = basePaths(provider)
            if !paths.isEmpty {
                rows.append(Row(id: .basePaths, icon: .hardDrives, titleKey: "Base paths", basePaths: paths))
            }
            connectionRows = rows
            // Status reads the effective fragments (including the legacy-field mapping), the same set used for outgoing requests.
            let hasFragment = !(RelayWebFragmentStore.shared.chatFragments(for: provider)?.isEmpty ?? true)
            modelRows.append(Row(
                id: .webSearch,
                icon: .globe,
                titleKey: webSearchTitleKey,
                value: .key(webSearchSubtitleKey),
                trailingKey: hasFragment ? webSearchSetKey : webSearchNotSetKey,
                destination: .webSearch
            ))
        case .local:
            let engine = engineProfile.flatMap(LocalEngineKind.init(rawValue:))
            // Only when there is more than one channel candidate (llama.cpp chat / native) can it be changed from edit connection.
            let canSwitchChannel = LocalEngineChannelCandidates.showsSelector(engineProfile: engineProfile)
            connectionRows = [
                Row(
                    id: .engineAddress,
                    icon: .link,
                    titleKey: "Engine address",
                    value: .verbatim(provider.baseURLText ?? ""),
                    destination: .editConnection
                ),
                Row(
                    id: .engine,
                    icon: .plug,
                    titleKey: "Engine · detected",
                    value: .verbatim(engine.map(engineDisplayName) ?? engineProfile ?? "")
                ),
                Row(
                    id: .channel,
                    icon: .hardDrives,
                    titleKey: "Channel · same role as protocol",
                    value: .transport(RelayEndpointResolver.connectionTransport(of: provider)),
                    destination: canSwitchChannel ? .editConnection : nil
                ),
                apiKeyRow(provider),
            ]
            modelRows.append(Row(
                id: .thinking,
                icon: .brain,
                titleKey: "Thinking",
                value: thinkingText(provider, lastUsedModelRef: lastUsedModelRef),
                trailingKey: "Read-only"
            ))
        }

        // Whether the parameters row is listed is decided only by the settings-section rule; this just places it as the last row of the model card.
        if ProviderSettingsRow.rows(for: provider, hasEndpointOptions: false).contains(.parameters) {
            modelRows.append(Row(
                id: .parameters,
                icon: parametersIcon,
                titleKey: parametersKey,
                destination: .parameters
            ))
        }

        return Self(
            form: form,
            avatar: RelayAvatarResolver.avatar(for: provider, choice: avatarChoice),
            // The status line's model count is the number of distinct ids across enabled models and the catalog, matching "enabled + addable" on the model-library rows.
            modelCount: enabledIDs.union(provider.catalogModels.map(\.id)).count,
            checkedAt: provider.lastCheckedAt,
            connectionRows: connectionRows,
            modelRows: modelRows,
            deleteKey: form == .local ? "Delete connection" : "Delete Custom Relay",
            footnoteKey: requestedTransport == .auto ? footnoteAutoKey : footnoteFixedKey
        )
    }

    /// Tappable (opens the keys page) if and only if the connection needs credentials or has a stored key.
    /// S0 (no credentials needed and no key stored) shows "No key needed" and is not tappable; adding a key goes through the auth method in edit connection.
    /// S1 (credentials needed but no key stored) keeps the existing "Tap to set"; with a key it shows the mask + saved.
    /// With 2 or more keys: title row "API Keys · N keys" + the first 3 inline + "%lld more".
    /// The auth-method footnote in edit connection must name this row's title and reads the key from here instead of keeping a second copy, so it is not private.
    static func apiKeyRow(_ provider: Provider) -> Row {
        if RelayKeyBinding.showsKeyUI(provider) {
            let rows = RelayKeysBoardModel.make(provider).rows
            return Row(
                id: .apiKey,
                icon: .key,
                titleKey: "API Keys",
                value: .count(keysCountKey, rows.count),
                destination: .apiKeys,
                keys: Array(rows.prefix(inlineKeyLimit)),
                moreKeysCount: max(rows.count - inlineKeyLimit, 0)
            )
        }
        let hasKey = RelayCredentialPolicy.hasStoredKey(ProviderCredentialResolver.apiKey(provider: provider, modelID: nil))
        let requires = RelayCredentialPolicy.requiresCredential(provider.relayRequested)
        let destination: Destination? = (requires || hasKey) ? .apiKeys : nil
        guard hasKey else {
            let valueKey = requires ? "Tap to set" : "No key needed"
            return Row(id: .apiKey, icon: .key, titleKey: "API Key", value: .key(valueKey), destination: destination)
        }
        let preview = provider.apiKeyPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        return Row(
            id: .apiKey,
            icon: .key,
            titleKey: "API Key",
            value: .verbatim(preview.isEmpty ? APIKeyMask.fullyMasked : preview),
            // A connection that needs no auth but still holds a key is not nudged to add more: the end of the row stays empty.
            trailingKey: requires ? addMoreKeysKey : nil,
            destination: destination
        )
    }

    /// "Protocol name + path", in the legend's fixed order; protocols this version does not recognize are not listed.
    private static func basePaths(_ provider: Provider) -> [BasePath] {
        let roots = RelayEndpointResolver.verifiedAPIRoots(of: provider)
        return (RelayProtocolMix.legendOrder + [.llamacppNative]).compactMap { transport in
            guard let root = roots[transport] else { return nil }
            let path = URL(string: root)?.path ?? ""
            return BasePath(
                transport: transport,
                name: RelayProtocolMix.legendName(transport),
                path: path.isEmpty ? "/" : path
            )
        }
    }

    /// Three kinds of thinking-row copy: read with the same write-path decision as the chat page (`engine-expectations.v1.json` thinking.writePaths).
    /// The subject is the fallback model; for unsupported, its display name stands in the placeholder.
    private static func thinkingText(_ provider: Provider, lastUsedModelRef: LastUsedModelRef?) -> Text {
        let fallback = ProviderSelectionSnapshot.relayFallbackModel(in: provider, lastUsedModelRef: lastUsedModelRef)
        let writePath = fallback.flatMap {
            ModelOptionCapabilityShape.localEngineThinking(provider: provider, model: $0)
        }
        switch writePath {
        case .chatTemplateToggle: return .key("Follows the chat template. Set it in Model Options in chat.")
        case .unsupported:
            return .format("The engine reports %@ doesn’t support thinking.", fallback.map(\.name) ?? "")
        case .modelDefault, .nonChatNotice, nil: return .key("This engine’s current channel can’t adjust thinking. The model decides.")
        }
    }

    private static func engineDisplayName(_ engine: LocalEngineKind) -> String {
        switch engine {
        case .llamacpp: "llama.cpp"
        case .ollama: "Ollama"
        case .lmstudio: "LM Studio"
        case .vllm: "vLLM"
        case .openwebui: "Open WebUI"
        }
    }
}

/// State machine of the "Re-check" button: it cannot be tapped again while running. The recovery card's "Re-verify" uses the same one.
@MainActor
@Observable
final class RelayRedetectRunner {
    private(set) var isRunning = false

    /// Tapping again while running returns nil and does not send a second request.
    @discardableResult
    func tap(_ action: @escaping @MainActor () async -> Bool) -> Task<Bool, Never>? {
        guard !isRunning else { return nil }
        isRunning = true
        return Task { @MainActor in
            let succeeded = await action()
            isRunning = false
            return succeeded
        }
    }
}
