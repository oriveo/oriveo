import Foundation
import Testing
@testable import Oriveo

/// This suite sends no requests; if any path does send one, it always gets a 503 and never leaves the machine.
private final class RelayLiteralIdentityOfflineProtocol: URLProtocol, @unchecked Sendable {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayLiteralIdentityOfflineProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Relay identity by literal ID: gpt-4o and gpt-4o-2024-08-06 are two different models,
/// and date snapshots, canonicalModelId and display names play no part in identity; canonical is only used to read old stored values compatibly. Official providers are unchanged.
///
/// Assertion subjects come from what production entry points actually produce: `Provider` decoding, `ProviderManager` enable / disable / catalog refresh,
/// `ProviderSelectionSnapshot`, `RelayRuntimeSupport`, `AppState.disableModel` and the parameter store.
@Suite("Relay literal identity RL2-IDENT", .serialized, .sharedProcessState)
@MainActor
struct RelayLiteralIdentityTests {
    private static var retainedStates: [AppState] = []
    private static let requested = RelayRequestedConfig(transport: .openaiChatCompletions, authMode: .bearer)

    private func makeState() -> AppState {
        let state = AppState(
            seedDemoData: false,
            sessionUID: "relay-literal-\(UUID().uuidString)",
            providerSession: RelayLiteralIdentityOfflineProtocol.session()
        )
        // ProviderManager holds AppState as unowned, and the background wrap-up task may outlive the test case.
        Self.retainedStates.append(state)
        return state
    }

    /// Shape after enrichment: every gpt-4o-family entry in the catalog and the enabled list carries canonical gpt-4o.
    private func model(_ id: String, canonical: String? = "gpt-4o") -> AIModel {
        TestFactories.makeModel(id: id, name: "GPT-4o", capabilities: [.text], priceTier: "", canonicalModelId: canonical)
    }

    private func relayProvider(enabled: [String], catalog: [String]) -> Provider {
        var provider = TestFactories.makeProvider(
            kind: .relay,
            models: enabled.map { model($0) },
            catalogModels: catalog.map { model($0) },
            apiKey: "sk-relay",
            baseURLText: "https://relay.example.com/v1"
        )
        provider.relayRequested = Self.requested
        return provider
    }

    private func upsert(_ state: AppState, _ provider: Provider) throws -> UUID {
        try #require(state.providerManager.upsertProvider(provider))
        return provider.id
    }

    private func roundTrip(_ provider: Provider) throws -> Provider {
        try JSONDecoder().decode(Provider.self, from: JSONEncoder().encode(provider))
    }

    @Test("RL2-IDENT-01 relay decoding does not drop dated rows: both the catalog and the enabled list keep the base and the dated snapshot")
    func RL2_IDENT_01_decodeKeepsDatedRows() throws {
        let ids = ["gpt-4o-2024-08-06", "gpt-4o", "gpt-4o-2024-11-20"]
        let decoded = try roundTrip(relayProvider(enabled: ids, catalog: ids))

        #expect(decoded.catalogModels.map(\.id) == ids)
        #expect(decoded.models.map(\.id) == ids)

        // The enabled list is also deduplicated by literal key: of two entries differing only in case / whitespace, the first one wins.
        let twins = try roundTrip(relayProvider(enabled: ["GPT-4o", "gpt-4o", " gpt-4o-2024-08-06"], catalog: ["gpt-4o"]))
        #expect(twins.models.map(\.id) == ["GPT-4o", " gpt-4o-2024-08-06"])
        let refreshed = ModelResolver.makeEnabledModels(
            from: [model("GPT-4o"), model("gpt-4o")],
            catalogModels: [model("gpt-4o"), model("gpt-4o-2024-08-06")],
            providerKind: .relay
        )
        #expect(refreshed.map(\.id) == ["gpt-4o"])
    }

    @Test("RL2-IDENT-02 picking a dated model: the conversation's stored value and the model sent upstream are both the dated ID")
    func RL2_IDENT_02_datedSelectionStoresAndSendsLiteral() throws {
        let state = makeState()
        let id = try upsert(state, relayProvider(enabled: ["gpt-4o", "gpt-4o-2024-08-06"], catalog: ["gpt-4o", "gpt-4o-2024-08-06"]))
        let stored = try #require(state.provider(for: id))
        let dated = try #require(stored.models.first { $0.id == "gpt-4o-2024-08-06" })

        #expect(ProviderSelectionSnapshot.persistedModelID(requestedModelID: dated.id, in: stored) == "gpt-4o-2024-08-06")
        #expect(AppState.persistedConversationModelID(requestedModelID: dated.id, in: stored) == "gpt-4o-2024-08-06")
        #expect(ProviderSelectionSnapshot.selectedModel(storedModelID: "gpt-4o-2024-08-06", in: stored)?.id == "gpt-4o-2024-08-06")
        #expect(RelayRuntimeSupport.pickChatDriverModelID(in: stored, currentModel: dated) == .success("gpt-4o-2024-08-06"))
        // Stored value resolves back: an undated one still resolves to the undated model.
        #expect(ProviderSelectionSnapshot.selectedModel(storedModelID: "gpt-4o", in: stored)?.id == "gpt-4o")
    }

    @Test("RL2-IDENT-03 disabling one does not disable the other; with the base enabled, the dated snapshot can still be enabled on its own")
    func RL2_IDENT_03_disableOneKeepsTheOther() throws {
        let state = makeState()
        let id = try upsert(state, relayProvider(enabled: ["gpt-4o"], catalog: ["gpt-4o", "gpt-4o-2024-08-06"]))

        #expect(state.providerManager.enableModel(modelID: "gpt-4o-2024-08-06", for: id) == .added(modelName: "GPT-4o"))
        #expect(try #require(state.provider(for: id)).models.map(\.id) == ["gpt-4o", "gpt-4o-2024-08-06"])

        state.providerManager.disableModel(modelID: "gpt-4o-2024-08-06", for: id)
        #expect(try #require(state.provider(for: id)).models.map(\.id) == ["gpt-4o"])
    }

    @Test("RL2-IDENT-04 catalog refresh: an enabled dated snapshot is not merged into the base; when the catalog only has the base, the dated snapshot is still kept")
    func RL2_IDENT_04_catalogRefreshKeepsDatedEnabled() throws {
        let state = makeState()
        var provider = relayProvider(enabled: ["gpt-4o-2024-08-06"], catalog: ["gpt-4o", "gpt-4o-2024-08-06"])

        state.providerManager.applyRelaySyncResult(
            ProviderSyncResult(models: [model("gpt-4o"), model("gpt-4o-2024-08-06")]),
            to: &provider
        )
        #expect(provider.models.map(\.id) == ["gpt-4o-2024-08-06"])
        #expect(provider.catalogModels.map(\.id) == ["gpt-4o", "gpt-4o-2024-08-06"])

        var baseOnly = relayProvider(enabled: ["gpt-4o", "gpt-4o-2024-08-06"], catalog: ["gpt-4o", "gpt-4o-2024-08-06"])
        state.providerManager.applyRelaySyncResult(ProviderSyncResult(models: [model("gpt-4o")]), to: &baseOnly)
        #expect(baseOnly.models.map(\.id) == ["gpt-4o", "gpt-4o-2024-08-06"])
        #expect(baseOnly.catalogModels.map(\.id) == ["gpt-4o"])
    }

    @Test("RL2-IDENT-04 catalog refresh: when enabled models are non-empty but none are in the new catalog, the first catalog entry is not added; when enabled is empty, it is added as before")
    func RL2_IDENT_04_catalogRefreshDoesNotSeedFirstWhenEnabledNonEmpty() throws {
        let state = makeState()
        var provider = relayProvider(enabled: ["gpt-4o-2024-08-06"], catalog: ["gpt-4o-2024-08-06"])
        state.providerManager.applyRelaySyncResult(ProviderSyncResult(models: [model("gpt-4o")]), to: &provider)
        #expect(provider.models.map(\.id) == ["gpt-4o-2024-08-06"])

        var empty = relayProvider(enabled: [], catalog: [])
        state.providerManager.applyRelaySyncResult(ProviderSyncResult(models: [model("gpt-4o")]), to: &empty)
        #expect(empty.models.map(\.id) == ["gpt-4o"])
    }

    @Test("RL2-IDENT-05 read compatibility: a legacy canonical stored value resolves to its single match, and is judged removed when there are several matches")
    func RL2_IDENT_05_readCompatForLegacyCanonicalValues() throws {
        let unique = relayProvider(enabled: ["gpt-4o-2024-08-06"], catalog: ["gpt-4o-2024-08-06"])
        #expect(ProviderSelectionSnapshot.selectedModel(storedModelID: "gpt-4o", in: unique)?.id == "gpt-4o-2024-08-06")
        #expect(ProviderSelectionSnapshot.conversationModelState(storedModelID: "gpt-4o", in: unique) == .resolved)
        let lastUsed = LastUsedModelRef(providerID: unique.id, modelID: "gpt-4o")
        #expect(ProviderSelectionSnapshot.relayFallbackModel(in: unique, lastUsedModelRef: lastUsed)?.id == "gpt-4o-2024-08-06")

        let ambiguous = relayProvider(
            enabled: ["gpt-4o-2024-08-06", "gpt-4o-2024-11-20"],
            catalog: ["gpt-4o-2024-08-06", "gpt-4o-2024-11-20"]
        )
        #expect(ProviderSelectionSnapshot.selectedModel(storedModelID: "gpt-4o", in: ambiguous) == nil)
        #expect(
            ProviderSelectionSnapshot.conversationModelState(storedModelID: "gpt-4o", in: ambiguous)
                == .removed(connectionName: ambiguous.displayName)
        )

        // A dated stored value does not fall back to the base.
        let baseOnly = relayProvider(enabled: ["gpt-4o"], catalog: ["gpt-4o"])
        #expect(
            ProviderSelectionSnapshot.conversationModelState(storedModelID: "gpt-4o-2024-08-06", in: baseOnly)
                == .removed(connectionName: baseOnly.displayName)
        )
    }

    @Test("RL2-IDENT-06 parameter keys are written by literal ID and read back with a canonical fallback")
    func RL2_IDENT_06_parameterKeysWriteLiteralReadCanonicalFallback() throws {
        let suiteName = "relay-literal-params-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = relayProvider(enabled: ["gpt-4o-2024-08-06"], catalog: ["gpt-4o-2024-08-06"])
        let dated = try #require(provider.models.first)

        let key = CapabilityPreferenceRuntimeIdentity.canonicalModelID(provider: provider, model: dated)
        #expect(key == "gpt-4o-2024-08-06")

        // Legacy data: the value lives under the canonical key.
        let legacy = GenerationParameterOverrides(values: ["temperature": .init(state: .value, value: .number(0.3))])
        store.setModelDefaults(legacy, providerID: provider.id, modelID: "gpt-4o")
        let transport = CapabilityPreferenceRuntimeIdentity(
            canonicalModelID: key, finalTransport: "openai_chat", runtimeRevision: "rev-1"
        ).wireValue
        store.setCapabilityPreferences(
            .init(web: .force), providerID: provider.id, modelID: "gpt-4o", conversationID: nil,
            transportIdentity: transport
        )
        store.setAdditionalRequestBody(
            .init(rawJSON: #"{"a":1}"#, sendsWithRequest: true),
            providerID: provider.id, modelID: "gpt-4o", conversationID: nil
        )

        // Literal key misses -> read the canonical key.
        #expect(store.modelDefaults(providerID: provider.id, modelID: key) == legacy)
        #expect(store.capabilityPreferences(
            providerID: provider.id, modelID: key, conversationID: nil, transportIdentity: transport
        )?.web == .force)
        #expect(store.additionalRequestBody(providerID: provider.id, modelID: key, conversationID: nil)?.rawJSON == #"{"a":1}"#)

        // Writes only touch the literal key; afterwards the literal key wins and the canonical key stays as it was.
        let literal = GenerationParameterOverrides(values: ["temperature": .init(state: .value, value: .number(0.9))])
        store.setModelDefaults(literal, providerID: provider.id, modelID: key)
        #expect(store.modelDefaults(providerID: provider.id, modelID: key) == literal)
        #expect(store.modelDefaults(providerID: provider.id, modelID: "gpt-4o") == legacy)
    }

    @Test("RL2-IDENT-06 cold start without a send path: the settings page reads directly by model.id and can still fall back to the old canonical record")
    func RL2_IDENT_06_settingsReadFallsBackWithoutSendPath() throws {
        let state = makeState()
        let id = try upsert(state, relayProvider(enabled: ["gpt-4o-2024-08-06"], catalog: ["gpt-4o-2024-08-06"]))
        let store = GenerationParameterSettingsStore.shared
        defer { store.removeScopes(providerID: id) }
        let legacy = GenerationParameterOverrides(values: ["temperature": .init(state: .value, value: .number(0.2))])
        store.setModelDefaults(legacy, providerID: id, modelID: "gpt-4o")

        // How AdvancedSettingsPage / GenerationParameterDefaultsSheet read: providerID + model.id, without going through identity computation.
        #expect(store.modelDefaults(providerID: id, modelID: "gpt-4o-2024-08-06") == legacy)
    }

    @Test("RL2-IDENT-10 metadata arrives late: providers first, metadata snapshot published later -> the old canonical key alias becomes readable")
    func RL2_IDENT_10_lateMetadataRegistersLegacyAliases() async throws {
        await MetadataClient.shared.resetForTesting()
        let state = makeState()
        // The stored value itself carries no canonical: the old canonical can only be resolved from metadata's resolveMap.
        var provider = relayProvider(enabled: [], catalog: [])
        provider.models = [model("my-4o", canonical: nil)]
        provider.catalogModels = [model("my-4o", canonical: nil)]
        let id = try upsert(state, provider)
        // The background wrap-up also writes providers once: wait for it to finish first, so a later read-back can only come from the snapshot publication.
        await state.providerManager.waitForRelayFinalizeForTesting(providerID: id)
        let store = GenerationParameterSettingsStore.shared
        defer { store.removeScopes(providerID: id) }
        let legacy = GenerationParameterOverrides(values: ["temperature": .init(state: .value, value: .number(0.4))])
        store.setModelDefaults(legacy, providerID: id, modelID: "gpt-4o")
        #expect(store.modelDefaults(providerID: id, modelID: "my-4o") == nil, "precondition: the old key cannot be resolved before metadata arrives")

        try await MetadataClient.shared.loadSplitForTesting(
            indexJSON: #"{"version":42,"view":"index","contractVersion":1,"providers":{"relay":{"catalogRevision":"sha256:relay-ident-10"}}}"#,
            indexETag: "etag-relay-ident-10",
            catalogJSONs: ["relay": #"{"view":"catalog","provider":"relay","catalogRevision":"sha256:relay-ident-10","resolveMap":{"my-4o":"gpt-4o"},"models":{"gpt-4o":{"canonicalModelId":"gpt-4o","capabilities":["text"]}}}"#]
        )
        #expect(CapabilityPreferenceRuntimeIdentity.legacyRelayModelIDs(provider: provider, model: provider.models[0]) == ["gpt-4o"], "precondition: the old key resolves once metadata is in")

        // No providers write at all: re-registration is triggered by the snapshot publication alone.
        #expect(store.modelDefaults(providerID: id, modelID: "my-4o") == legacy)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("RL2-IDENT-07 disabling deletes keys: the literal key is deleted; the canonical key is deleted only when no other enabled model on that connection has a canonical equal to it")
    func RL2_IDENT_07_disableRemovesLiteralAndOrphanedCanonicalKeys() throws {
        let state = makeState()
        var provider = relayProvider(enabled: ["gpt-4o", "gpt-4o-2024-08-06"], catalog: ["gpt-4o", "gpt-4o-2024-08-06"])
        provider.models.append(model("claude-4-haiku", canonical: "claude-4-haiku"))
        let id = try upsert(state, provider)
        let store = GenerationParameterSettingsStore.shared
        defer { store.removeScopes(providerID: id) }
        let values = GenerationParameterOverrides(values: ["temperature": .init(state: .value, value: .number(0.5))])
        for key in ["gpt-4o", "gpt-4o-2024-08-06"] {
            store.setModelDefaults(values, providerID: id, modelID: key)
        }

        // Disable the dated snapshot: the literal key is deleted; the base is still enabled and its canonical is also gpt-4o -> the canonical key stays.
        state.disableModel(modelID: "gpt-4o-2024-08-06", for: id)
        #expect(try #require(state.provider(for: id)).models.map(\.id) == ["gpt-4o", "claude-4-haiku"])
        #expect(Self.storedModelIDs(store, providerID: id) == ["gpt-4o"])

        // Then disable the base: its literal key is gpt-4o, and once it is deleted no enabled model has gpt-4o as canonical.
        store.setModelDefaults(values, providerID: id, modelID: "gpt-4o-2024-08-06")
        state.disableModel(modelID: "gpt-4o", for: id)
        #expect(try #require(state.provider(for: id)).models.map(\.id) == ["claude-4-haiku"])
        #expect(Self.storedModelIDs(store, providerID: id) == ["gpt-4o-2024-08-06"])
    }

    @Test("RL2-IDENT-08 regression: dated snapshots of official providers (openAI) still fold into the base")
    func RL2_IDENT_08_officialProviderStillFoldsDatedSnapshot() throws {
        let base = model("gpt-4o")
        let dated = model("gpt-4o-2024-08-06")
        let official = TestFactories.makeProvider(kind: .openAI, models: [base], catalogModels: [dated, base])

        let decoded = try roundTrip(official)
        #expect(decoded.catalogModels.map(\.id) == ["gpt-4o"])
        #expect(ModelResolver.modelsShareSameRemoteModel(base, dated, providerKind: .openAI))
        #expect(ModelResolver.matchingModel(modelID: "gpt-4o-2024-08-06", in: [base], providerKind: .openAI)?.id == "gpt-4o")
        #expect(ModelResolver.preferredStoredModelIdentifier(for: dated, providerKind: .openAI) == "gpt-4o")
    }

    @Test("RL2-IDENT-07 disabling deletes keys: the canonical key is not deleted when it equals the literal key (compared by key) of a still-enabled model")
    func RL2_IDENT_07_canonicalKeyMatchingRemainingLiteralIsKept() throws {
        let state = makeState()
        // The remaining GPT-4o's canonical is not gpt-4o, but its literal key (different case) is exactly the disabled model's canonical key.
        var provider = relayProvider(enabled: [], catalog: [])
        provider.models = [model("GPT-4o", canonical: "openai/gpt-4o"), model("gpt-4o-2024-08-06"), model("claude-4-haiku", canonical: "claude-4-haiku")]
        provider.catalogModels = provider.models
        let id = try upsert(state, provider)
        let store = GenerationParameterSettingsStore.shared
        defer { store.removeScopes(providerID: id) }
        let values = GenerationParameterOverrides(values: ["temperature": .init(state: .value, value: .number(0.5))])
        for key in ["gpt-4o", "gpt-4o-2024-08-06"] {
            store.setModelDefaults(values, providerID: id, modelID: key)
        }

        state.disableModel(modelID: "gpt-4o-2024-08-06", for: id)
        #expect(try #require(state.provider(for: id)).models.map(\.id) == ["GPT-4o", "claude-4-haiku"])
        #expect(Self.storedModelIDs(store, providerID: id) == ["gpt-4o"])
    }

    private struct RawRecord: Decodable {
        let providerID: UUID
        let modelID: String
    }

    /// Reads the shared store's persisted records directly: the read API falls back to canonical, so it cannot tell whether the key itself is still there.
    private static func storedModelIDs(_ store: GenerationParameterSettingsStore, providerID: UUID) -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: "generation_parameter_settings.v1"),
              let records = try? JSONDecoder().decode([RawRecord].self, from: data) else { return [] }
        return Set(records.filter { $0.providerID == providerID }.map(\.modelID))
    }
}
