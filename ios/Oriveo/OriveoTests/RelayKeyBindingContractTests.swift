import Foundation
import Testing
@testable import Oriveo

/// Cross-platform contract for relay multi-key storage and binding (RK-2).
///
/// Fixture `shared/test-fixtures/relay/key-binding.v1.json` bindCases / opsCases / readCases / legacyCases,
/// plus the "local only" entries of `connectionFields` in `portable-config.v1.json` (KEY-SYNC). Models always come in through the production decoder;
/// KEY-LEGACY runs production decoding + production enabling + production catalog merge, and KEY-SYNC asserts the actual output of the production Firestore write, backup export and local storage.
@Suite("Relay multi-key · storage and binding", .serialized)
@MainActor
struct RelayKeyBindingContractTests {

    // MARK: - Fixtures

    private static func fixture(_ name: String) throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/test-fixtures/relay/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func section(_ name: String) throws -> [[String: Any]] {
        let root = try fixture("key-binding.v1.json")
        let section = try #require(root[name] as? [String: Any])
        return try #require(section["cases"] as? [[String: Any]])
    }

    private static func caseItem(_ section: String, _ caseId: String) throws -> [String: Any] {
        try #require(try Self.section(section).first { $0["caseId"] as? String == caseId }, "fixture is missing \(section)/\(caseId)")
    }

    /// Baseline model JSON produced by the production encoder, overlaid with fixture fields, then fed through the production decoder.
    private static func model(_ raw: [String: Any]) throws -> AIModel {
        let id = try #require(raw["id"] as? String)
        var json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(TestFactories.makeModel(id: id))) as? [String: Any]
        )
        for (key, value) in raw { json[key] = value }
        return try JSONDecoder().decode(AIModel.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private static func models(_ raw: Any?) throws -> [AIModel] {
        try (raw as? [[String: Any]] ?? []).map(model)
    }

    private static func relayKeys(_ raw: Any?) throws -> [RelayKey]? {
        guard let raw else { return nil }
        return try JSONDecoder().decode([RelayKey].self, from: JSONSerialization.data(withJSONObject: raw))
    }

    /// Provider for opsCases / readCases: {apiKey, relayKeys?, models, catalog}.
    private static func provider(_ raw: Any?) throws -> Provider {
        let object = try #require(raw as? [String: Any])
        var provider = TestFactories.makeProvider(
            kind: .relay,
            models: try models(object["models"]),
            catalogModels: try models(object["catalog"]),
            apiKey: try #require(object["apiKey"] as? String),
            baseURLText: "https://relay.example.com/v1"
        )
        provider.relayKeys = try relayKeys(object["relayKeys"])
        return provider
    }

    private static func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)
    }

    /// Takes only the keys the fixture compares from the production encoder output.
    private static func projected(_ model: AIModel, keys: [String]) throws -> [String: Any] {
        let encoded = try #require(try json(model) as? [String: Any])
        var out: [String: Any] = [:]
        for key in keys { out[key] = encoded[key] }
        return out
    }

    private static func projectedProvider(_ provider: Provider) throws -> [String: Any] {
        var out: [String: Any] = ["apiKey": provider.apiKey]
        if let keys = provider.relayKeys { out["relayKeys"] = try json(keys) }
        out["models"] = try provider.models.map {
            try projected($0, keys: ["id", "relayKeyID", "relayDeniedKeyID", "relayTransport", "relayTransportSource"])
        }
        out["catalog"] = try provider.catalogModels.map { try projected($0, keys: ["id", "relayListedByKeyIDs"]) }
        return out
    }

    private static func same(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return (lhs as AnyObject).isEqual(rhs as AnyObject)
        default: return false
        }
    }

    private static let modelKeyFields = ["relayKeyID", "relayListedByKeyIDs", "relayDeniedKeyID"]

    /// The Provider JSON from the production encoder has no relayKeys, and models and catalog have no key-binding fields at all.
    private static func expectNoKeyFields(_ provider: Provider) throws {
        let encoded = try #require(try json(provider) as? [String: Any])
        #expect(encoded["relayKeys"] == nil)
        for list in ["models", "catalogModels"] {
            for entry in encoded[list] as? [[String: Any]] ?? [] {
                for field in modelKeyFields { #expect(entry[field] == nil, "\(list) \(entry["id"] ?? "") wrote \(field)") }
            }
        }
    }

    // MARK: - KEY-BIND

    private func runBind(_ caseId: String) throws {
        let item = try Self.caseItem("bindCases", caseId)
        let families = try #require(item["families"] as? [String: Any])
        let result = RelayKeyBinding.bind(
            keyIDs: try #require(item["keys"] as? [String]),
            catalog: try Self.models(item["catalog"]),
            enabled: try Self.models(item["enabled"]),
            targetModelID: try #require(item["target"] as? String),
            family: { families[$0] as? String }
        )
        #expect(result == item["expect"] as? String)
    }

    @Test("KEY-BIND-single_key_writes_nothing") func bindSingleKey() throws { try runBind("single_key_writes_nothing") }
    @Test("KEY-BIND-only_one_key_lists_target") func bindOnlyOne() throws { try runBind("only_one_key_lists_target") }
    @Test("KEY-BIND-several_keys_follow_enabled_same_family") func bindFollowFamily() throws { try runBind("several_keys_follow_enabled_same_family") }
    @Test("KEY-BIND-several_keys_no_family_enabled_first_in_key_order") func bindKeyOrder() throws { try runBind("several_keys_no_family_enabled_first_in_key_order") }
    @Test("KEY-BIND-family_key_not_listing_target_is_ignored") func bindFamilyNotListing() throws { try runBind("family_key_not_listing_target_is_ignored") }
    @Test("KEY-BIND-other_family_enabled_is_ignored") func bindOtherFamily() throws { try runBind("other_family_enabled_is_ignored") }
    @Test("KEY-BIND-manual_id_follows_same_family") func bindManualFamily() throws { try runBind("manual_id_follows_same_family") }
    @Test("KEY-BIND-manual_id_no_family_uses_primary") func bindManualPrimary() throws { try runBind("manual_id_no_family_uses_primary") }
    @Test("KEY-BIND-enabled_without_key_id_counts_as_primary") func bindEnabledNoKey() throws { try runBind("enabled_without_key_id_counts_as_primary") }
    @Test("KEY-BIND-enabled_dangling_key_id_counts_as_primary") func bindEnabledDangling() throws { try runBind("enabled_dangling_key_id_counts_as_primary") }
    @Test("KEY-BIND-unknown_target_family_never_matches") func bindUnknownFamily() throws { try runBind("unknown_target_family_never_matches") }
    @Test("KEY-BIND-legacy_catalog_entry_counts_as_primary_listing") func bindLegacyCatalog() throws { try runBind("legacy_catalog_entry_counts_as_primary_listing") }

    // MARK: - KEY-OPS

    private static func operation(_ raw: Any?) throws -> RelayKeyBinding.Operation {
        let op = try #require(raw as? [String: Any])
        let id = op["id"] as? String ?? ""
        switch op["type"] as? String {
        case "add": return .add(id: id, name: op["name"] as? String, apiKey: try #require(op["apiKey"] as? String))
        case "rename": return .rename(id: id, name: op["name"] as? String)
        case "replaceSecret": return .replaceSecret(id: id, apiKey: try #require(op["apiKey"] as? String))
        case "move": return .move(id: id, toIndex: try #require(op["toIndex"] as? Int))
        case "delete": return .delete(id: id)
        case "rebind":
            return .rebind(modelID: try #require(op["modelID"] as? String), keyID: try #require(op["keyID"] as? String))
        default: throw CocoaError(.coderInvalidValue)
        }
    }

    private func runOps(_ caseId: String) throws {
        let item = try Self.caseItem("opsCases", caseId)
        let result = RelayKeyBinding.apply(try Self.operation(item["op"]), to: try Self.provider(item["provider"]))
        if item["expect"] as? String == "refused" {
            #expect(result == nil)
            return
        }
        let provider = try #require(result, "operation was rejected")
        let expect = try #require(item["expect"] as? [String: Any])
        let actual = try Self.projectedProvider(provider)
        for key in ["apiKey", "relayKeys", "models", "catalog"] {
            #expect(Self.same(actual[key], expect[key]), "\(key): \(String(describing: actual[key])) ≠ \(String(describing: expect[key]))")
        }
        // Invariant: the primary key entry is stored empty and the primary key value lives in provider.apiKey.
        if let first = provider.relayKeys?.first { #expect(first.apiKey.isEmpty) }
    }

    @Test("KEY-OPS-add_key_materializes_list_and_pins_models") func opsAdd() throws { try runOps("add_key_materializes_list_and_pins_models") }
    @Test("KEY-OPS-rename_key") func opsRename() throws { try runOps("rename_key") }
    @Test("KEY-OPS-replace_secret_clears_status_and_denial_keeps_catalog") func opsReplace() throws { try runOps("replace_secret_clears_status_and_denial_keeps_catalog") }
    @Test("KEY-OPS-replace_primary_secret_writes_api_key") func opsReplacePrimary() throws { try runOps("replace_primary_secret_writes_api_key") }
    @Test("KEY-OPS-reorder_moves_primary_secret") func opsReorder() throws { try runOps("reorder_moves_primary_secret") }
    @Test("KEY-OPS-delete_key_rebinds_to_primary_and_prunes_catalog") func opsDelete() throws { try runOps("delete_key_rebinds_to_primary_and_prunes_catalog") }
    @Test("KEY-OPS-delete_primary_promotes_next") func opsDeletePrimary() throws { try runOps("delete_primary_promotes_next") }
    @Test("KEY-OPS-delete_last_key_is_refused") func opsDeleteLast() throws { try runOps("delete_last_key_is_refused") }
    @Test("KEY-OPS-rebind_clears_denial_and_reachable_transport") func opsRebind() throws { try runOps("rebind_clears_denial_and_reachable_transport") }
    @Test("KEY-OPS-rebind_keeps_user_transport") func opsRebindUser() throws { try runOps("rebind_keeps_user_transport") }
    @Test("KEY-OPS-add_empty_id_is_refused") func opsRefused1() throws { try runOps("add_empty_id_is_refused") }
    @Test("KEY-OPS-add_duplicate_id_is_refused") func opsRefused2() throws { try runOps("add_duplicate_id_is_refused") }
    @Test("KEY-OPS-rename_unknown_id_is_refused") func opsRefused3() throws { try runOps("rename_unknown_id_is_refused") }
    @Test("KEY-OPS-replace_unknown_id_is_refused") func opsRefused4() throws { try runOps("replace_unknown_id_is_refused") }
    @Test("KEY-OPS-delete_unknown_id_is_refused") func opsRefused5() throws { try runOps("delete_unknown_id_is_refused") }
    @Test("KEY-OPS-move_out_of_range_is_refused") func opsRefused6() throws { try runOps("move_out_of_range_is_refused") }
    @Test("KEY-OPS-rebind_unknown_key_is_refused") func opsRefused7() throws { try runOps("rebind_unknown_key_is_refused") }
    @Test("KEY-OPS-rebind_model_not_enabled_is_refused") func opsRefused8() throws { try runOps("rebind_model_not_enabled_is_refused") }
    @Test("KEY-OPS-implicit_rename_is_refused") func opsRefused9() throws { try runOps("implicit_rename_is_refused") }
    @Test("KEY-OPS-implicit_move_is_refused") func opsRefused10() throws { try runOps("implicit_move_is_refused") }
    @Test("KEY-OPS-implicit_rebind_is_refused") func opsRefused11() throws { try runOps("implicit_rebind_is_refused") }
    @Test("KEY-OPS-add_to_single_entry_list_keeps_primary_status") func opsAddSingleEntry() throws { try runOps("add_to_single_entry_list_keeps_primary_status") }
    @Test("KEY-OPS-replace_secret_single_entry_list_clears_status") func opsReplaceSingleEntry() throws { try runOps("replace_secret_single_entry_list_clears_status") }

    // MARK: - KEY-READ

    private func runRead(_ caseId: String) throws {
        let item = try Self.caseItem("readCases", caseId)
        let provider = try Self.provider(item["provider"])
        let expect = try #require(item["expect"] as? [String: Any])
        #expect(RelayKeyBinding.showsKeyUI(provider) == expect["showsKeyUI"] as? Bool)

        let rows = RelayKeyBinding.rows(provider)
        let expectedRows = try #require(expect["rows"] as? [[String: Any]])
        #expect(rows.count == expectedRows.count)
        for (row, wanted) in zip(rows, expectedRows) {
            #expect(row.id == wanted["id"] as? String)
            #expect(row.name == wanted["name"] as? String)
            #expect(row.isPrimary == wanted["isPrimary"] as? Bool)
            #expect(row.status?.rawValue == wanted["status"] as? String)
            #expect(row.catalogCount == wanted["catalogCount"] as? Int)
            #expect(row.enabledCount == wanted["enabledCount"] as? Int)
        }

        let expectedModels = try #require(expect["models"] as? [String: [String: Any]])
        for (modelID, wanted) in expectedModels {
            let state = try #require(RelayKeyBinding.modelState(provider, modelID: modelID))
            #expect(state.boundKeyID == wanted["boundKeyID"] as? String)
            #expect(state.alternateKeyIDs == wanted["alternateKeyIDs"] as? [String])
            #expect(state.deniedOnCurrentKey == wanted["deniedOnCurrentKey"] as? Bool)
        }
    }

    @Test("KEY-READ-legacy_single_key") func readLegacy() throws { try runRead("legacy_single_key") }
    @Test("KEY-READ-two_keys_with_denial") func readTwoKeys() throws { try runRead("two_keys_with_denial") }
    @Test("KEY-READ-single_entry_list_with_status") func readSingleEntry() throws { try runRead("single_entry_list_with_status") }

    // MARK: - KEY-LEGACY (production decoding + production enabling + production catalog merge)

    /// Legacy snapshot: Provider JSON from the production encoder (without any RK-2 fields) plus the plaintext apiKey of the old snapshot, then fed through the production decoder.
    private static func decodeStored(_ raw: Any?) throws -> Provider {
        let stored = try provider(raw)
        var json = try #require(try json(stored) as? [String: Any])
        json["apiKey"] = stored.apiKey
        return try JSONDecoder().decode(Provider.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private static func makeState() -> AppState {
        let state = AppState(sessionUID: "relay-key-binding-tests-\(UUID().uuidString)")
        state.providers = []
        state.conversations = []
        retainedStates.append(state)
        return state
    }

    private static var retainedStates: [AppState] = []

    @Test("KEY-LEGACY-decode_has_one_implicit_key")
    func legacyDecode() throws {
        let item = try Self.caseItem("legacyCases", "decode_has_one_implicit_key")
        let provider = try Self.decodeStored(item["stored"])
        let expect = try #require(item["expect"] as? [String: Any])
        #expect(provider.relayKeys == nil)
        #expect(RelayKeyBinding.keyIDs(provider) == expect["keyIDs"] as? [String])
        let resolve = try #require(expect["resolve"] as? [String: String])
        for (modelKey, secret) in resolve {
            let modelID: String? = modelKey == "null" ? nil : modelKey
            #expect(ProviderCredentialResolver.apiKey(provider: provider, modelID: modelID) == secret)
        }
    }

    @Test("KEY-LEGACY-enable_writes_no_key_id")
    func legacyEnable() async throws {
        await MetadataClient.shared.resetForTesting()
        let item = try Self.caseItem("legacyCases", "enable_writes_no_key_id")
        let state = Self.makeState()
        let provider = try Self.decodeStored(item["stored"])
        state.providers = [provider]
        let target = try #require(item["enable"] as? String)
        #expect(state.providerManager.enableModel(modelID: target, for: provider.id) != .notFound)
        let saved = try #require(state.providers.first { $0.id == provider.id })
        #expect(saved.models.contains { $0.id == target })
        try Self.expectNoKeyFields(saved)
    }

    /// Runs the legacy refresh cases through the production `refreshRelayCatalog` (fake upstream): a single-key catalog refresh writes only the primary key status (one list entry) and no model key fields.
    private func runLegacyRefresh(_ caseId: String) async throws {
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        await MetadataClient.shared.resetForTesting()
        let item = try Self.caseItem("legacyCases", caseId)
        let refresh = try #require(item["refresh"] as? [String: Any])
        let reply: (Int, String)
        if let ids = refresh["ok"] as? [String] {
            let data = ids.map { #"{"id":"\#($0)","object":"model"}"# }.joined(separator: ",")
            reply = (200, #"{"object":"list","data":[\#(data)]}"#)
        } else {
            reply = (try #require(refresh["status"] as? Int), try #require(refresh["body"] as? String))
        }
        RelayKeyLegacyFakeServer.install { request in
            request.url?.path == "/v1/models" ? reply : (404, "")
        }
        let state = AppState(
            seedDemoData: false,
            sessionUID: "relay-key-legacy-\(UUID().uuidString)",
            providerSession: RelayKeyLegacyFakeServer.session()
        )
        Self.retainedStates.append(state)
        var stored = try Self.decodeStored(item["stored"])
        stored.relayRequested = RelayRequestedConfig(transport: .openaiChatCompletions, authMode: .bearer, securityMode: .remoteHTTPS)
        #expect(stored.relayKeys == nil)
        state.providers = [stored]

        let fetched = await state.providerManager.refreshRelayCatalog(providerID: stored.id)
        #expect(fetched == (refresh["ok"] != nil), "\(caseId)")
        let saved = try #require(state.provider(for: stored.id))
        let expect = try #require(item["expect"] as? [String: Any])
        #expect(Set(saved.catalogModels.map(\.id)) == Set(try #require(expect["catalogIDs"] as? [String])), "\(caseId)")

        let encoded = try #require(try Self.json(saved) as? [String: Any])
        #expect((encoded["relayKeys"] != nil) == (expect["relayKeysPersisted"] as? Bool), "\(caseId)")
        let expectedKeys = try #require(expect["relayKeys"] as? [[String: Any]])
        let keys = try #require(saved.relayKeys)
        #expect(keys.map(\.id) == expectedKeys.compactMap { $0["id"] as? String })
        #expect(keys.map(\.apiKey) == expectedKeys.compactMap { $0["apiKey"] as? String })
        for (key, wanted) in zip(keys, expectedKeys) {
            let status = try #require(wanted["status"] as? [String: Any])
            #expect(key.status?.state.rawValue == status["state"] as? String, "\(caseId)")
            if let code = status["httpStatus"] as? Int { #expect(key.status?.httpStatus == code, "\(caseId)") }
        }
        #expect(expect["modelKeyFieldsPersisted"] as? Bool == false)
        for list in ["models", "catalogModels"] {
            for entry in encoded[list] as? [[String: Any]] ?? [] {
                for field in Self.modelKeyFields { #expect(entry[field] == nil, "\(list) \(entry["id"] ?? "") wrote \(field)") }
            }
        }
    }

    @Test("KEY-LEGACY-catalog_refresh_writes_no_listing")
    func legacyRefresh() async throws { try await runLegacyRefresh("catalog_refresh_writes_no_listing") }

    @Test("KEY-LEGACY-catalog_refresh_failure_writes_status_only")
    func legacyRefreshFailure() async throws { try await runLegacyRefresh("catalog_refresh_failure_writes_status_only") }

    // MARK: - Wiring: with two or more keys, production enabling writes relayKeyID

    @Test("KEY-BIND production enabling: with two keys, relayKeyID is written according to bindCases (only_one_key_lists_target)")
    func enableWritesBoundKeyOnMultiKey() async throws {
        await MetadataClient.shared.resetForTesting()
        let item = try Self.caseItem("bindCases", "only_one_key_lists_target")
        let state = Self.makeState()
        var provider = TestFactories.makeProvider(
            kind: .relay,
            models: try Self.models(item["enabled"]),
            catalogModels: try Self.models(item["catalog"]),
            apiKey: "sk-a",
            baseURLText: "https://relay.example.com/v1"
        )
        provider.relayKeys = try #require(item["keys"] as? [String]).map { RelayKey(id: $0, apiKey: $0 == "initial" ? "" : "sk-\($0)") }
        state.providers = [provider]
        let target = try #require(item["target"] as? String)
        #expect(state.providerManager.enableModel(modelID: target, for: provider.id) != .notFound)
        let saved = try #require(state.providers.first { $0.id == provider.id })
        #expect(saved.models.first { $0.id == target }?.relayKeyID == item["expect"] as? String)
        #expect(ProviderCredentialResolver.apiKey(provider: saved, modelID: target) == "sk-k-claude")
    }

    // MARK: - KEY-SYNC

    @Test("KEY-SYNC-relay_keys_local_only")
    func syncRelayKeysLocalOnly() throws {
        let connectionFields = try #require(try Self.fixture("portable-config.v1.json")["connectionFields"] as? [String: Any])
        #expect(connectionFields["all"] as? [String] == ["relayKeys"])
        #expect((connectionFields["portable"] as? [String])?.isEmpty == true)

        var model = TestFactories.makeModel(id: "claude-opus-4")
        model.relayKeyID = "k-b"
        var provider = TestFactories.makeProvider(
            kind: .relay, models: [model], catalogModels: [model], apiKey: "sk-a",
            baseURLText: "https://relay.example.com/v1"
        )
        provider.relayKeys = [
            RelayKey(id: "initial", name: "OpenAI"),
            RelayKey(id: "k-b", name: "Claude", apiKey: "sk-b", status: .init(state: .ok, httpStatus: 200)),
        ]

        // Backup export: same as above .
        let exported = try JSONEncoder().encode(BackupProvider(from: provider))
        let exportedObject = try #require(try JSONSerialization.jsonObject(with: exported) as? [String: Any])
        #expect(exportedObject["relayKeys"] == nil)
        #expect(!String(decoding: exported, as: UTF8.self).contains("sk-b"))

        // Local storage round trip: the snapshot does not store key values; the Keychain fills them back in and the result is unchanged.
        let uid = "relay-key-sync-\(UUID().uuidString)"
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        let snapshot = AppSessionSnapshot(
            selectedTab: .home, hasCompletedOnboarding: true, providers: [provider],
            lastUsedModelRef: nil
        )
        let persisted = try JSONEncoder().encode(snapshot.persistingProviderAPIKeys(for: uid))
        #expect(!String(decoding: persisted, as: UTF8.self).contains("sk-b"))
        let restored = try JSONDecoder().decode(AppSessionSnapshot.self, from: persisted).hydratingProviderAPIKeys(for: uid)
        let roundTrip = try #require(restored.providers.first)
        #expect(roundTrip.relayKeys == provider.relayKeys)
        #expect(roundTrip.apiKey == "sk-a")
        #expect(ProviderCredentialResolver.apiKey(provider: roundTrip, modelID: "claude-opus-4") == "sk-b")

        // Deleting a connection also deletes its `#keyID` accounts.
        ProviderAPIKeyStore.delete(providerID: provider.id, uid: uid)
        #expect(ProviderAPIKeyStore.loadRelayKey(keyID: "k-b", providerID: provider.id, uid: uid) == nil)
    }

    // MARK: - Coverage

    @Test("KEY every fixture caseId has a test of the same name (bind / ops / read / legacy)")
    func fixtureCasesCovered() throws {
        let expected: [String: Set<String>] = [
            "bindCases": [
                "single_key_writes_nothing", "only_one_key_lists_target", "several_keys_follow_enabled_same_family",
                "several_keys_no_family_enabled_first_in_key_order", "family_key_not_listing_target_is_ignored",
                "other_family_enabled_is_ignored", "manual_id_follows_same_family", "manual_id_no_family_uses_primary",
                "enabled_without_key_id_counts_as_primary", "enabled_dangling_key_id_counts_as_primary",
                "unknown_target_family_never_matches", "legacy_catalog_entry_counts_as_primary_listing",
            ],
            "opsCases": [
                "add_key_materializes_list_and_pins_models", "rename_key",
                "replace_secret_clears_status_and_denial_keeps_catalog", "replace_primary_secret_writes_api_key",
                "reorder_moves_primary_secret", "delete_key_rebinds_to_primary_and_prunes_catalog",
                "delete_primary_promotes_next", "delete_last_key_is_refused",
                "rebind_clears_denial_and_reachable_transport", "rebind_keeps_user_transport",
                "add_to_single_entry_list_keeps_primary_status", "replace_secret_single_entry_list_clears_status",
                "add_empty_id_is_refused", "add_duplicate_id_is_refused", "rename_unknown_id_is_refused", "replace_unknown_id_is_refused", "delete_unknown_id_is_refused", "move_out_of_range_is_refused", "rebind_unknown_key_is_refused", "rebind_model_not_enabled_is_refused", "implicit_rename_is_refused", "implicit_move_is_refused", "implicit_rebind_is_refused",
            ],
            "readCases": ["single_entry_list_with_status", "legacy_single_key", "two_keys_with_denial"],
            "legacyCases": [
                "decode_has_one_implicit_key", "enable_writes_no_key_id", "catalog_refresh_writes_no_listing",
                "catalog_refresh_failure_writes_status_only",
            ],
        ]
        for (name, ids) in expected {
            #expect(Set(try Self.section(name).compactMap { $0["caseId"] as? String }) == ids, "\(name)")
        }
        let root = try Self.fixture("key-binding.v1.json")
        #expect(root["implicitKeyID"] as? String == RelayKeyBinding.implicitKeyID)
        #expect(root["keyStatusStates"] as? [String] == RelayKey.Status.State.allCases.map(\.rawValue))
    }
}

/// Fake upstream: answers per request (status code, body) and records all requests.
private final class RelayKeyLegacyFakeServer: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) -> (Int, String))?

    static func install(_ value: @escaping (URLRequest) -> (Int, String)) {
        lock.withLock { handler = value }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayKeyLegacyFakeServer.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (code, body) = Self.lock.withLock { Self.handler?(request) ?? (404, "") }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
