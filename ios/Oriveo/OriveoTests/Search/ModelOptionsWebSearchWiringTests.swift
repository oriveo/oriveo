import Foundation
import Testing
@testable import Oriveo

/// In-memory credential backend: follows SearchServiceStore's production semantics, only swapping the medium.
private final class WiringCredentials: McpCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func read(account: String) -> Data? { lock.withLock { items[account] } }
    func write(_ data: Data, account: String) throws { lock.withLock { items[account] = data } }
    func delete(account: String) throws { _ = lock.withLock { items.removeValue(forKey: account) } }
    func accounts() -> [String] { lock.withLock { Array(items.keys) } }
}

/// Web card wiring semantics (external search services contract, "wiring"): computed fresh before send, a single routing input, nothing the panel cannot store,
/// new-conversation source kept in memory only, conversation delete and guest migration, 0 services + native rejected keeps the toggle, copy never exposes placeholders.
@MainActor
@Suite("External search web card wiring")
struct ModelOptionsWebSearchWiringTests {
    typealias Shape = ModelOptionCapabilityShape

    private static func makeStore(scope: String = "uid-1") -> (SearchServiceStore, URL, WiringCredentials) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-wiring-\(UUID().uuidString)", isDirectory: true)
        let credentials = WiringCredentials()
        return (SearchServiceStore(directory: directory, credentials: credentials, scope: scope), directory, credentials)
    }

    private static let customService = StoredSearchService(
        id: "s-nas", kind: .custom, name: "NAS", address: "https://nas.example/search", protocolID: "searxng"
    )

    private static func state(
        _ facts: WebSearchFacts, panelWritable: Bool = true, webOn: Bool = true,
        services: [WebSearchStateService] = [], stored: SearchJSON? = nil
    ) -> WebSearchState {
        SearchRoute.resolveWebSearchState(.init(
            facts: facts, panelWritable: panelWritable, webOn: webOn, modelKey: "c:m",
            services: services, stored: stored
        ))
    }

    private static let nas = WebSearchStateService(id: "s-nas", name: "NAS", status: .ready)

    // MARK: ① Computed fresh before send

    @Test("Cold start, panel never opened, conversation picked an external service: the pre-send computation yields a request without native web fields")
    func coldStartExternalSourceDropsNativeFields() async throws {
        let (store, directory, _) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = TestFactories.makeModel(id: "gpt-cold", capabilities: [.text], isDefault: true)
        let provider = TestFactories.makeProvider(kind: .openAI, models: [model])
        let conversationID = UUID()
        try await store.save(Self.customService, key: nil)
        let picked = try #require(SearchRoute.updateSearchSource(
            stored: nil, modelKey: ModelOptionsWebSearch.modelKey(provider: provider, model: model),
            event: .pickService(serviceId: Self.customService.id, serviceName: "NAS")
        ))
        try await store.setConversationSource(picked, conversationID: conversationID.uuidString)

        // Fresh process: no panel state at all, reading only from storage and the built-in catalog.
        let search = WebSearchSettingsModel()
        await search.load(store: store, providers: [provider])
        let suppressed = await ModelOptionsWebSearch.nativeFieldsSuppressed(
            search: search, provider: provider, model: model, conversationID: conversationID,
            partitionID: "uid-1", panelWritable: true, webOn: true
        )
        #expect(suppressed)

        var selection = ChatCapabilitySelection(reasoningMode: .automatic, webSearchEnabled: true)
        selection.typedPreferences = .init(web: .automatic, reasoningIntent: nil)
        let stripped = selection.withoutNativeWebSearch
        #expect(stripped.webSearchEnabled == false)
        #expect(stripped.typedPreferences?.web == .off)

        // Control: a conversation that has not enabled external on this model suppresses no fields (outbound is unchanged).
        let other = await ModelOptionsWebSearch.nativeFieldsSuppressed(
            search: search, provider: provider, model: model, conversationID: UUID(),
            partitionID: "uid-1", panelWritable: true, webOn: true
        )
        #expect(other == false)
    }

    // MARK: ② One set of facts

    @Test("facts normalization: presentation state → recipeWeb, relay web row → relayStatus")
    func factsMapping() {
        let facts = { (presentation: CapabilityControlPresentation) in
            ModelOptionsWebSearch.facts(
                form: .byok, presentation: presentation, relayWeb: nil, nativeRejected: false,
                managedWebAvailable: false, toolCall: .supported
            )
        }
        #expect(facts(.automaticAvailable).recipeWeb == .autoAvailable)
        #expect(facts(.forceUnsupported).recipeWeb == .autoAvailable)
        #expect(facts(.unsupported).recipeWeb == .unavailable)
        #expect(facts(.customOnly).recipeWeb == .customOnly)
        #expect(facts(.pending).recipeWeb == .none)
        let relay = ModelOptionsWebSearch.facts(
            form: .relay, presentation: .unknown, relayWeb: .localEngine, nativeRejected: false,
            managedWebAvailable: false, toolCall: .unknown
        )
        #expect(relay.relayStatus == .localEngine)
    }

    // MARK: ③ What the panel cannot store (given by shapeMode)

    @Test("Panel cannot store: toggle-type rows have shapeMode = existing with the same shape as before; rows with no service still give an action")
    func notWritableKeepsToggleRows() {
        var input = Shape.Input(
            capability: .web, presentation: .unsupported, selectedIntent: "automatic", isWritable: false
        )
        let base = Shape.resolve(input)
        let toggleRow = Self.state(.init(form: .byok, recipeWeb: .unavailable), panelWritable: false, services: [Self.nas])
        #expect(toggleRow.shapeMode == .existing)
        input.webSearchState = toggleRow
        #expect(Shape.resolve(input) == base)

        let noService = Self.state(.init(form: .byok, recipeWeb: .unavailable), panelWritable: false)
        input.webSearchState = noService
        guard case let .notice(notice) = Shape.resolve(input) else {
            Issue.record("A row with no service should be a notice plus an action")
            return
        }
        #expect(notice.cta?.action == .addSearchService)
        #expect(noService.oneTapArms == false)
    }

    // MARK: External takes effect only after one tap

    @Test("Native-model conversation with web on → switch to a model without native support: the card shows off with a not-enabled hint, send suppresses no fields, the chip is not lit")
    func switchingToNonNativeModelDoesNotSearch() async throws {
        let (store, directory, _) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.save(Self.customService, key: nil)
        let nativeModel = TestFactories.makeModel(id: "gpt-native", capabilities: [.text], isDefault: true)
        let otherModel = TestFactories.makeModel(id: "deepseek-chat", capabilities: [.text], isDefault: false)
        let provider = TestFactories.makeProvider(kind: .openAI, models: [nativeModel, otherModel])
        let search = WebSearchSettingsModel()
        await search.load(store: store, providers: [provider])

        let onNative = SearchRoute.resolveWebSearchState(ModelOptionsWebSearch.stateInput(
            search, facts: .init(form: .byok, recipeWeb: .autoAvailable, toolCall: .supported),
            panelWritable: true, webOn: true, provider: provider, model: nativeModel, stored: nil
        ))
        #expect(onNative.route.path == .native)
        #expect(onNative.toggleControls == .conversationWeb)

        let switched = SearchRoute.resolveWebSearchState(ModelOptionsWebSearch.stateInput(
            search, facts: .init(form: .byok, recipeWeb: .unavailable, toolCall: .supported),
            panelWritable: true, webOn: true, provider: provider, model: otherModel, stored: nil
        ))
        #expect(switched.armHint)
        #expect(switched.toggleOn == false)
        #expect(switched.chipLit == false)
        #expect(switched.nativeFieldsSuppressed == false)
        #expect(switched.card.notes.contains { $0.key == "card.armHint" })

        var input = Shape.Input(capability: .web, presentation: .unsupported, selectedIntent: "automatic")
        input.webSearchState = switched
        guard case let .toggleWithSource(toggle, _) = Shape.resolve(input) else {
            Issue.record("The card should be toggleWithSource")
            return
        }
        #expect(toggle.isOn == false)
        let chip = ChatView.webSearchAdjusted(
            .init(webSearchEnabled: true, reasoningMode: .automatic, reasoningIntent: nil), preview: switched
        )
        #expect(chip.webSearchEnabled == false)
    }

    @Test("Model without native support with external enabled and conversation web off: send goes through external (suppressing native fields), chip lit")
    func externalOnWithConversationWebOff() async throws {
        let (store, directory, _) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.save(Self.customService, key: nil)
        let model = TestFactories.makeModel(id: "deepseek-chat", capabilities: [.text], isDefault: true)
        let provider = TestFactories.makeProvider(kind: .openAI, models: [model])
        let conversationID = UUID()
        let armed = SearchRoute.updateSearchSource(
            stored: nil, modelKey: ModelOptionsWebSearch.modelKey(provider: provider, model: model),
            event: .pickService(serviceId: Self.customService.id, serviceName: "NAS")
        )
        try await store.setConversationSource(armed, conversationID: conversationID.uuidString)
        let search = WebSearchSettingsModel()
        await search.load(store: store, providers: [provider])
        let state = SearchRoute.resolveWebSearchState(ModelOptionsWebSearch.stateInput(
            search, facts: .init(form: .byok, recipeWeb: .unavailable, toolCall: .supported),
            panelWritable: true, webOn: false, provider: provider, model: model,
            stored: await store.conversationSource(conversationID.uuidString)
        ))
        #expect(state.toggleControls == .external)
        #expect(state.nativeFieldsSuppressed)
        #expect(state.chipLit == true)
        // The send path computes through the same entry; even with conversation web off it goes external.
        let suppressed = await ModelOptionsWebSearch.nativeFieldsSuppressed(
            search: search, provider: provider, model: model, conversationID: conversationID,
            partitionID: "uid-1", panelWritable: true, webOn: false
        )
        #expect(suppressed)
    }

    @Test("Manually turning external off: removes only this model's external and leaves conversation web unchanged (the toggle controls external and does not write conversation web)")
    func disarmKeepsConversationWeb() throws {
        let armed = SearchRoute.updateSearchSource(
            stored: nil, modelKey: "c:m", event: .pickService(serviceId: "s-nas", serviceName: "NAS")
        )
        let stored = try armed.map { try SearchJSON.parse(JSONEncoder().encode($0)) }
        let on = Self.state(.init(form: .byok, recipeWeb: .unavailable), webOn: true, services: [Self.nas], stored: stored)
        #expect(on.toggleControls == .external)
        #expect(on.toggleOn)
        let disarmed = SearchRoute.updateSearchSource(stored: stored, modelKey: "c:m", event: .disarm)
        #expect(disarmed?.methods["c:m"] == nil)
        #expect(disarmed?.serviceId == "s-nas")
        // Conversation web is still on (webOn unchanged): external is off and the card shows "not enabled".
        let off = Self.state(
            .init(form: .byok, recipeWeb: .unavailable), webOn: true, services: [Self.nas],
            stored: try disarmed.map { try SearchJSON.parse(JSONEncoder().encode($0)) }
        )
        #expect(off.toggleOn == false)
        #expect(off.armHint)
    }

    @Test("Delete service: external off, fallback hint shown")
    func deletedServiceTurnsExternalOffWithNotice() throws {
        let armed = SearchRoute.updateSearchSource(
            stored: nil, modelKey: "c:m", event: .pickService(serviceId: "s-gone", serviceName: "Exa")
        )
        let state = Self.state(
            .init(form: .byok, recipeWeb: .unavailable), webOn: true, services: [Self.nas],
            stored: try armed.map { try SearchJSON.parse(JSONEncoder().encode($0)) }
        )
        #expect(state.toggleOn == false)
        #expect(state.source.notice?.fromName == "Exa")
        #expect(state.source.changed)
        #expect(state.card.notes.first?.key == "card.fallbackNotice")
    }

    @Test("Catalog unavailable: the card keeps the selection and shows a status note")
    func catalogUnavailableKeepsChoiceWithNote() throws {
        let preset = WebSearchStateService(id: "s-ds", name: "DeepSeek", status: .catalogUnavailable)
        let armed = SearchRoute.updateSearchSource(
            stored: nil, modelKey: "c:m", event: .pickService(serviceId: "s-ds", serviceName: "DeepSeek")
        )
        let state = Self.state(
            .init(form: .byok, recipeWeb: .unavailable), webOn: true, services: [preset],
            stored: try armed.map { try SearchJSON.parse(JSONEncoder().encode($0)) }
        )
        #expect(state.source.method == .external)
        #expect(state.source.serviceId == "s-ds")
        #expect(state.toggleOn)
        #expect(state.card.notes.contains { $0.key == "row.catalogUnavailable" })
    }

    // MARK: Adding from the panel selects the new service

    @Test("After a panel-initiated add (web card CTA / last row of the search method page) succeeds, pick_service the new service; adding directly in settings does not")
    func panelInitiatedAddPicksNewService() async throws {
        let (store, directory, _) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let search = WebSearchSettingsModel()
        await search.load(store: store, providers: [])
        let conversationID = UUID()

        // Both "Add search service" entries in the panel record origin = settings (source-level semantics, see ModelControlsSheet).
        let sheet = try String(contentsOf: SearchContractSupport.repoRoot.appendingPathComponent(
            "ios/Oriveo/Oriveo/Features/Chat/ModelControls/ModelControlsSheet.swift"
        ), encoding: .utf8)
        #expect(sheet.components(separatedBy: "expectArmAfterAdd(.settings)").count - 1 == 2)

        SearchArmAfterAdd.shared.expect(.init(conversationID: conversationID, modelKey: "c:m", persisted: true, origin: .settings))
        var first = StoredSearchService(id: "s-a", kind: .custom, name: "A", address: "https://a.example/search", protocolID: "searxng")
        _ = try await search.addCustom(first, key: nil)
        let picked = await store.conversationSource(conversationID.uuidString)
        #expect(picked?["methods"]?["c:m"]?.stringValue == "external")
        #expect(picked?["serviceId"]?.stringValue == "s-a")
        #expect(SearchArmAfterAdd.shared.pending == nil)

        // Adding directly in settings: no panel-initiated record, the conversation source is untouched.
        first.id = "s-b"
        first.name = "B"
        first.address = "https://b.example/search"
        _ = try await search.addCustom(first, key: nil)
        #expect(await store.conversationSource(conversationID.uuidString)?["serviceId"]?.stringValue == "s-a")

        // Entered settings from the panel and left without adding: voided, so a later direct add does not fire.
        SearchArmAfterAdd.shared.expect(.init(conversationID: conversationID, modelKey: "c:m", persisted: true, origin: .settings))
        SearchArmAfterAdd.shared.clear(origin: .settings)
        #expect(SearchArmAfterAdd.shared.pending == nil)
    }

    // MARK: ④ New-conversation source kept in memory only

    @Test("New conversation: the source stays in memory, is written once under the real id after the conversation is created, and the draft id is never persisted")
    func draftSourceStaysInMemoryUntilAdopted() async throws {
        let (store, directory, _) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let draftID = UUID()
        let conversationID = UUID()
        let value = SearchSourceStored(methods: ["c:m": .external], serviceId: "s-nas", serviceName: "NAS")
        SearchSourceDrafts.shared.set(value, for: draftID)
        #expect(SearchSourceDrafts.shared.value(for: draftID) != nil)
        #expect(await store.conversationSource(draftID.uuidString) == nil)

        let write = SearchSourceDrafts.shared.adopt(from: draftID, to: conversationID, store: store)
        // The first message send can read this in-memory copy.
        #expect(SearchSourceDrafts.shared.value(for: conversationID) != nil)
        #expect(SearchSourceDrafts.shared.value(for: draftID) == nil)
        await write?.value
        #expect(await store.conversationSource(conversationID.uuidString)?["serviceId"]?.stringValue == "s-nas")
        #expect(await store.conversationSource(draftID.uuidString) == nil)
        #expect(SearchSourceDrafts.shared.value(for: conversationID) == nil)
    }

    // MARK: ⑤ Conversation delete and guest migration

    @Test("Deleting a conversation deletes its source; guest migration carries the source along with the conversation (even when the guest has no services)")
    func sourcesFollowDeleteAndGuestMigration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-wiring-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = WiringCredentials()
        let guest = SearchServiceStore(directory: directory, credentials: credentials, scope: "guest")
        let value = SearchSourceStored(methods: ["c:m": .native])
        try await guest.setConversationSource(value, conversationID: "a")
        try await guest.setConversationSource(value, conversationID: "b")
        try await guest.removeConversationSources(["a"])
        #expect(await guest.conversationSource("a") == nil)
        #expect(await guest.conversationSource("b") != nil)

        try await SearchServiceStore.migratePartition(
            from: "guest", to: "uid-9", directory: directory, credentials: credentials
        )
        let account = SearchServiceStore(directory: directory, credentials: credentials, scope: "uid-9")
        #expect(await account.conversationSource("b")?["methods"]?["c:m"]?.stringValue == "native")
        #expect(await guest.conversationSource("b") == nil)
    }

    // MARK: ⑦ 0 services + native revoked / rejected (given by shapeMode)

    @Test("0 services + native rejected: existing_with_actions, keeps the toggle and status copy and only appends \"Add search service\"")
    func rejectedNativeKeepsToggle() throws {
        var input = Shape.Input(capability: .web, presentation: .automaticAvailable, selectedIntent: "automatic")
        guard case let .toggle(base) = Shape.resolve(input) else {
            Issue.record("Should be a toggle")
            return
        }
        let rejected = Self.state(.init(form: .byok, recipeWeb: .autoAvailable, nativeRejected: true))
        #expect(rejected.shapeMode == .existingWithActions)
        input.webSearchState = rejected
        guard case let .toggle(toggle) = Shape.resolve(input) else {
            Issue.record("The toggle was altered on rejection")
            return
        }
        #expect(toggle.isOn == base.isOn)
        #expect(toggle.caption == base.caption)
        #expect(toggle.target == base.target)
        #expect(toggle.cta?.action == .addSearchService)
    }

    // MARK: ⑧ Copy

    @Test("Card copy with placeholders does not expose them when parameters are missing")
    func cardTextNeverShowsPlaceholders() {
        for key in ["card.useService", "card.offUseService", "card.reuseStatus", "card.reuseDetail",
                    "card.sourceLine", "card.fallbackNotice", "picker.nativeSub"] {
            let text = Shape.webSearchCardText(key: key)
            #expect(!text.contains("%@") && !text.contains("$@") && !text.contains("{"), "\(key): \(text)")
        }
    }
}
