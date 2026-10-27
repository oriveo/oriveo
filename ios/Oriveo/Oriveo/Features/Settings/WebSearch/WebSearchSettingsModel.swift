import Foundation
import Observation

// Data layer for Settings › Web search (external search services contract): reads stored services, the catalog and model connections, runs test searches, and writes only after a test passes.
// Status, grouping, default, consent sentences and test results are all derived through the seven pure functions of SearchSettings; this file only assembles and reads/writes.

/// What one stored service looks like on the settings page.
struct WebSearchServiceItem: Identifiable, Equatable {
    let service: StoredSearchService
    /// Entry in the current catalog (active); nil when withdrawn / not in the catalog / the catalog is unavailable.
    let entry: SearchJSON?
    let row: SearchServiceRowState
    let displayName: String
    /// Last 4 characters of the key the user pasted (detail page Key row); nil when there is no key.
    let keyTail: String?

    var id: String { service.id }
    var isCustom: Bool { service.kind == .custom }
}

/// All inputs needed for one test search (an unsaved service is built in memory, the key is never persisted).
enum WebSearchTestTarget: Sendable {
    case preset(entry: SearchJSON, regionId: String, boundHost: String, key: String?)
    case custom(spec: SearchJSON, address: SearchServiceAddress, requestPath: String, key: String?)
}

@MainActor
@Observable
final class WebSearchSettingsModel {
    private(set) var items: [WebSearchServiceItem] = []
    /// The effective default service (resolveDefaultSearchService).
    private(set) var defaultID: String?
    private(set) var catalogAvailable = false
    /// Usable catalog entries (catalog order).
    private(set) var entries: [SearchJSON] = []
    /// Model connections that have a key locally.
    private(set) var connections: [SearchSettingsConnection] = []
    private(set) var loaded = false

    @ObservationIgnored private var store: SearchServiceStore?
    @ObservationIgnored private var providers: [Provider] = []
    @ObservationIgnored private var withdrawnIDs: Set<String> = []
    @ObservationIgnored private var catalogNames: [String: String] = [:]
    @ObservationIgnored private let executor = SearchExecutor()
    /// Screenshot staging only: per-conversation source kept in memory (key = conversation id).
    @ObservationIgnored private var stagedSources: [String: SearchJSON]?

    // MARK: Read

    func load(appState: AppState) async {
        #if DEBUG
        // Screenshot staging only: manifest data lives in memory; storage, the catalog singleton and keys are untouched
        if let staged = WebSearchShots.staged {
            items = staged.items
            defaultID = staged.defaultID
            connections = staged.connections
            entries = staged.entries
            catalogNames = staged.catalogNames
            catalogAvailable = !staged.entries.isEmpty
            stagedSources = staged.sources
            loaded = true
            return
        }
        #endif
        await load(store: SearchServiceStore(scope: appState.sessionPartitionUID), providers: appState.providers)
    }

    /// Read stored services, the catalog (cache / built-in; ensureLoaded makes no network request) and model connections. The fresh computation before sending also goes through here.
    func load(store: SearchServiceStore, providers: [Provider], catalog: SearchCatalogStore = .shared) async {
        defer { WebSearchLocalServices.update(items.map(\.id)) }
        self.store = store
        self.providers = providers
        connections = Self.connections(from: providers)
        await catalog.ensureLoaded()
        let available = await catalog.isAvailable
        let presetsWithdrawn = await catalog.presetsWithdrawn
        catalogAvailable = available && !presetsWithdrawn
        entries = catalogAvailable ? await catalog.activeEntries() : []
        let document = await catalog.document
        var names: [String: String] = [:]
        for entry in document?["services"]?.arrayValue ?? [] {
            if let id = entry["id"]?.stringValue, let name = entry["displayName"]?.stringValue { names[id] = name }
        }
        catalogNames = names
        let services = await store.services()
        var withdrawn = Set<String>()
        var built: [WebSearchServiceItem] = []
        for service in services {
            let serviceID = service.serviceId ?? ""
            if await catalog.isWithdrawn(serviceID) { withdrawn.insert(serviceID) }
            let key = service.kind == .reuseConnection ? nil : (try? await store.key(for: service)) ?? nil
            let entry = service.kind == .custom ? nil : entries.first { $0["id"]?.stringValue == serviceID }
            let row = SearchSettings.searchServiceRowState(
                service: service.rowInput(hasKey: key != nil),
                catalogAvailable: catalogAvailable,
                entry: entry,
                withdrawn: withdrawn.contains(serviceID),
                connections: connections
            )
            built.append(WebSearchServiceItem(
                service: service,
                entry: entry,
                row: row,
                displayName: displayName(of: service),
                keyTail: key.map { String($0.suffix(4)) }
            ))
        }
        withdrawnIDs = withdrawn
        items = built
        defaultID = await store.resolvedDefaultServiceID()
        loaded = true
    }

    /// Red dot on the web search cell of the settings home.
    @MainActor
    static var entryShowsBadge: Bool {
        #if DEBUG
        // Screenshot staging only: manifest preset.badge
        if let forced = WebSearchShots.badgeOverride { return forced }
        #endif
        return FeatureBadges.shared.isUnseen(FeatureBadges.settingsWebSearch)
    }

    /// Value of the "Web search" cell on the settings home: the default service display name; nil when there is no service (shows "Not set").
    static func defaultServiceName(appState: AppState) async -> String? {
        let model = WebSearchSettingsModel()
        await model.load(appState: appState)
        guard let id = model.defaultID else { return nil }
        return model.items.first { $0.id == id }?.displayName
    }

    func item(_ serviceID: String) -> WebSearchServiceItem? {
        items.first { $0.id == serviceID }
    }

    func entry(_ serviceID: String?) -> SearchJSON? {
        entries.first { $0["id"]?.stringValue == serviceID }
    }

    /// Display name (searchServiceDisplayName): custom uses its name; presets go catalog displayName → name saved at save time → serviceId.
    func displayName(of service: StoredSearchService) -> String {
        SearchSettings.searchServiceDisplayName(
            kind: service.kind == .custom ? .custom : .preset,
            name: service.name,
            serviceId: service.serviceId,
            catalogDisplayName: catalogNames[service.serviceId ?? ""]
        )
    }

    /// Display name of a preset not yet stored (add sheet, connect page).
    func catalogName(_ serviceID: String?) -> String {
        SearchSettings.searchServiceDisplayName(
            kind: .preset, name: nil, serviceId: serviceID, catalogDisplayName: catalogNames[serviceID ?? ""]
        )
    }

    var addSheet: SearchAddSheet {
        SearchSettings.searchAddSheetSections(
            catalogAvailable: catalogAvailable,
            entries: entries,
            connections: connections,
            services: items.map {
                SearchSettingsServiceRef(id: $0.id, kind: $0.isCustom ? .custom : .preset, serviceId: $0.service.serviceId)
            }
        )
    }

    /// Official BYOK model connections that have a key locally (ProviderForm = official, API key auth; other forms do not count), in connection list order.
    /// The address uses requestBaseURLText(), the single entry point for the actual request address (including official site selection); when empty it falls back to that provider's default address.
    static func connections(from providers: [Provider]) -> [SearchSettingsConnection] {
        providers.compactMap { provider in
            guard ProviderForm.of(provider) == .official, provider.authMode == .apiKey,
                  !ProviderCredentialResolver.apiKey(provider: provider, modelID: nil).isEmpty else { return nil }
            let literal = provider.requestBaseURLText()?.trimmingCharacters(in: .whitespacesAndNewlines)
            return SearchSettingsConnection(
                id: provider.id.uuidString,
                name: provider.displayName,
                providerKind: provider.kind.rawValue,
                baseUrl: (literal?.isEmpty == false ? literal : nil) ?? provider.kind.defaultBaseURLText
            )
        }
    }

    func connectionName(_ connectionID: String?) -> String? {
        connections.first { $0.id == connectionID }?.name
    }

    /// The key actually sent when reusing a connection (follows the connection, not stored separately).
    func connectionKey(_ connectionID: String?) -> String? {
        guard let provider = providers.first(where: { $0.id.uuidString == connectionID }) else { return nil }
        let key = ProviderCredentialResolver.apiKey(provider: provider, modelID: nil)
        return key.isEmpty ? nil : key
    }

    /// Whether this preset has a reusable connection locally (the detail page offers the "Use your connection" option when changing a key).
    func reusableConnection(for entry: SearchJSON?) -> (connection: SearchSettingsConnection, regionId: String)? {
        guard let entry, let kind = entry["reuse"]?["providerKind"]?.stringValue else { return nil }
        for connection in connections where connection.providerKind == kind {
            if let region = SearchCatalog.regionForConnection(entry, connectionBaseUrl: connection.baseUrl) {
                return (connection, region)
            }
        }
        return nil
    }

    // MARK: Test search

    /// Run one test search (result count defaults to 5). The result lives only in memory.
    func runTest(_ target: WebSearchTestTarget, query: String, count: Int = SearchSettings.resultCountDefault) async -> SearchTestPresentation {
        let start = ContinuousClock.now
        let outcome: SearchExecutionOutcome
        switch target {
        case let .preset(entry, regionId, boundHost, key):
            outcome = await executor.runPreset(
                entry: entry, regionId: regionId, boundHost: boundHost, withdrawn: false,
                query: query, count: count, key: key
            )
        case let .custom(spec, address, requestPath, key):
            outcome = await executor.runCustom(
                spec: spec, address: address, requestPath: requestPath, query: query, count: count, key: key
            )
        }
        let elapsed = ContinuousClock.now - start
        let latencyMs = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        switch outcome {
        case .results(let results):
            return SearchSettings.searchTestPresentation(.passed(count: results.count, latencyMs: latencyMs))
        case .empty:
            return SearchSettings.searchTestPresentation(.passed(count: 0, latencyMs: latencyMs))
        case .failure(let classification):
            return SearchSettings.searchTestPresentation(.failed(errorClass: classification.errorClass, card: classification.card))
        }
    }

    /// Test target for a stored service (detail page "Test").
    func testTarget(for item: WebSearchServiceItem) async -> WebSearchTestTarget? {
        let service = item.service
        switch service.kind {
        case .preset, .reuseConnection:
            guard let entry = item.entry, let regionId = service.regionId, let host = service.boundHost else { return nil }
            let key = service.kind == .reuseConnection
                ? connectionKey(service.connectionRef)
                : (try? await store?.key(for: service)) ?? nil
            return .preset(entry: entry, regionId: regionId, boundHost: host, key: key)
        case .custom:
            guard let address = SearchTransport.parseServiceAddress(service.address) else { return nil }
            let spec: SearchJSON? = service.protocolID == "searxng"
                ? SearchTransport.searxngSpec
                : service.mappingJSON.flatMap { try? SearchJSON.parse($0) }
            guard let spec else { return nil }
            let path = service.protocolID == "searxng"
                ? SearchTransport.searxngPath(address.path)
                : (address.path.isEmpty ? "/" : address.path)
            let key = (try? await store?.key(for: service)) ?? nil
            return .custom(spec: spec, address: address, requestPath: path, key: key)
        }
    }

    // MARK: Write (called only after a test passes)

    /// Save a new preset (the test has passed). Returns the new service id; `becameDefault` is true when it becomes the effective default.
    func addPreset(
        entry: SearchJSON,
        regionId: String,
        connectionRef: String?,
        key: String?,
        testResult: String = "passed"
    ) async throws -> (id: String, becameDefault: Bool) {
        guard let store else { throw SearchServiceStoreError.invalidKey("key_empty") }
        let host = SearchCatalog.region(of: entry, id: regionId)?["host"]?.stringValue
        let service = StoredSearchService(
            id: UUID().uuidString,
            kind: connectionRef == nil ? .preset : .reuseConnection,
            serviceId: entry["id"]?.stringValue,
            regionId: regionId,
            boundHost: host,
            connectionRef: connectionRef,
            name: entry["displayName"]?.stringValue
        )
        try await store.save(service, key: connectionRef == nil ? key : nil)
        let resolved = await store.resolvedDefaultServiceID()
        await serviceListChanged(added: service)
        return (service.id, resolved == service.id)
    }

    /// Save a new custom service (the test has passed).
    func addCustom(_ service: StoredSearchService, key: String?, testResult: String = "passed") async throws -> Bool {
        guard let store else { return false }
        try await store.save(service, key: key)
        await serviceListChanged(added: service)
        return await store.resolvedDefaultServiceID() == service.id
    }

    /// After the service list is added to / removed from / edited: an add that came from the web card turns external on with the new service id, and the panel and composer preview are notified to recompute (no polling).
    private func serviceListChanged(added: StoredSearchService? = nil) async {
        if let added, let store {
            await SearchArmAfterAdd.shared.serviceAdded(id: added.id, name: displayName(of: added), store: store)
        }
        NotificationCenter.default.post(name: .oriveoConversationSearchSourceChanged, object: nil)
    }

    /// Update a stored service (change key / rename / change address or protocol / reconfirm host / result count). key non-nil = also write the new key.
    func update(_ service: StoredSearchService, key: String? = nil) async throws {
        try await store?.save(service, key: key)
        await serviceListChanged()
    }

    // MARK: Per-conversation source

    /// Services for which searchServiceSelectable is true (storage order): used by both the web card count and the "Search method" sheet.
    var selectableItems: [WebSearchServiceItem] {
        items.filter { SearchRoute.searchServiceSelectable($0.row.status) }
    }

    func conversationSource(_ conversationID: String) async -> SearchJSON? {
        if let stagedSources { return stagedSources[conversationID] }
        return await store?.conversationSource(conversationID)
    }

    func setConversationSource(_ value: SearchSourceStored?, conversationID: String) async {
        if stagedSources != nil {
            stagedSources?[conversationID] = try? value.map { try SearchJSON.parse(JSONEncoder().encode($0)) }
            return
        }
        try? await store?.setConversationSource(value, conversationID: conversationID)
        NotificationCenter.default.post(name: .oriveoConversationSearchSourceChanged, object: nil)
    }

    func setDefault(_ serviceID: String) async throws {
        try await store?.setDefaultServiceID(serviceID)
        defaultID = await store?.resolvedDefaultServiceID()
        await serviceListChanged()
    }

    func delete(_ serviceID: String) async throws {
        try await store?.remove(serviceID)
        await serviceListChanged()
    }

    /// Who becomes the default after a service is deleted (when the deleted one is the default and others remain, the confirmation adds a sentence).
    func defaultAfterDeleting(_ serviceID: String) -> WebSearchServiceItem? {
        guard defaultID == serviceID else { return nil }
        let remaining = items.map(\.id).filter { $0 != serviceID }
        let next = SearchSettings.resolveDefaultSearchService(serviceIds: remaining, storedDefault: serviceID)
        return next.flatMap(item)
    }

    // MARK: Custom form

    /// addressClass of a custom address: uses the existing LAN check of model connections (classified after RelayRequestSecurity resolution); resolution failure = unresolved.
    static func addressClass(_ address: SearchServiceAddress) async -> SearchAddressClass {
        let origin = "http://\(address.host)\(address.port.map { ":\($0)" } ?? "")"
        let verdict = await RelayRequestSecurity.classifyForModeSelection(origin, mode: .localHTTP)
        if verdict.allowed { return .lan }
        return verdict.reason.hasPrefix("dns") || verdict.reason == "invalid_url" ? .unresolved : .public
    }

    /// Validation on "Continue" / "Save": validateCustomSearchService + normalizeSearchKey when a key is entered → customFormFieldErrors.
    /// storedSnapshot: passed when editing a stored same_as service whose reference is unchanged: reuse it and treat the preset as available during validation (customServiceEditPlan).
    func validate(_ draft: WebSearchCustomDraft, storedSnapshot: SearchJSON? = nil) async -> WebSearchCustomValidation {
        let parsed = SearchTransport.parseServiceAddress(draft.address)
        var addressClass: SearchAddressClass?
        if let parsed { addressClass = await Self.addressClass(parsed) }
        let keepsSnapshot = draft.protocolID == "same_as" && storedSnapshot != nil
        let sameAsEntry = draft.protocolID == "same_as" && !keepsSnapshot ? entry(draft.sameAsServiceID) : nil
        let manual = draft.protocolID == "manual" ? draft.manualMapping : nil
        let validation = SearchTransport.validateCustomSearchService(CustomSearchServiceInput(
            name: draft.name,
            address: draft.address,
            protocolID: draft.protocolID,
            platform: .ios,
            addressClass: addressClass,
            presetID: draft.sameAsServiceID,
            catalogAvailable: keepsSnapshot || catalogAvailable,
            presetActive: keepsSnapshot || sameAsEntry != nil,
            manual: manual
        ))
        var errors = validation.errors
        var normalizedKey: String?
        if !SearchJSText.trim(draft.key).isEmpty {
            let normalized = SearchTransport.normalizeSearchKey(draft.key)
            if let error = normalized.error { errors.append(error) }
            normalizedKey = normalized.key
        }
        let presentation = (try? SearchSettings.customFormFieldErrors(errors: errors, warnings: validation.warnings))
            ?? SearchFormFieldErrors(fields: [:], warnings: [:], blocking: true)
        var spec: SearchJSON?
        switch draft.protocolID {
        case "searxng": spec = SearchTransport.searxngSpec
        case "same_as": spec = keepsSnapshot ? storedSnapshot : sameAsEntry.map { SearchTransport.snapshotPresetMapping($0, regionId: nil) }
        default: spec = manual
        }
        var target: WebSearchTestTarget?
        if !presentation.blocking, let parsed, let spec, let path = validation.requestPath {
            target = .custom(spec: spec, address: parsed, requestPath: path, key: normalizedKey)
        }
        return WebSearchCustomValidation(fields: presentation, target: target, spec: spec, key: normalizedKey)
    }
}

/// Custom form validation result: field hints + the test target when a test can run.
struct WebSearchCustomValidation {
    var fields: SearchFormFieldErrors
    var target: WebSearchTestTarget?
    var spec: SearchJSON?
    var key: String?
}

/// Draft of the custom form (shared by adding and detail editing).
struct WebSearchCustomDraft: Equatable {
    struct Param: Identifiable, Equatable {
        let id = UUID()
        var name = ""
        var value = ""
    }

    var name = ""
    var address = ""
    var key = ""
    /// searxng / same_as / manual
    var protocolID = "searxng"
    var sameAsServiceID: String?
    var method = "GET"
    /// bearer / header / none
    var auth = "bearer"
    var headerName = ""
    var queryField = "q"
    var countField = ""
    var params: [Param] = []
    var resultsPath = ""
    var titlePath = ""
    var urlPath = ""
    var snippetPath = ""
    var sitePath = ""
    var datePath = ""

    init() {}

    /// Restore from a stored custom service (detail page editing).
    init(service: StoredSearchService) {
        name = service.name ?? ""
        address = service.address ?? ""
        protocolID = service.protocolID ?? "searxng"
        guard let mapping = service.mappingJSON.flatMap({ try? SearchJSON.parse($0) }) else { return }
        if protocolID == "same_as" {
            sameAsServiceID = mapping["snapshotOf"]?["serviceId"]?.stringValue
            return
        }
        method = mapping["method"]?.stringValue ?? "GET"
        auth = mapping["auth"]?["kind"]?.stringValue ?? "bearer"
        headerName = mapping["auth"]?["name"]?.stringValue ?? ""
        queryField = mapping["query"]?["field"]?.stringValue ?? ""
        countField = mapping["count"]?["field"]?.stringValue ?? ""
        params = (mapping["static"]?["params"]?.objectValue?.entries ?? []).map {
            Param(name: $0.key, value: $0.value.jsString)
        }
        let response = mapping["response"]
        resultsPath = response?["results"]?.stringValue ?? ""
        func first(_ key: String) -> String { response?[key]?.arrayValue?.first?.stringValue ?? "" }
        titlePath = first("title")
        urlPath = first("url")
        snippetPath = first("snippet")
        sitePath = first("site")
        datePath = first("date")
    }

    /// Manual mapping (json_http/v1 subset); for GET the query / count / extra parameters go in the query string, for POST in the body.
    var manualMapping: SearchJSON {
        let location: SearchJSON = method == "GET" ? "query" : "body"
        var object = SearchJSONObject()
        object["kind"] = .string(SearchTransport.kind)
        object["method"] = .string(method)
        var authObject = SearchJSONObject([("kind", .string(auth))])
        if auth == "header" { authObject["name"] = .string(SearchJSText.trim(headerName)) }
        object["auth"] = .object(authObject)
        object["query"] = ["field": .string(SearchJSText.trim(queryField)), "in": location]
        let count = SearchJSText.trim(countField)
        object["count"] = count.isEmpty ? .null : ["field": .string(count), "in": location]
        let filled = params.filter { !SearchJSText.trim($0.name).isEmpty }
        if !filled.isEmpty {
            var values = SearchJSONObject()
            for param in filled { values[SearchJSText.trim(param.name)] = Self.paramValue(param.value) }
            object["static"] = .object(SearchJSONObject([("in", location), ("params", .object(values))]))
        } else {
            object["static"] = .null
        }
        func paths(_ raw: String) -> SearchJSON {
            let trimmed = SearchJSText.trim(raw)
            return trimmed.isEmpty ? [] : [.string(trimmed)]
        }
        var response = SearchJSONObject()
        response["results"] = .string(SearchJSText.trim(resultsPath))
        response["title"] = paths(titlePath)
        response["url"] = paths(urlPath)
        response["snippet"] = paths(snippetPath)
        if !SearchJSText.trim(sitePath).isEmpty { response["site"] = paths(sitePath) }
        if !SearchJSText.trim(datePath).isEmpty { response["date"] = paths(datePath) }
        object["response"] = .object(response)
        object["errors"] = []
        return .object(object)
    }

    /// Value of an extra parameter: true / false → boolean, integer literal → integer, anything else as text.
    private static func paramValue(_ raw: String) -> SearchJSON {
        let trimmed = SearchJSText.trim(raw)
        if trimmed == "true" { return true }
        if trimmed == "false" { return false }
        if let integer = Int64(trimmed) { return .int(integer) }
        return .string(raw)
    }
}

/// Result of the most recent read of locally stored search service ids (refreshed on every load; the fresh computation before sending also goes through load). The chat error card uses it to decide whether to offer
/// "Answer again with X"; before anything has been read it is treated as present (resolved against the current state at tap time; if gone, the settings page opens).
@MainActor
enum WebSearchLocalServices {
    private static var ids: Set<String>?

    static func update(_ ids: [String]) { self.ids = Set(ids) }

    static func contains(_ id: String) -> Bool { ids?.contains(id) ?? true }
}
