import Foundation

// External web search: web-row resolution, web card and per-conversation selection, and this turn's path (see the external search services contract).
// Mirrors scripts/lib/search-route.mjs line by line; fixture shared/search-contracts/web-route-resolution.v1.json.
// The nine functions are defined only here on this platform; UI state is always taken from them.

// MARK: - Vocabulary

nonisolated enum SearchSourceMethod: String, Codable, Sendable, Equatable {
    case `default`
    case native
    case external
}

nonisolated struct WebSearchRouteInput: Sendable, Equatable {
    enum Form: String, Sendable {
        case byok
        case relay
        case subscriptionCodex = "subscription_codex"
        case subscriptionGrok = "subscription_grok"
        case free
        case managed
    }

    enum NativeWeb: String, Sendable {
        case available
        case unavailable
        case unknown
        case withdrawnOrRejected = "withdrawn_or_rejected"
    }

    enum RelayRecord: String, Sendable {
        case searched
        case supported
        case rejected
        case silent
        case untested
        case templateOnly = "template_only"
        case userOverrideOff = "user_override_off"
        case localEngine = "local_engine"
        case protocolUndecided = "protocol_undecided"
    }

    enum ToolCall: String, Sendable {
        case supported
        case unknown
        case unsupported
    }

    var form: Form
    var nativeWeb: NativeWeb? = nil
    var relayWebRecord: RelayRecord? = nil
    /// Number of selectable services (services for which searchServiceSelectable is true).
    var externalServices: Int = 0
    /// oneTapReuseTarget is non-nil.
    var reusableConnection: Bool = false
    var toolCall: ToolCall = .unknown
    var webOn: Bool = false
    /// Comes from resolveSearchSource.
    var method: SearchSourceMethod = .default
}

nonisolated struct WebSearchRoute: Codable, Sendable, Equatable {
    enum Row: String, Codable, Sendable {
        case toggleNativeUnchanged = "toggle_native_unchanged"
        case toggleWithSourcePicker = "toggle_with_source_picker"
        case toggleExternal = "toggle_external"
        case toggleExternalPresearchNotice = "toggle_external_presearch_notice"
        case oneTapReuseConnectionKey = "one_tap_reuse_connection_key"
        case cannotSearch = "cannot_search"
        case relayUnchanged = "relay_unchanged"
        case alwaysOnUnchanged = "always_on_unchanged"
        case freeUnchanged = "free_unchanged"
        case managedUnchanged = "managed_unchanged"
    }

    enum Path: String, Codable, Sendable {
        case none
        case native
        case relayFragment = "relay_fragment"
        case externalTool = "external_tool"
        case externalPresearch = "external_presearch"

        var isExternal: Bool { self == .externalTool || self == .externalPresearch }
    }

    enum Action: String, Codable, Sendable {
        case addSearchService = "add_search_service"
        case openSupportedModels = "open_supported_models"
        case oneTapEnable = "one_tap_enable"
        case pickSource = "pick_source"
    }

    var row: Row
    var path: Path
    var primaryAction: Action? = nil
    var secondaryAction: Action? = nil
    var sourceAction: Action? = nil
    var fragmentAttached: Bool? = nil
}

/// Service input for the "Search method" sheet and sourceCases: id + the status from searchServiceRowState.
nonisolated struct SearchSelectableService: Sendable, Equatable {
    var id: String
    var status: SearchServiceRowState.Status
}

nonisolated struct SearchOneTapTarget: Codable, Sendable, Equatable {
    var serviceId: String
    var regionId: String
    var connectionRef: String
    var connectionName: String?

    private enum CodingKeys: String, CodingKey { case serviceId, regionId, connectionRef, connectionName }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(serviceId, forKey: .serviceId)
        try container.encode(regionId, forKey: .regionId)
        try container.encode(connectionRef, forKey: .connectionRef)
        try container.encode(connectionName, forKey: .connectionName)
    }
}

/// Stored value of the per-conversation source (key searchSourceStorageKey): methods records native / external per "conversation x model".
nonisolated struct SearchSourceStored: Encodable, Sendable, Equatable {
    struct Notice: Codable, Sendable, Equatable {
        var fromName: String
    }

    /// modelKey → native / external (default is never stored).
    var methods: [String: SearchSourceMethod] = [:]
    var serviceId: String? = nil
    var serviceName: String? = nil
    var notice: Notice? = nil

    var isEmpty: Bool { methods.isEmpty && serviceId == nil && serviceName == nil && notice == nil }

    private enum CodingKeys: String, CodingKey { case methods, serviceId, serviceName, notice }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(methods.mapValues(\.rawValue), forKey: .methods)
        try container.encode(serviceId, forKey: .serviceId)
        try container.encode(serviceName, forKey: .serviceName)
        try container.encode(notice, forKey: .notice)
    }
}

nonisolated struct SearchSourceResolution: Encodable, Sendable, Equatable {
    struct Notice: Encodable, Sendable, Equatable {
        var fromName: String
    }

    var method: SearchSourceMethod
    var serviceId: String?
    var notice: Notice?
    /// nil = delete the key.
    var nextStored: SearchSourceStored?
    /// When false, storage must not be written (prevents a self-triggering write loop).
    var changed: Bool

    private enum CodingKeys: String, CodingKey { case method, serviceId, notice, nextStored, changed }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(method, forKey: .method)
        try container.encode(serviceId, forKey: .serviceId)
        try container.encode(notice, forKey: .notice)
        try container.encode(nextStored, forKey: .nextStored)
        try container.encode(changed, forKey: .changed)
    }
}

nonisolated enum SearchSourceEvent: Sendable, Equatable {
    case pickNative
    case pickService(serviceId: String, serviceName: String?)
    /// The external switch is turned off: back to default, keeping the service that was picked.
    case disarm
    case acknowledgeNotice
}

nonisolated enum SearchSourcePickerItem: Encodable, Sendable, Equatable {
    case native(selected: Bool)
    case service(serviceId: String, isDefault: Bool, status: SearchServiceRowState.Status, selected: Bool)
    case add

    private enum CodingKeys: String, CodingKey { case kind, selected, serviceId, isDefault, status }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .native(selected):
            try container.encode("native", forKey: .kind)
            try container.encode(selected, forKey: .selected)
        case let .service(serviceId, isDefault, status, selected):
            try container.encode("service", forKey: .kind)
            try container.encode(serviceId, forKey: .serviceId)
            try container.encode(isDefault, forKey: .isDefault)
            try container.encode(status, forKey: .status)
            try container.encode(selected, forKey: .selected)
        case .add:
            try container.encode("add", forKey: .kind)
        }
    }
}

/// Input for the web card's display name: whether this conversation's source is the model's built-in search or a service.
nonisolated enum WebSearchCardSource: Sendable, Equatable {
    case native
    /// status = the current service's searchServiceRowState.status (a note is given when abnormal).
    case service(name: String, status: SearchServiceRowState.Status? = nil)
}

nonisolated struct WebSearchCardNotice: Sendable, Equatable {
    var fromName: String
}

/// How the web card is drawn: semantic copy keys (card.*, mapped through the l10n registry to webSearch.card.* and existing keys).
nonisolated struct WebSearchCardPresentation: Encodable, Sendable, Equatable {
    struct Text: Encodable, Sendable, Equatable {
        var key: String
        var args: [String: String] = [:]
    }

    struct ActionText: Encodable, Sendable, Equatable {
        var key: String
        var args: [String: String] = [:]
        var action: WebSearchRoute.Action
    }

    /// true = the existing form, rendered as before, untouched.
    var existing: Bool
    var toggle = false
    var status: Text? = nil
    /// Notes under the status row, all shown in order.
    var notes: [Text] = []
    var link: ActionText? = nil
    var cta: ActionText? = nil
    var secondary: ActionText? = nil

    private enum CodingKeys: String, CodingKey { case existing, toggle, status, notes, link, cta, secondary }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(existing, forKey: .existing)
        guard !existing else { return }
        try container.encode(toggle, forKey: .toggle)
        try container.encode(status, forKey: .status)
        try container.encode(notes, forKey: .notes)
        try container.encode(link, forKey: .link)
        try container.encode(cta, forKey: .cta)
        try container.encode(secondary, forKey: .secondary)
    }
}

// MARK: - Inputs and outputs of the combined entry point

/// Facts normalized from this platform's state (input of resolveWebSearchState, see the function comment).
nonisolated struct WebSearchFacts: Sendable, Equatable {
    /// recipe web control: auto_available / unavailable / none (no recipe or not loaded) / custom_only (needs the user's own configuration).
    enum RecipeWeb: String, Sendable {
        case autoAvailable = "auto_available"
        case unavailable
        case none
        case customOnly = "custom_only"
    }

    /// Relay web row: web-probe presentation statusId, or local_engine / protocol_undecided.
    enum RelayStatus: String, Sendable {
        case searched = "web_probe_searched"
        case userOn = "web_user_on"
        case rejected = "web_probe_rejected"
        case silent = "web_probe_silent"
        case unverified = "web_probe_unverified"
        case untested = "web_probe_untested"
        case userOff = "web_user_off"
        case localEngine = "local_engine"
        case protocolUndecided = "protocol_undecided"

        var record: WebSearchRouteInput.RelayRecord {
            switch self {
            case .searched: .searched
            case .userOn: .supported
            case .rejected: .rejected
            case .silent: .silent
            case .unverified: .untested
            case .untested: .templateOnly
            case .userOff: .userOverrideOff
            case .localEngine: .localEngine
            case .protocolUndecided: .protocolUndecided
            }
        }
    }

    var form: WebSearchRouteInput.Form
    var recipeWeb: RecipeWeb = .none
    var nativeRejected: Bool = false
    /// Only meaningful for relays; nil is treated as protocol undecided.
    var relayStatus: RelayStatus? = nil
    var managedWebAvailable: Bool = false
    var toolCall: WebSearchRouteInput.ToolCall = .unknown
}

/// Service input of the combined entry point: name has already gone through searchServiceDisplayName.
nonisolated struct WebSearchStateService: Sendable, Equatable {
    var id: String
    var name: String
    var status: SearchServiceRowState.Status
}

nonisolated struct WebSearchStateInput: Sendable, Equatable {
    var facts: WebSearchFacts
    /// Whether the panel can persist the switch; send and preview pass the same criterion.
    var panelWritable: Bool = true
    var webOn: Bool = false
    var modelKey: String
    var services: [WebSearchStateService] = []
    var defaultServiceId: String? = nil
    /// Value of conversationSource (a new conversation = the in-memory value).
    var stored: SearchJSON? = nil
    var oneTapTarget: SearchOneTapTarget? = nil
    var oneTapServiceName: String? = nil
}

nonisolated struct WebSearchState: Encodable, Sendable, Equatable {
    enum ShapeMode: String, Encodable, Sendable {
        /// Rendered as before, unchanged.
        case existing
        /// The existing form as is + the card's detail / action.
        case existingWithActions = "existing_with_actions"
        /// A new notice (card.status goes to the status row).
        case searchNotice = "search_notice"
        /// The new form (switch + source sub-row).
        case toggleWithSource = "toggle_with_source"
    }

    var nativeWeb: WebSearchRouteInput.NativeWeb?
    var route: WebSearchRoute
    var source: SearchSourceResolution
    var shapeMode: ShapeMode
    var card: WebSearchCardPresentation
    var pickerItems: [SearchSourcePickerItem]
    /// What the switch controls: external = the external search for this conversation x this model (on = pick_service, off = disarm, conversation web is not written);
    /// conversationWeb = the conversation-level web switch (existing).
    enum ToggleControls: String, Encodable, Sendable {
        case external
        case conversationWeb = "conversation_web"
    }

    /// The switch shows on.
    var toggleOn: Bool
    /// Whether the input-box web chip is lit; nil = follow the existing liveness.
    var chipLit: Bool?
    var toggleControls: ToggleControls?
    /// Conversation web is on, but external is not yet turned on for this model (explained by notes on the card).
    var armHint: Bool
    /// This turn goes through external: native / relay web fields are suppressed in the request; when false, outbound is unchanged.
    var nativeFieldsSuppressed: Bool
    /// Whether, once one-tap enable succeeds, external can be recorded as turned on.
    var oneTapArms: Bool

    private enum CodingKeys: String, CodingKey {
        case nativeWeb, route, source, shapeMode, card, pickerItems, toggleOn, chipLit, toggleControls, armHint
        case nativeFieldsSuppressed, oneTapArms
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(nativeWeb?.rawValue, forKey: .nativeWeb)
        try container.encode(route, forKey: .route)
        try container.encode(source, forKey: .source)
        try container.encode(shapeMode, forKey: .shapeMode)
        try container.encode(card, forKey: .card)
        try container.encode(pickerItems, forKey: .pickerItems)
        try container.encode(toggleOn, forKey: .toggleOn)
        try container.encode(chipLit, forKey: .chipLit)
        try container.encode(toggleControls, forKey: .toggleControls)
        try container.encode(armHint, forKey: .armHint)
        try container.encode(nativeFieldsSuppressed, forKey: .nativeFieldsSuppressed)
        try container.encode(oneTapArms, forKey: .oneTapArms)
    }
}

nonisolated struct SearchTurnInput: Sendable, Equatable {
    var path: WebSearchRoute.Path
    var thinkingOn: Bool = false
    var continuationStateAvailable: Bool? = nil
    var upstreamRejectedTools: Bool = false
    /// `tool_loop` / `presearch`.
    var thinkingWithTools: String? = nil
    var hostMaxSteps: Int? = nil
}

nonisolated struct SearchTurnPath: Encodable, Sendable, Equatable {
    var path: WebSearchRoute.Path
    var fallbackReason: String?
    var noticeOnce: Bool
    var requestHasNativeSearchFields: Bool
    var requestHasWebSearchTool: Bool

    private enum CodingKeys: String, CodingKey {
        case path, fallbackReason, noticeOnce, requestHasNativeSearchFields, requestHasWebSearchTool
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(fallbackReason, forKey: .fallbackReason)
        try container.encode(noticeOnce, forKey: .noticeOnce)
        try container.encode(requestHasNativeSearchFields, forKey: .requestHasNativeSearchFields)
        try container.encode(requestHasWebSearchTool, forKey: .requestHasWebSearchTool)
    }
}

/// Outcome of one search request: an HTTP status, or a local timeout / network failure.
nonisolated enum SearchCallAttempt: Sendable, Equatable {
    case status(Int)
    case failure(String)
}

nonisolated struct SearchCallPlan: Encodable, Sendable, Equatable {
    struct Call: Encodable, Sendable, Equatable {
        var leg: Int
        var call: Int
        var requests: Int
        /// response / cap_reached / the last status code or the local failure name.
        var outcome: String
    }

    var requestsSent: Int
    var calls: [Call]
}

nonisolated enum SearchRegenerateAction: String, Sendable {
    case send
    case regenerate
    case editResend = "edit_resend"
    case reSearch = "re_search"
}

nonisolated struct SearchRegeneratePolicy: Encodable, Sendable, Equatable {
    var reusePrevious: Bool
    var newSearchesAllowed: Bool
}

// MARK: - Nine functions

nonisolated enum SearchRoute {
    private static let relayNative: Set<WebSearchRouteInput.RelayRecord> = [.searched, .supported]
    private static let relayUnchanged: Set<WebSearchRouteInput.RelayRecord> = [.userOverrideOff, .localEngine, .protocolUndecided]

    private static func externalPath(_ toolCall: WebSearchRouteInput.ToolCall) -> WebSearchRoute.Path {
        toolCall == .unsupported ? .externalPresearch : .externalTool
    }

    /// The web row and this turn's web path. A turn takes exactly one path: path has a single value.
    static func resolveWebSearchRoute(_ input: WebSearchRouteInput) -> WebSearchRoute {
        let services = input.externalServices
        let method: SearchSourceMethod = services > 0 ? input.method : .default
        let on = input.webOn

        switch input.form {
        case .free: return .init(row: .freeUnchanged, path: .none)
        case .managed: return .init(row: .managedUnchanged, path: on && input.nativeWeb == .available ? .native : .none)
        case .subscriptionGrok: return .init(row: .alwaysOnUnchanged, path: .native)
        case .relay, .byok, .subscriptionCodex: break
        }

        var nativeKind: WebSearchRoute.Path?
        var fragmentForbidden = false
        if input.form == .relay {
            // User override web=false, local engine, protocol undecided: behavior unchanged, and no external search is offered
            if let record = input.relayWebRecord, relayUnchanged.contains(record) {
                return .init(row: .relayUnchanged, path: .none)
            }
            if let record = input.relayWebRecord, relayNative.contains(record) {
                nativeKind = .relayFragment
            } else {
                fragmentForbidden = true
            }
        } else if input.nativeWeb == .available {
            nativeKind = .native
        }

        if let nativeKind {
            if services == 0 {
                return .init(row: input.form == .relay ? .relayUnchanged : .toggleNativeUnchanged, path: on ? nativeKind : .none)
            }
            let path: WebSearchRoute.Path = !on ? .none : (method == .external ? externalPath(input.toolCall) : nativeKind)
            return .init(row: .toggleWithSourcePicker, path: path, sourceAction: .pickSource)
        }

        // Cannot search natively (including unknown, revoked / rejected, relay not confirmed)
        if services > 0 {
            var out = WebSearchRoute(
                row: input.toolCall == .unsupported ? .toggleExternalPresearchNotice : .toggleExternal,
                path: on ? externalPath(input.toolCall) : .none,
                sourceAction: .pickSource
            )
            if fragmentForbidden { out.fragmentAttached = false }
            return out
        }
        if input.form == .relay { return .init(row: .relayUnchanged, path: .none) }
        // With no local service, webOn is ignored: a switch that is on most likely belongs to a model that could search natively
        if input.reusableConnection {
            return .init(row: .oneTapReuseConnectionKey, path: .none, primaryAction: .oneTapEnable)
        }
        return .init(row: .cannotSearch, path: .none, primaryAction: .addSearchService, secondaryAction: .openSupportedModels)
    }

    /// Whether a service can appear in the web card and the "Search method" sheet (also decides the externalServices count):
    /// revoked and catalog-unavailable presets do not count; ones that need a key / host changed / connection gone still count (the error card gives the repair action at send time).
    static func searchServiceSelectable(_ status: SearchServiceRowState.Status) -> Bool {
        status != .withdrawn
    }

    /// Which service "one-tap enable" attaches to: the first catalog-order entry that has reuse and a connection with the same providerKind whose address resolves to a site;
    /// one from the same vendor as the current model is preferred, otherwise the first. The output is also the prefill for the connection setup page.
    static func oneTapReuseTarget(
        catalogAvailable: Bool,
        entries: [SearchJSON],
        connections: [SearchSettingsConnection],
        currentProviderKind: String?
    ) -> SearchOneTapTarget? {
        guard catalogAvailable else { return nil }
        var candidates: [(target: SearchOneTapTarget, providerKind: String?)] = []
        for entry in entries {
            guard let reuse = entry["reuse"], reuse.isTruthy else { continue }
            for connection in connections where connection.providerKind == reuse["providerKind"]?.stringValue {
                if let regionId = SearchCatalog.regionForConnection(entry, connectionBaseUrl: connection.baseUrl) {
                    candidates.append((
                        SearchOneTapTarget(
                            serviceId: entry["id"]?.stringValue ?? "", regionId: regionId,
                            connectionRef: connection.id, connectionName: connection.name
                        ),
                        connection.providerKind
                    ))
                    break
                }
            }
        }
        return (candidates.first { $0.providerKind == currentProviderKind } ?? candidates.first)?.target
    }

    /// Local storage key for the per-conversation selection: under that account's search partition, not synced with preferences, not in backups.
    static func searchSourceStorageKey(_ conversationId: String) -> String {
        "conversationSource:\(conversationId)"
    }

    private static func normalizeStored(_ stored: SearchJSON?) -> SearchSourceStored {
        guard let stored, stored.objectValue != nil else { return SearchSourceStored() }
        var methods: [String: SearchSourceMethod] = [:]
        for entry in stored["methods"]?.objectValue?.entries ?? [] {
            if let method = entry.value.stringValue.flatMap(SearchSourceMethod.init(rawValue:)), method != .default {
                methods[entry.key] = method
            }
        }
        return SearchSourceStored(
            methods: methods,
            serviceId: stored["serviceId"]?.stringValue,
            serviceName: stored["serviceName"]?.stringValue,
            notice: stored["notice"]?["fromName"]?.stringValue.map { SearchSourceStored.Notice(fromName: $0) }
        )
    }

    private static func withoutExternal(_ methods: [String: SearchSourceMethod]) -> [String: SearchSourceMethod] {
        methods.filter { $0.value != .external }
    }

    /// Which source this conversation uses this turn (read path: called when opening model options, on every send, and before the chip preview).
    /// methods is remembered per "conversation x model" and survives a model switch; if the selected service was deleted or revoked → clear serviceId and every external, record a one-time notice;
    /// with no selectable service: clear external and serviceId without a notice, keep native. When changed is false, storage must not be written.
    static func resolveSearchSource(
        stored: SearchJSON?, modelKey: String, selectable: [SearchSelectableService], defaultServiceId: String?
    ) -> SearchSourceResolution {
        let original = normalizeStored(stored)
        var next = original
        let ids = selectable.map(\.id)
        let fallbackId = defaultServiceId.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
        var serviceId = fallbackId
        if ids.isEmpty {
            next.methods = withoutExternal(next.methods)
            next.serviceId = nil
            next.serviceName = nil
            next.notice = nil
        } else if let picked = next.serviceId, ids.contains(picked) {
            serviceId = picked
        } else if next.serviceId != nil {
            next.notice = .init(fromName: next.serviceName ?? "")
            next.methods = withoutExternal(next.methods)
            next.serviceId = nil
            next.serviceName = nil
        }
        return SearchSourceResolution(
            method: next.methods[modelKey] ?? .default,
            serviceId: serviceId,
            notice: next.notice.map { .init(fromName: $0.fromName) },
            nextStored: next.isEmpty ? nil : next,
            changed: next != original
        )
    }

    /// User actions on the web card / "Search method" page (write path). pick_service = explicitly choose external (turn it on for this model);
    /// disarm only turns off external for this model; picking any source clears the notice. Returns nil = delete the key.
    static func updateSearchSource(stored: SearchJSON?, modelKey: String, event: SearchSourceEvent) -> SearchSourceStored? {
        var next = normalizeStored(stored)
        switch event {
        case .pickNative:
            next.methods[modelKey] = .native
            next.notice = nil
        case let .pickService(serviceId, serviceName):
            next.methods[modelKey] = .external
            next.serviceId = serviceId
            next.serviceName = serviceName
            next.notice = nil
        case .disarm:
            if next.methods[modelKey] == .external { next.methods[modelKey] = nil }
        case .acknowledgeNotice:
            next.notice = nil
        }
        return next.isEmpty ? nil : next
    }

    /// Rows of the "Search method" sheet: when native is possible the first row is "Built into model", then the selectable services (storage order), and the last row is the add-search-service row.
    static func searchSourcePickerItems(
        nativeCapable: Bool,
        selectable: [SearchSelectableService],
        defaultServiceId: String?,
        method: SearchSourceMethod,
        serviceId: String?
    ) -> [SearchSourcePickerItem] {
        var items: [SearchSourcePickerItem] = []
        let external = method == .external
        if nativeCapable { items.append(.native(selected: !external)) }
        for service in selectable {
            items.append(.service(
                serviceId: service.id, isDefault: service.id == defaultServiceId, status: service.status,
                selected: external && service.id == serviceId
            ))
        }
        items.append(.add)
        return items
    }

    private static let cardRows: Set<WebSearchRoute.Row> = [
        .toggleWithSourcePicker, .toggleExternal, .toggleExternalPresearchNotice,
        .oneTapReuseConnectionKey, .cannotSearch,
    ]

    /// How the web card is drawn. existing = the existing form, untouched; when native is not explicitly unavailable, the three row kinds without a service
    /// keep the existing status-row copy (status = nil) and only add an action.
    private static let statusNote: [SearchServiceRowState.Status: String] = [
        .needsKey: "row.needsKey", .hostChanged: "row.hostChanged",
        .connectionMissing: "row.connectionMissing", .catalogUnavailable: "row.catalogUnavailable",
    ]

    /// How the web card is drawn. existing = the existing form, untouched; notes are all shown in order: fallback notice → the current service's abnormal status →
    /// each "search first, then answer" → not-yet-on explanation → one-tap enable explanation. When native is not explicitly unavailable, rows without a service keep the existing status-row copy (status = nil).
    static func webSearchCardPresentation(
        route: WebSearchRoute,
        nativeWeb: WebSearchRouteInput.NativeWeb = .unavailable,
        webOn: Bool = false,
        source: WebSearchCardSource? = nil,
        oneTapServiceName: String? = nil,
        notice: WebSearchCardNotice? = nil,
        armHint: Bool = false
    ) -> WebSearchCardPresentation {
        guard cardRows.contains(route.row) else { return .init(existing: true) }
        typealias Text = WebSearchCardPresentation.Text
        typealias ActionText = WebSearchCardPresentation.ActionText
        var name: String?
        var serviceStatus: SearchServiceRowState.Status?
        if case let .service(serviceName, status)? = source {
            name = serviceName
            serviceStatus = status
        }
        var out = WebSearchCardPresentation(existing: false)
        if let notice { out.notes.append(Text(key: "card.fallbackNotice", args: ["from": notice.fromName])) }
        let note = serviceStatus.flatMap { statusNote[$0] }.map { Text(key: $0) }
        switch route.row {
        case .toggleWithSourcePicker:
            out.toggle = true
            out.link = name != nil
                ? ActionText(key: "card.sourceLine", args: ["name": name ?? ""], action: .pickSource)
                : ActionText(key: "card.sourceLineNative", action: .pickSource)
            if let note { out.notes.append(note) }
        case .toggleExternal, .toggleExternalPresearchNotice:
            out.toggle = true
            out.status = Text(key: webOn ? "card.useService" : "card.offUseService", args: ["name": name ?? ""])
            out.link = ActionText(key: "card.changeService", action: .pickSource)
            if let note { out.notes.append(note) }
            if route.row == .toggleExternalPresearchNotice { out.notes.append(Text(key: "card.presearchNotice")) }
            if armHint { out.notes.append(Text(key: "card.armHint", args: ["name": name ?? ""])) }
        case .oneTapReuseConnectionKey:
            if nativeWeb == .unavailable {
                out.status = Text(key: "card.reuseStatus", args: ["name": oneTapServiceName ?? ""])
            } else {
                out.notes.append(Text(key: "card.reuseDetail", args: ["name": oneTapServiceName ?? ""]))
            }
            out.cta = ActionText(key: "card.oneTap", action: .oneTapEnable)
        case .cannotSearch:
            out.status = nativeWeb == .unavailable ? Text(key: "card.cannotSearch") : nil
            out.cta = ActionText(key: "card.addService", action: .addSearchService)
            out.secondary = ActionText(key: "card.supportedModels", action: .openSupportedModels)
        default:
            break
        }
        return out
    }

    // MARK: The single combined entry point: the panel, send, and input-box preview all call only this

    private static let toggleRows: Set<WebSearchRoute.Row> = [.toggleWithSourcePicker, .toggleExternal, .toggleExternalPresearchNotice]
    private static let externalRows: Set<WebSearchRoute.Row> = [.toggleExternal, .toggleExternalPresearchNotice]

    /// nativeWeb for BYOK / subscription Codex: native revoked or tier rejected takes priority; custom_only and none are both unknown.
    private static func nativeWebOf(_ facts: WebSearchFacts) -> WebSearchRouteInput.NativeWeb {
        if facts.nativeRejected { return .withdrawnOrRejected }
        switch facts.recipeWeb {
        case .autoAvailable: return .available
        case .unavailable: return .unavailable
        case .none, .customOnly: return .unknown
        }
    }

    /// The single combined entry point for the web card and this turn's web path. Each platform only normalizes its own facts into facts; everything else is decided by this function.
    static func resolveWebSearchState(_ input: WebSearchStateInput) -> WebSearchState {
        let facts = input.facts
        let selectable = input.services.filter { searchServiceSelectable($0.status) }
        let selectableRefs = selectable.map { SearchSelectableService(id: $0.id, status: $0.status) }
        let resolved = resolveSearchSource(
            stored: input.stored, modelKey: input.modelKey, selectable: selectableRefs, defaultServiceId: input.defaultServiceId
        )
        // The panel cannot persist: the per-conversation selection does not take effect (send and preview pass the same panelWritable)
        var source = resolved
        if !input.panelWritable { source.method = .default }
        let nativeWeb: WebSearchRouteInput.NativeWeb? = switch facts.form {
        case .byok, .subscriptionCodex: nativeWebOf(facts)
        case .managed: facts.managedWebAvailable ? .available : .unavailable
        case .relay, .free, .subscriptionGrok: nil
        }
        var routeInput = WebSearchRouteInput(
            form: facts.form,
            nativeWeb: nativeWeb,
            externalServices: selectable.count,
            reusableConnection: input.oneTapTarget != nil,
            toolCall: facts.toolCall,
            webOn: input.webOn,
            method: source.method
        )
        if facts.form == .relay { routeInput.relayWebRecord = (facts.relayStatus ?? .protocolUndecided).record }
        // First decide which kind of row it is, then which state the switch reads: an external row = whether external is on for this conversation x this model, independent of conversation web
        var probeInput = routeInput
        probeInput.webOn = true
        let externalRow = externalRows.contains(resolveWebSearchRoute(probeInput).row)
        let effectiveOn = externalRow ? source.method == .external : routeInput.webOn
        var effectiveInput = routeInput
        effectiveInput.webOn = effectiveOn
        let route = resolveWebSearchRoute(effectiveInput)
        let armHint = externalRow && routeInput.webOn && !effectiveOn
        let current = selectable.first { $0.id == source.serviceId }
        let usesService = externalRow || (route.row == .toggleWithSourcePicker && source.method == .external)
        let currentName = (current?.name).flatMap { $0.isEmpty ? nil : $0 } ?? source.serviceId ?? ""
        let card = webSearchCardPresentation(
            route: route,
            nativeWeb: nativeWeb ?? .unavailable,
            webOn: effectiveOn,
            source: usesService ? .service(name: currentName, status: current?.status) : .native,
            oneTapServiceName: input.oneTapServiceName,
            notice: source.notice.map { WebSearchCardNotice(fromName: $0.fromName) },
            armHint: armHint
        )
        let shapeMode: WebSearchState.ShapeMode
        if card.existing {
            shapeMode = .existing
        } else if toggleRows.contains(route.row) {
            shapeMode = input.panelWritable ? .toggleWithSource : .existing
        } else {
            shapeMode = card.status == nil ? .existingWithActions : .searchNotice
        }
        let pickerItems = toggleRows.contains(route.row)
            ? searchSourcePickerItems(
                nativeCapable: route.row == .toggleWithSourcePicker, selectable: selectableRefs,
                defaultServiceId: input.defaultServiceId, method: source.method, serviceId: source.serviceId
            )
            : []
        let toggleOn = toggleRows.contains(route.row) && route.path != .none
        return WebSearchState(
            nativeWeb: nativeWeb,
            route: route,
            source: source,
            shapeMode: shapeMode,
            card: card,
            pickerItems: pickerItems,
            toggleOn: toggleOn,
            chipLit: shapeMode == .toggleWithSource ? toggleOn : nil,
            toggleControls: externalRow ? .external : (route.row == .toggleWithSourcePicker ? .conversationWeb : nil),
            armHint: armHint,
            nativeFieldsSuppressed: route.path.isExternal,
            oneTapArms: input.panelWritable
        )
    }

    /// How this turn is actually sent: whether tool calls switch to pre-search, and which kind of web field appears in the request.
    static func resolveSearchTurnPath(_ input: SearchTurnInput) -> SearchTurnPath {
        let path = input.path
        guard path.isExternal else {
            return .init(
                path: path, fallbackReason: nil, noticeOnce: false,
                requestHasNativeSearchFields: path == .native || path == .relayFragment,
                requestHasWebSearchTool: false
            )
        }
        var resolved = path
        var fallbackReason: String?
        if path == .externalTool {
            if input.hostMaxSteps == 0 {
                fallbackReason = "no_tool_continuation"
            } else if input.thinkingOn && input.thinkingWithTools == "presearch" {
                fallbackReason = "thinking_tools_unsupported"
            } else if input.thinkingOn && input.continuationStateAvailable == false {
                fallbackReason = "thinking_no_continuation"
            } else if input.upstreamRejectedTools {
                fallbackReason = "tools_rejected"
            }
            if fallbackReason != nil { resolved = .externalPresearch }
        }
        return .init(
            path: resolved, fallbackReason: fallbackReason, noticeOnce: fallbackReason == "tools_rejected",
            requestHasNativeSearchFields: false, requestHasWebSearchTool: resolved == .externalTool
        )
    }

    /// At most 3 requests per reply (retries count); only 408 / 502 / 503 are retried automatically, once.
    static let searchCallLimits = (maxSearchRequestsPerReply: 3, retryableStatuses: [408, 502, 503], maxRetriesPerCall: 1)

    /// Search calls within one reply: legs = [[outcomes of each request of each call]]; calls beyond the cap send no request and return cap_reached.
    static func planSearchCalls(legs: [[[SearchCallAttempt]]]) -> SearchCallPlan {
        let maxRequests = searchCallLimits.maxSearchRequestsPerReply
        var sent = 0
        var calls: [SearchCallPlan.Call] = []
        for (legIndex, leg) in legs.enumerated() {
            for (callIndex, attempts) in leg.enumerated() {
                if sent >= maxRequests {
                    calls.append(.init(leg: legIndex, call: callIndex, requests: 0, outcome: "cap_reached"))
                    continue
                }
                var requests = 0
                var last: SearchCallAttempt?
                var index = 0
                while index < attempts.count, index <= searchCallLimits.maxRetriesPerCall {
                    if sent >= maxRequests { break }
                    requests += 1
                    sent += 1
                    last = attempts[index]
                    guard case .status(let code)? = last, searchCallLimits.retryableStatuses.contains(code) else { break }
                    index += 1
                }
                let outcome: String
                switch last {
                case .status(let code)?: outcome = (200..<300).contains(code) ? "response" : String(code)
                case .failure(let name)?: outcome = name
                case nil: outcome = "cap_reached"
                }
                calls.append(.init(leg: legIndex, call: callIndex, requests: requests, outcome: outcome))
            }
        }
        return SearchCallPlan(requestsSent: sent, calls: calls)
    }

    /// Regenerate / resend after edit: by default reuses that message's previous result; it searches again only when the user taps "Search again".
    static func regenerateSearchPolicy(action: SearchRegenerateAction, previousResultsPersisted: Bool) -> SearchRegeneratePolicy {
        if action == .reSearch { return .init(reusePrevious: false, newSearchesAllowed: true) }
        if action == .regenerate || action == .editResend, previousResultsPersisted {
            return .init(reusePrevious: true, newSearchesAllowed: false)
        }
        return .init(reusePrevious: false, newSearchesAllowed: true)
    }
}
