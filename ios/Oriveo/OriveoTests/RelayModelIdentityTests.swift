import Foundation
import Testing
@testable import Oriveo

/// This suite sends no requests; if any path does send one, it always gets a 503 and never leaves the machine.
private final class RelayIdentityOfflineProtocol: URLProtocol, @unchecked Sendable {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayIdentityOfflineProtocol.self]
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

/// Relay model identity rules (relay identity is judged by literal ID).
///
/// The two kinds of folding belong to different places:
/// - Prefix folding is an iOS-only compatibility layer for old data (the shared fixture `shared/test-fixtures/relay/routing-fixtures.json`
///   marks PC-06 with `"platform": "ios"`; the identity key first strips `relay-manual-`), and the current behavior is still recorded.
/// - Date folding has been removed: relay identity is judged by literal ID, and date snapshots, canonical and display names play no part;
///   the identity layer (`ModelResolver` / `ProviderSelectionSnapshot` / `disableModel`) flipped together;
///   for the full behavior cases see `RelayLiteralIdentityTests` (RL2-IDENT-01 to 08).
///
/// Everything goes through production entry points (`ProviderManager.registerRelay` / `enableModel` / `ensureModelEnabledAsDefault` /
/// `saveManualModelData` / `disableModel`, `ProviderSelectionSnapshot`, `RelayRuntimeSupport`),
/// and asserts on the `Provider` they actually wrote. Post-write enrichment runs in a background task and the cases do not wait for it,
/// so a synchronous assertion sees the moment right after the write, before any canonical exists.
@Suite("Relay model identity rules", .serialized)
@MainActor
struct RelayModelIdentityTests {
    private static var retainedStates: [AppState] = []

    private func makeState() -> AppState {
        let state = AppState(
            seedDemoData: false,
            sessionUID: "relay-identity-\(UUID().uuidString)",
            providerSession: RelayIdentityOfflineProtocol.session()
        )
        // ProviderManager holds AppState as unowned, and the background wrap-up task may outlive the test case.
        Self.retainedStates.append(state)
        return state
    }

    private static let requested = RelayRequestedConfig(transport: .openaiChatCompletions, authMode: .bearer)

    private func register(
        _ state: AppState,
        catalog: [String],
        sample: String?,
        requested: RelayRequestedConfig = RelayModelIdentityTests.requested
    ) -> UUID {
        state.providerManager.registerRelay(
            name: "Identity Relay",
            endpoint: "https://relay.example.com/v1",
            apiKey: "sk-relay",
            relayRequested: requested,
            catalogModelIDs: catalog,
            preferredModelID: sample
        ).id
    }

    /// Connection shape after enrichment / catalog refresh has written canonical: the official alias table merges the dated snapshot into the undated one
    /// (the same path as `gpt-5.4-2026-04-01` -> `gpt-5.4` in `MetadataFixtureTests`).
    private func upsertEnriched(_ state: AppState, enabled: [String]) throws -> UUID {
        let catalog = ["gpt-4o", "gpt-4o-2024-08-06"].map {
            TestFactories.makeModel(id: $0, capabilities: [.text], priceTier: "", canonicalModelId: "gpt-4o")
        }
        var provider = TestFactories.makeProvider(
            kind: .relay,
            models: catalog.filter { enabled.contains($0.id) },
            catalogModels: catalog,
            apiKey: "sk-relay",
            baseURLText: "https://relay.example.com/v1"
        )
        provider.relayRequested = Self.requested
        try #require(state.providerManager.upsertProvider(provider))
        return provider.id
    }

    // MARK: - Question 1: the `relay-manual-` prefix
    //
    // Where folding happens: `ModelResolver.resolvedProviderModelIdentifier` only checks whether the ID starts with `<kind>-manual-`,
    // ignoring `isManual` and unable to tell old data from new input; `preferredStoredModelIdentifier` / `normalizedLookupCandidates`
    // both go through it.
    // This is an iOS-only compatibility layer for old data (PC-06 is marked `"platform": "ios"`), recorded as iOS-only technical debt and not on any cross-platform list.
    // Unlock criteria (either): PC-06 in `shared/test-fixtures/relay/routing-fixtures.json` is deleted or its expectation changes to the original prefixed ID;
    // or a decision records that old `relay-manual-` prefixed data is no longer supported / the prefix is only stripped for models that are not `isManual`.

    @Test("RLY-IDENT-01 current behavior: enabling relay-manual-gpt-4o actually enables the gpt-4o in the catalog")
    func RLY_IDENT_01_prefixedIDEnablesTheBareCatalogModel() throws {
        let state = makeState()
        let id = register(state, catalog: ["gpt-4o", "claude-4-haiku"], sample: "claude-4-haiku")

        let result = state.providerManager.enableModel(modelID: "relay-manual-gpt-4o", for: id)

        #expect(result == .added(modelName: "gpt-4o"))
        let stored = try #require(state.provider(for: id))
        #expect(stored.models.map(\.id) == ["claude-4-haiku", "gpt-4o"])
    }

    @Test("RLY-IDENT-02 current behavior: when gpt-4o is already enabled, adding relay-manual-gpt-4o adds no enabled entry through either entry point (step 2 and the model library)")
    func RLY_IDENT_02_prefixedIDIsAbsorbedByTheEnabledBareModel() throws {
        // Batch enabling saved in step 2: when prefix folding hits, it is added as manual, and the manual step then merges it into the already enabled gpt-4o by the same remote model.
        let stepTwo = makeState()
        let stepTwoID = register(stepTwo, catalog: ["gpt-4o"], sample: "gpt-4o")
        #expect(stepTwo.providerManager.enableModel(modelID: "relay-manual-gpt-4o", for: stepTwoID) == .alreadyEnabled)
        #expect(stepTwo.providerManager.ensureModelEnabledAsDefault(providerID: stepTwoID, modelID: "relay-manual-gpt-4o"))
        #expect(try #require(stepTwo.provider(for: stepTwoID)).models.map(\.id) == ["gpt-4o"])

        // Model library "Add model ID manually".
        let library = makeState()
        let libraryID = register(library, catalog: ["gpt-4o"], sample: "gpt-4o")
        #expect(library.providerManager.saveManualModelData(providerID: libraryID, modelID: "relay-manual-gpt-4o"))
        let stored = try #require(library.provider(for: libraryID))
        #expect(stored.models.map(\.id) == ["gpt-4o"])
        // The row probed in the catalog is replaced whole by the manual entry from the same source.
        #expect(stored.catalogModels.map(\.id) == ["relay-manual-gpt-4o"])
    }

    @Test("RLY-IDENT-03 current behavior: with no gpt-4o in the catalog, relay-manual-gpt-4o is stored as is, yet both what is sent upstream and what the conversation stores is gpt-4o")
    func RLY_IDENT_03_prefixedIDIsStoredVerbatimButSentBare() throws {
        let state = makeState()
        let id = register(state, catalog: [], sample: "relay-manual-gpt-4o")

        let stored = try #require(state.provider(for: id))
        let model = try #require(stored.models.first)
        #expect(stored.models.map(\.id) == ["relay-manual-gpt-4o"])
        #expect(model.isManual)
        #expect(RelayRuntimeSupport.pickChatDriverModelID(in: stored, currentModel: model) == .success("gpt-4o"))
        #expect(ProviderSelectionSnapshot.persistedModelID(requestedModelID: model.id, in: stored) == "gpt-4o")
    }

    // MARK: - Question 2: date snapshot suffix
    //
    // Unlocked: the `relayCases` in the shared fixture `shared/model-contracts/model_identity_contract.v1.json`
    // give the relay literal-identity expectations. Both former foldings were removed from the relay branch:
    // 1) Lookup: the relay branch of `ModelResolver.matchingModel` only accepts literal keys and no longer uses the ID with the date suffix removed as a candidate;
    // 2) canonical: enrichment / catalog refresh still writes `canonicalModelId` (for pricing and inheriting official capabilities), but it plays no part in identity,
    //    and is only a single-match fallback when `ModelResolver.resolveStoredModel` resolves old stored values.

    @Test("RLY-IDENT-04 both IDs are in the catalog and just written with no canonical yet: both can be enabled")
    func RLY_IDENT_04_bothCatalogIDsEnableBeforeEnrichment() throws {
        let state = makeState()
        let id = register(state, catalog: ["gpt-4o", "gpt-4o-2024-08-06"], sample: "gpt-4o")

        let result = state.providerManager.enableModel(modelID: "gpt-4o-2024-08-06", for: id)

        #expect(result == .added(modelName: "gpt-4o-2024-08-06"))
        #expect(try #require(state.provider(for: id)).models.map(\.id) == ["gpt-4o", "gpt-4o-2024-08-06"])
    }

    @Test("RLY-IDENT-05 the dated ID is not in the catalog: enabling from the model library cannot find it, and step 2 save adds it by literal ID so both are stored")
    func RLY_IDENT_05_datedIDOutsideCatalogIsADifferentModel() throws {
        let state = makeState()
        let baseOnly = register(state, catalog: ["gpt-4o"], sample: "gpt-4o")
        // Model library enabling: this literal ID is not in the catalog, and it is no longer folded into the undated one.
        #expect(state.providerManager.enableModel(modelID: "gpt-4o-2024-08-06", for: baseOnly) == .notFound)
        #expect(try #require(state.provider(for: baseOnly)).models.map(\.id) == ["gpt-4o"])
        // Step 2 save: folding hit another model, so it is added as manual and no longer silently dropped.
        #expect(state.providerManager.ensureModelEnabledAsDefault(providerID: baseOnly, modelID: "gpt-4o-2024-08-06"))
        let stored = try #require(state.provider(for: baseOnly))
        #expect(Set(stored.models.map(\.id)) == ["gpt-4o", "gpt-4o-2024-08-06"])
        #expect(stored.models.first { $0.id == "gpt-4o-2024-08-06" }?.isManual == true)

        let datedOnly = register(state, catalog: ["gpt-4o-2024-08-06"], sample: "gpt-4o-2024-08-06")
        #expect(state.providerManager.enableModel(modelID: "gpt-4o", for: datedOnly) == .notFound)
        #expect(try #require(state.provider(for: datedOnly)).models.map(\.id) == ["gpt-4o-2024-08-06"])
    }

    @Test("RLY-IDENT-06 after canonical has been written, another dated snapshot can still be enabled from the model library")
    func RLY_IDENT_06_enrichedSnapshotEnablesSeparately() throws {
        let state = makeState()
        let id = try upsertEnriched(state, enabled: ["gpt-4o"])

        #expect(state.providerManager.enableModel(modelID: "gpt-4o-2024-08-06", for: id) == .added(modelName: "gpt-4o-2024-08-06"))
        #expect(try #require(state.provider(for: id)).models.map(\.id) == ["gpt-4o", "gpt-4o-2024-08-06"])
    }

    @Test("RLY-IDENT-07 with both enabled and canonical present, picking the dated one stores the dated ID in the conversation, and disabling one does not disable the other")
    func RLY_IDENT_07_enrichedPairStaysSeparateInSelectionAndDisable() throws {
        let state = makeState()
        let id = try upsertEnriched(state, enabled: ["gpt-4o", "gpt-4o-2024-08-06"])
        let stored = try #require(state.provider(for: id))

        #expect(ProviderSelectionSnapshot.persistedModelID(requestedModelID: "gpt-4o-2024-08-06", in: stored) == "gpt-4o-2024-08-06")
        #expect(ProviderSelectionSnapshot.selectedModel(storedModelID: "gpt-4o-2024-08-06", in: stored)?.id == "gpt-4o-2024-08-06")
        #expect(ProviderSelectionSnapshot.selectedModel(storedModelID: "gpt-4o", in: stored)?.id == "gpt-4o")

        state.providerManager.disableModel(modelID: "gpt-4o-2024-08-06", for: id)
        #expect(try #require(state.provider(for: id)).models.map(\.id) == ["gpt-4o"])
    }

    // MARK: - Question 3: relayRequested.modelID at registration
    //
    // This is an invariant that must always hold, not a record of current behavior: the first write in `registerRelay` already goes through
    // `relayWriteNormalized`, so a connection carrying a modelID never entered memory, persistence or outbound sync.
    // The `withoutModelID` call afterwards by the caller clears the un-normalized copy returned by `registerRelay`.

    @Test("RLY-IDENT-08 the first write in registerRelay already carries no relayRequested.modelID, and the outbound sync document has none either")
    func RLY_IDENT_08_registerNeverStoresRequestedModelID() throws {
        let state = makeState()
        let requested = RelayRequestedConfig(transport: .openaiChatCompletions, authMode: .bearer, modelID: "model-b")
        let id = register(state, catalog: ["model-a", "model-b"], sample: "model-b", requested: requested)

        let stored = try #require(state.provider(for: id))
        #expect(stored.relayRequested?.modelID == nil)
        #expect(stored.relayRequested?.transport == .openaiChatCompletions)
        #expect(stored.models.map(\.id) == ["model-b"])
    }
}
