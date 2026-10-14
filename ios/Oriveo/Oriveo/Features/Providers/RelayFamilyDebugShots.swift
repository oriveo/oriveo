#if DEBUG
import SwiftUI
import UIKit

/// Debug direct-open pages for the relay family: used for screenshot sampling; a Release build contains none of this file.
///
/// Usage: `xcrun simctl launch <udid> <bundle id> -AUTO_OPEN_PAGE <page name>`; page names are in `Shot`.
///
/// When launched with one of these page names the whole process uses an in-memory `AppState` (`OriveoApp.init` goes through
/// `seedDemoData` based on `isRequested`): the demo connections live only in memory and never reach the session snapshot, the Keychain or sync; launched without the argument, this file does nothing.
/// Every row on a page is still computed by the production row models; this file only supplies data and navigation.
///
/// Demo data, per-page presets and the clock are read only from the shared cross-platform manifest `shared/test-fixtures/shots/relay.v1.json`,
/// and objects are built through production constructors; if the manifest cannot be read, fails to parse or lacks a field, opening is refused rather than falling back to hardcoded values.
/// Navigation, injection points, network stubs, wait durations and error body copy are platform mechanics and stay here.
///
/// Some state is a page-private `@State` that cannot be set from outside, so the corresponding file gets a `#if DEBUG` injection point
/// (each one has a "screenshots only" note beside it). All 7 injection points are wired up; the list below is kept as an index:
///
/// 1. In the existing `.onAppear` of `ProviderDetailView.swift`, before `guard page == .detail`:
///    ```
///    if let groups = RelayFamilyDebugShots.takeExpandedLibraryGroups(on: page) { expandedLibraryGroups = groups }
///    if RelayFamilyDebugShots.takePresentsEditConnection(on: page) { showEditRelay = true }
///    if let seed = RelayFamilyDebugShots.takeCapabilityTest(on: page) {
///        capabilityTest = RelayCapabilityTestController(
///            debugInput: seed.input, modelName: seed.modelName, runningSince: seed.runningSince
///        )
///    }
///    ```
/// 2. `RelayCapabilityTestPanel.swift`: add a same-file extension to `RelayCapabilityTestController`,
///    `convenience init(debugInput:modelName:runningSince:)`, which writes the three `private(set)` properties.
/// 3. Initial values of the two `@State`s in `RelayKeysPage.swift`:
///    `pageState` registers in-flight keys one by one with `begin(.replaceSecret)` from `fetchingKeyIDs` and presets the notice already given from `keysNotices`,
///    `showAddKey = RelayFamilyDebugShots.presentsAddKey`.
/// 4. At the end of the existing `.onAppear` in `RelayWebSearchPage.swift`:
///    `if let edited = RelayFamilyDebugShots.takeWebSearchEdit(from: current) { draft = edited }`
/// 5. At the end of the existing `.onAppear` in `RelayEditView.swift`:
///    `RelayFamilyDebugShots.feedEditFailure(for: provider) { saveError = $0 }`
/// 6. In `RelaySetupView.init`, after `coordinator` is built:
///    ```
///    if let flows = RelayFamilyDebugShots.makeSetupFlows(coordinator: coordinator) {
///        _setupCoordinator = State(initialValue: coordinator)
///        _flow = State(initialValue: flows.quick)
///        _manualFlow = State(initialValue: flows.manual)
///        _showsManualSetup = State(initialValue: flows.startsInManualSetup)
///        return
///    }
///    ```
/// 7. Initial value of `RelaySetupModelsView.showsManualAdd` in `RelaySetupStepViews.swift`:
///    `RelayFamilyDebugShots.presentsManualModelAlert`.
enum RelayFamilyDebugShots {
    enum Shot: String, CaseIterable {
        case relayDetail, relayDetailIssue, localDetail
        case relayKeys, relayKeyInput, relayKeysAdded
        case relayLibrary, relayLibraryLast, relayLibraryByKey
        case relayAdvanced, relayAdvancedFixed, relayCapabilityTest, relayCapabilityTestWeb
        case relayWebSearch, relayWebSearchRejected
        case relayEdit, relayEditFailure, localEdit
        case relayManualSetup, relayManualSetupFailure
        case relaySetupModels, relaySetupModelsAlert, relaySetup
        case relayModelOptionsWeb, relayModelOptionsWebRejected
    }

    /// The launch argument named a page of this family. `OriveoApp.init` uses this to decide whether to use the in-memory AppState.
    static var isRequested: Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-AUTO_OPEN_PAGE"), index + 1 < arguments.count else { return false }
        return Shot(rawValue: arguments[index + 1]) != nil
    }

    // MARK: - State read by injection points

    struct CapabilityTestSeed {
        let input: RelayCapabilityTestPanel.Input
        let modelName: String
        let runningSince: Date
    }

    struct SetupFlows {
        let quick: RelayQuickSetupFlow
        let manual: RelayManualSetupFlow
        let startsInManualSetup: Bool
    }

    private static var active: Shot?
    /// The manifest product currently applied; the network stub and the injection points only trust this.
    private static var staged: Staged?
    /// Whether a screenshot is already staged: placeholders inside a screenshot do not read live metadata, so re-shot results do not drift with the online default model.
    static var isActive: Bool { active != nil }
    /// Keys page: the keys shown as "catalog still loading".
    private(set) static var fetchingKeyIDs: Set<String> = []
    /// Keys page: open the page with the "Add key" alert showing.
    private(set) static var presentsAddKey = false
    /// Keys page: the preset in-page notice (add-success screenshot, computed by the production notice function).
    private(set) static var keysNotices: [RelayKeysBoardModel.Notice] = []
    /// Setup step 2: open the page with the "Add model ID manually" alert showing.
    private(set) static var presentsManualModelAlert = false
    private static var pendingExpandedLibraryGroups: Set<String>?
    private static var pendingEditConnection = false
    private static var pendingEditFailure: EditFailure?
    private static var pendingCapabilityTest: CapabilityTestSeed?
    private static var pendingWebSearchTemplates: [RelayTransport]?
    private static var setupFlows: SetupFlows?
    private static var editFailureFed = false

    // Each take... below hands its value out only once: when the page is covered and revealed again, onAppear fires again and the alert must not show a second time.

    static func takeExpandedLibraryGroups(on page: ProviderDetailView.Page) -> Set<String>? {
        guard page == .modelLibrary, let groups = pendingExpandedLibraryGroups else { return nil }
        pendingExpandedLibraryGroups = nil
        return groups
    }

    static func takePresentsEditConnection(on page: ProviderDetailView.Page) -> Bool {
        guard page == .detail, pendingEditConnection else { return false }
        pendingEditConnection = false
        return true
    }

    /// The stack holds the detail, library and advanced layers at once, and the sheet can only be presented from the topmost one.
    static func takeCapabilityTest(on page: ProviderDetailView.Page) -> CapabilityTestSeed? {
        guard case .modelAdvanced = page, let seed = pendingCapabilityTest else { return nil }
        pendingCapabilityTest = nil
        return seed
    }

    /// "Has unsaved changes": change the draft through the page's own "Use template" step.
    static func takeWebSearchEdit(from current: RelayWebSearchDraft) -> RelayWebSearchDraft? {
        guard let templates = pendingWebSearchTemplates else { return nil }
        pendingWebSearchTemplates = nil
        var edited = current
        for transport in templates where edited == current {
            edited.useTemplate(transport)
        }
        return edited == current ? nil : edited
    }

    /// Feed one verification failure into the failure card state the edit-connection page already has.
    static func feedEditFailure(for provider: Provider?, into setError: @escaping (OriveoError) -> Void) {
        guard let failure = pendingEditFailure, let provider else { return }
        pendingEditFailure = nil
        Task { @MainActor in
            // Give it only after the form has been laid out: the page dismisses the keyboard and scrolls to the failure card at the moment it goes from absent to present.
            try? await Task.sleep(nanoseconds: failure.delayNanoseconds)
            setError(RelayEditFailurePresentation.error(from: failure.error, provider: provider))
            editFailureFed = true
        }
    }

    /// Swap the add page's two flows for versions that send no network requests: the catalog is answered by a local stub, and the 1-token verification throws the failure given by the manifest directly.
    /// The page calls this every time it is rebuilt, so it must always return the same instances, otherwise the later orchestration cannot drive the ones on the page.
    static func makeSetupFlows(coordinator: CustomLLMSetupCoordinator) -> SetupFlows? {
        guard active != nil, let script = staged?.presets.setup else { return nil }
        if let setupFlows { return setupFlows }
        let family: (String) -> String? = { RelayFamilyHeuristics.infer(modelID: $0)?.rawValue }
        let quick = RelayQuickSetupFlow(
            coordinator: coordinator,
            makeDiscoveryService: { RelayDiscoveryService(session: RelayFamilyDebugCatalogStub.session, retryBackoff: []) },
            family: { family($0) },
            cachedFamily: family
        )
        let pingError = script.pingError
        let manual = RelayManualSetupFlow(
            quick: quick,
            family: { family($0) },
            ping: { _, _, _, _ in throw pingError }
        )
        let flows = SetupFlows(quick: quick, manual: manual, startsInManualSetup: script.startsInManualSetup)
        setupFlows = flows
        return flows
    }

    // MARK: - Entry

    static func open(_ shot: Shot, appState: AppState) async {
        // This property is the AppState switch for "persist or not". Placing demo connections in a persisting state would write them into the real session and Keychain, so it is better not to place them.
        guard !appState.prefersAuthoritativeConversationStore else {
            report("\(shot.rawValue): AppState is not in-memory; demo data was not injected")
            return
        }
        guard let staged = stage(shot, manifestData: { try manifestData() }) else { return }
        active = shot
        self.staged = staged
        RelayFamilyDebugCatalogStub.modelIDs = staged.setupCatalog
        appState.providers = [staged.relay, staged.local]
        appState.selectedTab = .providers
        arm(staged.presets)
        // Saved web-search fragments and probe records (preset webFragments / webProbeRecords) must exist before the page opens, so the first frame lists them.
        let probeContext = appState.providerManager.relayWebProbeAutoContext
        seedWebProbeState(staged, fragments: probeContext.fragments, records: probeContext.records)
        seedChatWebPreference(staged, store: .shared)
        appState.navigation.reset(to: staged.path)
        await settle(shot, staged: staged, appState: appState)
    }

    /// Read the manifest and build everything this page needs; if any step fails, refuse to open and log one line, without falling back to hardcoded values.
    static func stage(_ shot: Shot, manifestData: () throws -> Data) -> Staged? {
        do {
            let manifest = try Manifest.load(from: manifestData())
            guard let page = manifest.pages.first(where: { $0.name == shot.rawValue }) else {
                report("\(shot.rawValue): the shots manifest has no such page; not opened")
                return nil
            }
            return try Staged(shot: shot, page: page, manifest: manifest)
        } catch {
            report("\(shot.rawValue): the shots manifest is unreadable or invalid; not opened (\(error))")
            return nil
        }
    }

    private static func arm(_ presets: Presets) {
        fetchingKeyIDs = presets.fetchingKeyIDs
        presentsAddKey = presets.presentsAddKey
        keysNotices = presets.keysNotices
        presentsManualModelAlert = presets.presentsManualModelAlert
        pendingExpandedLibraryGroups = presets.expandedLibraryGroups
        pendingEditConnection = presets.editConnection
        pendingEditFailure = presets.editFailure
        pendingCapabilityTest = presets.capabilityTest
        pendingWebSearchTemplates = presets.webSearchTemplates
    }

    private static func path(
        for shot: Shot, page: Manifest.Page, relayID: UUID, localID: UUID, presets: Presets
    ) throws -> [AppRoute] {
        let detail = AppRoute.providerDetail(providerID: relayID)
        let library = AppRoute.relayModelLibrary(providerID: relayID)
        switch shot {
        case .relayDetail, .relayDetailIssue, .relayEdit, .relayEditFailure:
            return [detail]
        case .localDetail, .localEdit:
            return [.providerDetail(providerID: localID)]
        case .relayKeys, .relayKeyInput, .relayKeysAdded:
            // The add-success notice of relayKeysAdded is preset into the keys page state (keysNotices) from the preset keyAdded.
            return [detail, .relayKeys(providerID: relayID)]
        case .relayLibrary, .relayLibraryLast:
            return [detail, library]
        case .relayLibraryByKey:
            // Same path as the key sheet's "View models": detail -> keys page -> open the model library with key(id), so the back title matches production and the first frame already has that filter.
            guard let keyID = presets.libraryKeyFilter else { throw ManifestError.invalid("\(page.name).keyFilter is missing") }
            return [detail, .relayKeys(providerID: relayID), .relayModelLibrary(providerID: relayID, keyID: keyID)]
        case .relayAdvanced, .relayCapabilityTest, .relayCapabilityTestWeb, .relayAdvancedFixed:
            guard let model = page.model else { throw ManifestError.invalid("\(page.name).model is missing") }
            return [detail, library, .relayModelAdvanced(providerID: relayID, modelID: model, readOnly: false)]
        case .relayWebSearch, .relayWebSearchRejected:
            return [detail, .relayWebSearch(providerID: relayID)]
        case .relaySetup, .relayManualSetup, .relayManualSetupFailure, .relaySetupModels, .relaySetupModelsAlert:
            return [.relaySetup(entryPoint: .providers)]
        case .relayModelOptionsWeb, .relayModelOptionsWebRejected:
            // The chat page is opened through the production entry point openChat after settle builds the conversation; the panel comes up from the composer bar's own sheet.
            guard presets.chatModelID != nil else { throw ManifestError.invalid("\(page.name).model is missing") }
            return []
        }
    }

    /// The part that can be staged only after the page is mounted: use the flow's own public actions and do not write its state directly.
    private static func settle(_ shot: Shot, staged: Staged, appState: AppState) async {
        switch shot {
        case .relayEditFailure:
            guard await waitUntil({ editFailureFed }) else {
                report("relayEditFailure: the edit-connection sheet did not appear or the failure card was not fed in (the injection points in ProviderDetailView / RelayEditView are not wired)")
                return
            }
            // When the failure card appears the page dismisses the keyboard and scrolls to it; the screenshot no longer taps back into the endpoint field.

        case .relaySetupModels, .relaySetupModelsAlert:
            guard let flows = await waitForSetupFlows(shot), let fill = staged.presets.setup?.fill else { return }
            flows.quick.setEndpoint(fill.endpoint)
            flows.quick.setSecret(fill.secret, for: fill.keyID)
            await flows.quick.next(appState: appState)?.value
            if flows.quick.step != .models {
                report("\(shot.rawValue): detection did not reach step 2")
            }

        case .relayManualSetupFailure:
            guard let flows = await waitForSetupFlows(shot), let script = staged.presets.setup,
                  let fill = script.fill, let modelID = script.modelID, let transport = script.transport else { return }
            flows.manual.setEndpoint(fill.endpoint)
            flows.manual.setSecret(fill.secret, for: fill.keyID)
            flows.manual.setModelID(modelID)
            // When a protocol is selected, verification is sent only once and does not take the per-protocol probe path that records a negative cache.
            flows.manual.setTransport(transport)
            _ = await flows.manual.validateAndSave(appState: appState, entryPoint: .providers)
            guard flows.manual.failureCardID != nil else {
                report("relayManualSetupFailure: verification produced no failure card")
                return
            }
            // After a failure the page shell dismisses the keyboard and scrolls the failure card into view; the screenshot no longer taps back into the input.

        case .relayManualSetup:
            _ = await waitForSetupFlows(shot)

        case .relayModelOptionsWeb, .relayModelOptionsWebRejected:
            await openModelOptions(shot, staged: staged, appState: appState)

        default:
            break
        }
    }

    /// Production host: one empty conversation (in memory, not persisted) plus the chat page; the panel opens through the composer bar's own sheet.
    /// The open is triggered by the composer bar's deterministic attach callback (`ChatComposerBar.onAppear` -> `takeModelOptions`), not by re-posting a notification on a timer.
    private static func openModelOptions(_ shot: Shot, staged: Staged, appState: AppState) async {
        guard let modelID = staged.presets.chatModelID,
              let model = staged.relay.models.first(where: { $0.id == modelID }) else { return }
        let conversation = Conversation(
            id: UUID(),
            title: L10n.tr("New Chat"),
            providerID: staged.relay.id,
            providerKind: staged.relay.kind,
            modelID: modelID,
            previewText: "",
            estimatedCost: 0,
            isDraft: false,
            messages: [],
            draftText: ""
        )
        appState.upsertConversationProjection(conversation)
        pendingModelOptions = (staged.relay.id, model.id)
        // The chat page lives on the home stack: switch back to home first, and open the conversation through the production entry point once the home stack is attached (a push right at launch would be overwritten by the root view's first-frame stack).
        appState.selectedTab = .home
        appState.navigation.reset(to: [])
        guard await waitUntil({ appState.navigation.path.isEmpty && appState.selectedTab == .home }) else { return }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        appState.openChat(conversationID: conversation.id)
        guard await waitUntil({ pendingModelOptions == nil }) else {
            report("\(shot.rawValue): the chat composer bar did not attach, so the model-options panel did not open")
            return
        }
    }

    /// Shot: waits for the composer bar of this relay model to attach, then opens the model-options panel.
    private static var pendingModelOptions: (providerID: UUID, modelID: String)?

    /// Called when the composer bar attaches: if it is the connection and model the shot names, takes the marker and returns true.
    static func takeModelOptions(providerID: UUID, modelID: String?) -> Bool {
        guard let pending = pendingModelOptions, pending.providerID == providerID, pending.modelID == modelID else { return false }
        pendingModelOptions = nil
        return true
    }

    private static func waitForSetupFlows(_ shot: Shot) async -> SetupFlows? {
        guard await waitUntil({ setupFlows != nil }), let flows = setupFlows else {
            report("\(shot.rawValue): the injection point in RelaySetupView.init is not wired; stuck at step 1")
            return nil
        }
        return flows
    }

    private static func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 40 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    private static func report(_ message: String) {
        print("[RelayFamilyDebugShots] \(message)")
    }

    // MARK: - Shared manifest

    enum ManifestError: Error, CustomStringConvertible {
        case repositoryNotFound
        case invalid(String)

        var description: String {
            switch self {
            case .repositoryNotFound: "Walking up from the source file location found no repository root containing \"shared/\""
            case let .invalid(reason): reason
            }
        }
    }

    /// The manifest is not in the bundle: the simulator process can read host files, so walk up from this source file's location to the repository root that contains `shared/`.
    static func manifestURL(sourceFile: String = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: sourceFile).deletingLastPathComponent()
        while directory.pathComponents.count > 1 {
            var isDirectory: ObjCBool = false
            let shared = directory.appendingPathComponent("shared")
            if FileManager.default.fileExists(atPath: shared.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return shared.appendingPathComponent("test-fixtures/shots/relay.v1.json")
            }
            directory.deleteLastPathComponent()
        }
        throw ManifestError.repositoryNotFound
    }

    static func manifestData() throws -> Data {
        try Data(contentsOf: manifestURL())
    }

    /// The shape of the manifest; keys starting with `$` are notes and are not read when decoding. What the values mean and how they are validated lives in `Staged`.
    struct Manifest: Decodable {
        struct Clock: Decodable {
            let connectionCheckedAgoSeconds: Double
            let keyCheckedAgoSeconds: Double
            let localCheckedAgoSeconds: Double
        }

        struct Key: Decodable {
            let ref: String
            let implicit: Bool?
            let id: String?
            let name: String?
            let secret: String
            let state: String
            let httpStatus: Int?
        }

        struct CatalogEntry: Decodable {
            let id: String
            let listedBy: [String]
        }

        struct Capabilities: Decodable {
            let image: Bool?
            let file: Bool?
            let imageGeneration: Bool?
            let toolCall: Bool?
        }

        struct EnabledModel: Decodable {
            let id: String
            let key: String
            let capabilities: Capabilities?
            let capabilitySource: String?
            let transport: String?
            let transportSource: String?
        }

        struct UnauthorizedError: Decodable {
            let httpStatus: Int
            let body: String
        }

        struct Relay: Decodable {
            let id: String
            let name: String
            let endpoint: String
            let apiRoot: String
            let transport: String
            let authMode: String
            let securityMode: String
            let resolvedTransports: [String]
            let unauthorizedError: UnauthorizedError
            let keys: [Key]
            let catalog: [CatalogEntry]
            let enabled: [EnabledModel]
        }

        struct Declaration: Decodable {
            let image: Bool?
            let toolCall: Bool?
            let thinking: Bool?
        }

        struct LocalModel: Decodable {
            let id: String
            let load: String
            let declaration: Declaration?
        }

        struct Local: Decodable {
            let id: String
            let name: String
            let endpoint: String
            let transport: String
            let authMode: String
            let securityMode: String
            let engine: String
            let models: [LocalModel]
            let enabledCount: Int
        }

        struct Connection: Decodable {
            let transport: String?
            let modelTransports: String?
            let status: String?
            let enabled: [String]?
        }

        struct ItemResult: Decodable {
            let verdict: String
            let reason: String
            let status: Int?
            let elapsedMs: Int
        }

        /// Arbitrary JSON (a web-search fragment object); only used to convert back to `Any` as-is.
        struct AnyJSON: Decodable {
            let value: Any

            init(from decoder: Decoder) throws {
                if let object = try? decoder.container(keyedBy: AnyKey.self) {
                    var dict: [String: Any] = [:]
                    for key in object.allKeys { dict[key.stringValue] = try object.decode(AnyJSON.self, forKey: key).value }
                    value = dict
                } else if var array = try? decoder.unkeyedContainer() {
                    var items: [Any] = []
                    while !array.isAtEnd { items.append(try array.decode(AnyJSON.self).value) }
                    value = items
                } else {
                    let single = try decoder.singleValueContainer()
                    if single.decodeNil() { value = NSNull() }
                    else if let bool = try? single.decode(Bool.self) { value = bool }
                    else if let int = try? single.decode(Int.self) { value = int }
                    else if let double = try? single.decode(Double.self) { value = double }
                    else { value = try single.decode(String.self) }
                }
            }

            struct AnyKey: CodingKey {
                let stringValue: String
                var intValue: Int? { nil }
                init?(stringValue: String) { self.stringValue = stringValue }
                init?(intValue: Int) { nil }
            }
        }

        struct CapabilityTest: Decodable {
            let key: String
            let items: [String]
            let results: [String: ItemResult]
            let running: String?
        }

        struct Failure: Decodable {
            let httpStatus: Int
            let reason: String
        }

        struct SaveFailure: Decodable {
            let afterMs: Int
            let httpStatus: Int
            let reason: String
            let canSaveUnverified: Bool
        }

        struct Setup: Decodable {
            let mode: String
            let endpoint: String?
            let key: String?
            let transport: String?
            let model: String?
            let submit: Bool?
            let detect: Bool?
            let manualModelAddOpen: Bool?
            let failure: Failure?
        }

        struct Preset: Decodable {
            let fetchingKeys: [String]?
            let addKeyOpen: Bool?
            let expandedGroups: [String]?
            /// Open the model library filtered by this key (ref).
            let keyFilter: String?
            /// The moment this key (ref) was just added and its catalog write-back is ok: the key's status is ok, and the page shows the add-success notice computed by the production notice function.
            let keyAdded: String?
            let capabilityTest: CapabilityTest?
            /// Web-search fragments saved before opening: protocol wire value -> fragment object.
            let webFragments: [String: AnyJSON]?
            /// Web-search probe records written to the device before opening; the hash is that protocol's current fragment.
            let webProbeRecords: [WebProbeRecord]?
            /// Model web override (value + source user / tested), written on the same row for the enabled model and the catalog.
            let webOverrides: [WebOverride]?
            /// Chat web-search switch: "on" = write "on" through the production switch write entry before opening (model default scope); absent = never set.
            let webPreference: String?
            let draftFromTemplate: [String]?
            let editConnection: Bool?
            let saveFailure: SaveFailure?
            let setup: Setup?
        }

        struct WebProbeRecord: Decodable {
            let model: String
            let transport: String
            let result: String
            let source: String
        }

        struct WebOverride: Decodable {
            let model: String
            let value: Bool
            let source: String
        }

        struct Page: Decodable {
            let name: String
            let host: String
            let view: String
            let model: String?
            let connection: Connection?
            let preset: Preset?
        }

        let schema: String
        let family: String
        let clock: Clock
        let relay: Relay
        let local: Local
        let setupCatalog: [String]
        let pages: [Page]

        /// After decoding, build every page this platform implements: missing fields, keys / models that cannot be resolved and unknown values are rejected at load time.
        static func load(from data: Data) throws -> Manifest {
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.schema == "oriveo-shots-manifest/v1", manifest.family == "relay" else {
                throw ManifestError.invalid("schema / family is not oriveo-shots-manifest/v1 · relay")
            }
            for page in manifest.pages {
                guard let shot = Shot(rawValue: page.name) else { continue }
                _ = try Staged(shot: shot, page: page, manifest: manifest)
            }
            return manifest
        }
    }

    // MARK: - Products built from the manifest

    struct EditFailure {
        let delayNanoseconds: UInt64
        let error: ProviderServiceError
    }

    struct SetupScript {
        struct Fill {
            let endpoint: String
            let keyID: String
            let secret: String
        }

        let startsInManualSetup: Bool
        let fill: Fill?
        let modelID: String?
        let transport: RelayTransport?
        let failure: ProviderServiceError?
        /// What the injected 1-token verification throws: use the failure given on the page, otherwise the demo relay's response to an invalid key.
        let pingError: ProviderServiceError
    }

    struct Presets {
        var fetchingKeyIDs: Set<String> = []
        var presentsAddKey = false
        var presentsManualModelAlert = false
        var expandedLibraryGroups: Set<String>?
        /// Open the model library filtered by key(id) (the key id, already resolved from ref).
        var libraryKeyFilter: String?
        /// In-page notice preset for the keys page.
        var keysNotices: [RelayKeysBoardModel.Notice] = []
        var editConnection = false
        var editFailure: EditFailure?
        var capabilityTest: CapabilityTestSeed?
        /// Web-search fragments stored in the local fragment store before opening (original text serialized with sorted keys).
        var webFragments: [RelayTransport: String] = [:]
        var webSearchTemplates: [RelayTransport]?
        /// Entries written to the local probe records before opening (the hash is that protocol's current fragment).
        var webProbeRecords: [WebProbeRecordSeed] = []
        /// Model-options panel pages: the model the chat session uses.
        var chatModelID: String?
        /// Before opening, write that model's chat web-search switch to "on".
        var chatWebSearch = false
        /// Web overrides written onto the model when the demo connection is built.
        var webOverrides: [WebOverrideSeed] = []
        /// Present only when the add page needs the no-network flows (manual setup / the pages whose catalog was detected).
        var setup: SetupScript?
    }

    struct WebProbeRecordSeed: Equatable {
        let modelID: String
        let transport: RelayTransport
        let result: RelayWebProbeRecord.Result
        let source: RelayWebProbeRecord.Source
    }

    struct WebOverrideSeed: Equatable {
        let modelID: String
        let value: Bool
        let source: RelayCapabilityOverrides.Source
    }

    /// Saved web-search fragments and probe records (preset webFragments / webProbeRecords) are written before the page opens;
    /// a record's hash uses that protocol's effective fragment (the saved one, or the protocol template when none is saved; the same function as production `RelayWebProbe.effectiveFragment`).
    static func seedWebProbeState(_ staged: Staged, fragments: RelayWebFragmentStore, records: RelayWebProbeStore) {
        let relay = staged.relay
        fragments.deleteConnection(relay.id)
        records.clearConnection(relay.id.uuidString)
        for (transport, raw) in staged.presets.webFragments {
            if let error = fragments.save(connectionID: relay.id, transport: transport, raw: raw) {
                report("preset webFragments could not be stored (\(error))")
            }
        }
        let set = fragments.chatFragments(for: relay)
        for seed in staged.presets.webProbeRecords {
            guard let fragment = RelayWebProbe.effectiveFragment(set, transport: seed.transport) else {
                report("preset webProbeRecords: \(seed.transport.rawValue) has neither a stored fragment nor a template; record not written")
                continue
            }
            records.record(
                connectionID: relay.id.uuidString, modelID: seed.modelID, transport: seed.transport.rawValue,
                result: seed.result, source: seed.source, fragmentHash: RelayWebProbe.fragmentHash(fragment)
            )
        }
    }

    /// Chat web-search switch (preset webPreference): first clear the switch records on the demo relay (never set = default), then write per the manifest through the production write entry.
    static func seedChatWebPreference(_ staged: Staged, store: GenerationParameterSettingsStore) {
        let relay = staged.relay
        store.removeCapabilityScopes(providerID: relay.id)
        guard staged.presets.chatWebSearch, let modelID = staged.presets.chatModelID,
              let model = relay.models.first(where: { $0.id == modelID }) else { return }
        RelayWebSwitch.write(true, provider: relay, model: model, conversationID: nil, store: store)
    }

    struct Staged {
        let relay: Provider
        let local: Provider
        let path: [AppRoute]
        let presets: Presets
        let setupCatalog: [String]

        init(shot: Shot, page: Manifest.Page, manifest: Manifest) throws {
            let keys = try Demo.keyIDs(manifest.relay)
            var relay = try Demo.relay(page: page, manifest: manifest, keyIDs: keys)
            let local = try Demo.local(manifest)
            let presets = try Demo.presets(page: page, relay: relay, manifest: manifest, keyIDs: keys)
            // preset webOverrides: tested goes through `RelayWebProbe.apply`, the production mirror of the probe write-back; user writes the override by source, the same as a manual setting on the advanced page.
            for seed in presets.webOverrides {
                switch seed.source {
                case .tested:
                    RelayWebProbe.apply(seed.value ? .searched : .rejected, modelID: seed.modelID, to: &relay)
                case .user:
                    func write(_ models: inout [AIModel]) {
                        for index in models.indices where models[index].id == seed.modelID {
                            var overrides = models[index].relayCapabilityOverrides ?? RelayCapabilityOverrides()
                            overrides.setValue(seed.value, for: .web, source: seed.source)
                            models[index].relayCapabilityOverrides = overrides
                        }
                    }
                    write(&relay.models)
                    write(&relay.catalogModels)
                }
            }
            self.relay = relay
            self.local = local
            self.presets = presets
            path = try RelayFamilyDebugShots.path(
                for: shot, page: page, relayID: relay.id, localID: local.id, presets: presets
            )
            setupCatalog = manifest.setupCatalog
        }
    }

    // MARK: - Demo data (all values are in the manifest; this only maps them)

    private enum Demo {
        static func parse<T: RawRepresentable>(_ raw: String, _ field: String) throws -> T where T.RawValue == String {
            guard let value = T(rawValue: raw) else { throw ManifestError.invalid("\(field) is not recognized: \(raw)") }
            return value
        }

        static func uuid(_ raw: String, _ field: String) throws -> UUID {
            guard let id = UUID(uuidString: raw) else { throw ManifestError.invalid("\(field) is not a UUID: \(raw)") }
            return id
        }

        /// Key reference name -> this platform's key id; the first must be the primary key (its value is in `provider.apiKey`, and the id is the implicit primary key id).
        static func keyIDs(_ relay: Manifest.Relay) throws -> [String: String] {
            guard relay.keys.first?.implicit == true else { throw ManifestError.invalid("the first relay.keys entry must be the implicit primary key") }
            var ids: [String: String] = [:]
            for (index, key) in relay.keys.enumerated() {
                if index == 0 {
                    ids[key.ref] = RelayKeyBinding.implicitKeyID
                } else {
                    guard key.implicit != true, let id = key.id else {
                        throw ManifestError.invalid("relay.keys[\(index)] lacks an id or declares implicit twice")
                    }
                    ids[key.ref] = id
                }
            }
            return ids
        }

        static func keyID(_ ref: String, in ids: [String: String], _ field: String) throws -> String {
            guard let id = ids[ref] else { throw ManifestError.invalid("\(field) references a nonexistent key: \(ref)") }
            return id
        }

        /// The demo relay's response to an invalid key (`relay.unauthorizedError`), wrapped as the production invalidAPIKey.
        static func unauthorizedError(_ manifest: Manifest) -> ProviderServiceError {
            let answer = manifest.relay.unauthorizedError
            return ProviderServiceError.invalidAPIKey(detail: "HTTP \(answer.httpStatus) · \(answer.body)")
        }

        /// Failure declared on the page: only the invalid-key case is accepted, and the http code must match `relay.unauthorizedError`.
        static func verificationError(httpStatus: Int, reason: String, manifest: Manifest) throws -> ProviderServiceError {
            guard reason == "invalid_api_key" else { throw ManifestError.invalid("No screenshot on this platform for the failure reason: \(reason)") }
            guard httpStatus == manifest.relay.unauthorizedError.httpStatus else {
                throw ManifestError.invalid("Failure httpStatus \(httpStatus) does not match relay.unauthorizedError")
            }
            return unauthorizedError(manifest)
        }

        static func relay(page: Manifest.Page, manifest: Manifest, keyIDs: [String: String]) throws -> Provider {
            let spec = manifest.relay
            let connection = page.connection
            let modelTransportsUnset: Bool
            switch connection?.modelTransports {
            case nil: modelTransportsUnset = false
            case "unset": modelTransportsUnset = true
            case let other?: throw ManifestError.invalid("\(page.name).connection.modelTransports is not recognized: \(other)")
            }
            let hasIssue: Bool
            switch connection?.status {
            case nil: hasIssue = false
            case "unverified": hasIssue = true
            case let other?: throw ManifestError.invalid("\(page.name).connection.status is not recognized: \(other)")
            }
            let enabledSpecs = try (connection?.enabled ?? spec.enabled.map(\.id)).map { id in
                guard let entry = spec.enabled.first(where: { $0.id == id }) else {
                    throw ManifestError.invalid("\(page.name).connection.enabled references a model that is not in relay.enabled: \(id)")
                }
                return entry
            }

            var resolvedRoots: [String: String] = [:]
            for raw in spec.resolvedTransports {
                let transport: RelayTransport = try parse(raw, "relay.resolvedTransports")
                resolvedRoots[transport.rawValue] = spec.apiRoot
            }
            let requested = RelayRequestedConfig(
                transport: try parse(connection?.transport ?? spec.transport, "relay.transport"),
                authMode: try parse(spec.authMode, "relay.authMode"),
                securityMode: try parse(spec.securityMode, "relay.securityMode"),
                // Two protocols verified the root address: the detail page's "Base paths" shows two rows, and the web-search settings page expands two sections accordingly and collapses the rest.
                resolvedAPIBaseURLs: resolvedRoots
            )
            var listedBy: [String: [String]] = [:]
            for entry in spec.catalog {
                listedBy[entry.id] = try entry.listedBy.map { try keyID($0, in: keyIDs, "relay.catalog.listedBy") }
            }

            // The model-level fields of the same model in the enabled list and in the catalog are written together, consistent with the production write path.
            func configure(_ model: inout AIModel) throws {
                model.relayListedByKeyIDs = listedBy[model.id]
                guard let entry = enabledSpecs.first(where: { $0.id == model.id }) else { return }
                model.relayKeyID = try keyID(entry.key, in: keyIDs, "relay.enabled.key")
                if let capabilities = entry.capabilities {
                    guard let rawSource = entry.capabilitySource else {
                        throw ManifestError.invalid("relay.enabled[\(entry.id)] has capabilities but no capabilitySource")
                    }
                    model.relayCapabilityOverrides = RelayCapabilityOverrides(
                        image: capabilities.image,
                        file: capabilities.file,
                        imageGeneration: capabilities.imageGeneration,
                        toolCall: capabilities.toolCall,
                        source: try parse(rawSource, "relay.enabled.capabilitySource")
                    )
                }
                switch (entry.transport, entry.transportSource) {
                case let (transport?, source?):
                    guard !modelTransportsUnset else { break }
                    model.relayTransport = try parse(transport, "relay.enabled.transport")
                    model.relayTransportSource = try parse(source, "relay.enabled.transportSource")
                case (nil, nil):
                    // No protocol = not verified, follows the connection default; the status field lands on "unknown · remembered after sending".
                    break
                default:
                    throw ManifestError.invalid("relay.enabled[\(entry.id)] must give both transport and transportSource or neither")
                }
            }

            var catalog = ProviderManager.relayCatalogModels(modelIDs: spec.catalog.map(\.id), relayRequested: requested)
            for index in catalog.indices { try configure(&catalog[index]) }
            let enabled = try enabledSpecs.map { entry in
                guard let model = catalog.first(where: { $0.id == entry.id }) else {
                    throw ManifestError.invalid("relay.enabled references a model that is not in the catalog: \(entry.id)")
                }
                return model
            }

            let primary = spec.keys[0]
            var provider = Provider(
                id: try uuid(spec.id, "relay.id"),
                kind: .relay,
                status: hasIssue ? .issue(ProviderIssueMessage.unverifiedConnectionKey) : .connected,
                models: enabled,
                catalogModels: catalog,
                lastCheckedAt: Date().addingTimeInterval(-manifest.clock.connectionCheckedAgoSeconds),
                apiKey: primary.secret,
                apiKeyPreview: APIKeyMask.masked(primary.secret),
                lastError: hasIssue ? ProviderIssueMessage.unverifiedConnectionKey : nil,
                baseURLText: spec.endpoint
            )
            provider.customName = spec.name
            provider.relayRequested = requested
            provider.relayKind = RelayKind(requested: requested)
            provider.cachedAvailableModelCount = catalog.count
            let checkedAt = Date().addingTimeInterval(-manifest.clock.keyCheckedAgoSeconds)
            // The primary key's value is in provider.apiKey and the entry's own is left empty; the other keys' values are in the entries (in memory only).
            // Preset keyAdded: that key was just added and its fetch wrote back ok, so its status is shown as ok.
            let addedRef = page.preset?.keyAdded
            provider.relayKeys = try spec.keys.enumerated().map { index, key in
                let isPrimary = index == 0
                let justAdded = key.ref == addedRef
                return RelayKey(
                    id: try keyID(key.ref, in: keyIDs, "relay.keys"),
                    name: key.name,
                    apiKey: isPrimary ? "" : key.secret,
                    status: RelayKey.Status(
                        state: justAdded ? .ok : try parse(key.state, "relay.keys.state"),
                        httpStatus: justAdded ? nil : key.httpStatus,
                        checkedAt: checkedAt
                    )
                )
            }
            return provider
        }

        static func local(_ manifest: Manifest) throws -> Provider {
            let spec = manifest.local
            let engine: LocalEngineKind = try parse(spec.engine, "local.engine")
            let requested = RelayRequestedConfig(
                transport: try parse(spec.transport, "local.transport"),
                authMode: try parse(spec.authMode, "local.authMode"),
                securityMode: try parse(spec.securityMode, "local.securityMode"),
                engineProfile: engine.rawValue
            )
            var runtime: [String: LocalModelRuntimeMetadata] = [:]
            for model in spec.models {
                let declaration = EngineDeclaration(
                    image: model.declaration?.image,
                    toolCall: model.declaration?.toolCall,
                    thinking: model.declaration?.thinking
                )
                runtime[model.id] = LocalModelRuntimeMetadata(
                    loadState: try parse(model.load, "local.models.load"),
                    executionLocality: .local,
                    engineDeclaration: declaration.isEmpty ? nil : declaration
                )
            }
            let catalog = ProviderManager.relayCatalogModels(
                modelIDs: spec.models.map(\.id),
                relayRequested: requested,
                runtimeMetadata: runtime
            )
            guard (0 ... catalog.count).contains(spec.enabledCount) else {
                throw ManifestError.invalid("local.enabledCount exceeds the model count")
            }
            var provider = Provider(
                id: try uuid(spec.id, "local.id"),
                kind: .relay,
                status: .connected,
                models: Array(catalog.prefix(spec.enabledCount)),
                catalogModels: catalog,
                lastCheckedAt: Date().addingTimeInterval(-manifest.clock.localCheckedAgoSeconds),
                apiKey: "",
                apiKeyPreview: "",
                lastError: nil,
                baseURLText: spec.endpoint
            )
            provider.customName = spec.name
            provider.relayRequested = requested
            provider.cachedAvailableModelCount = catalog.count
            return provider
        }

        static func presets(
            page: Manifest.Page, relay: Provider, manifest: Manifest, keyIDs: [String: String]
        ) throws -> Presets {
            var presets = Presets()
            if page.view == "modelOptions" {
                guard let model = page.model, relay.models.contains(where: { $0.id == model }) else {
                    throw ManifestError.invalid("\(page.name).model is missing or not an enabled model")
                }
                presets.chatModelID = model
            }
            guard let preset = page.preset else { return presets }
            presets.fetchingKeyIDs = Set(try (preset.fetchingKeys ?? []).map { try keyID($0, in: keyIDs, "preset.fetchingKeys") })
            presets.presentsAddKey = preset.addKeyOpen == true
            if let groups = preset.expandedGroups {
                presets.expandedLibraryGroups = Set(try groups.map { raw -> String in
                    let family: RelayModelFamily = try parse(raw, "preset.expandedGroups")
                    return family.rawValue
                })
            }
            if let ref = preset.keyFilter {
                presets.libraryKeyFilter = try keyID(ref, in: keyIDs, "preset.keyFilter")
            }
            if let ref = preset.keyAdded {
                let id = try keyID(ref, in: keyIDs, "preset.keyAdded")
                guard let notice = RelayKeysBoardModel.notice(
                    accepted: true, operation: .add(id: id, name: nil, apiKey: ""), provider: relay
                ), case .added = notice else {
                    throw ManifestError.invalid("\(page.name).keyAdded: no add-success notice can be computed for this key (is the catalog empty?)")
                }
                presets.keysNotices = [notice]
            }
            presets.editConnection = preset.editConnection == true
            if let failure = preset.saveFailure {
                // This platform's failure card always offers "Save (unverified)"; if the manifest asks for anything else it cannot be staged here, so refuse rather than stage it wrong.
                guard failure.canSaveUnverified else { throw ManifestError.invalid("\(page.name).saveFailure.canSaveUnverified=false is not supported on this platform") }
                presets.editFailure = EditFailure(
                    delayNanoseconds: UInt64(max(failure.afterMs, 0)) * 1_000_000,
                    error: try verificationError(httpStatus: failure.httpStatus, reason: failure.reason, manifest: manifest)
                )
            }
            for (rawTransport, fragment) in preset.webFragments ?? [:] {
                let transport: RelayTransport = try parse(rawTransport, "preset.webFragments")
                guard JSONSerialization.isValidJSONObject(fragment.value),
                      let data = try? JSONSerialization.data(withJSONObject: fragment.value, options: [.sortedKeys]) else {
                    throw ManifestError.invalid("preset.webFragments.\(rawTransport) is not a JSON object")
                }
                let raw = String(decoding: data, as: UTF8.self)
                if case let .failure(error) = RelayWebFragments.validate(raw) {
                    throw ManifestError.invalid("preset.webFragments.\(rawTransport) is invalid: \(error)")
                }
                presets.webFragments[transport] = raw
            }
            for record in preset.webProbeRecords ?? [] {
                let transport: RelayTransport = try parse(record.transport, "preset.webProbeRecords.transport")
                guard relay.models.contains(where: { $0.id == record.model }) else {
                    throw ManifestError.invalid("preset.webProbeRecords.model is not an enabled model: \(record.model)")
                }
                // With no fragment stored for the protocol, the record hangs under the template hash (effective fragment = stored ?? template).
                guard presets.webFragments[transport] != nil || RelayWebFragments.template(for: transport) != nil else {
                    throw ManifestError.invalid("preset.webProbeRecords.\(record.transport) has neither webFragments nor a template")
                }
                presets.webProbeRecords.append(WebProbeRecordSeed(
                    modelID: record.model, transport: transport,
                    result: try parse(record.result, "preset.webProbeRecords.result"),
                    source: try parse(record.source, "preset.webProbeRecords.source")
                ))
            }
            for override in preset.webOverrides ?? [] {
                guard relay.models.contains(where: { $0.id == override.model }) else {
                    throw ManifestError.invalid("preset.webOverrides.model is not an enabled model: \(override.model)")
                }
                presets.webOverrides.append(WebOverrideSeed(
                    modelID: override.model, value: override.value,
                    source: try parse(override.source, "preset.webOverrides.source")
                ))
            }
            switch preset.webPreference {
            case nil: break
            case "on":
                guard page.view == "modelOptions" else {
                    throw ManifestError.invalid("\(page.name).webPreference is only for modelOptions pages")
                }
                presets.chatWebSearch = true
            case let other?:
                throw ManifestError.invalid("\(page.name).webPreference is not recognized: \(other)")
            }
            if let test = preset.capabilityTest {
                guard let model = page.model else { throw ManifestError.invalid("\(page.name) has capabilityTest but no model") }
                presets.capabilityTest = try capabilityTestSeed(
                    provider: relay, modelID: model, preset: test,
                    keyID: try keyID(test.key, in: keyIDs, "preset.capabilityTest.key")
                )
            }
            if let templates = preset.draftFromTemplate {
                presets.webSearchTemplates = try templates.map { try parse($0, "preset.draftFromTemplate") }
            }
            if let setup = preset.setup {
                presets.presentsManualModelAlert = setup.manualModelAddOpen == true
                presets.setup = try setupScript(page: page, setup: setup, manifest: manifest, keyIDs: keyIDs)
            }
            return presets
        }

        /// Only the manual setup page and pages whose catalog was detected swap in the no-network flows; the quick-setup page that stops at step 1 uses the production flow.
        static func setupScript(
            page: Manifest.Page, setup: Manifest.Setup, manifest: Manifest, keyIDs: [String: String]
        ) throws -> SetupScript? {
            let manual: Bool
            switch setup.mode {
            case "manual": manual = true
            case "quick": manual = false
            default: throw ManifestError.invalid("\(page.name).setup.mode is not recognized: \(setup.mode)")
            }
            let detect = setup.detect == true
            let submit = setup.submit == true
            guard manual || detect else { return nil }
            var fill: SetupScript.Fill?
            switch (setup.endpoint, setup.key) {
            case let (endpoint?, keyRef?):
                guard endpoint == "relay" else { throw ManifestError.invalid("\(page.name).setup.endpoint is not recognized: \(endpoint)") }
                let id = try keyID(keyRef, in: keyIDs, "setup.key")
                guard let key = manifest.relay.keys.first(where: { $0.ref == keyRef }) else {
                    throw ManifestError.invalid("\(page.name).setup.key does not exist: \(keyRef)")
                }
                fill = SetupScript.Fill(endpoint: manifest.relay.endpoint, keyID: id, secret: key.secret)
            case (nil, nil):
                fill = nil
            default:
                throw ManifestError.invalid("\(page.name).setup.endpoint and key must both be given or neither")
            }
            if detect, fill == nil { throw ManifestError.invalid("\(page.name).setup.detect lacks endpoint / key") }
            let transport: RelayTransport? = try setup.transport.map { try parse($0, "setup.transport") }
            let failure = try setup.failure.map { try verificationError(httpStatus: $0.httpStatus, reason: $0.reason, manifest: manifest) }
            if submit, fill == nil || setup.model == nil || transport == nil || failure == nil {
                throw ManifestError.invalid("\(page.name).setup.submit lacks endpoint / key / model / transport / failure")
            }
            return SetupScript(
                startsInManualSetup: manual, fill: fill, modelID: setup.model, transport: transport, failure: failure,
                pingError: failure ?? unauthorizedError(manifest)
            )
        }

        /// Combinations such as one item passed, one failed and one running are given by the manifest; the display is still computed by `RelayCapabilityTestPanel.make`.
        static func capabilityTestSeed(
            provider: Provider, modelID: String, preset: Manifest.CapabilityTest, keyID: String
        ) throws -> CapabilityTestSeed? {
            guard let model = provider.models.first(where: { $0.id == modelID }) else { return nil }
            // The panel's key name comes from the key the model is bound to; if the key named by the manifest does not match, the two sides are not the same picture.
            guard model.relayKeyID == keyID else {
                throw ManifestError.invalid("capabilityTest.key does not match the key bound to \(modelID)")
            }
            guard let runningRaw = preset.running else { throw ManifestError.invalid("capabilityTest lacks running") }
            var results: [RelayCapabilityTestPanel.Item: RelayCapabilityTest.ItemResult] = [:]
            for (rawItem, result) in preset.results {
                let item: RelayCapabilityTestPanel.Item = try parse(rawItem, "capabilityTest.results")
                results[item] = RelayCapabilityTest.ItemResult(
                    verdict: try parse(result.verdict, "capabilityTest.verdict"),
                    reason: try parse(result.reason, "capabilityTest.reason"),
                    status: result.status,
                    elapsedMs: result.elapsedMs
                )
            }
            return CapabilityTestSeed(
                input: RelayCapabilityTestPanel.Input(
                    transport: RelayEndpointResolver.effectiveTransport(provider: provider, model: model),
                    items: try preset.items.map { try parse($0, "capabilityTest.items") },
                    keyName: RelayModelAdvancedBoard.keySection(
                        provider: provider, modelID: modelID, readOnly: false
                    )?.current.title,
                    phase: .running,
                    results: results,
                    running: RelayCapabilityTestPanel.Running(item: try parse(runningRaw, "capabilityTest.running"), elapsedMs: 0),
                    written: false,
                    stopReason: nil
                ),
                modelName: model.name,
                runningSince: Date()
            )
        }
    }
}

/// Catalog stub for the add flow: answers every request locally with the currently applied manifest's `setupCatalog`, and does not touch the network at all.
/// Attached only to the screenshot flow's own session and not registered process-wide. When no manifest is applied it answers as offline.
nonisolated final class RelayFamilyDebugCatalogStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var appliedModelIDs: [String]?

    static var modelIDs: [String]? {
        get { lock.withLock { appliedModelIDs } }
        set { lock.withLock { appliedModelIDs = newValue } }
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.protocolClasses = [RelayFamilyDebugCatalogStub.self]
        return URLSession(configuration: configuration)
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let modelIDs = Self.modelIDs else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let payload: [String: Any] = [
            "object": "list",
            "data": modelIDs.map { ["id": $0, "object": "model"] },
        ]
        guard let url = request.url,
              let body = try? JSONSerialization.data(withJSONObject: payload),
              let response = HTTPURLResponse(
                  url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
