import Foundation
import Testing
@testable import Oriveo

/// Main-thread cost of large relay catalogs.
///
/// Scale follows a real public relay: about 22,000 models in the catalog, 1,500 enabled.
/// `ProviderManager` is `@MainActor`, and `updateProvider` used to run the whole
/// `ProviderCatalogResolver.resolve` synchronously on the main thread, where the relay branch
/// (`resolveFromLocal`) compared every catalog model against every enabled model: "catalog x enabled"
/// calls to `modelsShareSameRemoteModel`.
@MainActor
@Suite("Relay large catalog main-thread cost", .serialized)
struct RelayCatalogScaleTests {
    private static let catalogCount = 22_000
    private static let enabledCount = 1_500
    /// Main-thread budget for a single write: after the user taps "Add model" it must return within three frames.
    private static let mainThreadBudgetMs = 50.0

    private static var retainedStates: [AppState] = []

    // MARK: - Fixture (shaped like the catalog models `ProviderManager.registerRelay` produces)

    private static func catalogModelID(_ index: Int) -> String {
        // Mixed case plus some snapshot date suffixes, covering the id shapes of real relay catalogs.
        let vendor = "Vendor-\(index % 300)"
        let suffix = index % 9 == 0 ? "-20250101" : ""
        return "\(vendor)/Model-\(index)\(suffix)"
    }

    private static func makeCatalogModel(_ id: String, isDefault: Bool = false) -> AIModel {
        AIModel(
            id: id,
            name: ModelResolver.displayName(forManualModelID: id, providerKind: .relay),
            capabilities: [.text],
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: isDefault,
            priceTier: "",
            summary: "Discovered from relay catalog",
            groupKey: ModelResolver.groupKey(forManualModelID: id, providerKind: .relay),
            groupName: ModelResolver.groupName(forManualModelID: id, providerKind: .relay)
        )
    }

    private static func makeRelayProvider(
        catalogCount: Int = catalogCount,
        enabledCount: Int = enabledCount
    ) -> Provider {
        let catalog = (0..<catalogCount).map { makeCatalogModel(catalogModelID($0), isDefault: $0 == 0) }
        let stride = max(1, catalogCount / enabledCount)
        let enabled = (0..<enabledCount).map { catalog[$0 * stride] }
        return Provider(
            id: UUID(),
            kind: .relay,
            status: .connected,
            models: enabled,
            catalogModels: catalog,
            lastCheckedAt: nil,
            apiKey: "sk-relay-scale",
            apiKeyPreview: "sk-...cale",
            lastError: nil,
            baseURLText: "https://relay.scale.test/v1",
            customName: "Scale Relay",
            relayRequested: RelayRequestedConfig(
                transport: .openaiChatCompletions,
                authMode: .bearer,
                securityMode: .remoteHTTPS,
                resolvedAPIBaseURL: "https://relay.scale.test/v1"
            )
        )
    }

    /// All 8 official providers on the relay allowlist carry a resolveMap: every relay catalog entry is
    /// looked up across these 8 for enrichment, shaped like the real metadata.
    private static func whitelistMetadataJSON() -> String {
        let kinds = ["openAI", "anthropic", "gemini", "deepseek", "miniMax", "zhipu", "qwen", "moonshot"]
        let providers = kinds.map { kind -> String in
            let ids = (0..<60).map { "\(kind.lowercased())-official-\($0)" }
            let resolve = ids.map { "\"\($0)\": \"\($0)\"" }.joined(separator: ",")
            let models = ids.map { id in
                """
                "\(id)": {
                  "canonicalModelId": "\(id)",
                  "displayName": "\(id)",
                  "contextLength": 128000,
                  "capabilities": ["text"],
                  "pricing": { "promptPerMToken": 1.0, "completionPerMToken": 2.0 },
                  "profiles": { "reasoning": null, "webSearch": null, "imageGen": null },
                  "uiHints": { "groupKey": null, "groupName": null, "rank": 1, "recommended": false, "badgeOrder": null }
                }
                """
            }.joined(separator: ",")
            return "\"\(kind)\": { \"defaultModelId\": \"\(ids[0])\", \"resolveMap\": {\(resolve)}, \"models\": {\(models)} }"
        }.joined(separator: ",")
        return "{ \"version\": 1, \"providers\": {\(providers)} }"
    }

    private func loadWhitelistMetadata() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: Self.whitelistMetadataJSON())
    }

    private func makeState(with provider: Provider) -> AppState {
        let state = AppState(
            seedDemoData: true,
            sessionUID: "relay-catalog-scale-\(UUID().uuidString)",
            providerSession: URLSession(configuration: .ephemeral)
        )
        state.providers = [provider]
        state.conversations = []
        Self.retainedStates.append(state)
        return state
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    private static func measure(_ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        return milliseconds(clock.measure(body))
    }

    // MARK: - Timing

    /// Runs `resolve` with 15 and with 1,500 enabled: if matching were still pairwise, time would grow linearly
    /// with the enabled count (pairwise, 1,500 enabled over 22k took 20.7s, over twenty times the 15-enabled run);
    /// with the index the two differ only by the cost of building it.
    @Test("resolve: with a 22k catalog, cost does not grow with the enabled count (1,500 / 15 enabled < 1.5x)")
    func resolveCostDoesNotScaleWithEnabledCount() async throws {
        try await loadWhitelistMetadata()
        defer { ProviderCatalogResolver.resetMemoForTesting() }

        func bestResolveMs(_ provider: Provider, expectEnabled: Int) -> Double {
            var samples: [Double] = []
            for _ in 0..<2 {
                ProviderCatalogResolver.resetMemoForTesting()
                var resolved: ResolvedProviderCatalog?
                samples.append(Self.measure { resolved = ProviderCatalogResolver.resolve(provider: provider) })
                #expect(resolved?.catalog.count == Self.catalogCount)
                #expect(resolved?.enabledModels.count == expectEnabled)
            }
            return samples.min() ?? .infinity
        }

        let few = bestResolveMs(Self.makeRelayProvider(enabledCount: 15), expectEnabled: 15)
        let many = bestResolveMs(Self.makeRelayProvider(), expectEnabled: Self.enabledCount)
        let ratio = many / few
        print("[RelayCatalogScale] resolve \(Self.catalogCount) catalog: enabled 15 = \(String(format: "%.1f", few))ms, enabled \(Self.enabledCount) = \(String(format: "%.1f", many))ms, ratio = \(String(format: "%.2f", ratio))")
        #expect(ratio < 1.5, "resolve grows with the enabled count: \(few)ms -> \(many)ms")
    }

    /// One "Add" in the Home model picker (AppState.enableModel -> ProviderManager.enableModel -> updateProvider):
    /// the longest single main-thread stall from the tap until the background finalize is merged.
    @Test("updateProvider: adding a model with 22k catalog / 1.5k enabled stalls the main thread < 50ms and the finalize is merged")
    func enableModelKeepsMainThreadResponsive() async throws {
        try await loadWhitelistMetadata()
        defer { ProviderCatalogResolver.resetMemoForTesting() }
        var provider = Self.makeRelayProvider()
        provider.cachedAvailableModelCount = nil
        let state = makeState(with: provider)
        let enabledIDs = Set(provider.models.map(\.id))
        let modelID = try #require(provider.catalogModels.first { !enabledIDs.contains($0.id) }?.id)
        ProviderCatalogResolver.resetMemoForTesting()

        let probe = MainThreadStallProbe()
        probe.start()
        pumpMainRunLoop(0.05)
        let callMs = Self.measure {
            state.enableModel(modelID: modelID, for: provider.id)
        }
        await state.providerManager.waitForRelayFinalizeForTesting(providerID: provider.id)
        pumpMainRunLoop(0.05)
        probe.stop()
        let stallMs = probe.maxStall * 1_000
        print("[RelayCatalogScale] enableModel \(Self.catalogCount)/\(Self.enabledCount): call = \(String(format: "%.1f", callMs))ms, main-thread max stall (incl. finalize commit) = \(String(format: "%.1f", stallMs))ms")

        let updated = try #require(state.providers.first { $0.id == provider.id })
        #expect(updated.models.count == Self.enabledCount + 1)
        #expect(updated.models.contains { $0.id == modelID })
        // The background finalize was merged: the cached available count derives from resolve.
        #expect(updated.cachedAvailableModelCount == Self.catalogCount)
        #expect(stallMs < Self.mainThreadBudgetMs, "longest main-thread stall \(stallMs)ms exceeds \(Self.mainThreadBudgetMs)ms")
    }

    /// A relay catalog refresh (refreshRelayCatalog -> applyRelaySyncResult) ran matchingModel for each enabled
    /// model against the whole new catalog on the main thread: 4.2s at 22k catalog / 1,500 enabled.
    /// The step is still linear in the catalog (about 45ms for 22k on a Debug simulator), so wall-clock time sits
    /// close to any budget and depends on machine load. The assertion therefore locks the growth instead: scaling
    /// catalog and enabled by 10x must grow time by less than 20x (linear is about 10x, quadratic about 100x).
    @Test("applyRelaySyncResult: 10x catalog grows time < 20x (linear), results match per-model matchingModel")
    func applyRelaySyncResultScalesLinearly() async throws {
        await MetadataClient.shared.resetForTesting()

        func bestMs(catalogCount: Int, enabledCount: Int) throws -> Double {
            let provider = Self.makeRelayProvider(catalogCount: catalogCount, enabledCount: enabledCount)
            let state = makeState(with: provider)
            // New catalog: the same models with ids upper-cased, forcing the exact pass through case folding.
            let refreshedCatalog = provider.catalogModels.map { Self.makeCatalogModel($0.id.uppercased()) }
            var samples: [Double] = []
            var result = provider
            for _ in 0..<2 {
                var working = provider
                samples.append(Self.measure {
                    state.providerManager.applyRelaySyncResult(ProviderSyncResult(models: refreshedCatalog), to: &working)
                })
                result = working
            }
            // Spot-check against per-model matchingModel (a full comparison would itself be quadratic).
            #expect(result.models.count == provider.models.count)
            for position in stride(from: 0, to: provider.models.count, by: 50) {
                let expected = ModelResolver.matchingModel(
                    modelID: provider.models[position].id, in: result.catalogModels, providerKind: .relay
                )
                #expect(result.models[position].id == expected?.id)
            }
            return samples.min() ?? .infinity
        }

        let small = try bestMs(catalogCount: Self.catalogCount / 10, enabledCount: Self.enabledCount / 10)
        let large = try bestMs(catalogCount: Self.catalogCount, enabledCount: Self.enabledCount)
        let ratio = large / small
        print("[RelayCatalogScale] applyRelaySyncResult \(Self.catalogCount / 10)/\(Self.enabledCount / 10) = \(String(format: "%.1f", small))ms, \(Self.catalogCount)/\(Self.enabledCount) = \(String(format: "%.1f", large))ms, ratio = \(String(format: "%.1f", ratio))")
        #expect(ratio < 20, "applyRelaySyncResult grows non-linearly: \(small)ms -> \(large)ms")
    }

    /// Adding a relay (RelaySetupView -> registerRelay): deduplicating the discovered ids used `result.contains`
    /// per id, quadratic in the catalog size (10.5s for the dedup step alone at 22k). As above, the growth
    /// factor is locked rather than a wall-clock budget.
    @Test("registerRelay: 10x catalog grows the longest main-thread stall < 20x (linear), resolve finalize merges in the background")
    func registerRelayScalesLinearly() async throws {
        await MetadataClient.shared.resetForTesting()
        defer { ProviderCatalogResolver.resetMemoForTesting() }

        func stallMs(catalogCount: Int) async throws -> Double {
            let state = makeState(with: Self.makeRelayProvider(catalogCount: 1, enabledCount: 1))
            // Real /models responses often contain duplicate entries.
            let unique = (0..<catalogCount).map(Self.catalogModelID)
            let ids = unique + unique.prefix(50)
            var registered: Provider?
            let probe = MainThreadStallProbe()
            probe.start()
            pumpMainRunLoop(0.05)
            let callMs = Self.measure {
                registered = state.providerManager.registerRelay(
                    name: "Scale Relay \(catalogCount)",
                    endpoint: "https://relay-\(catalogCount).scale.test/v1",
                    apiKey: "sk-relay-scale-\(catalogCount)",
                    catalogModelIDs: ids,
                    preferredModelID: Self.catalogModelID(7)
                )
            }
            let providerID = try #require(registered?.id)
            await state.providerManager.waitForRelayFinalizeForTesting(providerID: providerID)
            pumpMainRunLoop(0.05)
            probe.stop()

            let stored = try #require(state.providers.first { $0.id == providerID })
            #expect(stored.catalogModels.map(\.id) == unique)
            #expect(stored.models.map(\.id) == [Self.catalogModelID(7)])
            #expect(stored.cachedAvailableModelCount == catalogCount)
            let stall = probe.maxStall * 1_000
            print("[RelayCatalogScale] registerRelay \(ids.count) ids: call = \(String(format: "%.1f", callMs))ms, main-thread max stall = \(String(format: "%.1f", stall))ms")
            return max(stall, callMs)
        }

        let small = try await stallMs(catalogCount: Self.catalogCount / 10)
        let large = try await stallMs(catalogCount: Self.catalogCount)
        let ratio = large / small
        print("[RelayCatalogScale] registerRelay ratio = \(String(format: "%.1f", ratio))")
        #expect(ratio < 20, "registerRelay grows non-linearly: \(small)ms -> \(large)ms")
    }

    // MARK: - Ordering: a background finalize must never overwrite a newer write

    @Test("two updateProvider calls in a row: a late finalize from the first never overwrites the second; a finalize after deletion never resurrects")
    func staleFinalizeNeverOverwritesNewerWrite() async throws {
        try await loadWhitelistMetadata()
        defer { ProviderCatalogResolver.resetMemoForTesting() }
        var provider = Self.makeRelayProvider(catalogCount: 3_000, enabledCount: 100)
        provider.cachedAvailableModelCount = nil
        let state = makeState(with: provider)
        let manager = state.providerManager

        var first = provider
        first.customName = "first"
        manager.updateProvider(first)
        var second = try #require(state.providers.first { $0.id == provider.id })
        second.customName = "second"
        second.models.removeLast()
        manager.updateProvider(second)
        await manager.waitForRelayFinalizeForTesting(providerID: provider.id)
        pumpMainRunLoop(0.2)

        let stored = try #require(state.providers.first { $0.id == provider.id })
        #expect(stored.customName == "second")
        #expect(stored.models.count == 99)
        #expect(stored.cachedAvailableModelCount == 3_000)

        // Rewritten elsewhere right after the write (paths that bypass updateProvider): the finalize is void and must not overwrite it.
        var external = stored
        external.customName = "pre-external"
        external.cachedAvailableModelCount = nil
        manager.updateProvider(external)
        let externalIndex = try #require(state.providers.firstIndex { $0.id == provider.id })
        state.providers[externalIndex].customName = "external"
        await manager.waitForRelayFinalizeForTesting(providerID: provider.id)
        pumpMainRunLoop(0.2)
        let afterExternal = try #require(state.providers.first { $0.id == provider.id })
        #expect(afterExternal.customName == "external")
        #expect(afterExternal.cachedAvailableModelCount == nil)

        // Deleted right after a write: the Provider is gone when the finalize returns and must not be re-inserted.
        var third = afterExternal
        third.customName = "third"
        manager.updateProvider(third)
        state.providers.removeAll { $0.id == provider.id }
        await manager.waitForRelayFinalizeForTesting(providerID: provider.id)
        pumpMainRunLoop(0.2)
        #expect(!state.providers.contains { $0.id == provider.id })
    }

    // MARK: - Conversation model normalization: conversations x catalog

    private static let conversationCount = 1_500

    /// Conversation model ids use the production `ProviderSelectionSnapshot.persistedModelID` (the value stored after
    /// picking a model). One conversation in 100 points at a model since removed from the catalog (the same function
    /// stores an unmatched id as is, minus its prefix), so normalization misses the exact pass and exercises the
    /// fuzzy pass and the default-model fallback.
    private static func makeConversations(for provider: Provider, count: Int) -> [Conversation] {
        (0..<count).map { index in
            let requested = index % 100 == 3
                ? "Vendor-\(index % 300)/Retired-\(index)"
                : provider.models[(index * 7) % provider.models.count].id
            let stored = ProviderSelectionSnapshot.persistedModelID(requestedModelID: requested, in: provider) ?? requested
            return TestFactories.makeConversation(providerID: provider.id, providerKind: .relay, modelID: stored)
        }
    }

    /// The per-conversation decision `normalizeConversationModelSelections` made before, copied verbatim as the
    /// reference.
    private static func referenceNormalizedModelID(_ storedModelID: String, in provider: Provider) -> String {
        if let resolved = ModelResolver.matchingModel(for: storedModelID, in: provider) {
            return ModelResolver.preferredStoredModelIdentifier(for: resolved, providerKind: provider.kind)
        }
        if let defaultModel = provider.defaultModel {
            return ModelResolver.preferredStoredModelIdentifier(for: defaultModel, providerKind: provider.kind)
        }
        return storedModelID
    }

    /// One "add" from the Home picker with 1,500 conversations on this relay: every Provider write normalizes their
    /// model ids against the new catalog, which used to run `matchingModel` over the whole 22k catalog for each one.
    @Test("conversation normalization: adding a model with a 22k catalog and 1.5k conversations stalls the main thread < 50ms and matches per-conversation matchingModel")
    func conversationNormalizationKeepsMainThreadResponsive() async throws {
        try await loadWhitelistMetadata()
        defer { ProviderCatalogResolver.resetMemoForTesting() }
        var provider = Self.makeRelayProvider()
        provider.cachedAvailableModelCount = nil
        let state = makeState(with: provider)
        let conversations = Self.makeConversations(for: provider, count: Self.conversationCount)
        state.conversations = conversations
        let enabledIDs = Set(provider.models.map(\.id))
        let modelID = try #require(provider.catalogModels.first { !enabledIDs.contains($0.id) }?.id)
        ProviderCatalogResolver.resetMemoForTesting()

        let probe = MainThreadStallProbe()
        probe.start()
        pumpMainRunLoop(0.05)
        let callMs = Self.measure {
            state.enableModel(modelID: modelID, for: provider.id)
        }
        let written = try #require(state.providers.first { $0.id == provider.id })
        await state.providerManager.waitForRelayFinalizeForTesting(providerID: provider.id)
        // The write and the finalize merge each queue a normalization; wait until everything queued has merged.
        await state.providerManager.waitForConversationNormalizationForTesting(providerID: provider.id)
        pumpMainRunLoop(0.05)
        probe.stop()
        let stallMs = probe.maxStall * 1_000
        print("[RelayCatalogScale] enableModel \(Self.catalogCount)/\(Self.enabledCount) with \(Self.conversationCount) conversations: call = \(String(format: "%.1f", callMs))ms, main-thread max stall (incl. normalization commits) = \(String(format: "%.1f", stallMs))ms")

        let updated = try #require(state.providers.first { $0.id == provider.id })
        #expect(updated.models.contains { $0.id == modelID })
        let storedByID = Dictionary(uniqueKeysWithValues: state.conversations.map { ($0.id, $0.modelID) })
        // Every retired-model conversation is checked (fuzzy pass + default fallback) and the rest are sampled (a full
        // comparison is itself conversations x catalog).
        for (position, conversation) in conversations.enumerated() where position % 100 == 3 || position % 60 == 0 {
            // The old timing: normalize against `written` at write time, then once more against the finalized
            // Provider when the finalize merge changed it.
            var expected = Self.referenceNormalizedModelID(conversation.modelID, in: written)
            if updated != written { expected = Self.referenceNormalizedModelID(expected, in: updated) }
            #expect(storedByID[conversation.id] == expected, "conversation #\(position) \(conversation.modelID)")
        }
        #expect(stallMs < Self.mainThreadBudgetMs, "longest main-thread stall \(stallMs)ms exceeds \(Self.mainThreadBudgetMs)ms")
    }

    /// The same 22k catalog with 15 vs 1,500 conversations: if normalization still scanned the catalog per
    /// conversation, the time would grow with the conversation count; with one index the two differ only by lookups.
    /// Measures wall clock from the write call to that write's normalization merging (normalization may run in the
    /// background, so timing only the main-thread call would miss it).
    @Test("conversation normalization: with a 22k catalog, write-to-merge time does not grow with conversations (1,500 / 15 < 3x)")
    func conversationNormalizationCostDoesNotScaleWithConversationCount() async throws {
        try await loadWhitelistMetadata()
        defer { ProviderCatalogResolver.resetMemoForTesting() }

        func bestSettleMs(conversationCount: Int) async throws -> (call: Double, settled: Double) {
            let provider = Self.makeRelayProvider()
            let state = makeState(with: provider)
            let conversations = Self.makeConversations(for: provider, count: conversationCount)
            var calls: [Double] = []
            var settles: [Double] = []
            for round in 0..<2 {
                // Start every round from the original conversations: the previous round already moved the retired
                // ones to the default model, and without a reset the fuzzy pass would not be measured.
                state.conversations = conversations
                var edited = try #require(state.providers.first { $0.id == provider.id })
                edited.customName = "Scale Relay \(round)"
                let clock = ContinuousClock()
                let start = clock.now
                calls.append(Self.measure { state.providerManager.updateProvider(edited) })
                await state.providerManager.waitForConversationNormalizationForTesting(providerID: provider.id)
                settles.append(Self.milliseconds(clock.now - start))
                let stale = conversations.filter { $0.modelID.contains("/Retired-") }.map(\.id)
                #expect(!stale.isEmpty)
                #expect(state.conversations.filter { stale.contains($0.id) }.allSatisfy { !$0.modelID.contains("/Retired-") })
                await state.providerManager.waitForRelayFinalizeForTesting(providerID: provider.id)
                await state.providerManager.waitForConversationNormalizationForTesting(providerID: provider.id)
            }
            return (calls.min() ?? .infinity, settles.min() ?? .infinity)
        }

        let few = try await bestSettleMs(conversationCount: 15)
        let many = try await bestSettleMs(conversationCount: Self.conversationCount)
        let ratio = many.settled / few.settled
        print("[RelayCatalogScale] updateProvider \(Self.catalogCount) catalog → normalization committed: conversations 15 = \(String(format: "%.1f", few.settled))ms (call \(String(format: "%.1f", few.call))ms), conversations \(Self.conversationCount) = \(String(format: "%.1f", many.settled))ms (call \(String(format: "%.1f", many.call))ms), ratio = \(String(format: "%.2f", ratio))")
        #expect(ratio < 3, "conversation normalization grows with the conversation count: \(few.settled)ms → \(many.settled)ms")
    }

    /// Normalization results merge on the main thread through `AppState.updateConversationModelProjections`, which
    /// used a `firstIndex` over the whole conversation list for every update: updates x conversations. When a model
    /// is retired every conversation on it falls back to the default, so there are as many updates as conversations.
    @Test("conversation model merge: 10x conversations and updates cost < 20x (linear), and every update is written")
    func conversationModelProjectionUpdateScalesLinearly() {
        func bestMs(count: Int) -> Double {
            let providerID = UUID()
            let state = makeState(with: Self.makeRelayProvider(catalogCount: 1, enabledCount: 1))
            let conversations = (0..<count).map {
                TestFactories.makeConversation(providerID: providerID, providerKind: .relay, modelID: "old-\($0)")
            }
            var samples: [Double] = []
            for round in 0..<2 {
                state.conversations = conversations
                let updates = conversations.reversed().map {
                    ConversationModelUpdate(
                        conversationID: $0.id,
                        providerID: providerID,
                        providerKind: .relay,
                        modelID: "new-\(round)-\($0.modelID)",
                        metadataUpdatedAt: nil
                    )
                }
                samples.append(Self.measure { state.updateConversationModelProjections(updates) })
                let stored = Dictionary(uniqueKeysWithValues: state.conversations.map { ($0.id, $0.modelID) })
                #expect(state.conversations.count == count)
                #expect(conversations.allSatisfy { stored[$0.id] == "new-\(round)-\($0.modelID)" })
            }
            return samples.min() ?? .infinity
        }

        let small = bestMs(count: 300)
        let large = bestMs(count: 3_000)
        let ratio = large / small
        print("[RelayCatalogScale] updateConversationModelProjections 300 = \(String(format: "%.1f", small))ms, 3000 = \(String(format: "%.1f", large))ms, ratio = \(String(format: "%.1f", ratio))")
        #expect(ratio < 20, "the conversation model merge grows faster than linearly: \(small)ms → \(large)ms")
    }

    /// The in-memory merge of `upsertConversationProjections` as it was before indexing, kept verbatim as the
    /// reference: a firstIndex per update, replace on a match, prepend on a miss (a prepend shifts every later index,
    /// and a repeated new id in the same batch replaces the one inserted first).
    private static func referenceUpsert(_ updates: [Conversation], into conversations: [Conversation]) -> [Conversation] {
        var next = conversations
        for updated in updates {
            if let index = next.firstIndex(where: { $0.id == updated.id }) {
                next[index] = updated
            } else {
                next.insert(updated, at: 0)
            }
        }
        return next
    }

    /// Folder batch moves and deletes merge through `AppState.upsertConversationProjections`, which used a
    /// `firstIndex` over the whole conversation list for every update: updates x conversations.
    @Test("conversation batch upsert: 10x conversations and updates cost < 20x (linear)")
    func conversationProjectionUpsertScalesLinearly() {
        func bestMs(count: Int) -> Double {
            let state = makeState(with: Self.makeRelayProvider(catalogCount: 1, enabledCount: 1))
            let conversations = (0..<count).map {
                TestFactories.makeConversation(title: "old-\($0)", providerID: UUID(), modelID: "m")
            }
            var samples: [Double] = []
            for round in 0..<2 {
                state.conversations = conversations
                // Half update existing conversations (in reverse order), half are new.
                let updates = conversations.reversed().prefix(count / 2).map { conversation -> Conversation in
                    var updated = conversation
                    updated.title = "new-\(round)-\(conversation.title)"
                    return updated
                } + (0..<(count / 2)).map {
                    TestFactories.makeConversation(title: "fresh-\(round)-\($0)", providerID: UUID(), modelID: "m")
                }
                let expected = Self.referenceUpsert(updates, into: conversations)
                samples.append(Self.measure { state.upsertConversationProjections(updates) })
                #expect(state.conversations.map(\.id) == expected.map(\.id))
                #expect(state.conversations.map(\.title) == expected.map(\.title))
            }
            return samples.min() ?? .infinity
        }

        let small = bestMs(count: 300)
        let large = bestMs(count: 3_000)
        let ratio = large / small
        print("[RelayCatalogScale] upsertConversationProjections 300 = \(String(format: "%.1f", small))ms, 3000 = \(String(format: "%.1f", large))ms, ratio = \(String(format: "%.1f", ratio))")
        #expect(ratio < 20, "the conversation batch upsert grows faster than linearly: \(small)ms → \(large)ms")
    }

    @Test("conversation batch upsert matches per-update firstIndex: replace / prepend / repeated ids in a batch (seeded)")
    func conversationProjectionUpsertMatchesReference() {
        struct SplitMix64 {
            var state: UInt64
            mutating func next() -> UInt64 {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return z ^ (z >> 31)
            }
            mutating func int(_ upper: Int) -> Int { Int(next() % UInt64(upper)) }
        }
        var rng = SplitMix64(state: 0x0F0F_1234_ABCD_0042)
        let state = makeState(with: Self.makeRelayProvider(catalogCount: 1, enabledCount: 1))
        let ids = (0..<30).map { _ in UUID() }
        for round in 0..<60 {
            // Ids in the base list are unique (AppState indexes conversations by id); an update batch may repeat ids
            // and carry ids the base list does not have.
            var pool = ids
            let base = (0..<rng.int(20)).map { position -> Conversation in
                let id = pool.remove(at: rng.int(pool.count))
                return TestFactories.makeConversation(id: id, title: "base-\(round)-\(position)", modelID: "m")
            }
            let updates = (0..<rng.int(20)).map {
                TestFactories.makeConversation(id: ids[rng.int(ids.count)], title: "upd-\(round)-\($0)", modelID: "m")
            }
            state.conversations = base
            state.upsertConversationProjections(updates)
            let expected = Self.referenceUpsert(updates, into: base)
            #expect(state.conversations.map(\.id) == expected.map(\.id), "round=\(round)")
            #expect(state.conversations.map(\.title) == expected.map(\.title), "round=\(round)")
        }
    }

    // MARK: - Model display names in Home and folder conversation rows

    /// A relay Provider produced by the production write path (updateProvider plus the background finalize enrichment).
    private func finalizedRelayProvider(catalogCount: Int = catalogCount, enabledCount: Int = enabledCount) async throws -> Provider {
        var provider = Self.makeRelayProvider(catalogCount: catalogCount, enabledCount: enabledCount)
        provider.cachedAvailableModelCount = nil
        let state = makeState(with: provider)
        state.providerManager.updateProvider(provider)
        await state.providerManager.waitForRelayFinalizeForTesting(providerID: provider.id)
        return try #require(state.providers.first { $0.id == provider.id })
    }

    /// Home (and folders) refresh the `ModelDisplayLookup` used by conversation rows whenever providers change:
    /// fingerprint the whole catalog, and rebuild when the fingerprint changes (one metadata lookup per catalog model,
    /// four sets of lookup keys, two date-suffix regexes each). Both steps used to run on the main thread.
    @Test("Home row lookup: refreshing a 22k catalog stalls the main thread < 50ms; matches a direct build; unchanged fingerprint is not rebuilt")
    func homeModelLookupRefreshKeepsMainThreadResponsive() async throws {
        try await loadWhitelistMetadata()
        defer { ProviderCatalogResolver.resetMemoForTesting() }
        let provider = try await finalizedRelayProvider()
        var added = provider
        let enabledIDs = Set(provider.models.map(\.id))
        added.models.append(try #require(provider.catalogModels.first { !enabledIDs.contains($0.id) }))
        var statusOnly = added
        statusOnly.lastCheckedAt = Date()

        let store = ConversationModelLookupStore()
        let probe = MainThreadStallProbe()
        probe.start()
        pumpMainRunLoop(0.05)
        let clock = ContinuousClock()
        let start = clock.now
        store.refresh(providers: [provider])                  // first build
        await store.waitForRefreshForTesting()
        let firstReadyMs = Self.milliseconds(clock.now - start)
        store.refresh(providers: [added])                     // one model added: fingerprint changes, rebuild
        await store.waitForRefreshForTesting()
        store.refresh(providers: [statusOnly])                // status only: fingerprint unchanged, reuse
        await store.waitForRefreshForTesting()
        pumpMainRunLoop(0.05)
        probe.stop()
        let stallMs = probe.maxStall * 1_000
        print("[RelayCatalogScale] home model lookup refresh \(Self.catalogCount): first ready = \(String(format: "%.1f", firstReadyMs))ms, main-thread max stall (2 builds + 1 reuse) = \(String(format: "%.1f", stallMs))ms")

        #expect(store.isReady)
        #expect(store.buildCountForTesting == 2)
        let direct = ModelDisplayLookup(providers: [added])
        let probes = added.models.prefix(40).map(\.id) + added.catalogModels.prefix(40).map(\.id)
            + ["Vendor-3/Retired-1", "vendor-9/model-9-20250101", "", "  \(added.catalogModels[17].id.uppercased())  "]
        for modelID in probes {
            #expect(store.lookup.modelDisplayName(providerID: added.id, modelID: modelID) == direct.modelDisplayName(providerID: added.id, modelID: modelID), "\(modelID)")
            #expect(store.lookup.contextLength(providerID: added.id, modelID: modelID) == direct.contextLength(providerID: added.id, modelID: modelID), "\(modelID)")
        }
        #expect(stallMs < Self.mainThreadBudgetMs, "longest main-thread stall \(stallMs)ms exceeds \(Self.mainThreadBudgetMs)ms")
    }

    /// `ConversationRow.resolveModelName` as it was before, kept verbatim as the reference: when the lookup has no
    /// answer, run matchingModel over the enabled models one by one.
    nonisolated private static func referenceRowModelName(
        _ conversation: Conversation,
        provider: Provider?,
        lookup: ModelDisplayLookup
    ) -> String? {
        guard let provider else { return nil }
        if let name = lookup.modelDisplayName(providerID: provider.id, modelID: conversation.modelID) {
            return name
        }
        return ModelResolver.matchingModel(
            modelID: conversation.modelID,
            in: ProviderSelectionSnapshot.enabledModels(in: provider),
            providerKind: provider.kind
        )?.name
    }

    /// A row with no display name (its model was removed from the relay) falls back to searching the enabled models.
    /// After "Add all" the enabled models are the whole catalog: each row used to run matchingModel model by model,
    /// with two more regexes per model once the exact pass missed.
    @Test("row fallback: with everything enabled the per-row cost does not grow with the catalog (22k / 2.2k < 3x) and matches per-model matchingModel")
    func conversationRowFallbackDoesNotScaleWithEnabledCount() async throws {
        await MetadataClient.shared.resetForTesting()
        defer { ProviderCatalogResolver.resetMemoForTesting() }

        func perRowMs(catalogCount: Int) throws -> Double {
            let provider = Self.makeRelayProvider(catalogCount: catalogCount, enabledCount: catalogCount)
            let lookup = ModelDisplayLookup(providers: [provider])
            let rows = (0..<6).map {
                TestFactories.makeConversation(providerID: provider.id, providerKind: .relay, modelID: "Vendor-\($0)/Retired-\($0)")
            }
            // The first pass builds this lookup's index; measure the marginal cost per row after that
            for row in rows { _ = ConversationRow.resolveModelName(for: row, provider: provider, lookup: lookup) }
            var samples: [Double] = []
            for _ in 0..<2 {
                samples.append(Self.measure {
                    for row in rows { _ = ConversationRow.resolveModelName(for: row, provider: provider, lookup: lookup) }
                } / Double(rows.count))
            }
            for row in rows {
                #expect(ConversationRow.resolveModelName(for: row, provider: provider, lookup: lookup)
                    == Self.referenceRowModelName(row, provider: provider, lookup: lookup))
            }
            return samples.min() ?? .infinity
        }

        let small = try perRowMs(catalogCount: Self.catalogCount / 10)
        let large = try perRowMs(catalogCount: Self.catalogCount)
        let ratio = large / small
        print("[RelayCatalogScale] conversation row fallback (all enabled) per row: \(Self.catalogCount / 10) = \(String(format: "%.3f", small))ms, \(Self.catalogCount) = \(String(format: "%.3f", large))ms, ratio = \(String(format: "%.1f", ratio))")
        #expect(ratio < 3, "the row fallback grows with the enabled count: \(small)ms → \(large)ms")
    }

    @Test("row display names match the previous resolution: seeded random catalogs, lookup built from the current Provider or an older one")
    func conversationRowModelNameMatchesReference() async throws {
        await MetadataClient.shared.resetForTesting()
        defer { ProviderCatalogResolver.resetMemoForTesting() }

        struct SplitMix64 {
            var state: UInt64
            mutating func next() -> UInt64 {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return z ^ (z >> 31)
            }
            mutating func int(_ upper: Int) -> Int { Int(next() % UInt64(upper)) }
        }
        let stems = ["alpha", "Beta", "GAMMA", "Straße", "STRASSE", "e\u{301}clair", "delta-2025-01-01", "eps"]
        func randomID(_ rng: inout SplitMix64) -> String {
            var id = stems[rng.int(stems.count)] + "-\(rng.int(8))"
            if rng.int(3) == 0 { id = id.uppercased() }
            if rng.int(5) == 0 { id += "-20250101" }
            if rng.int(9) == 0 { id = "relay-manual-" + id }
            if rng.int(4) == 0 { id = stems[rng.int(stems.count)] }
            return id
        }
        func randomModel(_ rng: inout SplitMix64) -> AIModel {
            let id = randomID(&rng)
            let canonical: String? = rng.int(3) == 0 ? randomID(&rng) : nil
            return Self.model(id, name: "name-\(rng.int(40))", canonical: canonical)
        }

        var rng = SplitMix64(state: 0xFEED_0000_1111_2222)
        for round in 0..<40 {
            let kind: ProviderKind = [.relay, .openAI, .openRouter][round % 3]
            var provider = Self.makeRelayProvider(catalogCount: 1, enabledCount: 1)
            provider.kind = kind
            if kind != .relay { provider.relayRequested = nil }
            provider.catalogModels = (0..<(10 + rng.int(40))).map { _ in randomModel(&rng) }
            provider.models = (0..<(1 + rng.int(20))).map { _ in randomModel(&rng) }
            // Same source: the lookup was built from this Provider; different source: it was built before the change
            // (the Home refresh has not caught up yet)
            var stale = provider
            stale.models = Array(provider.models.dropFirst()) + [randomModel(&rng)]
            for lookupSource in [provider, stale] {
                let lookup = ModelDisplayLookup(providers: [lookupSource])
                for _ in 0..<30 {
                    let modelID = rng.int(2) == 0 ? randomID(&rng) : provider.models[rng.int(provider.models.count)].id
                    let row = TestFactories.makeConversation(providerID: provider.id, providerKind: kind, modelID: modelID)
                    #expect(
                        ConversationRow.resolveModelName(for: row, provider: provider, lookup: lookup)
                            == Self.referenceRowModelName(row, provider: provider, lookup: lookup),
                        "round=\(round) kind=\(kind) modelID=\(modelID)"
                    )
                }
            }
        }
    }

    /// Model ids normalized by the production `updateProvider`, compared one by one with the per-conversation
    /// `matchingModel(for:in:)` plus default fallback it replaces. The catalog has case twins, date suffixes, legacy
    /// prefixes, canonical ids and duplicate ids; the conversations have retired models, whitespace, the same
    /// character written composed and decomposed (a stored id resolves once, so two canonically equivalent spellings
    /// must not resolve differently), and another provider's conversation.
    @Test("conversation normalization matches per-conversation matchingModel: seeded random catalogs x relay / built-in / openRouter")
    func conversationNormalizationMatchesPerConversationReference() async throws {
        await MetadataClient.shared.resetForTesting()
        defer { ProviderCatalogResolver.resetMemoForTesting() }

        struct SplitMix64 {
            var state: UInt64
            mutating func next() -> UInt64 {
                state &+= 0x9e37_79b9_7f4a_7c15
                var z = state
                z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
                z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
                return z ^ (z >> 31)
            }
            mutating func int(_ upper: Int) -> Int { Int(next() % UInt64(upper)) }
        }

        let stems = ["alpha", "Beta", "GAMMA", "e\u{301}clair", "\u{E9}clair", "delta-2025-01-01", "Straße", "eps"]
        func randomID(_ rng: inout SplitMix64) -> String {
            var id = stems[rng.int(stems.count)] + "-\(rng.int(10))"
            if rng.int(3) == 0 { id = id.uppercased() }
            if rng.int(5) == 0 { id += "-20250101" }
            if rng.int(9) == 0 { id = "relay-manual-" + id }
            if rng.int(4) == 0 { id = stems[rng.int(stems.count)] }
            return id
        }
        func randomModel(_ rng: inout SplitMix64) -> AIModel {
            let id = randomID(&rng)
            let canonical: String? = switch rng.int(4) {
            case 0: randomID(&rng)
            case 1: " " + randomID(&rng).lowercased() + " "
            default: nil
            }
            return Self.model(id, name: rng.int(3) == 0 ? randomID(&rng) : id, canonical: canonical, isDefault: rng.int(8) == 0)
        }

        var rng = SplitMix64(state: 0x0bad_5eed_1234_5678)
        for round in 0..<30 {
            let kind: ProviderKind = [.relay, .openAI, .openRouter][round % 3]
            var provider = Self.makeRelayProvider(catalogCount: 1, enabledCount: 1)
            provider.kind = kind
            if kind != .relay { provider.relayRequested = nil }
            let catalog = (0..<(20 + rng.int(60))).map { _ in randomModel(&rng) }
            provider.catalogModels = rng.int(4) == 0 ? [] : catalog
            provider.models = (0..<(1 + rng.int(20))).map { _ in
                rng.int(2) == 0 ? catalog[rng.int(catalog.count)] : randomModel(&rng)
            }
            let state = makeState(with: provider)
            let otherProviderID = UUID()
            var conversations: [Conversation] = (0..<60).map { _ in
                let modelID: String = switch rng.int(6) {
                case 0: randomID(&rng)
                case 1: " " + catalog[rng.int(catalog.count)].id + " "
                case 2: ""
                default: catalog[rng.int(catalog.count)].id
                }
                return TestFactories.makeConversation(providerID: provider.id, providerKind: kind, modelID: modelID)
            }
            conversations.append(TestFactories.makeConversation(providerID: otherProviderID, modelID: catalog[0].id.uppercased()))
            state.conversations = conversations

            state.providerManager.updateProvider(provider)
            let written = try #require(state.providers.first { $0.id == provider.id })
            // A relay's normalization and finalize both run in the background: wait for the finalize merge, then for
            // every queued normalization.
            await state.providerManager.waitForRelayFinalizeForTesting(providerID: provider.id)
            await state.providerManager.waitForConversationNormalizationForTesting(providerID: provider.id)
            let settled = try #require(state.providers.first { $0.id == provider.id })
            // The old timing: normalize against `written` at write time, then once more against the finalized
            // Provider when the finalize merge changed it.
            func reference(_ stored: String, in written: Provider) -> String {
                written.allModels.isEmpty ? stored : Self.referenceNormalizedModelID(stored, in: written)
            }
            let storedByID = Dictionary(uniqueKeysWithValues: state.conversations.map { ($0.id, $0.modelID) })
            for conversation in conversations {
                var expected = conversation.modelID
                if conversation.providerID == provider.id {
                    expected = reference(expected, in: written)
                    if settled != written { expected = reference(expected, in: settled) }
                }
                #expect(storedByID[conversation.id] == expected, "round=\(round) kind=\(kind) stored=\(conversation.modelID)")
            }
        }
    }

    // MARK: - Equivalence: index lookup == pairwise comparison

    /// The pairwise matching of `resolveFromLocal`, copied verbatim as the reference: every catalog model against
    /// every enabled model, then every enabled model against the catalog as it stands (including models inserted
    /// earlier in the loop), prepending the ones that do not match.
    private struct ReferenceOutcome: Equatable {
        var catalog: [String]
        var enabled: [String]
        var defaultID: String?
        var availableCount: Int
        var hasManualModels: Bool
    }

    private static func entryKey(_ entry: ResolvedModel) -> String {
        "\(entry.model.id)|enabled=\(entry.isEnabled)|manual=\(entry.isManual)"
    }

    private static func referenceOutcome(provider: Provider, forceManual: Bool) -> ReferenceOutcome {
        let source: [AIModel] = (!forceManual && provider.kind == .relay)
            ? RelayOfficialCatalogResolver.enrichCatalog(
                provider: provider,
                runtimeConfig: MetadataClient.shared.syncRelayRuntimeConfig(),
                metadata: .shared
            )
            : provider.catalogModels
        let enabledIds = Set(provider.models.map(\.id))
        var catalog: [ResolvedModel] = []
        var enabledModels: [ResolvedModel] = []
        var hasManualModels = false
        for model in source {
            let isEnabled = enabledIds.contains(model.id)
                || provider.models.contains(where: {
                    ModelResolver.modelsShareSameRemoteModel($0, model, providerKind: provider.kind)
                })
            let isManual = forceManual || ModelResolver.isManualModel(model, providerKind: provider.kind)
            let resolved = ResolvedModel(model: model, isEnabled: isEnabled, isManual: isManual)
            catalog.append(resolved)
            if isEnabled { enabledModels.append(resolved) }
            if isManual { hasManualModels = true }
        }
        for model in provider.models {
            if !catalog.contains(where: {
                ModelResolver.modelsShareSameRemoteModel($0.model, model, providerKind: provider.kind)
            }) {
                let isManual = forceManual || ModelResolver.isManualModel(model, providerKind: provider.kind)
                let resolved = ResolvedModel(model: model, isEnabled: true, isManual: isManual)
                catalog.insert(resolved, at: 0)
                enabledModels.insert(resolved, at: 0)
                if isManual { hasManualModels = true }
            }
        }
        // resolveDefaultModel (metadataDefaultId == nil), unchanged
        var defaultModel: ResolvedModel? = enabledModels.first
        if let userDefault = provider.models.first(where: \.isDefault),
           let match = enabledModels.first(where: {
               $0.model.id.caseInsensitiveCompare(userDefault.id) == .orderedSame
                   || ModelResolver.modelsShareSameRemoteModel($0.model, userDefault, providerKind: provider.kind)
           }) {
            defaultModel = match
        }
        return ReferenceOutcome(
            catalog: catalog.map(entryKey),
            enabled: enabledModels.map(entryKey),
            defaultID: defaultModel?.model.id,
            availableCount: catalog.filter(\.model.isAvailable).count,
            hasManualModels: hasManualModels
        )
    }

    private static func actualOutcome(_ resolved: ResolvedProviderCatalog) -> ReferenceOutcome {
        ReferenceOutcome(
            catalog: resolved.catalog.map(entryKey),
            enabled: resolved.enabledModels.map(entryKey),
            defaultID: resolved.defaultModel?.model.id,
            availableCount: resolved.availableModelCount,
            hasManualModels: resolved.hasManualModels
        )
    }

    private static func model(
        _ id: String,
        name: String? = nil,
        canonical: String? = nil,
        isDefault: Bool = false,
        isAvailable: Bool = true,
        isManual: Bool = false
    ) -> AIModel {
        AIModel(
            id: id,
            name: name ?? id,
            capabilities: [.text],
            reasoningModeAvailable: false,
            isAvailable: isAvailable,
            isDefault: isDefault,
            priceTier: "",
            canonicalModelId: canonical,
            isManual: isManual
        )
    }

    /// Case / Unicode probes: the folding used by the index must agree pair for pair with `caseInsensitiveCompare == .orderedSame`.
    private static let unicodeProbes: [String] = [
        "GPT-4o", "gpt-4O", "gpt-4o-2024-08-06", "Straße", "STRASSE", "strasse", "İstanbul", "istanbul",
        "ISTANBUL", "Ωmega", "ωMEGA", "ΣΊΣΥΦΟΣ", "σίσυφος", "e\u{301}clair", "\u{E9}clair", "ÉCLAIR",
        "ﬁle", "FILE", "\u{FF21}\u{FF22}\u{FF23}", "\u{FF41}\u{FF42}\u{FF43}", "abc", "Kelvin-\u{212A}", "kelvin-k", "a\u{200B}b", "ab",
        "relay-manual-x", "X", "", " ", "модель-а", "модель-а ",
    ]

    @Test("RemoteModelIndex agrees with modelsShareSameRemoteModel pair for pair (case / Unicode / prefixes / name fallback)")
    func remoteModelIndexMatchesPairwiseComparison() {
        var probes: [AIModel] = []
        for (i, text) in Self.unicodeProbes.enumerated() {
            probes.append(Self.model(text))                                   // id only
            probes.append(Self.model("id-\(i)", name: text))                  // name fallback only
            probes.append(Self.model("id-c-\(i)", canonical: "  \(text)  ")) // canonical with whitespace
            probes.append(Self.model("relay-manual-\(text)"))                // legacy manual prefix
            probes.append(Self.model("openRouter-manual-\(text)"))
        }
        for kind in [ProviderKind.relay, .openRouter, .openAI, .grok] {
            for target in probes {
                let index = ModelResolver.RemoteModelIndex([target], providerKind: kind)
                for query in probes {
                    let expected = ModelResolver.modelsShareSameRemoteModel(target, query, providerKind: kind)
                    #expect(
                        index.containsRemoteModel(of: query) == expected,
                        "kind=\(kind) target=\(target.id)/\(target.name)/\(target.canonicalModelId ?? "-") query=\(query.id)/\(query.name)/\(query.canonicalModelId ?? "-")"
                    )
                }
            }
        }
    }

    @Test("resolve matches the pairwise reference entry for entry: relay / subscription / fallback (incl. openRouter without name fallback)")
    func resolveMatchesPairwiseReferenceOnCraftedCases() async throws {
        await MetadataClient.shared.resetForTesting()
        defer { ProviderCatalogResolver.resetMemoForTesting() }

        let catalog: [AIModel] = [
            Self.model("GPT-4o", isDefault: true),
            Self.model("gpt-4o"),                                   // case duplicate
            Self.model("claude-3-5-sonnet-20241022", canonical: "claude-3-5-sonnet"),
            Self.model("Vendor/Model-A", name: "Shared Name"),
            Self.model("Vendor/Model-B", name: "shared name"),      // same name as above, different id
            Self.model("canon-x-raw", canonical: "  Canon-X  "),    // canonical with whitespace
            Self.model("canon-empty", canonical: "   "),            // blank canonical falls back to id
            Self.model("relay-manual-legacy"),                      // legacy manual prefix
            Self.model("manual-flagged", isManual: true),
            Self.model("Straße"),
            Self.model("ﬁle-model"),
            Self.model("unavailable-one", isAvailable: false),
        ] + Self.unicodeProbes.enumerated().map { Self.model("probe-\($0.offset)", name: $0.element) }

        let enabled: [AIModel] = [
            Self.model("gpt-4O"),                                   // case-insensitive hit
            Self.model("claude-3-5-sonnet", isDefault: true),       // hits canonical
            Self.model("other-id", name: "SHARED NAME"),            // name-only hit (no hit under openRouter)
            Self.model("canon-x"),                                  // hits the trimmed canonical
            Self.model("legacy"),                                   // hits the id without prefix
            Self.model("STRASSE"),
            Self.model("FILE-MODEL"),
            Self.model("missing-1", name: "Dup Missing"),           // not in catalog
            Self.model("missing-2", name: "dup missing"),           // not in catalog, same name as above: inserted once (non-openRouter)
            Self.model("missing-1"),                                // duplicate id of an inserted one
            Self.model("manual-extra", isManual: true),
            Self.model("relay-manual-extra-legacy"),
            Self.model("ωMEGA"),
            Self.model("e\u{301}clair-x", name: "\u{E9}CLAIR"),
        ]

        func provider(kind: ProviderKind, authMode: ProviderAuthMode = .apiKey) -> Provider {
            var p = Self.makeRelayProvider(catalogCount: 1, enabledCount: 1)
            p.kind = kind
            p.authMode = authMode
            p.relayRequested = kind == .relay ? p.relayRequested : nil
            p.catalogModels = catalog
            p.models = enabled
            return p
        }

        let cases: [(String, Provider, Bool)] = [
            ("relay", provider(kind: .relay), false),
            ("openAI subscription", provider(kind: .openAI, authMode: .subscription), false),
            ("grok subscription", provider(kind: .grok, authMode: .subscription), false),
            ("openRouter fallback", provider(kind: .openRouter), true),
            ("openAI fallback", provider(kind: .openAI), true),
        ]
        for (label, p, forceManual) in cases {
            ProviderCatalogResolver.resetMemoForTesting()
            let expected = Self.referenceOutcome(provider: p, forceManual: forceManual)
            let actual = Self.actualOutcome(ProviderCatalogResolver.resolve(provider: p))
            #expect(actual == expected, "\(label)")
        }
    }

    @Test("resolve matches the pairwise reference entry for entry: random catalogs (fixed seed, with duplicates and models outside the catalog)")
    func resolveMatchesPairwiseReferenceOnRandomCatalogs() async throws {
        try await loadWhitelistMetadata()
        defer { ProviderCatalogResolver.resetMemoForTesting() }

        struct SplitMix64 {
            var state: UInt64
            mutating func next() -> UInt64 {
                state &+= 0x9e37_79b9_7f4a_7c15
                var z = state
                z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
                z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
                return z ^ (z >> 31)
            }
            mutating func int(_ upper: Int) -> Int { Int(next() % UInt64(upper)) }
        }

        // A small vocabulary forces many collisions: case, date suffixes, legacy prefixes, official hits (ids in the allowlist metadata).
        let stems = ["alpha", "Beta", "GAMMA", "openai-official-3", "qwen-official-7", "delta-2025-01-01", "eps"]
        func randomID(_ rng: inout SplitMix64) -> String {
            var id = stems[rng.int(stems.count)] + "-\(rng.int(12))"
            if rng.int(3) == 0 { id = id.uppercased() }
            if rng.int(5) == 0 { id += "-20250101" }
            if rng.int(9) == 0 { id = "relay-manual-" + id }
            if rng.int(4) == 0 { id = stems[rng.int(stems.count)] }
            return id
        }
        func randomModel(_ rng: inout SplitMix64) -> AIModel {
            let id = randomID(&rng)
            let name = rng.int(3) == 0 ? randomID(&rng) : id
            let canonical: String? = switch rng.int(4) {
            case 0: randomID(&rng)
            case 1: "  " + randomID(&rng).lowercased() + " "
            default: nil
            }
            return Self.model(
                id,
                name: name,
                canonical: canonical,
                isDefault: rng.int(10) == 0,
                isAvailable: rng.int(6) != 0,
                isManual: rng.int(8) == 0
            )
        }

        var rng = SplitMix64(state: 0x0123_4567_89ab_cdef)
        for round in 0..<40 {
            let kinds: [(ProviderKind, ProviderAuthMode)] = [(.relay, .apiKey), (.openAI, .subscription), (.openRouter, .apiKey)]
            let (kind, authMode) = kinds[round % kinds.count]
            var p = Self.makeRelayProvider(catalogCount: 1, enabledCount: 1)
            p.kind = kind
            p.authMode = authMode
            if kind != .relay { p.relayRequested = nil }
            p.catalogModels = (0..<(40 + rng.int(80))).map { _ in randomModel(&rng) }
            p.models = (0..<(5 + rng.int(40))).map { _ in
                rng.int(2) == 0 ? p.catalogModels[rng.int(p.catalogModels.count)] : randomModel(&rng)
            }
            // openRouter only avoids the fallback when metadata has an entry for it; the allowlist metadata here has none -> forceManual fallback
            let forceManual = kind == .openRouter
            ProviderCatalogResolver.resetMemoForTesting()
            let expected = Self.referenceOutcome(provider: p, forceManual: forceManual)
            let actual = Self.actualOutcome(ProviderCatalogResolver.resolve(provider: p))
            #expect(actual == expected, "round=\(round) kind=\(kind)")
        }
    }

    @Test("MatchingModelIndex agrees with matchingModel on every query (exact / case / date suffix / legacy prefix / canonical / whitespace / duplicates)")
    func matchingModelIndexMatchesLinearScan() {
        let models: [AIModel] = [
            Self.model("GPT-4o"),
            Self.model("gpt-4o"),                                          // case duplicate: the first one wins
            Self.model("gpt-4o-2024-08-06", canonical: "gpt-4o"),
            Self.model("claude-3-5-sonnet-20241022"),
            Self.model("claude-3-5-sonnet-2024-10-22", canonical: "Claude-3-5-Sonnet-2024-10-22"),
            Self.model("relay-manual-legacy-model"),
            Self.model("openAI-manual-other"),
            Self.model("canon-raw", canonical: "  Canon-Target  "),
            Self.model("Straße"),
            Self.model("vendor/Model-X-20250101"),
            Self.model("vendor/model-x"),
        ] + Self.unicodeProbes.enumerated().map { Self.model($0.element.isEmpty ? "empty-\($0.offset)" : $0.element) }

        let queries = [
            "gpt-4o", "GPT-4O", " gpt-4o ", "gpt-4o-2024-08-06", "gpt-4o-20240806", "claude-3-5-sonnet",
            "CLAUDE-3-5-SONNET-20241022", "claude-3-5-sonnet-2024-10-22", "legacy-model", "relay-manual-legacy-model",
            "relay-manual-LEGACY-MODEL-20250101", "openAI-manual-other", "other", "canon-target", "CANON-RAW",
            "strasse", "STRASSE", "vendor/model-x-20250101", "VENDOR/MODEL-X", "missing", "", "   ",
            "relay-manual-", "missing-20250101",
        ] + Self.unicodeProbes

        for kind in [ProviderKind.relay, .openAI, .openRouter] {
            for list in [models, models.reversed(), Array(models.prefix(4)), []] {
                var index = ModelResolver.MatchingModelIndex(list, providerKind: kind)
                for query in queries {
                    let expected = ModelResolver.matchingModel(modelID: query, in: list, providerKind: kind)
                    let actual = index.match(query)
                    #expect(
                        actual?.id == expected?.id && actual?.canonicalModelId == expected?.canonicalModelId,
                        "kind=\(kind) query=\(query) expected=\(expected?.id ?? "nil") actual=\(actual?.id ?? "nil")"
                    )
                }
            }
        }
    }
}
