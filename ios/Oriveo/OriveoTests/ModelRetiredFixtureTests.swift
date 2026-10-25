import Foundation
import Testing
@testable import Oriveo

/// Retired-model decisions. Fixture `shared/test-fixtures/provider-catalog/model-retired.v1.json`,
/// one RETIRED_<id> per case, run through the production pure function `ConversationModelRetirement`.
@Suite("RETIRED model retirement decisions", .sharedProcessState)
struct ModelRetiredFixtureTests {

    // MARK: - Fixture

    nonisolated static func fixture() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/test-fixtures/provider-catalog/model-retired.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                return try #require(object as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func now() throws -> Date {
        let text = try #require(try fixture()["now"] as? String)
        return try #require(ConversationModelRetirement.parseDate(text))
    }

    private static func fixtureCase(_ group: String, _ id: String) throws -> [String: Any] {
        let cases = try #require(try fixture()[group] as? [[String: Any]])
        return try #require(cases.first { $0["id"] as? String == id }, "fixture is missing \(group).\(id)")
    }

    private static func string(_ value: Any?) -> String? { value as? String }

    private static func catalog(_ value: Any?) throws -> ConversationModelRetirement.Catalog? {
        guard let object = value as? [String: Any] else { return nil }
        let models = (object["models"] as? [[String: Any]] ?? []).map { model -> ConversationModelRetirement.CatalogModel in
            let lifecycle = (model["lifecycle"] as? [String: Any]).map {
                ConversationModelRetirement.Lifecycle(
                    state: string($0["state"]),
                    shutdownAt: string($0["shutdownAt"]).flatMap(ConversationModelRetirement.parseDate),
                    routedTo: string($0["routedTo"])
                )
            }
            return .init(id: model["id"] as? String ?? "", displayName: string(model["displayName"]), lifecycle: lifecycle)
        }
        let tombstones = (object["retiredModels"] as? [[String: Any]] ?? []).map {
            MetadataClient.RetiredModelTombstone(
                id: $0["id"] as? String ?? "",
                displayName: string($0["displayName"]),
                retiredAt: string($0["retiredAt"]),
                routedTo: string($0["routedTo"])
            )
        }
        return .init(
            models: models,
            retiredModels: tombstones,
            resolveMap: object["resolveMap"] as? [String: String] ?? [:],
            defaultModelId: string(object["defaultModelId"])
        )
    }

    private func checkConversation(_ id: String) throws {
        let item = try Self.fixtureCase("conversationCases", id)
        let conversation = try #require(item["conversation"] as? [String: Any])
        let expect = try #require(item["expect"] as? [String: Any])
        let modelId = try #require(conversation["modelId"] as? String)
        let result = ConversationModelRetirement.conversationStatus(
            catalog: try Self.catalog(item["catalog"]),
            userModels: item["userModels"] as? [String] ?? [],
            modelId: modelId,
            storedName: Self.string(conversation["storedName"]),
            now: try Self.now()
        )
        #expect(result.status.rawValue == expect["status"] as? String, "RETIRED-\(id) status")
        #expect(result.successorId == Self.string(expect["successorId"]), "RETIRED-\(id) successorId")
        #expect(result.displayName == expect["displayName"] as? String, "RETIRED-\(id) displayName")
        #expect(result.sendBlocked == expect["sendBlocked"] as? Bool, "RETIRED-\(id) sendBlocked")
        #expect(result.modelId == expect["modelIdAfter"] as? String, "RETIRED-\(id) modelIdAfter")
    }

    private func checkNewChat(_ id: String) throws {
        let item = try Self.fixtureCase("newChatCases", id)
        let expect = try #require(item["expect"] as? [String: Any])
        let result = ConversationModelRetirement.newChatModel(
            catalog: try Self.catalog(item["catalog"]),
            userModels: item["userModels"] as? [String] ?? [],
            userModelCanonicalIds: item["userModelCanonicalIds"] as? [String: String] ?? [:],
            preferredModelId: Self.string(item["preferredModelId"]),
            now: try Self.now()
        )
        #expect(result.modelId == Self.string(expect["modelId"]), "RETIRED-\(id) modelId")
        #expect(result.hint?.rawValue == Self.string(expect["hint"]), "RETIRED-\(id) hint")
    }

    @Test func fixtureCaseListIsCovered() throws {
        let fixture = try Self.fixture()
        let ids = ((fixture["conversationCases"] as? [[String: Any]] ?? []) + (fixture["newChatCases"] as? [[String: Any]] ?? []))
            .compactMap { $0["id"] as? String }
        #expect(Set(ids) == Self.coveredIDs, "When the fixture adds or removes cases, update test_RETIRED_<id> in this file")
        #expect((fixture["pendingUntil"] as? [String: Any])?["ios"] == nil, "iOS is wired up, so pendingUntil.ios should be removed")
    }

    private static let coveredIDs: Set<String> = [
        "tombstone_with_successor", "tombstone_without_retired_at", "tombstone_without_successor", "tombstone_successor_not_in_catalog",
        "stored_name_wins", "deprecated_past_shutdown", "deprecated_future_shutdown", "missing_from_catalog",
        "hand_entered_model", "canonical_alias_resolves", "catalog_not_loaded", "active_model",
        "preferred_available", "preferred_retired_falls_to_default",
        "default_not_enabled_falls_to_first_available", "no_preferred_uses_default",
        "alias_dated_default_matches_undated_enabled",
        "alias_undated_default_matches_dated_enabled",
        "alias_canonical_matches_enabled",
        "alias_exact_undated_beats_other_snapshot",
        "alias_case_insensitive",
        "alias_prefix_near_miss_not_matched",
        "alias_compact_mmdd_suffix_not_matched",
        "alias_match_retired_enabled_skipped",
        "alias_match_retired_enabled_with_canonical_skipped",
    ]

    // MARK: - Conversation

    @Test func test_RETIRED_tombstone_with_successor() throws { try checkConversation("tombstone_with_successor") }
    @Test func test_RETIRED_tombstone_without_retired_at() throws { try checkConversation("tombstone_without_retired_at") }
    @Test func test_RETIRED_tombstone_without_successor() throws { try checkConversation("tombstone_without_successor") }
    @Test func test_RETIRED_tombstone_successor_not_in_catalog() throws { try checkConversation("tombstone_successor_not_in_catalog") }
    @Test func test_RETIRED_stored_name_wins() throws { try checkConversation("stored_name_wins") }
    @Test func test_RETIRED_deprecated_past_shutdown() throws { try checkConversation("deprecated_past_shutdown") }
    @Test func test_RETIRED_deprecated_future_shutdown() throws { try checkConversation("deprecated_future_shutdown") }
    @Test func test_RETIRED_missing_from_catalog() throws { try checkConversation("missing_from_catalog") }
    @Test func test_RETIRED_hand_entered_model() throws { try checkConversation("hand_entered_model") }
    @Test func test_RETIRED_canonical_alias_resolves() throws { try checkConversation("canonical_alias_resolves") }
    @Test func test_RETIRED_catalog_not_loaded() throws { try checkConversation("catalog_not_loaded") }
    @Test func test_RETIRED_active_model() throws { try checkConversation("active_model") }

    // MARK: - New chat

    @Test func test_RETIRED_preferred_available() throws { try checkNewChat("preferred_available") }
    @Test func test_RETIRED_preferred_retired_falls_to_default() throws { try checkNewChat("preferred_retired_falls_to_default") }
    @Test func test_RETIRED_default_not_enabled_falls_to_first_available() throws {
        try checkNewChat("default_not_enabled_falls_to_first_available")
    }
    @Test func test_RETIRED_no_preferred_uses_default() throws { try checkNewChat("no_preferred_uses_default") }

    // MARK: - New chat: catalog default <-> enabled id alias matching

    @Test func test_RETIRED_alias_dated_default_matches_undated_enabled() throws { try checkNewChat("alias_dated_default_matches_undated_enabled") }
    @Test func test_RETIRED_alias_undated_default_matches_dated_enabled() throws { try checkNewChat("alias_undated_default_matches_dated_enabled") }
    @Test func test_RETIRED_alias_canonical_matches_enabled() throws { try checkNewChat("alias_canonical_matches_enabled") }
    @Test func test_RETIRED_alias_exact_undated_beats_other_snapshot() throws { try checkNewChat("alias_exact_undated_beats_other_snapshot") }
    @Test func test_RETIRED_alias_case_insensitive() throws { try checkNewChat("alias_case_insensitive") }
    @Test func test_RETIRED_alias_prefix_near_miss_not_matched() throws { try checkNewChat("alias_prefix_near_miss_not_matched") }
    @Test func test_RETIRED_alias_compact_mmdd_suffix_not_matched() throws { try checkNewChat("alias_compact_mmdd_suffix_not_matched") }
    @Test func test_RETIRED_alias_match_retired_enabled_skipped() throws { try checkNewChat("alias_match_retired_enabled_skipped") }
    @Test func test_RETIRED_alias_match_retired_enabled_with_canonical_skipped() throws { try checkNewChat("alias_match_retired_enabled_with_canonical_skipped") }

    // MARK: - Production decode path

    /// A schema 2 index entry carries retiredModels; after MetadataClient's split decoding and merge, the conversation retirement read point gets the tombstones;
    /// the lifecycle of a catalog model is read out through the production parser as state / shutdownAt / routedTo.
    @Test func indexRetiredModelsDecodeThroughMetadataClient() async throws {
        let index: [String: Any] = [
            "version": 1,
            "view": "index",
            "metadataSchema": 2,
            "metadataRevision": 7,
            "providers": [
                "deepseek": [
                    "displayName": "DeepSeek",
                    "defaultModelId": "deepseek-flash",
                    "modelCount": 0,
                    "catalogRevision": "sha256:retired-fixture",
                    "retiredModels": [
                        ["id": "deepseek-chat", "displayName": "DeepSeek Chat", "retiredAt": "2026-07-24T00:00:00Z", "routedTo": "deepseek-flash"],
                        ["id": "deepseek-reasoner", "displayName": "DeepSeek Reasoner", "retiredAt": "2026-07-24T00:00:00Z", "routedTo": NSNull()],
                    ],
                ],
            ],
        ]
        let indexJSON = try #require(String(data: try JSONSerialization.data(withJSONObject: ["code": 0, "data": index]), encoding: .utf8))
        let client = MetadataClient()
        await client.resetForTesting()
        let catalogJSON = #"{"view":"catalog","provider":"deepseek","catalogRevision":"sha256:retired-fixture","models":{"deepseek-flash":{"displayName":"DeepSeek Flash","capabilities":["text"]}}}"#
        try await client.loadSplitForTesting(
            indexJSON: indexJSON,
            indexETag: "index-etag-retired",
            catalogJSONs: ["deepseek": catalogJSON]
        )

        // Through the production read point: the catalog value that the conversation retirement decision reads under one lock.
        let read = client.syncConversationRetirementRead(
            providerKind: .deepseek,
            modelIDs: ["deepseek-chat", "deepseek-reasoner"]
        )
        let catalog = try #require(read.catalog)
        #expect(catalog.defaultModelId == "deepseek-flash")
        #expect(catalog.retiredModels == [
            .init(id: "deepseek-chat", displayName: "DeepSeek Chat", retiredAt: "2026-07-24T00:00:00Z", routedTo: "deepseek-flash"),
            .init(id: "deepseek-reasoner", displayName: "DeepSeek Reasoner", retiredAt: "2026-07-24T00:00:00Z", routedTo: nil),
        ])
        #expect(client.providerDefaultModelID(providerKind: .deepseek) == "deepseek-flash")

        let entryJSON = #"{"displayName":"GPT Legacy","lifecycle":{"state":"deprecated","shutdownAt":"2026-10-01T00:00:00Z","routedTo":"gpt-next"}}"#
        let entry = try JSONDecoder().decode(MetadataClient.ModelMetadataEntry.self, from: Data(entryJSON.utf8))
        #expect(entry.lifecycleState == "deprecated")
        #expect(entry.lifecycleShutdownAt == ConversationModelRetirement.parseDate("2026-10-01T00:00:00Z"))
        #expect(entry.lifecycleRoutedTo == "gpt-next")
        await client.resetForTesting()
    }

    @Test("810 enabled models: unavailableEnabledModelIDs stays within a time bound")
    func unavailableEnabledModelIDsLargeProviderIsBounded() async throws {
        let (client, provider, now) = try await Self.largeProviderFixture()

        var samples: [Duration] = []
        var unavailable: Set<String> = []
        for _ in 0..<7 {
            let started = ContinuousClock.now
            unavailable = ProviderSelectionSnapshot.unavailableEnabledModelIDs(in: provider, metadata: client, now: now)
            samples.append(ContinuousClock.now - started)
        }
        let median = samples.sorted()[samples.count / 2]
        print("[PERF] unavailableEnabledModelIDs 810 models median=\(median) samples=\(samples)")
        // The production decision really ran: the first 100 are shut down + 10 are not in the catalog.
        #expect(unavailable.count == 110)
        #expect(unavailable.contains("m-0"))
        #expect(unavailable.contains("m-99"))
        #expect(unavailable.contains("m-805"))
        #expect(!unavailable.contains("m-100"))
        // It is no longer on the new-chat hot path (only the capability-match tier remains), so the bound is loose to absorb machine jitter.
        #expect(median < .milliseconds(250), "unavailableEnabledModelIDs median \(median) for 810 models exceeds 250 ms")
        await client.resetForTesting()
    }

    @Test("810 enabled models: newChatModel takes the longest path (last used is retired, the catalog default is excluded and the retry is still unavailable, the first 100 are shut down); Debug simulator time < 50 ms")
    func newChatModelLargeProviderStopsAtFirstAvailable() async throws {
        let (client, provider, now) = try await Self.largeProviderFixture()
        // Last used m-0 is past its shutdown date -> skipped; the catalog default m-1 is shut down -> excluded and retried, reaching m-50 whose canonical is also m-1, which is shut down too ->
        // then judge the first available one by one: skip the first 100 shut-down models, stop at m-100, and never judge the other 709.
        let ref = LastUsedModelRef(providerID: provider.id, modelID: "m-0")

        var samples: [Duration] = []
        var chosen: AIModel?
        for _ in 0..<7 {
            let started = ContinuousClock.now
            chosen = ProviderSelectionSnapshot.newChatModel(in: provider, lastUsedModelRef: ref, metadata: client)
            samples.append(ContinuousClock.now - started)
        }
        let median = samples.sorted()[samples.count / 2]
        print("[PERF] newChatModel 810 models median=\(median) samples=\(samples)")
        #expect(chosen?.id == "m-100")
        // The whole-table decision on the same fixture agrees: last used, the catalog default and its alias are all unavailable, and m-100 is the first available.
        let unavailable = ProviderSelectionSnapshot.unavailableEnabledModelIDs(in: provider, metadata: client, now: now)
        #expect(unavailable.isSuperset(of: ["m-0", "m-1", "m-50"]))
        #expect(!unavailable.contains("m-100"))
        #expect(provider.models.filter { !unavailable.contains($0.id) }.first?.id == "m-100")
        // The 16 ms-per-frame criterion targets Release; this is an unoptimized Debug build with a measured median of about 15 ms (typical path 0.08 ms) and about 55 ms for the whole-table decision.
        // The absolute bound of 50 ms absorbs jitter; a regression back to the whole-table decision is caught by a same-machine relative ratio (the lazy path must be under half of the whole table), independent of machine speed.
        #expect(median < .milliseconds(50), "newChatModel median \(median) for 810 models exceeds 50 ms")
        var tableSamples: [Duration] = []
        for _ in 0..<5 {
            let started = ContinuousClock.now
            _ = ProviderSelectionSnapshot.unavailableEnabledModelIDs(in: provider, metadata: client, now: now)
            tableSamples.append(ContinuousClock.now - started)
        }
        let tableMedian = tableSamples.sorted()[tableSamples.count / 2]
        #expect(median * 2 < tableMedian, "newChatModel median \(median) is not below half of the whole-table decision \(tableMedian)")
        await client.resetForTesting()
    }

    /// 800 models in the catalog (the first 100 are deprecated and past their shutdown date) + 10 not in the catalog -> 110 unavailable;
    /// the catalog default m-1 is shut down, and the canonical of m-50 is also m-1 (the catalog default can match a second one, which is shut down as well).
    private static func largeProviderFixture() async throws -> (MetadataClient, Provider, Date) {
        var catalogModels: [String: Any] = [:]
        for i in 0..<800 {
            var entry: [String: Any] = ["displayName": "Model \(i)", "capabilities": ["text"]]
            if i < 100 {
                entry["lifecycle"] = ["state": "deprecated", "shutdownAt": "2026-01-01T00:00:00Z", "routedTo": "m-1"]
            }
            catalogModels["m-\(i)"] = entry
        }
        let index: [String: Any] = [
            "version": 1,
            "view": "index",
            "metadataSchema": 2,
            "metadataRevision": 7,
            "providers": [
                "deepseek": [
                    "displayName": "DeepSeek",
                    "defaultModelId": "m-1",
                    "modelCount": 800,
                    "catalogRevision": "sha256:large-provider",
                ],
            ],
        ]
        let indexJSON = try #require(String(data: try JSONSerialization.data(withJSONObject: ["code": 0, "data": index]), encoding: .utf8))
        let catalog: [String: Any] = [
            "view": "catalog", "provider": "deepseek", "catalogRevision": "sha256:large-provider", "models": catalogModels,
        ]
        let catalogJSON = try #require(String(data: try JSONSerialization.data(withJSONObject: catalog), encoding: .utf8))
        let client = MetadataClient()
        await client.resetForTesting()
        try await client.loadSplitForTesting(
            indexJSON: indexJSON,
            indexETag: "index-etag-large",
            catalogJSONs: ["deepseek": catalogJSON]
        )
        let enabled = (0..<810).map { i -> AIModel in
            var model = TestFactories.makeModel(id: "m-\(i)")
            if i == 50 { model.canonicalModelId = "m-1" }
            return model
        }
        let provider = TestFactories.makeProvider(kind: .deepseek, models: enabled)
        let now = try #require(ConversationModelRetirement.parseDate("2026-10-21T00:00:00Z"))

        return (client, provider, now)
    }
}
