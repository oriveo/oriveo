import Foundation

/// State of the lazy verification of enabled models in this session's memory: not persisted, cleared on success / rebind / re-detection;
/// when the effective key's value changes, it clears the "unreachable" bound to that key and lazily verifies once more those without a protocol, and a successful send clears that model's;
/// a successful catalog fetch / a normal key-status write-back do not clear it (a relay may gate only one protocol); "verifying" is ended only by the in-flight lazy verification wrapping up.
enum RelayModelProbeState: Equatable, Sendable {
    case inFlight
    case failed(RelayModelProbeFailure)
}

/// The reason of the last attempt when all lazy-verification candidates fail: one sentence from the existing failure classification (already localized) + the upstream status code (nil if unavailable).
struct RelayModelProbeFailure: Equatable, Sendable {
    let summary: String
    let httpStatus: Int?
}

/// Board of the Relay / local connection > model library sub-page.
/// It consumes only existing verdicts (image entry, negative cache, tool ruling, evidence facade) and does not set up a second set of capability rules.
/// Rows are computed individually on demand (`row`): the catalog may have hundreds of rows, and computing all of them at once would put the whole capability projection on the first frame.
struct RelayCatalogBoardModel: Equatable {
    enum SectionID: String, Equatable, Sendable {
        case enabled, library
    }

    enum Filter: Hashable, Sendable {
        case all
        case transport(RelayTransport)
        /// Show only models listed by one key; the chip appears only when in effect.
        case key(String)
    }

    enum Capability: CaseIterable, Equatable, Sendable {
        case image, file, thinking, tool, web

        var icon: PhosphorIcon {
            switch self {
            case .image: .eye
            case .file: .paperclip
            case .thinking: .brain
            case .tool: .wrench
            case .web: .globe
            }
        }

        /// Capability names in screen-reader alt text: reuse the existing ones from the Advanced page / model options, with no new copy.
        var titleKey: String {
            switch self {
            case .image: "Vision"
            case .file: "Files"
            case .thinking: "Thinking"
            case .tool: "Tool calls"
            case .web: "Web Search"
            }
        }

        var titleTable: L10n.Table {
            switch self {
            case .image, .web: .chat
            case .file, .thinking, .tool: .providers
            }
        }
    }

    enum Support: Equatable, Sendable {
        case supported, unknown, unsupported

        /// Status words in screen-reader alt text: the same group as the capability rows on the Advanced page.
        var key: String {
            switch self {
            case .supported: "Supported"
            case .unknown: "Unknown"
            case .unsupported: "Not supported"
            }
        }

        var table: L10n.Table {
            self == .unknown ? .localizable : .providers
        }
    }

    enum Status: Equatable, Sendable {
        case missingFromCatalog
        case verified
        case reachable
        case setByYou
        case unknownUntilSent
        case verifyOnEnable
        /// The currently effective key is judged to have no access to this model (`modelState.deniedOnCurrentKey`).
        case deniedOnCurrentKey
        /// Lazy verification of this model is in flight.
        case verifying
        /// Lazy verification of this model failed in this session; tap to see the reason.
        case unreachable(RelayModelProbeFailure)

        var key: String {
            switch self {
            case .missingFromCatalog: "No longer in the catalog"
            case .verified: "Verified"
            case .reachable: "Reachable"
            case .setByYou: "Set by you"
            case .unknownUntilSent: "Unknown · remembered after sending"
            case .verifyOnEnable: "Verified when enabled"
            case .deniedOnCurrentKey: "Current key has no access"
            case .verifying: "Verifying…"
            case .unreachable: "Not reachable · See why"
            }
        }

        /// "Unknown · remembered after sending" reuses the model options entry (Chat table); the others are in the Providers table.
        var table: L10n.Table {
            self == .unknownUntilSent ? .chat : .providers
        }
    }

    /// Where tapping the row itself goes: an enabled row goes to "Model > Advanced", a catalog row goes to the read-only Advanced.
    enum TapTarget: Equatable, Sendable {
        case advanced, readOnlyAdvanced
    }

    /// Trailing actions from start to end: enabled = start a new chat + "...", catalog = plus sign / unavailable.
    enum Trailing: Hashable, Sendable {
        case newChat, more, add, unavailable
    }

    /// The remove item in "...". When only one model is left the menu stays, and this item is dimmed with a reason --
    /// when the whole menu disappears the user cannot tell whether removal is disallowed or the feature does not exist.
    struct RemoveItem: Equatable, Sendable {
        let isEnabled: Bool
        /// The reason when dimmed; nil when removable.
        let disabledReasonKey: String?
    }

    struct Row: Equatable {
        let id: String
        let name: String
        /// nil = local connection (the channel is connection-level, so no protocol chip is drawn).
        let protocolTransport: RelayTransport?
        /// Order is the same as `Capability.allCases`.
        let caps: [Support]
        let status: Status?
        let tapTarget: TapTarget
        let trailing: [Trailing]
        /// Only enabled rows have it; nil for catalog rows.
        let removeItem: RemoveItem?
        /// With 2 or more keys, the key chip on enabled rows: the name or mask of the bound key; nil otherwise.
        let keyChip: String?
    }

    /// One row per key at the top of the catalog area (2 or more keys).
    struct KeyStatusItem: Equatable {
        enum State: Equatable {
            case ok
            /// Failure: "<code> <status word>"; with no status code, only the status word.
            case failed(httpStatus: Int?, statusKey: String)
            /// The catalog of this key has not been fetched yet.
            case unchecked
        }

        let id: String
        let title: String
        let catalogCount: Int
        let state: State

        /// Refresh only this key (the onlyKeyID refresh).
        var showsRetry: Bool {
            if case .failed = state { return true }
            return false
        }
    }

    /// What the model library catalog area draws from top to bottom (only for relay / local model library pages).
    enum LibraryBlock: Equatable, Sendable {
        case loading
        case keyStatusBar
        case failureCard
        case catalog
    }

    enum FailureCardAction: Equatable, Sendable {
        case retry
    }

    struct Section: Equatable {
        let id: SectionID
        let titleKey: String
        let count: Int
        let rows: [Row]
    }

    struct LegendItem: Equatable {
        let support: Support
        let key: String
    }

    static let enabledSectionKey = "Enabled · %lld"
    static let unreachableTitleKey = "Why it isn’t reachable"
    static let failureCardTitleKey = "Couldn’t get the model list"
    /// The failure card has only retry; the manual-add entry appears in a single place at the bottom of the whole page.
    static let failureCardActions: [FailureCardAction] = [.retry]
    static let enableHintKey = "Enabling sends 1 tiny request to confirm the model works. Tap a model in the catalog to view Advanced first. No request is sent."
    /// Enable hint when the connection protocol is not auto: enabling does not probe, so only the second half remains.
    static let enableHintChosenProtocolKey = "Tap a model in the catalog to view Advanced first. No request is sent."
    static let removeDisabledReasonKey = "This connection needs at least one model."
    /// "Enable all" in the catalog group header (board Catalog); the English source text matches the Web at the same position.
    static let enableAllKey = "Add All"
    static let librarySectionKey = "Model library · %lld"
    static let footnoteKey = "Sources are shown only in Advanced"
    static let legend: [LegendItem] = [
        .init(support: .supported, key: "Two-tone = supported"),
        .init(support: .unknown, key: "Gray = unknown"),
        .init(support: .unsupported, key: "Dim = not supported"),
    ]
    /// Fixed order of the filter chips.
    static let filterOrder: [RelayTransport] = [
        .openaiChatCompletions, .openaiResponses, .anthropicMessages, .geminiGenerateContent,
    ]

    /// Empty = no chips (fewer than two distinct protocols, or a local connection).
    let filters: [Filter]
    /// Always `.all` when the chips are not shown.
    let selectedFilter: Filter
    let sections: [Section]

    static func make(
        provider: Provider,
        enabledModels: [AIModel],
        catalogModels: [AIModel],
        filter: Filter,
        partitionID: String,
        now: Date,
        negativeCache: RelayNegativeCache = .shared,
        probeStates: [String: RelayModelProbeState] = [:]
    ) -> Self {
        let enabledIDs = Set(enabledModels.map(\.id))
        let libraryModels = catalogModels.filter { !enabledIDs.contains($0.id) }
        let filters = filters(provider: provider, models: enabledModels + libraryModels, current: filter)
        let selected = effectiveFilter(filter, available: filters)
        let membership = RelayCatalogMembership.Index(provider: provider)

        let enabledRows = enabledModels
            .filter { matches(selected, provider: provider, model: $0) }
            .map {
                row(
                    provider: provider, model: $0, section: .enabled,
                    isMissingFromCatalog: membership.isMissingEnabledModel($0),
                    partitionID: partitionID, now: now, negativeCache: negativeCache,
                    probeState: probeStates[$0.id]
                )
            }
        let libraryRows = libraryModels
            .filter { matches(selected, provider: provider, model: $0) }
            .map {
                row(
                    provider: provider, model: $0, section: .library, isMissingFromCatalog: false,
                    partitionID: partitionID, now: now, negativeCache: negativeCache
                )
            }
        return Self(
            filters: filters,
            selectedFilter: selected,
            sections: [
                Section(id: .enabled, titleKey: enabledSectionKey, count: enabledModels.count, rows: enabledRows),
                Section(
                    id: .library, titleKey: librarySectionKey,
                    count: libraryCount(enabledModels: enabledModels, catalogModels: catalogModels), rows: libraryRows
                ),
            ]
        )
    }

    // MARK: Split-out parts (the view calls them section by section / row by row, using the same implementation as `make`)

    static func isLocal(_ provider: Provider) -> Bool {
        let profile = provider.relayRequested?.engineProfile?.trimmingCharacters(in: .whitespacesAndNewlines)
        return profile?.isEmpty == false
    }

    /// Catalog count = catalog minus enabled (the same convention as the "N can be added" on the detail page's model library row).
    static func libraryCount(enabledModels: [AIModel], catalogModels: [AIModel]) -> Int {
        Set(catalogModels.map(\.id)).subtracting(enabledModels.map(\.id)).count
    }

    static func protocolTransport(provider: Provider, model: AIModel) -> RelayTransport? {
        // The protocol column and the filter use the protocol actually sent first (Claude-family auto first-sends Messages), the same answer as sending.
        isLocal(provider) ? nil : RelayFirstSendTransport.current(provider: provider, model: model)
    }

    /// When `current` is key(id) and that key still exists and the catalog is non-zero, the key chip is placed after All; otherwise it does not appear.
    static func filters(provider: Provider, models: [AIModel], current: Filter = .all) -> [Filter] {
        guard !isLocal(provider) else { return [] }
        let present = Set(models.compactMap { protocolTransport(provider: provider, model: $0) })
        let ordered = filterOrder.filter(present.contains)
        let transports = ordered.count >= 2 ? ordered.map(Filter.transport) : []
        if case let .key(keyID) = current, isListingKey(provider: provider, keyID: keyID) {
            return [.all, current] + transports
        }
        return transports.isEmpty ? [] : [.all] + transports
    }

    /// The key still exists and its catalog is non-zero.
    private static func isListingKey(provider: Provider, keyID: String) -> Bool {
        let ids = RelayKeyBinding.keyIDs(provider)
        guard ids.contains(keyID) else { return false }
        return provider.catalogModels.contains { RelayKeyBinding.listingKeyIDs($0, keyIDs: ids).contains(keyID) }
    }

    static func effectiveFilter(_ filter: Filter, available: [Filter]) -> Filter {
        available.contains(filter) ? filter : .all
    }

    /// The key's display name in the key chip: the same read model as the row title on the keys page.
    static func keyFilterTitle(provider: Provider, keyID: String) -> String? {
        RelayKeysBoardModel.make(provider).rows.first { $0.id == keyID }?.title
    }

    static func matches(_ filter: Filter, provider: Provider, model: AIModel) -> Bool {
        switch filter {
        case .all:
            return true
        case let .transport(transport):
            return protocolTransport(provider: provider, model: model) == transport
        case let .key(keyID):
            // Catalog entries are found only by id to decide the lister (the same convention as the panel's catalog count N); those outside the catalog (such as manually added ones) do not appear.
            guard let entry = provider.catalogModels.first(where: { $0.id == model.id }) else { return false }
            return RelayKeyBinding.listingKeyIDs(entry, keyIDs: RelayKeyBinding.keyIDs(provider)).contains(keyID)
        }
    }

    static func row(
        provider: Provider,
        model: AIModel,
        section: SectionID,
        isMissingFromCatalog: Bool,
        partitionID: String,
        now: Date = Date(),
        negativeCache: RelayNegativeCache = .shared,
        probeState: RelayModelProbeState? = nil
    ) -> Row {
        let caps = Capability.allCases.map {
            support($0, provider: provider, model: model, partitionID: partitionID, now: now, negativeCache: negativeCache)
        }
        return Row(
            id: model.id,
            name: model.name,
            protocolTransport: protocolTransport(provider: provider, model: model),
            caps: caps,
            status: sessionStatus(provider: provider, model: model, section: section, probeState: probeState)
                ?? status(
                    provider: provider, model: model, section: section,
                    isMissingFromCatalog: isMissingFromCatalog, caps: caps
                ),
            tapTarget: section == .enabled ? .advanced : .readOnlyAdvanced,
            trailing: section == .enabled ? [.newChat, .more] : [model.isAvailable ? .add : .unavailable],
            removeItem: section == .enabled ? removeItem(provider) : nil,
            keyChip: section == .enabled ? keyChip(provider: provider, modelID: model.id) : nil
        )
    }

    /// A connection keeps at least one enabled model (the same criterion as the earlier "no removal when only one is left").
    static func removeItem(_ provider: Provider) -> RemoveItem {
        let canRemove = provider.models.count > 1
        return RemoveItem(isEnabled: canRemove, disabledReasonKey: canRemove ? nil : removeDisabledReasonKey)
    }

    /// Three states by which an enabled row overrides persisted state: no access > verifying > unreachable. A local connection does not probe per model and has no key judgment.
    static func sessionStatus(
        provider: Provider,
        model: AIModel,
        section: SectionID,
        probeState: RelayModelProbeState?
    ) -> Status? {
        guard section == .enabled, !isLocal(provider) else { return nil }
        if RelayKeyBinding.modelState(provider, modelID: model.id)?.deniedOnCurrentKey == true {
            return .deniedOnCurrentKey
        }
        switch probeState {
        case .inFlight?: return .verifying
        case let .failed(failure)?: return .unreachable(failure)
        case nil: return nil
        }
    }

    /// The label of the bound key, the same read model as the keys page (name or mask); nil with fewer than 2 keys.
    static func keyChip(provider: Provider, modelID: String) -> String? {
        guard RelayKeyBinding.showsKeyUI(provider),
              let bound = RelayKeyBinding.modelState(provider, modelID: modelID)?.boundKeyID else { return nil }
        return RelayKeysBoardModel.make(provider).rows.first { $0.id == bound }?.title
    }

    // MARK: Group "Enable all"

    /// Which models the group header "Enable all" would enable (same order as the group rows); empty = the button does not appear.
    /// Only models that are not yet enabled, marked available in the catalog, and whose landing key after enabling is not judged no-access.
    static func enableAllModelIDs(provider: Provider, groupModels: [AIModel]) -> [String] {
        let enabledIDs = Set(provider.models.map(\.id))
        let keyIDs = RelayKeyBinding.keyIDs(provider)
        return groupModels.filter { model in
            guard model.isAvailable, !enabledIDs.contains(model.id) else { return false }
            guard let deniedKeyID = model.relayDeniedKeyID else { return true }
            // Which key it lands on follows the same rule as enabling a single model.
            let boundKeyID = RelayKeyBinding.effectiveKeyID(
                ProviderManager.relayBoundKeyID(for: model.id, in: provider), keyIDs: keyIDs
            )
            return deniedKeyID != boundKeyID
        }
        .map(\.id)
    }

    // MARK: Catalog area

    /// Per-key status strip; nil with fewer than 2 keys.
    static func keyStatusBar(_ provider: Provider) -> [KeyStatusItem]? {
        guard RelayKeyBinding.showsKeyUI(provider) else { return nil }
        let keys = RelayKeyBinding.keys(provider)
        return RelayKeysBoardModel.make(provider).rows.map { row in
            let status = keys.first { $0.id == row.id }?.status
            let state: KeyStatusItem.State = switch status?.state {
            case .ok?: .ok
            case let failed?: .failed(httpStatus: status?.httpStatus, statusKey: RelayKeysBoardModel.statusKey(failed))
            case nil: .unchecked
            }
            return KeyStatusItem(id: row.id, title: row.title, catalogCount: row.catalogCount ?? 0, state: state)
        }
    }

    /// Single key: the failure card on top, the old catalog stays below as usual; success but empty draws no catalog area.
    /// 2 or more keys: failure is expressed only by the per-key status strip (each with its own Retry), and no failure card is stacked on top.
    static func libraryBlocks(provider: Provider, isRefreshing: Bool) -> [LibraryBlock] {
        let catalog: [LibraryBlock] = provider.catalogModels.isEmpty ? [] : [.catalog]
        let state = RelayCatalogPresentationState.resolve(for: provider, isRefreshing: isRefreshing)
        if state == .loading { return [.loading] }
        if RelayKeyBinding.showsKeyUI(provider) { return [.keyStatusBar] + catalog }
        return state == .failed ? [.failureCard] + catalog : catalog
    }

    struct LibraryHeader: Equatable {
        let host: String
        /// De-duplicated count of enabled union catalog (the same convention as the detail status row).
        let modelCount: Int
        /// Only with 2 or more keys.
        let keyCount: Int?
    }

    /// Subtitle of the model library page header: "host · N models (· N keys)".
    static func libraryHeader(_ provider: Provider) -> LibraryHeader {
        LibraryHeader(
            host: RelayKeysBoardModel.make(provider).host,
            modelCount: Set(provider.models.map(\.id)).union(provider.catalogModels.map(\.id)).count,
            keyCount: RelayKeyBinding.showsKeyUI(provider) ? RelayKeyBinding.keys(provider).count : nil
        )
    }

    /// Enable hint below the group; nil = not shown. Enabling on a local connection does not probe per model, so it is not shown;
    /// when the connection protocol is not auto, enabling does not probe either, and "will send 1 tiny request" is no longer said.
    static func enableHint(for provider: Provider) -> String? {
        guard !isLocal(provider) else { return nil }
        return RelayEndpointResolver.requestedConnectionTransport(of: provider) == .auto
            ? enableHintKey
            : enableHintChosenProtocolKey
    }

    /// Enabled: catalog already missing > observed > reachable > user > no model-level protocol; catalog row: has a non-unknown capability -> verify on enabling.
    /// A local connection does not probe per model on enabling; only "catalog already missing" applies. When the user chose the connection protocol, models without their own protocol (in both areas)
    /// follow the connection and are not probed, showing the "set by user" tier.
    static func status(
        provider: Provider,
        model: AIModel,
        section: SectionID,
        isMissingFromCatalog: Bool,
        caps: [Support]
    ) -> Status? {
        if section == .enabled, isMissingFromCatalog { return .missingFromCatalog }
        guard !isLocal(provider) else { return nil }
        if RelayProbeCandidates.followsUserChosenConnection(provider: provider, model: model) { return .setByYou }
        switch section {
        case .enabled:
            guard let transport = model.relayTransport, transport != .auto,
                  let source = model.relayTransportSource else { return .unknownUntilSent }
            switch source {
            case .observed: return .verified
            case .reachable: return .reachable
            case .user: return .setByYou
            }
        case .library:
            return caps.contains { $0 != .unknown } ? .verifyOnEnable : .unknownUntilSent
        }
    }

    // MARK: Five capabilities, three states

    static func support(
        _ capability: Capability,
        provider: Provider,
        model: AIModel,
        partitionID: String,
        now: Date,
        negativeCache: RelayNegativeCache
    ) -> Support {
        switch capability {
        case .image:
            // A user override comes before the negative cache (same order as the entry point: user > negative cache > tested > engine declaration > official catalog),
            // and the override is left to the entry point to judge; not user-set and the negative cache unexpired -> unsupported (same answer as the Detected source);
            // entry not visible -> unsupported; visible but no positive Relay vision evidence -> unknown; any other visible case -> supported.
            if !RelayCapabilityTest.isUserSet(model.relayCapabilityOverrides, .image), negativeCache.isRejected(
                connectionID: provider.id.uuidString, modelID: model.id,
                transport: RelayFirstSendTransport.current(provider: provider, model: model).rawValue,
                kind: .image, now: now
            ) {
                return .unsupported
            }
            guard ChatView.photoPickerVisible(provider: provider, model: model, partitionID: partitionID) else {
                return .unsupported
            }
            return RelayRejectionRecording.imageSupportUnknown(provider: provider, model: model) ? .unknown : .supported
        case .file:
            // A user override comes before everything (the same answer as the file row on the Advanced page); otherwise draw the model facts:
            // negative cache not expired -> unsupported; native allowlist non-empty -> supported; wire authorization is left to the model options.
            if let forced = model.relayCapabilityOverrides?.file {
                return forced ? .supported : .unsupported
            }
            if negativeCache.isRejected(
                connectionID: provider.id.uuidString, modelID: model.id,
                transport: RelayFirstSendTransport.current(provider: provider, model: model).rawValue,
                kind: .file, now: now
            ) {
                return .unsupported
            }
            return model.nativeFileMimes.isEmpty ? .unknown : .supported
        case .tool:
            switch ToolCallCapabilityPolicy.decide(provider: provider, model: model).verdict {
            case true?: return .supported
            case false?: return .unsupported
            case nil: return .unknown
            }
        case .thinking:
            if provider.relayRequested?.engineProfile != nil, let declared = model.engineDeclaration?.thinking {
                return declared ? .supported : .unsupported
            }
            if ModelCapabilityEvidencePresentation(provider: provider, model: model, partitionID: partitionID)
                .permitsDisplay(.reasoning) {
                return .supported
            }
            let projection = ChatView.capabilityProjection(provider: provider, model: model, partitionID: partitionID)
            let levels = projection.resolutions.filter { $0.key.hasPrefix("reasoning_level/") }.values
            // Every tier judged unsupported by the evidence layer counts as unsupported; a tier lacking evidence keeps the whole item unknown.
            return !levels.isEmpty && levels.allSatisfy { $0.support == .unsupported } ? .unsupported : .unknown
        case .web:
            let projection = ChatView.capabilityProjection(provider: provider, model: model, partitionID: partitionID)
            switch projection.resolution(for: "web_search")?.support {
            case .supported?: return .supported
            case .unsupported?: return .unsupported
            case .unknown?, nil: return .unknown
            }
        }
    }
}
