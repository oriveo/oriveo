import Foundation
import Testing
@testable import Oriveo

/// iOS consumption of the shared fixture `capability/cross-end-closure.v1.json`:
/// bundledInputCases (in the bundled-snapshot state the snapshot verdict is projected without downgrading),
/// newChatDefaultCases (the four-tier fallback for a new chat), newChatAcrossConnectionsCases (fallback across
/// connections), relayVideoEnvelopeCases (an envelope does not decide video, and an absent envelope is not a
/// rejection). dateTimeCases are consumed in OriveoProviderKit `MetadataPayloadSchemaValidatorTests`. Every case
/// is one CLOSURE_<id> test, and the assertions come from the production entry points
/// `CapabilityEvidenceProductionAdapter.capabilityProjection` / `ProviderSelectionSnapshot.activeModel`.
@Suite("CLOSURE cross-end closure contract", .serialized, .sharedProcessState)
struct CrossEndClosureContractTests {
    private static let metadataETag = "cross-end-closure"
    private static let inputKeys: Set<String> = Set(CapabilityEvidenceFacade.inputCapabilityKeys)

    // MARK: - Fixture

    private static func fixture() throws -> [String: Any] {
        let data = try Data(contentsOf: sharedFixtureURL("capability/cross-end-closure.v1.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func cases(_ section: String) throws -> [[String: Any]] {
        let root = try #require(try fixture()[section] as? [String: Any], "\(section)")
        #expect((root["appliesTo"] as? [String])?.contains("ios") == true, "\(section) applies to iOS")
        return try #require(root["cases"] as? [[String: Any]], "\(section)")
    }

    private static func fixtureCase(_ section: String, _ id: String) throws -> [String: Any] {
        try #require(try cases(section).first { $0["id"] as? String == id }, "CLOSURE-\(id)")
    }

    private static func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    /// Compares the fixture expect with the production projection field by field (disabledReason / outbound / hint use the contract codes).
    private static func expectProjection(
        _ input: CapabilityEvidenceFacade.InputCapabilityProjection, _ expect: [String: Any], id: String
    ) throws {
        #expect(input.visible == (try #require(expect["visible"] as? Bool)), "CLOSURE-\(id) visible")
        #expect(input.editable == (try #require(expect["editable"] as? Bool)), "CLOSURE-\(id) editable")
        #expect(input.outbound.rawValue == expect["outbound"] as? String, "CLOSURE-\(id) outbound")
        #expect(input.hint?.rawValue == expect["hint"] as? String, "CLOSURE-\(id) hint")
        #expect(input.disabledReason?.rawValue == expect["disabledReason"] as? String, "CLOSURE-\(id) disabledReason")
    }

    // MARK: - bundledInputCases

    /// The bundled snapshot and an online response decode into the same catalog table (`MetadataClient` falls back
    /// to the bundled snapshot on a cold start through the same `replaceTable`), so the projection side has no
    /// "bundled snapshot" branch; here the snapshot verdict is written into the production catalog table as a
    /// catalog with metadataRevision 0 and then goes through the official projection.
    private func checkBundled(_ id: String) async throws {
        let item = try Self.fixtureCase("bundledInputCases", id)
        #expect(item["catalogSource"] as? String == "bundled", "CLOSURE-\(id)")
        #expect(item["connection"] as? String == "official", "CLOSURE-\(id)")
        #expect(item["endImplements"] as? Bool == true, "CLOSURE-\(id)")
        let key = try #require(item["key"] as? String)
        let verdict = try #require(item["verdict"] as? [String: Any])
        let payload: [String: Any] = [
            "version": 1,
            "metadataRevision": 0,
            "capabilityRuntime": [
                "schemaVersion": RequestPreferenceResolver.runtimeSchemaVersion,
                "revision": "sha256:cross-end-closure", "generatedAt": "2026-10-20T00:00:00Z",
                "recipes": [:], "controlDefinitions": [:], "sourceIndex": [:],
            ] as [String: Any],
            "providers": ["qwen": [
                "resolveMap": ["closure-model": "closure-model"],
                "models": ["closure-model": [
                    "canonicalModelId": "closure-model",
                    "transport": "openai_chat",
                    "capabilities": ["text", "image", "file", "video"],
                    "profiles": [:],
                    "capabilityControls": [key: verdict],
                ] as [String: Any]],
            ] as [String: Any]],
        ]
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try Self.json(payload), metadataETag: Self.metadataETag)
        let persisted = TestFactories.makeModel(id: "closure-model", capabilities: [.text, .image])
        let model = MetadataClient.shared.syncCurrentCapabilityEvidenceModel(persisted, providerKind: .qwen)
        let provider = TestFactories.makeProvider(id: UUID(), kind: .qwen, models: [model])
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: "cross-end-closure",
            hasExplicitValue: false, metadataETag: Self.metadataETag
        )
        let projection = CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: provider, model: model, identity: identity, keys: Self.inputKeys
        )
        let input = try #require(projection.inputProjection(for: key), "CLOSURE-\(id)")
        try Self.expectProjection(input, try #require(item["expect"] as? [String: Any]), id: id)
        await MetadataClient.shared.resetForTesting()
    }

    @Test func test_CLOSURE_bundled_unavailable_model_absent_stays_disabled() async throws {
        try await checkBundled("bundled_unavailable_model_absent_stays_disabled")
    }

    @Test func test_CLOSURE_bundled_kill_switch_stays_disabled() async throws {
        try await checkBundled("bundled_kill_switch_stays_disabled")
    }

    @Test func test_CLOSURE_bundled_auto_available_visible() async throws {
        try await checkBundled("bundled_auto_available_visible")
    }

    @Test func test_CLOSURE_bundled_unknown_hints_once() async throws {
        try await checkBundled("bundled_unknown_hints_once")
    }

    // MARK: - newChatDefaultCases

    /// Each case installs its catalog in its own MetadataClient instance (the shared one is untouched) and
    /// takes the new-chat model through production `ProviderSelectionSnapshot.activeModel`; the hint uses the
    /// same criterion as production `newChatRetiredFallback` (`lastUsedModelUnavailable` after dropping
    /// connections that lack credentials).
    private func checkNewChat(_ id: String) async throws {
        let item = try Self.fixtureCase("newChatDefaultCases", id)
        let catalog = try #require(item["catalog"] as? [String: Any])
        let catalogModels = try #require(catalog["models"] as? [[String: Any]])
        let index: [String: Any] = [
            "version": 1, "view": "index", "metadataSchema": 2, "metadataRevision": 7,
            "providers": ["deepseek": [
                "displayName": "DeepSeek",
                "defaultModelId": catalog["defaultModelId"] ?? NSNull(),
                "modelCount": catalogModels.count,
                "catalogRevision": "sha256:cross-end-closure",
                "retiredModels": catalog["retiredModels"] ?? [],
            ] as [String: Any]],
        ]
        var models: [String: Any] = [:]
        for model in catalogModels {
            var entry: [String: Any] = ["displayName": model["displayName"] ?? "", "capabilities": ["text"]]
            // An optional lifecycle (deprecated / shutdownAt / routedTo) goes into the catalog entry as is, and the production parser decides shutdown.
            if let lifecycle = model["lifecycle"] { entry["lifecycle"] = lifecycle }
            models[try #require(model["id"] as? String)] = entry
        }
        let catalogPayload: [String: Any] = [
            "view": "catalog", "provider": "deepseek", "catalogRevision": "sha256:cross-end-closure",
            "models": models, "resolveMap": catalog["resolveMap"] ?? [:],
        ]
        let client = MetadataClient()
        await client.resetForTesting()
        try await client.loadSplitForTesting(
            indexJSON: try Self.json(["code": 0, "data": index]),
            indexETag: "index-etag-closure",
            catalogJSONs: ["deepseek": try Self.json(catalogPayload)]
        )

        let connectionDefault = item["connectionDefaultModelId"] as? String
        // Optional userModelCanonicalIds: enabled id -> canonical, which goes into AIModel.canonicalModelId.
        let canonicalIds = item["userModelCanonicalIds"] as? [String: String] ?? [:]
        let userModels = try #require(item["userModels"] as? [String]).map {
            TestFactories.makeModel(id: $0, isDefault: $0 == connectionDefault, canonicalModelId: canonicalIds[$0])
        }
        let provider = TestFactories.makeProvider(id: UUID(), kind: .deepseek, models: userModels)
        let ref = (item["lastUsedModelId"] as? String).map { LastUsedModelRef(providerID: provider.id, modelID: $0) }

        let expect = try #require(item["expect"] as? [String: Any])
        let chosen = ProviderSelectionSnapshot.activeModel(in: [provider], lastUsedModelRef: ref, metadata: client)
        #expect(chosen?.model.id == expect["modelId"] as? String, "CLOSURE-\(id) modelId")
        // The hint is asserted at the resolution layer with the same criterion as newChatRetiredFallback: connections
        // missing credentials are dropped first, then the last used model is judged. It is also asserted when the
        // chain is empty (modelId null); whether the UI shows it is not the resolution layer's business, so a
        // fallback target is not required.
        let usable = [provider].filter { ProviderSelectionSnapshot.isUsableForNewChat($0) }
        let unadopted = ProviderSelectionSnapshot.lastUsedModelUnavailable(in: usable, lastUsedModelRef: ref, metadata: client)
        #expect((unadopted ? "last_used_retired" : nil) == expect["hint"] as? String, "CLOSURE-\(id) hint")
        await client.resetForTesting()
    }

    @Test func test_CLOSURE_last_used_available_beats_connection_default() async throws {
        try await checkNewChat("last_used_available_beats_connection_default")
    }

    @Test func test_CLOSURE_connection_default_retired_falls_to_catalog_default() async throws {
        try await checkNewChat("connection_default_retired_falls_to_catalog_default")
    }

    @Test func test_CLOSURE_connection_default_not_enabled_skipped() async throws {
        try await checkNewChat("connection_default_not_enabled_skipped")
    }

    @Test func test_CLOSURE_all_enabled_retired_returns_none() async throws {
        try await checkNewChat("all_enabled_retired_returns_none")
    }

    @Test func test_CLOSURE_last_used_retired_skips_connection_default() async throws {
        try await checkNewChat("last_used_retired_skips_connection_default")
    }

    @Test func test_CLOSURE_no_last_used_ignores_connection_default() async throws {
        try await checkNewChat("no_last_used_ignores_connection_default")
    }

    @Test func test_CLOSURE_enabled_model_missing_from_catalog_skipped() async throws {
        try await checkNewChat("enabled_model_missing_from_catalog_skipped")
    }

    @Test func test_CLOSURE_last_used_retired_and_all_enabled_retired_returns_none() async throws {
        try await checkNewChat("last_used_retired_and_all_enabled_retired_returns_none")
    }

    @Test func test_CLOSURE_last_used_disabled_by_user_no_hint() async throws {
        try await checkNewChat("last_used_disabled_by_user_no_hint")
    }

    @Test func test_CLOSURE_last_used_disabled_and_retired_hints() async throws {
        try await checkNewChat("last_used_disabled_and_retired_hints")
    }

    @Test func test_CLOSURE_last_used_missing_with_shut_down_canonical_skipped() async throws {
        try await checkNewChat("last_used_missing_with_shut_down_canonical_skipped")
    }

    // MARK: - newChatAcrossConnectionsCases

    /// A fixture connection id with hyphens removed is the lowercased raw ProviderKind value (openai = .openAI).
    private static func fixtureKind(_ raw: String) -> ProviderKind? {
        let key = raw.replacingOccurrences(of: "-", with: "")
        return ProviderKind.allCases.first { $0.rawValue.lowercased() == key }
    }

    /// See `fixtureKind` for the fixture connection ids; the metadata key uses the raw value. The catalogs of all
    /// connections go into one independent MetadataClient, and the new-chat model is taken across connections
    /// through production `ProviderSelectionSnapshot.activeModel`.
    private func checkAcross(_ id: String) async throws {
        let item = try Self.fixtureCase("newChatAcrossConnectionsCases", id)
        let connections = try #require(item["connections"] as? [[String: Any]])
        var indexProviders: [String: Any] = [:]
        var catalogJSONs: [String: String] = [:]
        var providers: [Provider] = []
        for connection in connections {
            let kindRaw = try #require(connection["id"] as? String)
            let kind = try #require(Self.fixtureKind(kindRaw), "CLOSURE-\(id) \(kindRaw)")
            let userModels = try #require(connection["userModels"] as? [String]).map { TestFactories.makeModel(id: $0) }
            // missingCredential = no key on this device; issue = an error status while the credential is present.
            providers.append(TestFactories.makeProvider(
                id: UUID(),
                kind: kind,
                status: connection["issue"] as? Bool == true ? .issue("closure fixture") : .connected,
                models: userModels,
                apiKey: connection["missingCredential"] as? Bool == true ? "" : "sk-test-key-12345"
            ))
            // A null catalog means a connection without a catalog, which does not go into metadata.
            guard let catalog = connection["catalog"] as? [String: Any] else { continue }
            let catalogModels = try #require(catalog["models"] as? [[String: Any]])
            indexProviders[kind.rawValue] = [
                "displayName": kindRaw,
                "defaultModelId": catalog["defaultModelId"] ?? NSNull(),
                "modelCount": catalogModels.count,
                "catalogRevision": "sha256:cross-end-closure",
                "retiredModels": catalog["retiredModels"] ?? [],
            ] as [String: Any]
            var models: [String: Any] = [:]
            for model in catalogModels {
                models[try #require(model["id"] as? String)] = ["displayName": model["displayName"] ?? "", "capabilities": ["text"]]
            }
            catalogJSONs[kind.rawValue] = try Self.json([
                "view": "catalog", "provider": kind.rawValue, "catalogRevision": "sha256:cross-end-closure",
                "models": models, "resolveMap": catalog["resolveMap"] ?? [:],
            ] as [String: Any])
        }
        let index: [String: Any] = [
            "version": 1, "view": "index", "metadataSchema": 2, "metadataRevision": 7, "providers": indexProviders,
        ]
        let client = MetadataClient()
        await client.resetForTesting()
        try await client.loadSplitForTesting(
            indexJSON: try Self.json(["code": 0, "data": index]),
            indexETag: "index-etag-closure-across",
            catalogJSONs: catalogJSONs
        )

        let ref: LastUsedModelRef? = try (item["lastUsedRef"] as? [String: Any]).map { raw in
            let kindRaw = try #require(raw["connectionId"] as? String)
            let kind = Self.fixtureKind(kindRaw)
            let provider = try #require(providers.first { $0.kind == kind }, "CLOSURE-\(id) lastUsedRef")
            return LastUsedModelRef(providerID: provider.id, modelID: try #require(raw["modelId"] as? String))
        }
        let expect = try #require(item["expect"] as? [String: Any])
        let chosen = ProviderSelectionSnapshot.activeModel(
            in: providers, lastUsedModelRef: ref, metadata: client
        )
        #expect(chosen?.provider.kind == (expect["connectionId"] as? String).flatMap(Self.fixtureKind), "CLOSURE-\(id) connectionId")
        #expect(chosen?.model.id == expect["modelId"] as? String, "CLOSURE-\(id) modelId")
        // The hint goes through the same production entry as the chat page (NewChatRetiredFallbackHint.resolve calls newChatRetiredFallback).
        let fallback = ProviderSelectionSnapshot.newChatRetiredFallback(
            in: providers, lastUsedModelRef: ref, metadata: client
        )
        #expect((fallback != nil ? "last_used_retired" : nil) == expect["hint"] as? String, "CLOSURE-\(id) hint")
        if let fallback {
            #expect(fallback.provider.id == chosen?.provider.id, "CLOSURE-\(id) hint fallback connection")
            #expect(fallback.model.id == chosen?.model.id, "CLOSURE-\(id) hint fallback model")
        }
        await client.resetForTesting()
    }

    @Test func test_CLOSURE_first_connection_all_retired_moves_to_next() async throws {
        try await checkAcross("first_connection_all_retired_moves_to_next")
    }

    @Test func test_CLOSURE_last_used_on_second_connection_wins() async throws {
        try await checkAcross("last_used_on_second_connection_wins")
    }

    @Test func test_CLOSURE_last_used_retired_on_dead_connection_moves_on() async throws {
        try await checkAcross("last_used_retired_on_dead_connection_moves_on")
    }

    @Test func test_CLOSURE_no_connection_usable_returns_none() async throws {
        try await checkAcross("no_connection_usable_returns_none")
    }

    @Test func test_CLOSURE_last_used_retired_falls_back_within_its_connection_first() async throws {
        try await checkAcross("last_used_retired_falls_back_within_its_connection_first")
    }

    @Test func test_CLOSURE_last_used_on_connection_missing_credential_skipped_no_hint() async throws {
        try await checkAcross("last_used_on_connection_missing_credential_skipped_no_hint")
    }

    @Test func test_CLOSURE_errored_first_connection_keeps_list_order() async throws {
        try await checkAcross("errored_first_connection_keeps_list_order")
    }

    // MARK: - relayVideoEnvelopeCases

    private static func relayTransport(_ firstSend: String) throws -> RelayTransport {
        switch firstSend {
        case "chat": return .openaiChatCompletions
        case "responses": return .openaiResponses
        case "messages": return .anthropicMessages
        default: throw CocoaError(.featureUnsupported)
        }
    }

    /// Based on relay/metadata-fixture.json, swaps the envelope of this case's first-send protocol for the fixture value (null = remove that envelope).
    private func checkRelay(_ id: String) async throws {
        let item = try Self.fixtureCase("relayVideoEnvelopeCases", id)
        #expect(item["connection"] as? String == "relay", "CLOSURE-\(id)")
        #expect(item["connectionEvidence"] is NSNull, "CLOSURE-\(id) covers only the no-connection-evidence case")
        let transport = try Self.relayTransport(try #require(item["firstSend"] as? String))
        let key = try #require(item["key"] as? String)

        var root = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: sharedFixtureURL("relay/metadata-fixture.json"))) as? [String: Any]
        )
        var runtime = try #require(root["relayRuntimeConfig"] as? [String: Any])
        var envelopes = try #require(runtime["transportEnvelopes"] as? [String: Any])
        let envelopeKey = RelayRuntimeSupport.envelopeKey(transport: transport)
        if let envelope = item["envelope"] as? [String: Any] {
            var merged = try #require(envelopes[envelopeKey] as? [String: Any], "\(envelopeKey)")
            merged.merge(envelope) { _, fixture in fixture }
            envelopes[envelopeKey] = merged
        } else {
            envelopes[envelopeKey] = nil
        }
        runtime["transportEnvelopes"] = envelopes
        root["relayRuntimeConfig"] = runtime
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try Self.json(root))

        let model = AIModel(
            id: "closure-relay-model", name: "closure-relay-model", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: ""
        )
        let provider = Provider(
            id: UUID(), kind: .relay, status: .connected, models: [model], catalogModels: [],
            apiKey: "key", apiKeyPreview: "...key", baseURLText: "https://relay.test/v1",
            relayRequested: RelayRequestedConfig(transport: transport)
        )
        #expect(RelayFirstSendTransport.current(provider: provider, model: model) == transport, "CLOSURE-\(id) first-send protocol")
        let identity = CapabilityEvidenceProductionAdapter.uiDispatchIdentity(
            provider: provider, model: model, partitionID: "cross-end-closure"
        )
        let projection = CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: provider, model: model, identity: identity, keys: Self.inputKeys
        )
        let input = try #require(projection.inputProjection(for: key), "CLOSURE-\(id)")
        try Self.expectProjection(input, try #require(item["expect"] as? [String: Any]), id: id)
        await MetadataClient.shared.resetForTesting()
    }

    @Test func test_CLOSURE_relay_video_chat_envelope_has_no_video_bit() async throws {
        try await checkRelay("relay_video_chat_envelope_has_no_video_bit")
    }

    @Test func test_CLOSURE_relay_video_messages_not_implemented() async throws {
        try await checkRelay("relay_video_messages_not_implemented")
    }

    @Test func test_CLOSURE_relay_video_envelope_missing_not_rejection() async throws {
        try await checkRelay("relay_video_envelope_missing_not_rejection")
    }

    @Test func test_CLOSURE_relay_vision_envelope_missing_not_rejection() async throws {
        try await checkRelay("relay_vision_envelope_missing_not_rejection")
    }

    // MARK: - Coverage

    /// The full set comes from the current fixture (ids are not hand-copied): every case of every section that applies to iOS has a test_CLOSURE_<id> in this file.
    @Test("Every CLOSURE case that applies to iOS has a matching test")
    func closureCasesCovered() throws {
        let source = try String(contentsOfFile: #filePath, encoding: .utf8)
        for section in ["bundledInputCases", "newChatDefaultCases", "newChatAcrossConnectionsCases", "relayVideoEnvelopeCases"] {
            for id in try Self.cases(section).compactMap({ $0["id"] as? String }) {
                #expect(source.contains("func test_CLOSURE_\(id)("), "\(section) CLOSURE-\(id) has no test")
            }
        }
    }
}
