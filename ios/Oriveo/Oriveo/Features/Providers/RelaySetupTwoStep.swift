import Foundation
import Observation

// MARK: - Two-step relay setup (Setup / SetupModels boards)
//
// Step 1: address + keys (possibly several) -> three check items on the check card (connectivity / fetch catalog / detect protocol), with zero chat requests.
// Step 2: tick models by group -> on save, a 1-token request goes only to the first ticked model in display order, and the connection is stored only if it passes.
// The view renders only the state here; state decisions live in pure types so structural tests can assert on them directly.

/// One key of step 1: value + optional name. The first is the primary key (id = `RelayKeyBinding.implicitKeyID`).
struct RelaySetupKeyDraft: Identifiable, Equatable {
    let id: String
    var secret = ""
    var name = ""

    var trimmedSecret: String { secret.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedName: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// How a key is referred to on chips and catalog rows: the name if there is one, otherwise the mask (no new "Key N" copy is added).
    var label: String { trimmedName ?? APIKeyMask.masked(trimmedSecret) }
}

// MARK: - One-sentence failures

/// The one-sentence failure of a step 1 item (button contract): four dedicated sentences, the rest reuse the existing failure reasons.
enum RelaySetupFailure: Equatable {
    /// Route unavailable / returned a web page.
    case address
    /// 401.
    case invalidKey
    /// 403.
    case cannotListModels
    /// Network class.
    case cannotConnect
    /// Catalog empty / only a generation route was found.
    case emptyCatalog
    /// Existing failure reason (a key in the Providers table).
    case other(textKey: String)
    /// The original text given by the upstream / system.
    case message(String)

    var textKey: String {
        switch self {
        case .address: "The address may point to a web page. Check whether /v1 is missing."
        case .invalidKey: "The key is invalid."
        case .cannotListModels: "This key can’t list models. You can add models manually."
        case .cannotConnect: "Can’t connect. Check your network or proxy."
        case .emptyCatalog: RelaySetupModelsBoard.emptyKey
        case .other(let textKey): textKey
        case .message(let text): text
        }
    }

    var text: String {
        if case .message(let text) = self { return text }
        return L10n.tr(textKey, table: .providers)
    }

    /// Verdict of the discovery service -> one sentence. `statusCodes` are the HTTP statuses of each attempt (authentication failures use them to tell 401 / 403 apart).
    static func classify(discoveryFailure: RelayDiscoveryFailureKind?, statusCodes: [Int]) -> Self {
        switch discoveryFailure {
        case .routeUnavailable, .invalidResponse:
            return .address
        case .authenticationRejected:
            if statusCodes.contains(401) { return .invalidKey }
            return statusCodes.contains(403) ? .cannotListModels : .invalidKey
        case .network, .temporaryFailure:
            return .cannotConnect
        case .embeddedQuery, .rateLimited, .invalidEndpoint, nil:
            return .other(textKey: discoveryReasonKey(discoveryFailure))
        }
    }

    static func classify(_ result: RelayDiscoveryResult) -> Self {
        classify(discoveryFailure: result.blockingFailure, statusCodes: result.attempts.compactMap(\.statusCode))
    }

    /// A request that threw (fetching the catalog with an extra key, or the discovery service itself failing): use the status code if there is one, otherwise classify as a network error.
    static func classify(status: Int?, error: Error) -> Self {
        switch status {
        case 401: return .invalidKey
        case 403: return .cannotListModels
        case 404, 405: return .address
        case .some(500 ... 599): return .cannotConnect
        default: break
        }
        if status == nil, error is URLError { return .cannotConnect }
        if status == nil, case ProviderServiceError.network = error { return .cannotConnect }
        return .message((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    /// Existing discovery failure reasons (formerly `RelaySetupView.discoveryFailureMessage`).
    static func discoveryReasonKey(_ failure: RelayDiscoveryFailureKind?) -> String {
        switch failure {
        case .embeddedQuery:
            "Remove query parameters from the request URL. Oriveo never tries API keys from query parameters automatically."
        case .authenticationRejected:
            "The server rejected the API key. Check the key or choose the documented protocol manually."
        case .rateLimited:
            "The service at this address is rate limiting requests. Wait a moment and try again; Oriveo didn't switch to another key or protocol."
        case .temporaryFailure, .network:
            "Couldn't connect to this address reliably. Check the address and try again."
        case .routeUnavailable:
            "Neither a model catalog nor a known generation endpoint answered at this address. Check the address, or choose the protocol manually."
        case .invalidEndpoint:
            "Enter a valid HTTPS request URL."
        case .invalidResponse:
            "The service at this address answered, but its model catalog format was not recognized."
        case nil:
            "No supported configuration was detected at this address."
        }
    }
}

// MARK: - Check card state

struct RelaySetupDetection: Equatable {
    enum ItemID: CaseIterable, Equatable {
        case connection
        case catalog
        case protocols
    }

    enum Status: Equatable {
        case pending
        case running
        case done
        case failed
        case skipped

        var isTerminal: Bool { self == .done || self == .failed || self == .skipped }
    }

    struct Check: Equatable {
        var status: Status = .pending
        var startedAt: Date?
        var finishedAt: Date?

        /// Time taken by this item; nil if not started, computed against `now` while in progress.
        func elapsed(now: Date) -> TimeInterval? {
            guard let startedAt else { return nil }
            return max(0, (finishedAt ?? now).timeIntervalSince(startedAt))
        }

        mutating func start(at date: Date = Date()) {
            status = .running
            startedAt = date
            finishedAt = nil
        }

        mutating func finish(_ result: Status, at date: Date = Date()) {
            status = result
            if startedAt == nil, result != .skipped { startedAt = date }
            finishedAt = startedAt == nil ? nil : date
        }
    }

    struct KeyLabel: Equatable {
        let id: String
        let label: String
    }

    /// One line per key under the fetch-catalog item: name + model count, or a failure sentence.
    struct KeyCatalog: Equatable {
        let keyID: String
        let label: String
        var status: Status = .pending
        var modelCount: Int?
        var failure: RelaySetupFailure?
    }

    var connection = Check()
    var catalog = Check()
    var protocols = Check()
    /// Detail of the connectivity item: the path the catalog request actually succeeded on (such as /v1/models).
    var reachablePath: String?
    var keyCatalogs: [KeyCatalog]
    /// The sentence that stops at step 1 (connectivity failed or the catalog is empty).
    var failure: RelaySetupFailure?
    /// Model count merged across all keys.
    var modelCount = 0
    /// What was tried when connectivity failed (in the form `GET /v1/models → 404`) and the upstream's own words, given verbatim beneath the one-sentence failure.
    var attemptLines: [String] = []
    var upstreamMessage: String?

    init(keys: [KeyLabel]) {
        keyCatalogs = keys.map { KeyCatalog(keyID: $0.id, label: $0.label) }
    }

    /// Which URLs were tried and what each returned; the upstream's own words prefer the 400 / 422 one (it often carries the relay's description of itself).
    static func diagnostics(from result: RelayDiscoveryResult) -> (lines: [String], upstream: String?) {
        let lines = result.attempts.map { attempt in
            let method = attempt.kind == .catalog ? "GET" : "POST"
            let path = URL(string: attempt.requestURL)?.path ?? attempt.requestURL
            let status = attempt.statusCode.map(String.init) ?? "—"
            return "\(method) \(path) → \(status)"
        }
        let informative = result.attempts.filter { $0.upstreamMessage?.isEmpty == false }
        let preferred = informative.last { attempt in
            guard let status = attempt.statusCode else { return false }
            return status == 400 || status == 422
        }
        return (lines, (preferred ?? informative.last)?.upstreamMessage)
    }

    var completedCount: Int {
        [connection, catalog, protocols].filter { $0.status.isTerminal }.count
    }

    var isFinished: Bool { completedCount == ItemID.allCases.count }
    /// Success with a non-empty catalog -> go to step 2 automatically; otherwise stay on step 1, and tapping Next again enters the manual-add state.
    var succeeded: Bool { isFinished && modelCount > 0 && connection.status == .done }
}

// MARK: - Step 2 pure model

/// Step 2, "Choose the models to use" (SetupModels board).
struct RelaySetupModelsBoard: Equatable {
    static let titleKey = "Choose models to use"
    static let keyCountKey = "%lld keys"
    static let searchKey = "Search %lld models"
    static let groupSelectedKey = "%lld selected"
    static let selectGroupKey = "Select all in group"
    static let addManualKey = "Add model ID manually"
    /// A line under the button shown when a manually added ID is already in the list.
    static let manualDuplicateNoteKey = "Already in the list. It’s selected now."
    static let saveNoteKey = "After saving, Oriveo sends one tiny request to the first selected model to confirm it works."
    static let saveSelectedKey = "Save (%lld selected)"
    static let emptyKey = "Couldn’t get the model list. Add the model IDs you want to use."
    static let stepOfKey = RelaySetupBoardModel.stepOfKey

    /// Groups = the group id / group name / in-group order of the same projection as the model library (`projectProviderCatalogGroups`).
    struct Group: Equatable, Sendable {
        let id: String
        let title: String
        let modelIDs: [String]
    }

    struct KeyLabel: Equatable {
        let id: String
        let label: String
    }

    struct Input {
        var groups: [Group] = []
        var selected: Set<String> = []
        /// Groups the user expanded / collapsed by hand; groups never touched follow the rule (a group with a selection is expanded).
        var expansion: [String: Bool] = [:]
        var searchText = ""
        /// Keys added this time (primary key first); key chips are drawn only with 2 or more.
        var keys: [KeyLabel] = []
        /// Which keys list a catalog entry (mergeCatalog); default = the primary key.
        var listedBy: [String: [String]] = [:]
        var protocols: [String: RelayTransport] = [:]
        var isSaving = false
        /// Family used for binding: obtained the same way as when enabling a model (a cached Server family -> `RelayFamilyHeuristics`).
        var family: (String) -> String? = RelaySetupModelsBoard.bindingFamily
    }

    struct Row: Equatable {
        let id: String
        let isSelected: Bool
        /// First candidate (ranked locally in step 1); nil = unknown, not drawn.
        let protocolTransport: RelayTransport?
        /// How the bound key is referred to; present only with 2 or more keys and when ticked.
        let keyLabel: String?
    }

    struct GroupRow: Equatable {
        let id: String
        let title: String
        let count: Int
        let selectedCount: Int
        let isExpanded: Bool
        let canSelectAll: Bool
        /// All rows shown after expanding (when searching, only matching rows remain).
        let rows: [Row]
    }

    let groups: [GroupRow]
    let totalModelCount: Int
    let selectedInDisplayOrder: [String]
    /// Ticked model -> bound key id (bound one by one in display order); empty for a single key.
    let boundKeyByModel: [String: String]
    let showsKeyChips: Bool
    /// "n keys" in the subtitle; nil = not shown (fewer than 2 keys).
    let subtitleKeyCount: Int?
    let showsEmptyNote: Bool
    let isSaveEnabled: Bool

    var selectedCount: Int { selectedInDisplayOrder.count }
    var saveCount: Int { selectedInDisplayOrder.count }
    /// Verification sample = the first ticked model in display order.
    var firstSelectedID: String? { selectedInDisplayOrder.first }

    static func make(_ input: Input) -> Self {
        let query = input.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seen = Set<String>()
        let displayOrder = input.groups.flatMap(\.modelIDs).filter { seen.insert($0).inserted }
        let selectedOrder = displayOrder.filter { input.selected.contains($0) }

        let keyIDs = input.keys.map(\.id)
        var bound: [String: String] = [:]
        if keyIDs.count >= 2 {
            let catalog = displayOrder.map { id -> AIModel in
                var model = stubModel(id)
                model.relayListedByKeyIDs = input.listedBy[id]
                return model
            }
            var enabled: [AIModel] = []
            for id in selectedOrder {
                let keyID = RelayKeyBinding.bind(
                    keyIDs: keyIDs,
                    catalog: catalog,
                    enabled: enabled,
                    targetModelID: id,
                    family: input.family
                ) ?? keyIDs[0]
                bound[id] = keyID
                var model = stubModel(id)
                model.relayKeyID = keyID
                enabled.append(model)
            }
        }
        let labels = Dictionary(input.keys.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })

        let groups: [GroupRow] = input.groups.compactMap { group in
            let visible = query.isEmpty ? group.modelIDs : group.modelIDs.filter { $0.lowercased().contains(query) }
            guard !visible.isEmpty else { return nil }
            let selectedCount = group.modelIDs.filter { input.selected.contains($0) }.count
            let expanded = query.isEmpty ? (input.expansion[group.id] ?? (selectedCount > 0)) : true
            return GroupRow(
                id: group.id,
                title: group.title,
                count: group.modelIDs.count,
                selectedCount: selectedCount,
                isExpanded: expanded,
                canSelectAll: selectedCount < group.modelIDs.count,
                rows: visible.map { id in
                    Row(
                        id: id,
                        isSelected: input.selected.contains(id),
                        protocolTransport: input.protocols[id],
                        keyLabel: bound[id].flatMap { labels[$0] }
                    )
                }
            )
        }

        return Self(
            groups: groups,
            totalModelCount: displayOrder.count,
            selectedInDisplayOrder: selectedOrder,
            boundKeyByModel: bound,
            showsKeyChips: keyIDs.count >= 2,
            subtitleKeyCount: keyIDs.count >= 2 ? keyIDs.count : nil,
            showsEmptyNote: input.groups.isEmpty,
            isSaveEnabled: !selectedOrder.isEmpty && !input.isSaving
        )
    }

    /// Select all in this group: everything in the group joins the selection (the button is disabled once all are selected).
    static func selectingAll(groupID: String, groups: [Group], selected: Set<String>) -> Set<String> {
        guard let group = groups.first(where: { $0.id == groupID }) else { return selected }
        return selected.union(group.modelIDs)
    }

    static func bindingFamily(_ modelID: String) -> String? {
        MetadataClient.shared.cachedRelayModelFamilyNow(for: modelID)
            ?? RelayFamilyHeuristics.infer(modelID: modelID)?.rawValue
    }

    private static func stubModel(_ id: String) -> AIModel {
        AIModel(
            id: id,
            name: id,
            capabilities: [.text],
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: false,
            priceTier: ""
        )
    }
}

// MARK: - Flow

/// The single state and action exit of the two-step setup. Generations (invalidate / cancel) are managed by the shared `CustomLLMSetupCoordinator`.
@MainActor
@Observable
final class RelayQuickSetupFlow {
    enum Step: Equatable {
        case connection
        case models
    }

    let coordinator: CustomLLMSetupCoordinator
    @ObservationIgnored private let makeDiscoveryService: () -> RelayDiscoveryService
    @ObservationIgnored private let family: (String) async -> String?
    @ObservationIgnored private let cachedFamily: (String) -> String?
    /// A custom relay is a public-internet entry point; the new-connection path accepts only HTTPS.
    private let securityMode: RelayConnectionSecurityMode = .remoteHTTPS

    private(set) var endpoint = ""
    private(set) var keys: [RelaySetupKeyDraft] = [RelaySetupKeyDraft(id: RelayKeyBinding.implicitKeyID)]
    private(set) var step: Step = .connection
    private(set) var detection: RelaySetupDetection?
    private(set) var discoveryResult: RelayDiscoveryResult?
    /// Keys used by this round of checks (primary key + extra keys with a value); saving adds keys from this list.
    private(set) var detectedKeys: [RelaySetupKeyDraft] = []
    /// Draft catalog merged across all keys (entry shape matches what registration stores).
    private(set) var catalogModels: [AIModel] = []
    private(set) var listedBy: [String: [String]] = [:]
    private(set) var manualModelIDs: [String] = []
    private(set) var modelGroups: [RelaySetupModelsBoard.Group] = []
    private(set) var protocols: [String: RelayTransport] = [:]
    private(set) var selected: Set<String> = []
    private(set) var expansion: [String: Bool] = [:]
    var searchText = ""
    private(set) var saveFailure: String?
    private(set) var isSaving = false
    @ObservationIgnored private var keyStates: [String: (state: RelayKey.Status.State, httpStatus: Int?)] = [:]
    @ObservationIgnored private var detectionTask: Task<Void, Never>?

    init(
        coordinator: CustomLLMSetupCoordinator,
        makeDiscoveryService: @escaping () -> RelayDiscoveryService = { RelayDiscoveryService() },
        family: @escaping (String) async -> String? = { await MetadataClient.shared.relayModelFamily(for: $0) },
        cachedFamily: @escaping (String) -> String? = { MetadataClient.shared.cachedRelayModelFamilyNow(for: $0) }
    ) {
        self.coordinator = coordinator
        self.makeDiscoveryService = makeDiscoveryService
        self.family = family
        self.cachedFamily = cachedFamily
    }

    // MARK: Step 1 input (changing the address / keys invalidates this round)

    func setEndpoint(_ value: String) {
        guard value != endpoint else { return }
        endpoint = value
        invalidateDetection()
    }

    func setSecret(_ value: String, for keyID: String) {
        guard let index = keys.firstIndex(where: { $0.id == keyID }), keys[index].secret != value else { return }
        keys[index].secret = value
        invalidateDetection()
    }

    /// The name is just a label and does not invalidate the check.
    /// The name input appears only with 2 or more keys (a single key does not store relayKeys).
    var showsKeyNames: Bool { keys.count >= 2 }

    func setName(_ value: String, for keyID: String) {
        guard let index = keys.firstIndex(where: { $0.id == keyID }) else { return }
        keys[index].name = value
    }

    @discardableResult
    func addKey() -> String {
        let id = UUID().uuidString
        keys.append(RelaySetupKeyDraft(id: id))
        return id
    }

    /// The primary key cannot be deleted.
    func removeKey(_ keyID: String) {
        guard keyID != RelayKeyBinding.implicitKeyID,
              let index = keys.firstIndex(where: { $0.id == keyID }) else { return }
        let hadSecret = !keys[index].trimmedSecret.isEmpty
        keys.remove(at: index)
        // Back to a single key: the name is no longer shown or storable, so clear it to avoid an invisible name on the check card and chips.
        if keys.count == 1 { keys[0].name = "" }
        if hadSecret { invalidateDetection() }
    }

    /// Write the normalized address back to the visible input before sending; returns whether it was rewritten (the view flashes the input slot accordingly).
    @discardableResult
    func writeBackEndpoint() -> Bool {
        let raw = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let writeback = RelaySecurityModeSelection.endpointWriteback(raw, securityMode: securityMode),
              writeback.endpoint != endpoint else { return false }
        endpoint = writeback.endpoint
        return true
    }

    var canDetect: Bool {
        let primary = keys[0].trimmedSecret
        guard RelaySetupDiscoveryInputPolicy.permitsDiscovery(endpoint: endpoint, apiKey: primary, authMode: .auto) else {
            return false
        }
        return keys.dropFirst().allSatisfy { $0.trimmedSecret.isEmpty || ProviderKeyInput.isPrintableASCII($0.trimmedSecret) }
    }

    var detectedRoot: String? { discoveryResult?.detections.first?.apiBaseURL }

    var previewLine: String? {
        RelaySetupBoardModel.previewLine(detectedRoot: detectedRoot, input: endpoint)
    }

    var host: String {
        ProviderManager.relayDomainName(from: endpoint) ?? endpoint
    }

    func connectionBoard(canAct: Bool) -> RelaySetupBoardModel {
        RelaySetupBoardModel.make(.init(detection: detection, canAct: canAct && canDetect))
    }

    var isDetecting: Bool {
        guard let detection else { return false }
        return !detection.isFinished
    }

    /// Primary button. While checking, returns the check task (tests wait for it to finish).
    @discardableResult
    func next(appState: AppState) -> Task<Void, Never>? {
        switch connectionBoard(canAct: true).nextAction {
        case .detect:
            return startDetection(appState: appState)
        case .wait:
            return nil
        case .models:
            step = .models
            return nil
        }
    }

    func cancelDetection() {
        invalidateDetection()
    }

    func backToConnection() {
        step = .connection
        saveFailure = nil
    }

    private func invalidateDetection() {
        detectionTask?.cancel()
        detectionTask = nil
        coordinator.invalidate()
        detection = nil
        discoveryResult = nil
        detectedKeys = []
        step = .connection
        resetModels()
    }

    private func resetModels() {
        catalogModels = []
        listedBy = [:]
        keyStates = [:]
        manualModelIDs = []
        showsManualModelDuplicateNote = false
        modelGroups = []
        protocols = [:]
        selected = []
        expansion = [:]
        searchText = ""
        saveFailure = nil
    }

    // MARK: Check (zero chat requests: the discovery service's generation-endpoint probe stays as before, otherwise only catalog GETs)

    private func startDetection(appState: AppState) -> Task<Void, Never>? {
        guard canDetect else { return nil }
        resetModels()
        let activeKeys = [keys[0]] + keys.dropFirst().filter { !$0.trimmedSecret.isEmpty }
        detectedKeys = activeKeys
        detection = RelaySetupDetection(keys: activeKeys.map { .init(id: $0.id, label: $0.label) })
        let attempt = coordinator.beginVerification(for: .relay)
        guard let normalized = RelaySetupView.normalizedRelayEndpoint(
            endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            securityMode: securityMode
        ) else {
            failConnection(.other(textKey: RelayEndpointPolicy.httpsRequiredMessageKey))
            _ = coordinator.acceptFailure(for: attempt)
            return nil
        }
        let service = appState.providerManager.openAIService
        let task = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.performDetection(attempt: attempt, endpoint: normalized, keys: activeKeys, service: service)
        }
        detectionTask = task
        coordinator.registerCancellation(for: attempt) { task.cancel() }
        return task
    }

    private func performDetection(
        attempt: CustomLLMSetupAttempt,
        endpoint: String,
        keys: [RelaySetupKeyDraft],
        service: OpenAIService
    ) async {
        let primary = keys[0]
        detection?.connection.start()
        let result: RelayDiscoveryResult
        do {
            result = try await makeDiscoveryService().discover(
                endpoint: endpoint,
                apiKey: primary.trimmedSecret,
                modelHint: nil,
                securityMode: securityMode
            )
        } catch is CancellationError {
            return
        } catch {
            guard coordinator.isCurrent(attempt) else { return }
            failConnection(RelaySetupFailure.classify(status: nil, error: error))
            _ = coordinator.acceptFailure(for: attempt)
            return
        }
        guard !Task.isCancelled, coordinator.isCurrent(attempt) else { return }
        discoveryResult = result
        guard let first = result.detections.first else {
            let diagnostics = RelaySetupDetection.diagnostics(from: result)
            detection?.attemptLines = diagnostics.lines
            detection?.upstreamMessage = diagnostics.upstream
            failConnection(RelaySetupFailure.classify(result))
            _ = coordinator.acceptFailure(for: attempt)
            return
        }
        detection?.reachablePath = result.attempts
            .last(where: { $0.failure == nil })
            .flatMap { URL(string: $0.requestURL)?.path }
        detection?.connection.finish(.done)

        // (2) Fetch catalog: the first key comes from discovery, the others GET one by one per catalogAPIRoot (syncProvider carries relayRequested).
        detection?.catalog.start()
        var seen = Set<String>()
        let primaryIDs = result.detections.flatMap(\.modelIDs).filter { seen.insert($0).inserted }
        setKeyCatalog(primary.id, count: primaryIDs.count)
        let requested = RelayAddVerification.connectionRequested(
            detection: first,
            explicitTransport: result.descriptor.explicitTransport,
            formAuthMode: .auto,
            securityMode: securityMode,
            modelID: nil
        )
        var fetches: [String: RelayKeyBinding.CatalogFetch] = [
            primary.id: .ok(ProviderManager.relayCatalogModels(modelIDs: primaryIDs, relayRequested: requested)),
        ]
        for key in keys.dropFirst() {
            updateKeyCatalog(key.id) { $0.status = .running }
            let recorder = RelayPreOutputRejection.Recorder()
            do {
                let sync = try await RelayPreOutputRejection.$current.withValue(recorder) {
                    try await service.syncProvider(
                        apiKey: key.trimmedSecret,
                        preferredModelID: nil,
                        baseURL: endpoint,
                        relayRequested: requested
                    )
                }
                guard !Task.isCancelled, coordinator.isCurrent(attempt) else { return }
                fetches[key.id] = .ok(sync.models)
                setKeyCatalog(key.id, count: sync.models.count)
            } catch is CancellationError {
                return
            } catch {
                guard coordinator.isCurrent(attempt) else { return }
                let rejection = recorder.rejection
                fetches[key.id] = .failed(
                    status: rejection?.status,
                    body: rejection.map { String(decoding: $0.body, as: UTF8.self) } ?? ""
                )
                updateKeyCatalog(key.id) {
                    $0.status = .failed
                    $0.failure = RelaySetupFailure.classify(status: rejection?.status, error: error)
                }
            }
        }

        let keyIDs = keys.map(\.id)
        let mergedIDs: [String]
        if keyIDs.count >= 2 {
            let merged = RelayKeyBinding.mergeCatalog(keyIDs: keyIDs, previous: [], results: fetches)
            mergedIDs = merged.catalog.map(\.id)
            listedBy = Dictionary(
                merged.catalog.map { ($0.id, $0.relayListedByKeyIDs ?? [primary.id]) },
                uniquingKeysWith: { first, _ in first }
            )
            keyStates = merged.states
        } else {
            mergedIDs = primaryIDs
        }
        catalogModels = ProviderManager.relayCatalogModels(modelIDs: mergedIDs, relayRequested: requested).map { model in
            var model = model
            model.relayListedByKeyIDs = listedBy[model.id]
            return model
        }
        detection?.modelCount = catalogModels.count
        guard !catalogModels.isEmpty else {
            detection?.catalog.finish(.failed)
            detection?.failure = .emptyCatalog
            detection?.protocols.finish(.skipped)
            _ = coordinator.acceptFailure(for: attempt)
            return
        }
        detection?.catalog.finish(.done)

        // (3) Detect protocol: gateway fields -> the cached Server family, rank candidates locally, send no request.
        detection?.protocols.start()
        var transports: [String: RelayTransport] = [:]
        let cachedFamily = cachedFamily
        for model in catalogModels {
            transports[model.id] = await RelayProtocolMix.protocolOf(
                modelID: model.id,
                endpointTypes: first.endpointTypesByModel[model.id],
                verifiedDefault: nil,
                family: { cachedFamily($0) }
            )
        }
        guard !Task.isCancelled, coordinator.isCurrent(attempt) else { return }
        protocols = transports
        rebuildGroups()
        detection?.protocols.finish(.done)
        step = .models
    }

    private func failConnection(_ failure: RelaySetupFailure) {
        detection?.connection.finish(.failed)
        detection?.failure = failure
        detection?.catalog.finish(.skipped)
        detection?.protocols.finish(.skipped)
        if var current = detection {
            for index in current.keyCatalogs.indices { current.keyCatalogs[index].status = .skipped }
            detection = current
        }
    }

    private func setKeyCatalog(_ keyID: String, count: Int) {
        updateKeyCatalog(keyID) {
            $0.modelCount = count
            $0.status = count > 0 ? .done : .failed
            $0.failure = count > 0 ? nil : .emptyCatalog
        }
    }

    private func updateKeyCatalog(_ keyID: String, _ body: (inout RelaySetupDetection.KeyCatalog) -> Void) {
        guard var current = detection, let index = current.keyCatalogs.firstIndex(where: { $0.keyID == keyID }) else { return }
        body(&current.keyCatalogs[index])
        detection = current
    }

    // MARK: Step 2

    var modelsBoard: RelaySetupModelsBoard {
        RelaySetupModelsBoard.make(.init(
            groups: modelGroups,
            selected: selected,
            expansion: expansion,
            searchText: searchText,
            keys: detectedKeys.map { .init(id: $0.id, label: $0.label) },
            listedBy: listedBy,
            protocols: protocols,
            isSaving: isSaving
        ))
    }

    func toggle(modelID: String) {
        if selected.contains(modelID) {
            selected.remove(modelID)
        } else {
            selected.insert(modelID)
        }
        saveFailure = nil
        showsManualModelDuplicateNote = false
    }

    func selectAll(groupID: String) {
        selected = RelaySetupModelsBoard.selectingAll(groupID: groupID, groups: modelGroups, selected: selected)
        saveFailure = nil
        showsManualModelDuplicateNote = false
    }

    func toggleGroup(_ groupID: String) {
        let isExpanded = modelsBoard.groups.first(where: { $0.id == groupID })?.isExpanded ?? false
        expansion[groupID] = !isExpanded
    }

    /// Result of manually adding a model ID.
    enum ManualModelAddResult: Equatable {
        case added
        /// Already in the catalog or added by hand before: nothing new is added, the existing item is ticked.
        case alreadyListed
        /// Empty string or whitespace only.
        case ignored
    }

    /// Criterion for the dialog's "Add" being tappable: non-empty after trimming leading and trailing whitespace.
    static func canAddManualModel(_ raw: String) -> Bool {
        !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The "already in the list" hint line under the "Add model ID manually" button; it disappears on the next successful add, on toggling a tick, or when the dialog is opened again.
    private(set) var showsManualModelDuplicateNote = false

    /// Called when the dialog is opened again.
    func clearManualModelDuplicateNote() {
        showsManualModelDuplicateNote = false
    }

    /// Add a model ID manually: it is ticked once added; the protocol chip takes the first candidate by the cached family (no request is sent).
    /// A relay judges sameness by the literal ID: one extra date-snapshot suffix is a different model, so `gpt-4o` and
    /// `gpt-4o-2024-08-06` take a row each and are stored separately. A case-only difference is for now still treated as the existing item in the list
    /// (tick the existing one, add no new row); whether that stays is out of scope here.
    @discardableResult
    func addManualModel(_ raw: String) -> ManualModelAddResult {
        let modelID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { return .ignored }
        let listed = catalogModels + manualModelIDs.map(Self.manualDraftModel)
        let existing = listed.first { $0.id.caseInsensitiveCompare(modelID) == .orderedSame }
        if existing == nil {
            manualModelIDs.append(modelID)
            protocols[modelID] = RelayProbeCandidates.fromFamily(cachedFamily(modelID)).first
            rebuildGroups()
        }
        selected.insert(existing?.id ?? modelID)
        saveFailure = nil
        showsManualModelDuplicateNote = existing != nil
        return existing == nil ? .added : .alreadyListed
    }

    /// What a manually added ID looks like in the draft catalog (the same shape as a hand-entered model that gets stored).
    private static func manualDraftModel(_ modelID: String) -> AIModel {
        var manual = ProviderManager.relayCatalogModels(modelIDs: [modelID], relayRequested: nil)[0]
        manual.isManual = true
        return manual
    }

    /// Groups and group order = the same projection as the model library: run `projectProviderCatalogGroups` on a draft connection shaped like the one stored at registration.
    private func rebuildGroups() {
        var catalog = catalogModels
        for modelID in manualModelIDs.reversed() where !catalog.contains(where: { $0.id == modelID }) {
            catalog.insert(Self.manualDraftModel(modelID), at: 0)
        }
        let draft = Provider(
            id: UUID(),
            kind: .relay,
            status: .connected,
            models: [],
            catalogModels: catalog,
            lastCheckedAt: nil,
            apiKey: "",
            apiKeyPreview: "",
            lastError: nil,
            baseURLText: endpoint,
            customName: host,
            relayRequested: nil
        )
        // The shared projection input is deduplicated by canonical form (a date snapshot merges into the undated one), while step 2 judges sameness by literal ID:
        // put the merged-away draft rows back in draft catalog order, otherwise a hand-added date form is neither shown, tickable nor storable.
        let shared = makeProviderCatalogProjectionInput(for: draft)
        let projectedByID = Dictionary(shared.catalogModels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var input = ProviderCatalogProjectionInput(
            providerID: shared.providerID,
            providerKind: shared.providerKind,
            providerDisplayName: shared.providerDisplayName,
            enabledModels: shared.enabledModels,
            catalogModels: catalog.map { projectedByID[$0.id] ?? $0 },
            priorityScores: shared.priorityScores
        )
        input.relayFamilies = shared.relayFamilies
        for model in catalog where projectedByID[model.id] == nil {
            if let family = RelaySetupModelsBoard.bindingFamily(model.id) {
                input.relayFamilies[model.id] = family
            }
        }
        input.relayOtherTitle = shared.relayOtherTitle
        modelGroups = projectProviderCatalogGroups(input: input, searchText: "").map { group in
            RelaySetupModelsBoard.Group(id: group.id, title: group.title, modelIDs: group.models.map(\.id))
        }
    }

    // MARK: Save (verify only the first ticked model in display order; a failure stores nothing)

    @discardableResult
    func save(
        appState: AppState,
        entryPoint: ProviderSetupEntryPoint,
        onWillComplete: () -> Void = {}
    ) async -> Bool {
        let board = modelsBoard
        guard !isSaving, let first = board.firstSelectedID,
              let normalized = RelaySetupView.normalizedRelayEndpoint(
                  endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                  securityMode: securityMode
              ) else { return false }
        isSaving = true
        saveFailure = nil
        defer { isSaving = false }

        let usedKeys = detectedKeys.isEmpty ? [keys[0]] : detectedKeys
        let primary = usedKeys[0]
        let boundKeyID = board.boundKeyByModel[first] ?? primary.id
        let secret = (usedKeys.first { $0.id == boundKeyID } ?? primary).trimmedSecret
        let detected = discoveryResult?.detections.first
        let explicitTransport = discoveryResult?.descriptor.explicitTransport
            ?? (try? RelayEndpointResolver.describe(normalized))?.explicitTransport
        let requested = detected.map {
            RelayAddVerification.connectionRequested(
                detection: $0,
                explicitTransport: explicitTransport,
                formAuthMode: .auto,
                securityMode: securityMode,
                modelID: first
            )
        } ?? Self.undetectedRequested(explicitTransport: explicitTransport, securityMode: securityMode, modelID: first)
        let endpointTypes = detected?.endpointTypesByModel[first]

        let attempt = coordinator.beginVerification(for: .relay)
        let service = appState.providerManager.openAIService
        let family = family
        let result: RelayAddVerification.Result
        do {
            result = try await RelayAddVerification.run(
                endpoint: normalized,
                requested: requested,
                userChosenTransport: explicitTransport,
                modelID: first,
                supportedEndpointTypes: endpointTypes,
                generationRoutePass: detected.flatMap { RelayAddVerification.generationRoutePass(detection: $0, modelID: first) },
                // Only a generation route was found (no catalog): the detected protocol comes first, followed by the candidate rules (generationRouteCases).
                generationRoute: detected.flatMap { $0.detectionEvidence == .generationProbe ? $0.transport : nil },
                family: { await family(first) },
                ping: { routed, model in
                    _ = try await service.pingRelay(
                        apiKey: secret,
                        baseURL: normalized,
                        modelID: model,
                        relayRequested: routed
                    )
                }
            )
        } catch {
            _ = coordinator.acceptFailure(for: attempt)
            return false
        }
        guard coordinator.isCurrent(attempt) else { return false }
        guard result.verified else {
            _ = coordinator.acceptFailure(for: attempt)
            saveFailure = String(
                format: L10n.tr("Automatic protocol testing failed: %@", table: .providers),
                Self.failureDetail(result.lastError)
            )
            return false
        }
        let evidence = CustomLLMConnectionEvidence.verified(attempt)
        guard coordinator.acceptVerified(evidence), coordinator.canCommit(evidence) else { return false }

        let manager = appState.providerManager
        var provider = manager.registerRelay(
            name: "",
            endpoint: normalized,
            apiKey: primary.trimmedSecret,
            relayRequested: requested,
            catalogModelIDs: catalogModels.map(\.id),
            preferredModelID: first,
            connectionState: .connected
        )
        provider.relayKind = RelayKind(transport: requested.transport)
        // The probe model lives only in the in-memory draft; the persisted relayRequested.modelID is always empty.
        provider.relayRequested = requested.withoutModelID
        let extras = usedKeys.dropFirst()
        if !extras.isEmpty {
            // Attach the other keys first (add), then write each key's lister and status; the verification sample is rebound to the key it was verified with.
            for key in extras {
                if let next = RelayKeyBinding.apply(.add(id: key.id, name: key.trimmedName, apiKey: key.trimmedSecret), to: provider) {
                    provider = next
                }
            }
            if let name = primary.trimmedName,
               let renamed = RelayKeyBinding.apply(.rename(id: primary.id, name: name), to: provider) {
                provider = renamed
            }
            for index in provider.catalogModels.indices {
                if let listed = listedBy[provider.catalogModels[index].id] {
                    provider.catalogModels[index].relayListedByKeyIDs = listed
                }
            }
            let now = Date()
            for (keyID, state) in keyStates {
                if let updated = RelayKeyAccess.settingStatus(
                    provider, keyID: keyID, state: state.state, httpStatus: state.httpStatus, at: now
                ) {
                    provider = updated
                }
            }
            if boundKeyID != primary.id,
               let rebound = RelayKeyBinding.apply(.rebind(modelID: first, keyID: boundKeyID), to: provider) {
                provider = rebound
            }
        }
        manager.updateProvider(provider)

        // Enable the other ticked models in bulk: bind by the binding rule and send no request (bulk enabling does not probe).
        // Do not go through enableModel first: it resolves by folding, so a hand-added date-snapshot form would be judged as the already-enabled one in the catalog.
        for modelID in board.selectedInDisplayOrder.dropFirst() {
            _ = manager.ensureModelEnabledAsDefault(providerID: provider.id, modelID: modelID)
        }
        if let outcome = result.modelOutcome, var refreshed = manager.provider(for: provider.id) {
            RelayModelProbe.apply(outcome, modelID: first, to: &refreshed)
            manager.updateProvider(refreshed)
        }

        onWillComplete()
        appState.completeRelaySetup(
            providerID: provider.id,
            entryPoint: entryPoint,
            verifiedModelID: first,
            // The notice reports how many were actually enabled: the enable path folds two rows pointing at one model into one, so reporting the ticked count would overcount.
            addedModelCount: manager.provider(for: provider.id)?.models.count ?? board.saveCount
        )
        return true
    }

    /// Add manually after connectivity failed: there is no probe verdict, so the connection protocol takes only what the address carries, otherwise auto (same shape as connectionRequested).
    private static func undetectedRequested(
        explicitTransport: RelayTransport?,
        securityMode: RelayConnectionSecurityMode,
        modelID: String
    ) -> RelayRequestedConfig {
        let transport = explicitTransport ?? .auto
        var config = RelayRequestedConfig(
            transport: transport,
            authMode: .auto,
            securityMode: securityMode,
            modelID: modelID,
            stream: true
        )
        switch transport {
        case .openaiResponses:
            config.disableResponseStorage = true
            config.codexCompatIdentity = true
        case .auto:
            config.disableResponseStorage = true
        default:
            break
        }
        return config
    }

    private static func failureDetail(_ error: Error?) -> String {
        guard let error else { return L10n.tr("No detected protocol completed the test request.", table: .providers) }
        if let providerError = error as? ProviderServiceError {
            return providerError.technicalDetail.isEmpty ? providerError.message : providerError.technicalDetail
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
