import Foundation

/// Pure board for Model > Advanced: an enabled model on a Relay / local connection, plus the read-only state reached from a catalog row.
/// State always calls existing functions (the vision / file / tool tri-states are the same as the model library board); this only arranges sources, controls and the five thinking cells.
struct RelayModelAdvancedBoard: Equatable {
    typealias Support = RelayCatalogBoardModel.Support

    /// Fixed order of the protocol segments.
    static let segments: [RelayTransport] = [
        .auto, .openaiChatCompletions, .openaiResponses, .anthropicMessages, .geminiGenerateContent,
    ]
    /// Reuses "Advanced" from the Localizable table.
    static let titleKey = "Advanced"
    static let restoreAllKey = "Restore all to automatic"
    static let autoEqualsKey = "Auto = %@"
    /// Once the connection protocol is chosen, Auto means "follow this connection", not a detection result; the parameter is the connection's default protocol name.
    static let autoFollowsConnectionKey = "Auto = this connection's default protocol (%@)"
    static let apiRootKey = "API root %@"
    static let capabilitiesHeaderKey = "Capabilities · auto values can be overridden"
    static let thinkingHeaderKey = "Thinking levels you can pick in chat"
    static let channelHintKey = "Change the channel in connection settings."
    /// Every change on this page is written immediately and there is no Save button, so the footer must say so.
    static let footerKey = "Changes apply right away and are saved only on this device."
    /// Key section.
    static let keySectionKey = "Key"
    static let keyAutoHintKey = "Auto = a key that lists this model"
    /// Read-only advanced view reached from a catalog row.
    static let readOnlyNoteKey = "Not enabled yet. View only. No request is sent."

    // MARK: Key section

    struct KeyOption: Equatable, Sendable {
        let id: String
        /// Name or mask (the same read model as the keys page).
        let title: String
        let maskedSecret: String
    }

    struct KeySection: Equatable, Sendable {
        /// The key currently bound.
        let current: KeyOption
        /// Every key after "Auto" in the menu, in key order.
        let options: [KeyOption]
        /// The key recomputed by the binding rule (`RelayKeyBinding.bind`).
        let autoKeyID: String
        /// The current binding equals the rule's result: the menu shows Auto.
        var isAuto: Bool { current.id == autoKeyID }
    }

    enum KeyChoice: Equatable, Sendable {
        case auto
        case key(String)
    }

    // MARK: Protocol row

    enum ProbeState: Equatable, Sendable {
        case testing, reachable, notReachable
    }

    /// Single-protocol probe result held in this page's memory; shown only when it belongs to the currently hand-picked protocol.
    struct Probe: Equatable, Sendable {
        let transport: RelayTransport
        let state: ProbeState
    }

    enum ProtocolStatus: Equatable, Sendable {
        case verified, reachable, setByYou, unknownUntilSent, notReachable, testing

        var key: String {
            switch self {
            case .verified: "Verified"
            case .reachable: "Reachable"
            case .setByYou: "Set by you"
            case .unknownUntilSent: "Unknown · remembered after sending"
            case .notReachable: "Not reachable"
            case .testing: "Testing..."
            }
        }

        var table: L10n.Table {
            self == .unknownUntilSent ? .chat : .providers
        }
    }

    /// What Auto means when selected: the two cases must not share one sentence.
    enum AutoMeaning: Equatable {
        /// The connection protocol is auto, or the model already has a detected / remembered-after-send protocol: Auto = that result.
        case detected(RelayTransport)
        /// The connection protocol is chosen and the model has no protocol of its own: Auto = follow this connection's default protocol.
        case followsConnection(RelayTransport)
    }

    /// One segment of the description line: copy key, the table it lives in, and parameters (untranslated values such as protocol name and path).
    struct ExplainPart: Equatable {
        let key: String
        let table: L10n.Table
        var argument: String?
    }

    /// The protocol card description has two lines: the first only says what Auto means, the second is the status and root address.
    struct ProtocolExplain: Equatable {
        /// nil = the model has its own protocol (Auto not selected), so only the second line is shown.
        let autoLine: ExplainPart?
        /// Segments are joined with " · ".
        let detailLine: [ExplainPart]
    }

    enum ProtocolRow: Equatable {
        /// `auto` has a value only when Auto is selected; `apiRootPath` is the path of effectiveAPIRoot.
        case relay(selected: RelayTransport, auto: AutoMeaning?, status: ProtocolStatus, apiRootPath: String)
        /// Local engine: the channel is read-only; a footnote appears when the engine has more than one channel.
        case local(channel: RelayTransport, showsChannelHint: Bool)

        /// The local channel card has no description line.
        var explain: ProtocolExplain? {
            guard case let .relay(_, auto, status, apiRootPath) = self else { return nil }
            let autoLine: ExplainPart?
            switch auto {
            case let .detected(transport)?:
                autoLine = ExplainPart(
                    key: RelayModelAdvancedBoard.autoEqualsKey, table: .providers,
                    argument: RelayProtocolMix.legendName(transport)
                )
            case let .followsConnection(transport)?:
                autoLine = ExplainPart(
                    key: RelayModelAdvancedBoard.autoFollowsConnectionKey, table: .providers,
                    argument: RelayProtocolMix.legendName(transport)
                )
            case nil:
                autoLine = nil
            }
            return ProtocolExplain(
                autoLine: autoLine,
                detailLine: [
                    ExplainPart(key: status.key, table: status.table),
                    ExplainPart(key: RelayModelAdvancedBoard.apiRootKey, table: .providers, argument: apiRootPath),
                ]
            )
        }
    }

    // MARK: Four capability rows

    enum Capability: CaseIterable, Equatable, Sendable {
        case image, file, imageGeneration, toolCall

        var overrideKey: RelayCapabilityOverrides.Key {
            switch self {
            case .image: .image
            case .file: .file
            case .imageGeneration: .imageGeneration
            case .toolCall: .toolCall
            }
        }

        var icon: PhosphorIcon {
            switch self {
            case .image: .eye
            case .file: .paperclip
            case .imageGeneration: .image
            case .toolCall: .wrench
            }
        }

        var titleKey: String {
            switch self {
            case .image: "Vision"
            case .file: "Files"
            case .imageGeneration: "Image generation"
            case .toolCall: "Tool calls"
            }
        }

        var titleTable: L10n.Table {
            self == .image ? .chat : .providers
        }

        /// Image generation has no remember-after-send mechanism, so unknown just says "Unknown".
        var unknownKey: String {
            self == .imageGeneration ? "Unknown" : "Unknown · remembered after sending"
        }

        var unknownTable: L10n.Table {
            self == .imageGeneration ? .localizable : .chat
        }
    }

    /// Source badge (in the fixed order of the capability source ranking); Gateway / Server facts are not drawn in this unit.
    enum Source: CaseIterable, Equatable, Sendable {
        case catalog, detected, tested, engine, user

        var key: String {
            switch self {
            case .catalog: "Official catalog"
            case .detected: "Detected"
            case .tested: "Tested"
            case .engine: "Engine declared"
            case .user: "Set by you"
            }
        }

        var icon: PhosphorIcon {
            switch self {
            case .catalog: .database
            case .detected: .scan
            case .tested: .checkCircle
            case .engine: .hardDrives
            case .user: .user
            }
        }
    }

    enum Control: CaseIterable, Equatable, Sendable {
        case auto, on, off

        var value: Bool? {
            switch self {
            case .auto: nil
            case .on: true
            case .off: false
            }
        }
    }

    struct CapabilityRow: Equatable {
        let capability: Capability
        let state: Support
        /// nil = no source (unknown draws no badge).
        let source: Source?
        let control: Control
    }

    // MARK: Five thinking cells

    struct ThinkingCell: Equatable {
        let mode: ReasoningMode
        /// Not in the automatic set = strikethrough, not tappable.
        let isAvailable: Bool
        let isSelected: Bool
        /// Struck-through cells and the last selected cell are not tappable.
        let isToggleable: Bool
    }

    enum Thinking: Equatable {
        case cells([ThinkingCell])
    }

    // MARK: Cards

    /// The cards of the page from top to bottom; the view draws this list, and a card with no content is not in it.
    enum Card: Equatable {
        case protocolOrChannel, key, capabilities, thinking
    }

    // MARK: Output

    let modelName: String
    let host: String?
    let restoreAllEnabled: Bool
    let protocolRow: ProtocolRow
    let capabilityRows: [CapabilityRow]
    /// nil = no thinking card: a local engine uses a template switch; when the automatic set is empty there is nothing to adjust, so the whole card is omitted.
    let thinking: Thinking?
    let legend: [Source]
    /// "Test capability" entry (the criteria are unchanged); not shown in read-only state.
    let showsTestEntry: Bool
    /// nil = fewer than 2 keys (or a local connection), so no Key section.
    let keySection: KeySection?
    /// A not-enabled model reached from a catalog row: one sentence at the top, all controls inoperable, opening sends no request.
    let isReadOnly: Bool

    var controlsEnabled: Bool { !isReadOnly }

    /// The read-only state can change nothing, so the "changes take effect immediately" footer is omitted.
    var showsFooter: Bool { !isReadOnly }

    var cards: [Card] {
        var cards: [Card] = [.protocolOrChannel]
        if keySection != nil { cards.append(.key) }
        cards.append(.capabilities)
        if thinking != nil { cards.append(.thinking) }
        return cards
    }

    static func make(
        provider: Provider,
        model: AIModel,
        partitionID: String,
        now: Date = Date(),
        probe: Probe? = nil,
        negativeCache: RelayNegativeCache = .shared,
        toolMemory: ToolCallMemoryStore = .shared,
        readOnly: Bool = false
    ) -> Self {
        let isLocal = RelayCatalogBoardModel.isLocal(provider)
        let overrides = model.relayCapabilityOverrides
        return Self(
            modelName: model.name,
            host: URL(string: provider.baseURLText ?? "")?.host,
            restoreAllEnabled: !readOnly && ((overrides.map { !$0.isEmpty } ?? false)
                || (model.relayTransport != nil && model.relayTransportSource == .user)),
            protocolRow: protocolRow(provider: provider, model: model, probe: probe),
            capabilityRows: Capability.allCases.map {
                capabilityRow(
                    $0, provider: provider, model: model, partitionID: partitionID, now: now,
                    negativeCache: negativeCache, toolMemory: toolMemory
                )
            },
            thinking: isLocal ? nil : thinking(provider: provider, model: model),
            legend: isLocal ? [.engine, .user] : [.catalog, .detected, .tested, .user],
            showsTestEntry: !readOnly && RelayCapabilityTest.showsEntry(provider: provider, model: model),
            keySection: isLocal ? nil : keySection(provider: provider, modelID: model.id, readOnly: readOnly),
            isReadOnly: readOnly
        )
    }

    // MARK: Key section parts

    /// Present only with 2 or more keys. Current binding = `modelState.boundKeyID`; read-only (not enabled) has no binding, so current = the key the rule would pick.
    static func keySection(provider: Provider, modelID: String, readOnly: Bool) -> KeySection? {
        guard RelayKeyBinding.showsKeyUI(provider) else { return nil }
        let options = RelayKeysBoardModel.make(provider).rows.map {
            KeyOption(id: $0.id, title: $0.title, maskedSecret: $0.maskedSecret)
        }
        let autoKeyID = autoKeyID(provider: provider, modelID: modelID)
        let currentID = readOnly
            ? autoKeyID
            : (RelayKeyBinding.modelState(provider, modelID: modelID)?.boundKeyID ?? autoKeyID)
        guard let current = options.first(where: { $0.id == currentID }) ?? options.first else { return nil }
        return KeySection(current: current, options: options, autoKeyID: autoKeyID)
    }

    /// "Auto" = treat this model as newly enabled and recompute by the binding rule (ignoring its own current binding); no "follow auto" marker is added.
    static func autoKeyID(provider: Provider, modelID: String) -> String {
        var others = provider
        others.models.removeAll { $0.id == modelID }
        return ProviderManager.relayBoundKeyID(for: modelID, in: others)
            ?? RelayKeyBinding.keyIDs(provider).first
            ?? RelayKeyBinding.implicitKeyID
    }

    /// The key operation to write when a menu item is picked; nil (nothing written) when read-only or the pick is already the current key.
    static func keyOperation(
        _ choice: KeyChoice,
        section: KeySection,
        modelID: String,
        readOnly: Bool = false
    ) -> RelayKeyBinding.Operation? {
        guard !readOnly else { return nil }
        let target: String = switch choice {
        case .auto: section.autoKeyID
        case let .key(id): id
        }
        guard target != section.current.id, section.options.contains(where: { $0.id == target }) else { return nil }
        return .rebind(modelID: modelID, keyID: target)
    }

    // MARK: Parts

    static func protocolRow(provider: Provider, model: AIModel, probe: Probe?) -> ProtocolRow {
        // An unverified model says "Auto = ..." according to the protocol actually sent first, the same answer as sending and the negative cache.
        let effective = RelayFirstSendTransport.current(provider: provider, model: model)
        if RelayCatalogBoardModel.isLocal(provider) {
            return .local(
                channel: effective,
                showsChannelHint: LocalEngineChannelCandidates.showsSelector(
                    engineProfile: provider.relayRequested?.engineProfile
                )
            )
        }
        let userTransport = model.relayTransportSource == .user ? model.relayTransport : nil
        let selected = userTransport ?? .auto
        var status = baseStatus(provider: provider, model: model)
        if let probe, let userTransport, probe.transport == userTransport {
            switch probe.state {
            case .testing: status = .testing
            case .reachable: status = .reachable
            case .notReachable: status = .notReachable
            }
        }
        let root = RelayEndpointResolver.effectiveAPIRoot(provider: provider, model: model)
        let path = URL(string: root)?.path ?? ""
        var auto: AutoMeaning?
        if selected == .auto {
            // Same criterion as the "user-set" label on the model library row: when following the connection, do not present it as a detection result.
            auto = RelayProbeCandidates.followsUserChosenConnection(provider: provider, model: model)
                ? .followsConnection(effective) : .detected(effective)
        }
        return .relay(
            selected: selected,
            auto: auto,
            status: status,
            apiRootPath: path.isEmpty ? "/" : path
        )
    }

    /// Reuses the status wording of the enabled rows in the model library.
    private static func baseStatus(provider: Provider, model: AIModel) -> ProtocolStatus {
        switch RelayCatalogBoardModel.status(
            provider: provider, model: model, section: .enabled, isMissingFromCatalog: false, caps: []
        ) {
        case .verified?: .verified
        case .reachable?: .reachable
        case .setByYou?: .setByYou
        case .unknownUntilSent?, .missingFromCatalog?, .verifyOnEnable?, .deniedOnCurrentKey?, .verifying?, .unreachable?, nil:
            .unknownUntilSent
        }
    }

    static func capabilityRow(
        _ capability: Capability,
        provider: Provider,
        model: AIModel,
        partitionID: String,
        now: Date,
        negativeCache: RelayNegativeCache,
        toolMemory: ToolCallMemoryStore
    ) -> CapabilityRow {
        let overridden = model.relayCapabilityOverrides?.value(for: capability.overrideKey)
        let state: Support
        switch capability {
        case .image, .toolCall:
            // The existing tri-state functions already factor overrides in (the highest source for vision / tools).
            state = RelayCatalogBoardModel.support(
                capability == .image ? .image : .tool,
                provider: provider, model: model, partitionID: partitionID, now: now, negativeCache: negativeCache
            )
        case .file:
            state = overridden.map { $0 ? .supported : .unsupported } ?? RelayCatalogBoardModel.support(
                .file, provider: provider, model: model, partitionID: partitionID, now: now, negativeCache: negativeCache
            )
        case .imageGeneration:
            state = overridden.map { $0 ? .supported : .unsupported }
                ?? (model.capabilities.contains(.imageGen) ? .supported : .unknown)
        }
        return CapabilityRow(
            capability: capability,
            state: state,
            source: source(
                capability, provider: provider, model: model, now: now,
                negativeCache: negativeCache, toolMemory: toolMemory
            ),
            control: overridden.map { $0 ? .on : .off } ?? .auto
        )
    }

    /// Take the first hit in the fixed order: user > tested > engine declaration (engineProfile only) > negative cache / tool memory > official catalog > none.
    static func source(
        _ capability: Capability,
        provider: Provider,
        model: AIModel,
        now: Date,
        negativeCache: RelayNegativeCache,
        toolMemory: ToolCallMemoryStore
    ) -> Source? {
        let key = capability.overrideKey
        if let overrides = model.relayCapabilityOverrides, overrides.value(for: key) != nil {
            return (overrides.sources[key] ?? .user) == .user ? .user : .tested
        }
        if RelayCatalogBoardModel.isLocal(provider) {
            let declared: Bool? = switch capability {
            case .image: model.engineDeclaration?.image
            case .toolCall: model.engineDeclaration?.toolCall
            case .file, .imageGeneration: nil
            }
            // A local connection draws only engine declaration / manual / tested (the same scope as the legend).
            return declared != nil ? .engine : nil
        }
        let cacheKind: RelayNegativeCache.Kind? = switch capability {
        case .image: .image
        case .file: .file
        case .toolCall: .toolCall
        case .imageGeneration: nil
        }
        if let cacheKind, negativeCache.isRejected(
            connectionID: provider.id.uuidString, modelID: model.id,
            transport: RelayFirstSendTransport.current(provider: provider, model: model).rawValue,
            kind: cacheKind, now: now
        ) {
            return .detected
        }
        if capability == .toolCall, toolMemory.lookup(connectionID: provider.id, modelID: model.id)?.toolCall == true {
            return .detected
        }
        let inherited: Bool = switch capability {
        case .image: model.capabilities.contains(.image)
        case .file: !model.nativeFileMimes.isEmpty
        case .imageGeneration: model.capabilities.contains(.imageGen)
        case .toolCall: model.toolCall != nil
        }
        return inherited ? .catalog : nil
    }

    static func thinking(provider: Provider, model: AIModel) -> Thinking? {
        let automatic = RelayReasoningLevelOverride.automaticModes(provider: provider, model: model)
        guard !automatic.isEmpty else { return nil }
        let narrowed = model.relayCapabilityOverrides?.reasoningLevels.map { levels in
            automatic.filter { levels.contains($0.rawValue) }
        }
        let selected = Set((narrowed?.isEmpty == false ? narrowed : nil) ?? automatic)
        return .cells(ReasoningMode.allCases.map { mode in
            let isAvailable = automatic.contains(mode)
            let isSelected = selected.contains(mode)
            return ThinkingCell(
                mode: mode,
                isAvailable: isAvailable,
                isSelected: isSelected,
                isToggleable: isAvailable && !(isSelected && selected.count == 1)
            )
        })
    }

    /// The set of levels to write after tapping a cell (original contract values, in the five-cell order); nil when the cell is not tappable.
    static func levelsAfterToggling(_ mode: ReasoningMode, cells: [ThinkingCell]) -> [String]? {
        guard let cell = cells.first(where: { $0.mode == mode }), cell.isToggleable else { return nil }
        return cells.filter { $0.mode == mode ? !$0.isSelected : $0.isSelected }.map(\.mode.rawValue)
    }
}
