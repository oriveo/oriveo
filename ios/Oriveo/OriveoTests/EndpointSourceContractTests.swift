import Foundation
import Testing
@testable import Oriveo

/// Cross-platform `endpointSource` contract (`shared/test-fixtures/provider-catalog/endpoint-source.v1.json`; its $comment is the rule).
/// One test per fixture caseId; resolve cases assert the address the production `EndpointResolver.resolve(provider:)` actually produces.
@Suite("endpointSource contract", .serialized)
@MainActor
struct EndpointSourceContractTests {

    // MARK: - Fixture

    private static func fixture() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/test-fixtures/provider-catalog/endpoint-source.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                return try #require(object as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func cases(_ group: String) throws -> [[String: Any]] {
        try #require(try fixture()[group] as? [[String: Any]])
    }

    private static func testCase(_ group: String, _ caseId: String) throws -> [String: Any] {
        try #require(try cases(group).first { $0["caseId"] as? String == caseId }, "Fixture is missing \(caseId)")
    }

    private static func config(_ name: String) throws -> [String: Any] {
        let configs = try #require(try fixture()["configs"] as? [String: Any])
        var config = try #require(configs[name] as? [String: Any])
        config["displayName"] = name
        return config
    }

    private static func kind(_ config: [String: Any]) throws -> ProviderKind {
        switch config["kind"] as? String {
        case "qwen": return .qwen
        case "deepseek": return .deepseek
        case "togetherAI": return .together
        case "zhipu": return .zhipu
        default: throw CocoaError(.coderInvalidValue)
        }
    }

    /// `metadataPatch`: `defaultBaseURL`, `regionOptions.<id>.baseURL`, `regionOptions.<id>` (null = remove that entry).
    static func patched(_ config: [String: Any], _ patch: [String: Any]) -> [String: Any] {
        var config = config
        for (path, value) in patch {
            let parts = path.split(separator: ".").map(String.init)
            if parts.count == 1 {
                if value is NSNull { config.removeValue(forKey: path) } else { config[path] = value }
                continue
            }
            guard parts[0] == "regionOptions", var options = config["regionOptions"] as? [[String: Any]],
                  let index = options.firstIndex(where: { $0["id"] as? String == parts[1] }) else { continue }
            if parts.count == 2 {
                if value is NSNull { options.remove(at: index) } else if let object = value as? [String: Any] { options[index] = object }
            } else {
                options[index][parts[2]] = value
            }
            config["regionOptions"] = options
        }
        return config
    }

    /// `metadataPatch` of the E-3 group: `"absent"` = no metadata (nil); any other string = a `metadataPresets` name that replaces the whole key; an object works as above.
    static func currentConfig(_ item: [String: Any], _ config: [String: Any]) throws -> [String: Any]? {
        switch item["metadataPatch"] {
        case let name as String where name == "absent":
            return nil
        case let name as String:
            let presets = try #require(try fixture()["metadataPresets"] as? [String: Any])
            let preset = try #require(presets[name] as? [String: Any], "Missing preset \(name)")
            return patched(config, preset)
        case let patch as [String: Any]:
            return patched(config, patch)
        default:
            throw CocoaError(.coderInvalidValue)
        }
    }

    static func currentCatalog(_ item: [String: Any], _ config: [String: Any]) throws -> ProviderSetupCatalog {
        try currentConfig(item, config).map { try catalog([$0]) } ?? ProviderSetupCatalog.fromProviderConfigs(nil)
    }

    static func applyMetadata(_ item: [String: Any], _ config: [String: Any]) async throws {
        if let current = try currentConfig(item, config) {
            try await loadMetadata([current])
        } else {
            await MetadataClient.shared.resetForTesting()
        }
    }

    static func catalog(_ configs: [[String: Any]]) throws -> ProviderSetupCatalog {
        let data = try JSONSerialization.data(withJSONObject: configs)
        let decoded = try JSONDecoder().decode([MetadataClient.PublicProviderConfig].self, from: data)
        return ProviderSetupCatalog.fromProviderConfigs(decoded)
    }

    static func loadMetadata(_ configs: [[String: Any]]) async throws {
        let body: [String: Any] = [
            "version": 1,
            "updatedAt": "2026-10-11T00:00:00Z",
            "providers": [String: Any](),
            "providerConfigs": configs,
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: String(decoding: data, as: UTF8.self))
    }

    private static func provider(kind: ProviderKind, baseURLText: String?, source: String?) -> Provider {
        var provider = TestFactories.makeProvider(kind: kind, models: [])
        provider.baseURLText = baseURLText
        provider.endpointSource = source.flatMap(ProviderEndpointSource.init(rawValue:))
        return provider
    }

    /// The fixture writes addresses with a scheme, while the iOS catalog and setup keep the literal form without one; compare after the contract's normalization.
    private static func sameURL(_ actual: String?, _ expected: String?) -> Bool {
        ProviderEndpointSourceRules.matchKey(actual) == ProviderEndpointSourceRules.matchKey(expected)
    }

    // MARK: - Executor

    private func runClassify(_ caseId: String) throws {
        let item = try Self.testCase("classifyCases", caseId)
        let config = try Self.config(try #require(item["config"] as? String))
        let catalog = try Self.catalog([config])
        var provider = Self.provider(kind: try Self.kind(config), baseURLText: item["baseURLText"] as? String, source: nil)
        let changed = provider.classifyEndpointSourceIfNeeded(catalog: catalog)
        #expect(changed)
        #expect(provider.endpointSource?.rawValue == item["expect"] as? String, "\(caseId)")
    }

    private func runResolve(_ caseId: String) async throws {
        let item = try Self.testCase("resolveCases", caseId)
        let config = try Self.config(try #require(item["config"] as? String))
        let kind = try Self.kind(config)
        let stored = try #require(item["stored"] as? [String: Any])
        var provider = Self.provider(
            kind: kind,
            baseURLText: stored["baseURLText"] as? String,
            source: stored["endpointSource"] as? String
        )

        if item["classifyWithBaseMetadataFirst"] as? Bool == true {
            // The production startup write-back: classify against the metadata of that moment and edit the array directly, leaving updatedAt alone.
            try await Self.loadMetadata([config])
            let state = AppState(seedDemoData: false, sessionUID: "endpoint-source-\(UUID().uuidString)")
            state.providers = [provider]
            let before = state.providers[0].updatedAt
            state.backfillProviderEndpointSources()
            provider = try #require(state.providers.first)
            #expect(provider.updatedAt == before, "The write-back does not change updatedAt")
            #expect(provider.endpointSource?.rawValue == item["expectEndpointSource"] as? String)
        }

        if item["metadataPatch"] as? String == "absent" {
            await MetadataClient.shared.resetForTesting()
        } else {
            let patch = try #require(item["metadataPatch"] as? [String: Any])
            try await Self.loadMetadata([Self.patched(config, patch)])
        }

        let resolved = try EndpointResolver.resolve(provider: provider, kind: .chat, metadataTransport: nil)
        let expected = try #require(item["expectBaseURL"] as? String)
        #expect(Self.sameURL(resolved.baseURL, expected), "\(caseId): \(resolved.baseURL) ≠ \(expected)")
        #expect(resolved.url.host == URL(string: expected)?.host)
    }

    private func runWrite(_ caseId: String) throws {
        let item = try Self.testCase("writeCases", caseId)
        let config = try Self.config(try #require(item["config"] as? String))
        let kind = try Self.kind(config)
        let catalog = try Self.catalog([config])
        let expect = try #require(item["expect"] as? [String: Any])
        let before = item["before"] as? [String: Any]
        var provider = Self.provider(
            kind: kind,
            baseURLText: before?["baseURLText"] as? String,
            source: before?["endpointSource"] as? String
        )

        switch item["action"] as? String {
        case "setup":
            let submission = try #require(catalog.setupSubmission(
                for: kind, optionID: item["regionId"] as? String, values: [:]
            ))
            #expect(submission.endpointSource.rawValue == expect["endpointSource"] as? String)
            #expect(Self.sameURL(submission.baseURLText, expect["baseURLText"] as? String))
            return
        case "editBaseURL":
            // The same-step recompute after ProviderManager.updateBaseURL writes the address.
            let previous = provider.baseURLText
            provider.baseURLText = item["baseURLText"] as? String
            provider.reclassifyEndpointSource(previousBaseURLText: previous, catalog: catalog)
        case "syncApply", "syncUpload":
            // Community edition has no sync layer.
            return
        default:
            Issue.record("Unknown action \(caseId)")
            return
        }
        #expect(provider.endpointSource?.rawValue == expect["endpointSource"] as? String, "\(caseId)")
        #expect(Self.sameURL(provider.baseURLText, expect["baseURLText"] as? String))
    }

    /// Lazy migration: computed in memory from the original record at request time, backfilled to local storage at startup (updatedAt untouched), then the next request after the backfill.
    private func runReconcile(_ caseId: String) async throws {
        let item = try Self.testCase("reconcileCases", caseId)
        let config = try Self.config(try #require(item["config"] as? String))
        let kind = try Self.kind(config)
        let stored = try #require(item["stored"] as? [String: Any])
        let expect = try #require(item["expect"] as? [String: Any])
        let expectRequest = try #require(item["expectRequestBaseURL"] as? String)
        try await Self.applyMetadata(item, config)

        let original = Self.provider(
            kind: kind,
            baseURLText: stored["baseURLText"] as? String,
            source: stored["endpointSource"] as? String
        )
        #expect(Self.sameURL(original.requestBaseURLText(), expectRequest), "\(caseId) computed at request time")

        let state = AppState(seedDemoData: false, sessionUID: "endpoint-source-reconcile-\(UUID().uuidString)")
        state.providers = [original]
        state.backfillProviderEndpointSources()
        let persisted = try #require(state.providers.first)
        #expect(persisted.updatedAt == original.updatedAt, "The backfill does not change updatedAt")
        #expect(persisted.endpointSource?.rawValue == expect["endpointSource"] as? String, "\(caseId)")
        #expect(Self.sameURL(persisted.baseURLText, expect["baseURLText"] as? String), "\(caseId): \(persisted.baseURLText ?? "nil")")

        let resolved = try EndpointResolver.resolve(provider: persisted, kind: .chat, metadataTransport: nil)
        #expect(Self.sameURL(resolved.baseURL, expectRequest), "\(caseId): \(resolved.baseURL) ≠ \(expectRequest)")
    }

    /// Goes through the production chat entry `AppState.sendMessage` and asserts the host of the request that went out.
    private func runSend(_ caseId: String, modelID: String) async throws {
        let item = try Self.testCase("reconcileCases", caseId)
        let config = try Self.config(try #require(item["config"] as? String))
        let kind = try Self.kind(config)
        let stored = try #require(item["stored"] as? [String: Any])
        let expectBase = try #require(item["expectRequestBaseURL"] as? String)
        let expectHost = try #require(URL(string: expectBase)?.host)
        try await Self.applyMetadata(item, config)

        let model = TestFactories.makeModel(id: modelID, capabilities: [.text], isDefault: true)
        var provider = TestFactories.makeProvider(kind: kind, models: [model], apiKey: "sk-endpoint-source-test")
        provider.baseURLText = stored["baseURLText"] as? String
        provider.endpointSource = (stored["endpointSource"] as? String).flatMap(ProviderEndpointSource.init(rawValue:))
        let host = try await Self.capturedChatHost(provider: provider, model: model)
        #expect(host == expectHost, "\(caseId): \(host ?? "nil") ≠ \(expectHost)")
    }

    static func capturedChatHost(provider: Provider, model: AIModel) async throws -> String? {
        EndpointSourceCaptureProtocol.reset()
        defer { EndpointSourceCaptureProtocol.reset() }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [EndpointSourceCaptureProtocol.self]
        let state = AppState(
            seedDemoData: false,
            sessionUID: "endpoint-source-send-\(UUID().uuidString)",
            providerSession: URLSession(configuration: sessionConfig)
        )
        let conversation = TestFactories.makeConversation(
            providerID: provider.id, providerKind: provider.kind, modelID: model.id
        )
        state.providers = [provider]
        state.upsertConversationProjection(conversation)

        _ = await state.sendMessage("Hello", in: conversation.id)
        let deadline = ContinuousClock.now + .seconds(5)
        while EndpointSourceCaptureProtocol.captured.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let request = try #require(EndpointSourceCaptureProtocol.captured.first, "No chat request was sent")
        return request.url?.host
    }

    /// The deterministic region segment of the id: the id actually derived by the production `regionID` and the migration grouping (`planDeterministicProviderMigration`).
    private func runIdentity(_ caseId: String) throws {
        let item = try Self.testCase("identityCases", caseId)
        let config = try Self.config(try #require(item["config"] as? String))
        let kind = try Self.kind(config)
        let catalog = try Self.currentCatalog(item, config)
        let stored = try #require(item["stored"] as? [String: Any])
        let expected = try #require(item["expectRegionId"] as? String)
        let provider = Self.provider(
            kind: kind,
            baseURLText: stored["baseURLText"] as? String,
            source: stored["endpointSource"] as? String
        )
        #expect(DeterministicProviderID.regionID(
            for: kind, baseURLText: provider.baseURLText, endpointSource: provider.endpointSource, setupCatalog: catalog
        ) == expected, "\(caseId)")
        let outcome = AppState.planDeterministicProviderMigration(providers: [provider], setupCatalog: catalog)
        #expect(outcome.providers.first?.id == DeterministicProviderID.make(kind: kind, regionID: expected), "\(caseId) migration grouping")
    }

    private func runEcho(_ caseId: String) throws {
        let item = try Self.testCase("echoCases", caseId)
        let config = try Self.config(try #require(item["config"] as? String))
        let kind = try Self.kind(config)
        let catalog = try Self.currentCatalog(item, config)
        let stored = try #require(item["stored"] as? [String: Any])
        let current = ProviderEndpointEditPolicy.currentOption(
            catalog: catalog,
            kind: kind,
            baseURLText: stored["baseURLText"] as? String,
            endpointSource: (stored["endpointSource"] as? String).flatMap(ProviderEndpointSource.init(rawValue:))
        )
        #expect(current?.id == item["expectRegionId"] as? String, "\(caseId): \(current?.id ?? "nil")")
    }

    /// The picker display (`hasEndpointOptions`) and the save gate (`usesConfigurableBaseURL` in `AppState.updateBaseURL`) use the same criterion.
    private func runRegionPicker(_ caseId: String) throws {
        let item = try Self.testCase("regionPickerCases", caseId)
        let config = try Self.config(try #require(item["config"] as? String))
        let kind = try Self.kind(config)
        let catalog = try Self.currentCatalog(item, config)
        let expected = try #require(item["expectShown"] as? Bool)
        #expect(!catalog.setupEndpointOptions(for: kind).isEmpty == expected, "\(caseId) display")
        #expect(catalog.usesConfigurableBaseURL(kind) == expected, "\(caseId) save")
    }

    private func runBuiltIn(_ caseId: String) throws {
        let item = try Self.testCase("builtInCases", caseId)
        let catalog = ProviderSetupCatalog.fromProviderConfigs(nil)
        if let kinds = item["kinds"] as? [String] {
            let table = try #require(try Self.fixture()["builtInDefaults"] as? [String: String])
            for name in kinds {
                let kind = try Self.kind(try Self.config(name))
                let expected = try #require(table[name])
                #expect(Self.sameURL(kind.defaultBaseURLText, expected), "\(name) built-in default")
                // With no metadata, the address written literally at setup is exactly this one.
                let submission = try #require(catalog.setupSubmission(for: kind, optionID: nil, values: [:]))
                #expect(Self.sameURL(submission.baseURLText, expected), "\(name) setup literal")
            }
            return
        }
        let kindName = try #require(item["kind"] as? String)
        let kind = try #require(ProviderKind(rawValue: kindName))
        if let ids = item["expectRegionIds"] as? [String] {
            #expect(catalog.setupEndpointOptions(for: kind).map(\.id) == ids, "\(caseId)")
            #expect(kind.setupEndpointOptions.map(\.id) == ids, "\(caseId) built-in table")
        }
        if let key = item["expectDefaultMatchKey"] as? String {
            #expect(ProviderEndpointSourceRules.matchKey(catalog.defaultBaseURLText(for: kind)) == key, "\(caseId)")
        }
    }

    // MARK: - Coverage guard

    @Test("Every ENDPOINT-SOURCE fixture caseId has a test of the same name")
    func everyCaseCovered() throws {
        let covered: [String: Set<String>] = [
            "classifyCases": ["empty_is_default", "blank_is_default", "equal_to_default_is_default", "region_match_exact", "region_match_trailing_slash", "region_match_legacy_compat_suffix", "region_match_case_insensitive_host", "region_beats_default_when_equal", "other_host_is_custom", "empty_with_regions_is_default"],
            "resolveCases": ["region_follows_metadata_change", "default_follows_metadata_change", "custom_keeps_literal", "region_removed_falls_back_to_literal", "untrusted_metadata_falls_back_to_literal", "no_metadata_uses_literal", "missing_source_is_classified_then_follows"],
            "writeCases": ["setup_region_choice_writes_region", "setup_without_regions_writes_default", "edit_base_reclassifies", "sync_incoming_base_reclassifies", "never_in_sync_payload"],
            "reconcileCases": ["qwen_us_region_moves_to_sg", "qwen_us_literal_unclassified_moves_to_sg", "qwen_us_custom_literal_moves_to_sg", "qwen_us_without_metadata_moves_to_builtin_sg", "zhipu_cn_literal_default_pins_cn", "zhipu_cn_literal_unclassified_pins_cn", "zhipu_empty_literal_follows_new_default", "zhipu_before_regions_stays_default", "together_default_moves_to_ai", "together_unclassified_moves_to_ai", "together_ai_untrusted_keeps_literal", "together_custom_keeps_literal"],
            "identityCases": ["identity_region_source_beats_moved_literal", "identity_unclassified_uses_literal", "identity_retired_us_literal_keeps_us", "identity_zhipu_cn_ignores_metadata_regions", "identity_zhipu_intl_ignores_metadata_regions"],
            "echoCases": ["echo_region_source_after_metadata_moves_address", "echo_unclassified_uses_literal", "echo_source_region_not_in_catalog_uses_literal", "echo_zhipu_cn_after_e3"],
            "regionPickerCases": ["picker_zhipu_after_e3", "picker_zhipu_before_e3", "picker_together", "picker_qwen"],
            "builtInCases": ["builtin_qwen_selectable_regions_drop_us", "builtin_qwen_default_is_intl", "builtin_zhipu_has_no_regions", "builtin_defaults_match_fixture"],
        ]
        for (group, ids) in covered {
            let fixtureIDs = Set(try Self.cases(group).compactMap { $0["caseId"] as? String })
            #expect(fixtureIDs == ids, "\(group) fixture and tests disagree")
        }
        // Each sendPath case has one SEND test.
        let sendIDs = Set(try Self.cases("reconcileCases").filter { $0["sendPath"] as? Bool == true }.compactMap { $0["caseId"] as? String })
        #expect(sendIDs == ["qwen_us_region_moves_to_sg", "zhipu_cn_literal_default_pins_cn", "together_default_moves_to_ai"])
    }

    @Test("ENDPOINT-SOURCE-identity_regions_frozen: the built-in frozen identity table matches the fixture identityRegions verbatim")
    func identityRegionsMatchFixture() throws {
        let table = try #require(try Self.fixture()["identityRegions"] as? [String: [[String: String]]])
        #expect(Set(ProviderSetupCatalog.identityRegions.keys.map(\.rawValue)) == Set(table.keys))
        for (name, rows) in table {
            let kind = try #require(ProviderKind(rawValue: name))
            let builtIn = try #require(ProviderSetupCatalog.identityRegions[kind])
            #expect(builtIn.map(\.id) == rows.compactMap { $0["id"] }, "\(name)")
            #expect(builtIn.map { "https://\($0.baseURLText)" } == rows.compactMap { $0["baseURL"] }, "\(name)")
        }
    }

    // MARK: - classifyCases

    @Test("ENDPOINT-SOURCE-empty_is_default") func classifyEmptyIsDefault() throws { try runClassify("empty_is_default") }
    @Test("ENDPOINT-SOURCE-blank_is_default") func classifyBlankIsDefault() throws { try runClassify("blank_is_default") }
    @Test("ENDPOINT-SOURCE-equal_to_default_is_default") func classifyEqualToDefaultIsDefault() throws { try runClassify("equal_to_default_is_default") }
    @Test("ENDPOINT-SOURCE-region_match_exact") func classifyRegionMatchExact() throws { try runClassify("region_match_exact") }
    @Test("ENDPOINT-SOURCE-region_match_trailing_slash") func classifyRegionMatchTrailingSlash() throws { try runClassify("region_match_trailing_slash") }
    @Test("ENDPOINT-SOURCE-region_match_legacy_compat_suffix") func classifyRegionMatchLegacyCompatSuffix() throws { try runClassify("region_match_legacy_compat_suffix") }
    @Test("ENDPOINT-SOURCE-region_match_case_insensitive_host") func classifyRegionMatchCaseInsensitiveHost() throws { try runClassify("region_match_case_insensitive_host") }
    @Test("ENDPOINT-SOURCE-region_beats_default_when_equal") func classifyRegionBeatsDefaultWhenEqual() throws { try runClassify("region_beats_default_when_equal") }
    @Test("ENDPOINT-SOURCE-other_host_is_custom") func classifyOtherHostIsCustom() throws { try runClassify("other_host_is_custom") }
    @Test("ENDPOINT-SOURCE-empty_with_regions_is_default") func classifyEmptyWithRegionsIsDefault() throws { try runClassify("empty_with_regions_is_default") }

    // MARK: - resolveCases

    @Test("ENDPOINT-SOURCE-region_follows_metadata_change") func resolveRegionFollowsMetadataChange() async throws { try await runResolve("region_follows_metadata_change") }
    @Test("ENDPOINT-SOURCE-default_follows_metadata_change") func resolveDefaultFollowsMetadataChange() async throws { try await runResolve("default_follows_metadata_change") }
    @Test("ENDPOINT-SOURCE-custom_keeps_literal") func resolveCustomKeepsLiteral() async throws { try await runResolve("custom_keeps_literal") }
    @Test("ENDPOINT-SOURCE-region_removed_falls_back_to_literal") func resolveRegionRemovedFallsBackToLiteral() async throws { try await runResolve("region_removed_falls_back_to_literal") }
    @Test("ENDPOINT-SOURCE-untrusted_metadata_falls_back_to_literal") func resolveUntrustedMetadataFallsBackToLiteral() async throws { try await runResolve("untrusted_metadata_falls_back_to_literal") }
    @Test("ENDPOINT-SOURCE-no_metadata_uses_literal") func resolveNoMetadataUsesLiteral() async throws { try await runResolve("no_metadata_uses_literal") }
    @Test("ENDPOINT-SOURCE-missing_source_is_classified_then_follows") func resolveMissingSourceIsClassifiedThenFollows() async throws { try await runResolve("missing_source_is_classified_then_follows") }

    // MARK: - writeCases

    @Test("ENDPOINT-SOURCE-setup_region_choice_writes_region") func writeSetupRegionChoiceWritesRegion() throws { try runWrite("setup_region_choice_writes_region") }
    @Test("ENDPOINT-SOURCE-setup_without_regions_writes_default") func writeSetupWithoutRegionsWritesDefault() throws { try runWrite("setup_without_regions_writes_default") }
    @Test("ENDPOINT-SOURCE-edit_base_reclassifies") func writeEditBaseReclassifies() throws { try runWrite("edit_base_reclassifies") }
    @Test("ENDPOINT-SOURCE-sync_incoming_base_reclassifies") func writeSyncIncomingBaseReclassifies() throws { try runWrite("sync_incoming_base_reclassifies") }
    @Test("ENDPOINT-SOURCE-never_in_sync_payload") func writeNeverInSyncPayload() throws { try runWrite("never_in_sync_payload") }

    // MARK: - reconcileCases
    @Test("ENDPOINT-SOURCE-qwen_us_region_moves_to_sg") func reconcileCaseQwenUsRegionMovesToSg() async throws { try await runReconcile("qwen_us_region_moves_to_sg") }
    @Test("ENDPOINT-SOURCE-qwen_us_literal_unclassified_moves_to_sg") func reconcileCaseQwenUsLiteralUnclassifiedMovesToSg() async throws { try await runReconcile("qwen_us_literal_unclassified_moves_to_sg") }
    @Test("ENDPOINT-SOURCE-qwen_us_custom_literal_moves_to_sg") func reconcileCaseQwenUsCustomLiteralMovesToSg() async throws { try await runReconcile("qwen_us_custom_literal_moves_to_sg") }
    @Test("ENDPOINT-SOURCE-qwen_us_without_metadata_moves_to_builtin_sg") func reconcileCaseQwenUsWithoutMetadataMovesToBuiltinSg() async throws { try await runReconcile("qwen_us_without_metadata_moves_to_builtin_sg") }
    @Test("ENDPOINT-SOURCE-zhipu_cn_literal_default_pins_cn") func reconcileCaseZhipuCnLiteralDefaultPinsCn() async throws { try await runReconcile("zhipu_cn_literal_default_pins_cn") }
    @Test("ENDPOINT-SOURCE-zhipu_cn_literal_unclassified_pins_cn") func reconcileCaseZhipuCnLiteralUnclassifiedPinsCn() async throws { try await runReconcile("zhipu_cn_literal_unclassified_pins_cn") }
    @Test("ENDPOINT-SOURCE-zhipu_empty_literal_follows_new_default") func reconcileCaseZhipuEmptyLiteralFollowsNewDefault() async throws { try await runReconcile("zhipu_empty_literal_follows_new_default") }
    @Test("ENDPOINT-SOURCE-zhipu_before_regions_stays_default") func reconcileCaseZhipuBeforeRegionsStaysDefault() async throws { try await runReconcile("zhipu_before_regions_stays_default") }
    @Test("ENDPOINT-SOURCE-together_default_moves_to_ai") func reconcileCaseTogetherDefaultMovesToAi() async throws { try await runReconcile("together_default_moves_to_ai") }
    @Test("ENDPOINT-SOURCE-together_unclassified_moves_to_ai") func reconcileCaseTogetherUnclassifiedMovesToAi() async throws { try await runReconcile("together_unclassified_moves_to_ai") }
    @Test("ENDPOINT-SOURCE-together_ai_untrusted_keeps_literal") func reconcileCaseTogetherAiUntrustedKeepsLiteral() async throws { try await runReconcile("together_ai_untrusted_keeps_literal") }
    @Test("ENDPOINT-SOURCE-together_custom_keeps_literal") func reconcileCaseTogetherCustomKeepsLiteral() async throws { try await runReconcile("together_custom_keeps_literal") }

    // MARK: - identityCases
    @Test("ENDPOINT-SOURCE-identity_region_source_beats_moved_literal") func identityCaseIdentityRegionSourceBeatsMovedLiteral() throws { try runIdentity("identity_region_source_beats_moved_literal") }
    @Test("ENDPOINT-SOURCE-identity_unclassified_uses_literal") func identityCaseIdentityUnclassifiedUsesLiteral() throws { try runIdentity("identity_unclassified_uses_literal") }
    @Test("ENDPOINT-SOURCE-identity_retired_us_literal_keeps_us") func identityCaseIdentityRetiredUsLiteralKeepsUs() throws { try runIdentity("identity_retired_us_literal_keeps_us") }
    @Test("ENDPOINT-SOURCE-identity_zhipu_cn_ignores_metadata_regions") func identityCaseIdentityZhipuCnIgnoresMetadataRegions() throws { try runIdentity("identity_zhipu_cn_ignores_metadata_regions") }
    @Test("ENDPOINT-SOURCE-identity_zhipu_intl_ignores_metadata_regions") func identityCaseIdentityZhipuIntlIgnoresMetadataRegions() throws { try runIdentity("identity_zhipu_intl_ignores_metadata_regions") }

    // MARK: - echoCases
    @Test("ENDPOINT-SOURCE-echo_region_source_after_metadata_moves_address") func echoCaseEchoRegionSourceAfterMetadataMovesAddress() throws { try runEcho("echo_region_source_after_metadata_moves_address") }
    @Test("ENDPOINT-SOURCE-echo_unclassified_uses_literal") func echoCaseEchoUnclassifiedUsesLiteral() throws { try runEcho("echo_unclassified_uses_literal") }
    @Test("ENDPOINT-SOURCE-echo_source_region_not_in_catalog_uses_literal") func echoCaseEchoSourceRegionNotInCatalogUsesLiteral() throws { try runEcho("echo_source_region_not_in_catalog_uses_literal") }
    @Test("ENDPOINT-SOURCE-echo_zhipu_cn_after_e3") func echoCaseEchoZhipuCnAfterE3() throws { try runEcho("echo_zhipu_cn_after_e3") }

    // MARK: - regionPickerCases
    @Test("ENDPOINT-SOURCE-picker_zhipu_after_e3") func pickerCasePickerZhipuAfterE3() throws { try runRegionPicker("picker_zhipu_after_e3") }
    @Test("ENDPOINT-SOURCE-picker_zhipu_before_e3") func pickerCasePickerZhipuBeforeE3() throws { try runRegionPicker("picker_zhipu_before_e3") }
    @Test("ENDPOINT-SOURCE-picker_together") func pickerCasePickerTogether() throws { try runRegionPicker("picker_together") }
    @Test("ENDPOINT-SOURCE-picker_qwen") func pickerCasePickerQwen() throws { try runRegionPicker("picker_qwen") }

    // MARK: - builtInCases
    @Test("ENDPOINT-SOURCE-builtin_qwen_selectable_regions_drop_us") func builtInCaseBuiltinQwenSelectableRegionsDropUs() throws { try runBuiltIn("builtin_qwen_selectable_regions_drop_us") }
    @Test("ENDPOINT-SOURCE-builtin_qwen_default_is_intl") func builtInCaseBuiltinQwenDefaultIsIntl() throws { try runBuiltIn("builtin_qwen_default_is_intl") }
    @Test("ENDPOINT-SOURCE-builtin_zhipu_has_no_regions") func builtInCaseBuiltinZhipuHasNoRegions() throws { try runBuiltIn("builtin_zhipu_has_no_regions") }
    @Test("ENDPOINT-SOURCE-builtin_defaults_match_fixture") func builtInCaseBuiltinDefaultsMatchFixture() throws { try runBuiltIn("builtin_defaults_match_fixture") }

    // MARK: - SEND (production chat entry)
    @Test("ENDPOINT-SOURCE-SEND-qwen_us_region_moves_to_sg") func sendQwenUsRegionMovesToSg() async throws { try await runSend("qwen_us_region_moves_to_sg", modelID: "qwen-plus") }
    @Test("ENDPOINT-SOURCE-SEND-zhipu_cn_literal_default_pins_cn") func sendZhipuCnLiteralDefaultPinsCn() async throws { try await runSend("zhipu_cn_literal_default_pins_cn", modelID: "glm-4.6") }
    @Test("ENDPOINT-SOURCE-SEND-together_default_moves_to_ai") func sendTogetherDefaultMovesToAi() async throws { try await runSend("together_default_moves_to_ai", modelID: "meta-llama/Llama-3.3-70B-Instruct-Turbo") }
    // An empty literal must also follow the new default on the real chat path (not a sendPath case; supplementary).
    @Test("ENDPOINT-SOURCE-SEND-zhipu_empty_literal_follows_new_default") func sendZhipuEmptyLiteralFollowsNewDefault() async throws { try await runSend("zhipu_empty_literal_follows_new_default", modelID: "glm-4.6") }

    // MARK: - Cross-platform supplements

    @Test("ENDPOINT-SOURCE-iOS chat send entry: a region source hits the new address after metadata changes the address")
    func chatSendFollowsRegionChange() async throws {
        let config = try Self.config("qwen")
        try await Self.loadMetadata([
            Self.patched(config, ["regionOptions.bj.baseURL": "https://cn-beijing.dashscope.aliyuncs.com"])
        ])
        EndpointSourceCaptureProtocol.reset()
        defer { EndpointSourceCaptureProtocol.reset() }

        let model = TestFactories.makeModel(id: "qwen-plus", capabilities: [.text], isDefault: true)
        var provider = TestFactories.makeProvider(kind: .qwen, models: [model], apiKey: "sk-qwen-test")
        provider.baseURLText = "dashscope.aliyuncs.com"
        provider.endpointSource = .region("bj")

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [EndpointSourceCaptureProtocol.self]
        let state = AppState(
            seedDemoData: false,
            sessionUID: "endpoint-source-send-\(UUID().uuidString)",
            providerSession: URLSession(configuration: sessionConfig)
        )
        let conversation = TestFactories.makeConversation(
            providerID: provider.id, providerKind: .qwen, modelID: model.id
        )
        state.providers = [provider]
        state.upsertConversationProjection(conversation)

        _ = await state.sendMessage("Hello", in: conversation.id)
        let deadline = ContinuousClock.now + .seconds(5)
        while EndpointSourceCaptureProtocol.captured.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let request = try #require(EndpointSourceCaptureProtocol.captured.first, "No chat request was sent")
        #expect(request.url?.host == "cn-beijing.dashscope.aliyuncs.com", "\(request.url?.absoluteString ?? "")")
    }
}

/// Captures the request only and answers 401, so the send chain wraps up quickly.
private final class EndpointSourceCaptureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storage: [URLRequest] = []

    static var captured: [URLRequest] { lock.withLock { storage } }
    static func reset() { lock.withLock { storage = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.storage.append(request) }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://capture.invalid")!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":{"message":"invalid key"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
