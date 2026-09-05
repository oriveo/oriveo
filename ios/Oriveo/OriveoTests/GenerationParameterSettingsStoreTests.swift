import Foundation
import Testing
@testable import Oriveo

private final class LocalRuntimeMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeLocalRuntimeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LocalRuntimeMockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func localRuntimeSecurityConfig() -> RelayRequestedConfig {
    RelayRequestedConfig(
        transport: .llamacppNative,
        authMode: .none,
        securityMode: .localHTTP,
        engineProfile: LocalEngineKind.llamacpp.rawValue
    )
}

@Suite("Generation parameter local scopes", .serialized)
struct GenerationParameterSettingsStoreTests {
    private struct SyncFixture: Decodable { let payload: GenerationParameterSyncPayload }
    private struct CapabilitySyncFixture: Decodable {
        struct ResolutionCase: Decodable {
            let caseId: String
            let singleSend: CapabilityPreferenceValues?
            let conversation: CapabilityPreferenceValues?
            let skillAgent: CapabilityPreferenceValues?
            let connectionModel: CapabilityPreferenceValues?
            let connection: CapabilityPreferenceValues?
            let providerRecipe: CapabilityPreferenceValues?
            let providerDefault: CapabilityPreferenceValues?
            let expected: CapabilityPreferenceValues
        }
        let payload: CapabilityPreferenceSyncPayload
        let resolutionCases: [ResolutionCase]
        let invalidTombstoneCases: [CapabilityPreferenceSyncTombstone]
    }
    @Test("Connection Reasoning Passes When Chip Is Auto")
    func connectionReasoningPassesWhenChipIsAuto() {
        let suiteName = "generation-parameter-reasoning-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID()
        store.setModelDefaults(
            .init(values: [
                "reasoning_effort": .init(state: .value, value: .string("high")),
                "temperature": .init(state: .value, value: .number(0.4)),
            ]),
            providerID: provider,
            modelID: "model-a"
        )

        let auto = store.resolve(
            transient: nil,
            providerID: provider,
            modelID: "model-a",
            conversationID: UUID(),
            reasoningMode: .automatic
        )
        #expect(auto?.values["reasoning_effort"]?.value == .string("high"))
        #expect(auto?.values["temperature"]?.value == .number(0.4))

        let unwired = store.resolve(
            transient: nil,
            providerID: provider,
            modelID: "model-a",
            conversationID: UUID()
        )
        #expect(unwired?.values["reasoning_effort"]?.value == .string("high"))
    }

    @Test("Explicit Chip Overrides Connection Reasoning")
    func explicitChipOverridesConnectionReasoning() {
        let suiteName = "generation-parameter-reasoning-chip-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID()
        store.setModelDefaults(
            .init(values: [
                "reasoning_effort": .init(state: .value, value: .string("high")),
                "reasoning_budget": .init(state: .value, value: .number(2048)),
                "temperature": .init(state: .value, value: .number(0.4)),
            ]),
            providerID: provider,
            modelID: "model-a"
        )

        let resolved = store.resolve(
            transient: nil,
            providerID: provider,
            modelID: "model-a",
            conversationID: UUID(),
            reasoningMode: .deep
        )
        #expect(resolved?.values["reasoning_effort"] == nil)
        #expect(resolved?.values["reasoning_budget"] == nil)
        #expect(resolved?.values["temperature"]?.value == .number(0.4))
    }

    @Test("Session Scope Never Carries Reasoning")
    func sessionScopeNeverCarriesReasoning() {
        let suiteName = "generation-parameter-reasoning-session-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID()
        let conversation = UUID()
        store.setSessionOverrides(
            .init(values: ["reasoning_effort": .init(state: .value, value: .string("low"))]),
            providerID: provider,
            modelID: "model-a",
            conversationID: conversation
        )

        let resolved = store.resolve(
            transient: .init(values: ["reasoning_mode": .init(state: .value, value: .string("on"))]),
            providerID: provider,
            modelID: "model-a",
            conversationID: conversation,
            reasoningMode: .automatic
        )
        #expect(resolved == nil)
    }

    @Test("Generic Relay Profile Remains Unknown")
    func genericRelayProfileRemainsUnknown() {
        let profile = LocalEngineGenerationProfiles.profile(
            for: nil,
            transport: .anthropicMessages
        )
        #expect(profile?.template == "anthropic_messages")
        #expect(profile?.parameters?.first(where: { $0.id == "temperature" })?.support == "unknown")
        #expect(profile?.wire?["temperature"] == "temperature")
        #expect(profile?.wire?["reasoning_effort"] == nil)
    }

    @Test("model defaults and session overrides remain isolated and preserve omit")
    func scopesAreIsolated() {
        let suiteName = "generation-parameter-store-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID()
        let conversationA = UUID()
        let conversationB = UUID()
        let defaultsValue = GenerationParameterOverrides(values: [
            "temperature": .init(state: .value, value: .number(0)),
            "top_p": .init(state: .value, value: .number(0.9)),
        ])
        store.setModelDefaults(defaultsValue, providerID: provider, modelID: "model-a")
        store.setSessionOverrides(
            .init(values: ["top_p": .init(state: .omit)]),
            providerID: provider,
            modelID: "model-a",
            conversationID: conversationA
        )

        let resolvedA = store.resolve(
            transient: nil,
            providerID: provider,
            modelID: "model-a",
            conversationID: conversationA
        )
        #expect(resolvedA?.values["temperature"]?.value == .number(0))
        #expect(resolvedA?.values["top_p"]?.state == .omit)

        let resolvedB = store.resolve(
            transient: nil,
            providerID: provider,
            modelID: "model-a",
            conversationID: conversationB
        )
        #expect(resolvedB?.values["top_p"]?.value == .number(0.9))
        #expect(store.modelDefaults(providerID: provider, modelID: "model-b") == nil)

        store.setModelDefaults(
            .init(values: ["temperature": .init(state: .inherit)]),
            providerID: provider,
            modelID: "model-a"
        )
        #expect(store.modelDefaults(providerID: provider, modelID: "model-a") == nil)

        store.setModelDefaults(
            defaultsValue,
            providerID: provider,
            modelID: "model-a",
            profileFingerprint: "endpoint-a|openai_chat_completions"
        )
        #expect(store.modelDefaults(
            providerID: provider,
            modelID: "model-a",
            profileFingerprint: "endpoint-b|anthropic_messages"
        )?.values["temperature"]?.value == .number(0))

        store.setSessionOverrides(
            .init(values: ["temperature": .init(state: .value, value: .number(0.3))]),
            providerID: provider,
            modelID: "model-a",
            conversationID: conversationA,
            profileFingerprint: "environment-a"
        )
        store.migrateSession(
            providerID: provider,
            modelID: "model-a",
            from: conversationA,
            to: conversationB,
            profileFingerprint: "environment-a"
        )
        #expect(store.sessionOverrides(
            providerID: provider,
            modelID: "model-a",
            conversationID: conversationA,
            profileFingerprint: "environment-a"
        ) == nil)
        #expect(store.sessionOverrides(
            providerID: provider,
            modelID: "model-a",
            conversationID: conversationB,
            profileFingerprint: "environment-a"
        )?.values["temperature"]?.value == .number(0.3))
        store.removeScopes(conversationID: conversationB)
        #expect(store.sessionOverrides(
            providerID: provider,
            modelID: "model-a",
            conversationID: conversationB,
            profileFingerprint: "environment-a"
        ) == nil)
    }

    @Test("Session Override Dot Ignores Dormant Values")
    func sessionOverrideDotIgnoresDormantValues() {
        let suiteName = "generation-parameter-dot-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID()
        let conversation = UUID()
        store.setSessionOverrides(
            .init(values: ["top_p": .init(state: .value, value: .number(0.8))]),
            providerID: provider,
            modelID: "model-a",
            conversationID: conversation
        )

        #expect(store.hasSessionOverrides(providerID: provider, modelID: "model-a", conversationID: conversation))
        #expect(store.hasSessionOverrides(
            providerID: provider,
            modelID: "model-a",
            conversationID: conversation,
            activeParameterIDs: ["top_p"]
        ))
        #expect(store.hasSessionOverrides(
            providerID: provider,
            modelID: "model-a",
            conversationID: conversation,
            activeParameterIDs: ["temperature"]
        ) == false)
    }

    @Test("connection defaults are portable and lower priority than model defaults")
    func connectionDefaultsArePortable() {
        let suiteName = "generation-parameter-connection-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let providerID = UUID()
        store.setConnectionDefaults(.init(values: [
            "temperature": .init(state: .value, value: .number(0.6)),
            "top_p": .init(state: .value, value: .number(0.8)),
        ]), providerID: providerID)
        store.setModelDefaults(.init(values: [
            "temperature": .init(state: .value, value: .number(0.2)),
        ]), providerID: providerID, modelID: "model-a")

        let modelA = store.resolve(
            transient: nil,
            providerID: providerID,
            modelID: "model-a",
            conversationID: UUID()
        )
        #expect(modelA?.values["temperature"]?.value == .number(0.2))
        #expect(modelA?.values["top_p"]?.value == .number(0.8))
        #expect(store.resolve(
            transient: nil,
            providerID: providerID,
            modelID: "model-b",
            conversationID: UUID()
        )?.values["temperature"]?.value == .number(0.6))
    }

    @Test("presets remain model/profile bound and exclude runtime settings")
    func presetsAreIsolated() {
        let suiteName = "generation-parameter-preset-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterPresetStore(defaults: defaults)
        let providerID = UUID()
        let preset = store.save(
            name: "Precise",
            providerID: providerID,
            modelID: "model-a",
            profileFingerprint: "profile-a",
            values: .init(values: [
                "temperature": .init(state: .value, value: .number(0.2)),
                "context_length": .init(state: .value, value: .number(32_768)),
            ])
        )
        #expect(preset.values.values["context_length"] == nil)
        #expect(store.list(providerID: providerID, modelID: "model-a", profileFingerprint: "profile-a").count == 1)
        #expect(store.apply(preset, providerID: providerID, modelID: "model-b", profileFingerprint: "profile-b") == nil)
        #expect(store.apply(
            preset,
            providerID: providerID,
            modelID: "model-b",
            profileFingerprint: "profile-b",
            semanticMapping: ["temperature": "sampling_temperature"]
        )?.values["sampling_temperature"]?.value == .number(0.2))
        #expect(store.list(
            providerID: providerID,
            modelID: "model-b",
            profileFingerprint: "profile-b",
            portableParameterIDs: ["temperature"]
        ) == [preset])
        #expect(store.list(
            providerID: providerID,
            modelID: "model-b",
            profileFingerprint: "profile-b",
            portableParameterIDs: ["top_p"]
        ).isEmpty)
        store.removeScopes(providerID: providerID, modelID: "model-a")
        #expect(store.list(providerID: providerID, modelID: "model-a", profileFingerprint: "profile-a").isEmpty)
    }

    @Test("shared sync fixture merges deterministically and omits sensitive values")
    func syncContractIsPortableAndPrivate() throws {
        let suiteName = "generation-parameter-sync-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = GenerationParameterSettingsStore(defaults: defaults)
        let presets = GenerationParameterPresetStore(defaults: defaults)
        let fixture = try JSONDecoder().decode(SyncFixture.self, from: Data(contentsOf: Self.syncFixtureURL()))

        let merged = GenerationParameterSyncContract.merge(
            fixture.payload,
            settings: settings,
            presets: presets,
            defaults: defaults
        )
        #expect(merged.records.count == 2)
        #expect(merged.presets.count == 1)
        let providerID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        #expect(settings.modelDefaults(
            providerID: providerID,
            modelID: "gpt-test",
            profileFingerprint: "different|openai_chat_completions||gpt-test"
        )?.values["temperature"]?.value == .number(0.4))

        settings.setModelDefaults(.init(values: [
            "temperature": .init(state: .value, value: .number(0.3)),
            "context_length": .init(state: .value, value: .number(32_768)),
            "stop": .init(state: .value, value: .stringList(["private prompt"])),
            "json_schema": .init(state: .value, value: .string("private")),
            "custom_secret": .init(state: .value, value: .string("secret")),
        ]), providerID: UUID(), modelID: "model-b", profileFingerprint: "ep_private|openai_chat_completions||model-b")
        let exported = try String(decoding: GenerationParameterSyncContract.exportJSON(
            settings: settings,
            presets: presets,
            defaults: defaults
        ), as: UTF8.self)
        #expect(exported.contains("temperature"))
        #expect(!exported.contains("ep_private"))
        #expect(!exported.contains("context_length"))
        #expect(!exported.contains("private prompt"))
        #expect(!exported.contains("json_schema"))
        #expect(!exported.contains("custom_secret"))

        let recordID = fixture.payload.records[0].recordId
        let deleted = GenerationParameterSyncContract.merge(
            .init(schemaVersion: 1, records: [], presets: [], tombstones: [
                .init(recordId: recordID, revision: 4, mutationId: "device-z"),
            ]),
            settings: settings,
            presets: presets,
            defaults: defaults
        )
        #expect(!deleted.records.contains { $0.recordId == recordID })
        let staleReplay = GenerationParameterSyncContract.merge(
            fixture.payload,
            settings: settings,
            presets: presets,
            defaults: defaults
        )
        #expect(!staleReplay.records.contains { $0.recordId == recordID })
    }


    private struct IDCasingFixture: Decodable {
        struct CanonicalCase: Decodable { let caseId: String; let input: String; let canonical: String }
        struct RecordIDCase: Decodable {
            let caseId: String
            let scope: String
            let providerId: String
            let modelId: String?
            let conversationId: String?
            let recordId: String
        }
        let canonicalCases: [CanonicalCase]
        let recordIdCases: [RecordIDCase]
    }

    private struct CasingFixtureRoot: Decodable { let idCasing: IDCasingFixture }

    private static let upperProvider = "9A1195DE-3AF9-5888-ABC8-B8177C458C07"
    private static let upperConversation = "7C9E6679-7425-40DE-944B-E07FC1F90AE7"

    @Test("export merge writeback loop keeps local settings readable")
    func syncLoopKeepsLocalScopesReadable() throws {
        let suiteName = "generation-parameter-loop-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = GenerationParameterSettingsStore(defaults: defaults)
        let presets = GenerationParameterPresetStore(defaults: defaults)
        let providerID = try #require(UUID(uuidString: Self.upperProvider))
        let conversationID = try #require(UUID(uuidString: Self.upperConversation))

        settings.setModelDefaults(.init(values: ["temperature": .init(state: .value, value: .number(0.4))]),
                                  providerID: providerID, modelID: "gpt-test")
        settings.setConnectionDefaults(.init(values: ["top_p": .init(state: .value, value: .number(0.8))]),
                                       providerID: providerID)
        settings.setSessionOverrides(.init(values: ["top_k": .init(state: .value, value: .number(40))]),
                                     providerID: providerID, modelID: "gpt-test", conversationID: conversationID)

        let wire = GenerationParameterSyncContract.exportPayload(
            settings: settings, presets: presets, defaults: defaults
        )
        #expect(wire.records.allSatisfy { $0.providerId == Self.upperProvider.lowercased() })
        #expect(wire.records.allSatisfy { $0.recordId == $0.recordId.lowercased() })
        _ = GenerationParameterSyncContract.merge(wire, settings: settings, presets: presets, defaults: defaults)

        #expect(settings.modelDefaults(providerID: providerID, modelID: "gpt-test")?
            .values["temperature"]?.value == .number(0.4))
        #expect(settings.connectionDefaults(providerID: providerID)?.values["top_p"]?.value == .number(0.8))
        let resolved = settings.resolve(transient: nil, providerID: providerID,
                                        modelID: "gpt-test", conversationID: conversationID)
        #expect(resolved?.values["top_k"]?.value == .number(40))
        #expect(resolved?.values["temperature"]?.value == .number(0.4))
        #expect(resolved?.values["top_p"]?.value == .number(0.8))
    }

    @Test("no-op sync preserves scope and preset updatedAt; a new remote winner advances it")
    func noOpSyncPreservesLocalTimestamps() throws {
        let suiteName = "generation-parameter-timestamp-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = GenerationParameterSettingsStore(defaults: defaults)
        let presets = GenerationParameterPresetStore(defaults: defaults)
        let providerID = UUID()

        settings.setModelDefaults(
            .init(values: ["temperature": .init(state: .value, value: .number(0.4))]),
            providerID: providerID,
            modelID: "gpt-test",
            profileFingerprint: "endpoint|openai_chat_completions||gpt-test"
        )
        _ = presets.save(
            name: "Precise",
            providerID: providerID,
            modelID: "gpt-test",
            profileFingerprint: "endpoint|openai_chat_completions||gpt-test",
            values: .init(values: ["temperature": .init(state: .value, value: .number(0.4))])
        )

        let oldButLive = Date().addingTimeInterval(-179 * 24 * 60 * 60)
        let encodedOld = oldButLive.timeIntervalSinceReferenceDate
        let settingsKey = "generation_parameter_settings.v1"
        let presetsKey = "generation_parameter_presets.v1"
        let settingsData = try #require(defaults.data(forKey: settingsKey))
        var rawScopes = try #require(
            JSONSerialization.jsonObject(with: settingsData) as? [[String: Any]]
        )
        rawScopes[0]["updatedAt"] = encodedOld
        defaults.set(try JSONSerialization.data(withJSONObject: rawScopes), forKey: settingsKey)
        let presetData = try #require(defaults.data(forKey: presetsKey))
        var rawPresets = try #require(
            JSONSerialization.jsonObject(with: presetData) as? [[String: Any]]
        )
        rawPresets[0]["updatedAt"] = encodedOld - 1
        defaults.set(try JSONSerialization.data(withJSONObject: rawPresets), forKey: presetsKey)

        let wire = GenerationParameterSyncContract.exportPayload(
            settings: settings, presets: presets, defaults: defaults
        )
        _ = GenerationParameterSyncContract.merge(
            wire, settings: settings, presets: presets, defaults: defaults
        )
        let afterNoOpSettingsData = try #require(defaults.data(forKey: settingsKey))
        let afterNoOpScopes = try #require(
            JSONSerialization.jsonObject(with: afterNoOpSettingsData) as? [[String: Any]]
        )
        let afterNoOpPresetData = try #require(defaults.data(forKey: presetsKey))
        let afterNoOpPresets = try #require(
            JSONSerialization.jsonObject(with: afterNoOpPresetData) as? [[String: Any]]
        )
        #expect((afterNoOpScopes[0]["updatedAt"] as? NSNumber)?.doubleValue == encodedOld)
        #expect((afterNoOpPresets[0]["updatedAt"] as? NSNumber)?.doubleValue == encodedOld - 1)
        #expect(settings.modelDefaults(providerID: providerID, modelID: "gpt-test")?
            .values["temperature"]?.value == .number(0.4))

        let current = try #require(wire.records.first)
        let newer = GenerationParameterSyncRecord(
            recordId: current.recordId,
            scope: current.scope,
            providerId: current.providerId,
            modelId: current.modelId,
            conversationId: current.conversationId,
            profileKey: current.profileKey,
            values: ["temperature": .init(state: .value, value: .number(0.9))],
            revision: current.revision + 1,
            mutationId: "remote-newer"
        )
        _ = GenerationParameterSyncContract.merge(
            .init(schemaVersion: 1, records: [newer], presets: [], tombstones: []),
            settings: settings,
            presets: presets,
            defaults: defaults
        )
        let afterRemoteData = try #require(defaults.data(forKey: settingsKey))
        let afterRemote = try #require(
            JSONSerialization.jsonObject(with: afterRemoteData) as? [[String: Any]]
        )
        #expect((afterRemote[0]["updatedAt"] as? NSNumber)?.doubleValue ?? 0 > encodedOld)
        #expect(settings.modelDefaults(providerID: providerID, modelID: "gpt-test")?
            .values["temperature"]?.value == .number(0.9))
    }

    @Test("day 181 same-version replay stays expired; a higher revision refreshes TTL")
    func expiredScopeDoesNotReviveOnSameVersionReplay() throws {
        let suiteName = "generation-parameter-expired-sync-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = GenerationParameterSettingsStore(defaults: defaults)
        let presets = GenerationParameterPresetStore(defaults: defaults)
        let providerID = UUID()

        settings.setModelDefaults(
            .init(values: ["temperature": .init(state: .value, value: .number(0.4))]),
            providerID: providerID,
            modelID: "gpt-test",
            profileFingerprint: "endpoint|openai_chat_completions||gpt-test"
        )
        let sameVersionRemote = GenerationParameterSyncContract.exportPayload(
            settings: settings, presets: presets, defaults: defaults
        )
        let settingsKey = "generation_parameter_settings.v1"
        let settingsData = try #require(defaults.data(forKey: settingsKey))
        var rawScopes = try #require(
            JSONSerialization.jsonObject(with: settingsData) as? [[String: Any]]
        )
        let expiredAt = Date().addingTimeInterval(-181 * 24 * 60 * 60)
        let encodedExpired = expiredAt.timeIntervalSinceReferenceDate
        rawScopes[0]["updatedAt"] = encodedExpired
        defaults.set(try JSONSerialization.data(withJSONObject: rawScopes), forKey: settingsKey)

        #expect(settings.modelDefaults(providerID: providerID, modelID: "gpt-test") == nil)
        #expect(GenerationParameterSyncContract.exportPayload(
            settings: settings, presets: presets, defaults: defaults
        ).records.isEmpty)
        _ = GenerationParameterSyncContract.merge(
            sameVersionRemote, settings: settings, presets: presets, defaults: defaults
        )
        let afterReplayData = try #require(defaults.data(forKey: settingsKey))
        let afterReplay = try #require(
            JSONSerialization.jsonObject(with: afterReplayData) as? [[String: Any]]
        )
        #expect((afterReplay[0]["updatedAt"] as? NSNumber)?.doubleValue == encodedExpired)
        #expect(settings.modelDefaults(providerID: providerID, modelID: "gpt-test") == nil)
        #expect(GenerationParameterSyncContract.exportPayload(
            settings: settings, presets: presets, defaults: defaults
        ).records.isEmpty)

        let current = try #require(sameVersionRemote.records.first)
        let newer = GenerationParameterSyncRecord(
            recordId: current.recordId,
            scope: current.scope,
            providerId: current.providerId,
            modelId: current.modelId,
            conversationId: current.conversationId,
            profileKey: current.profileKey,
            values: ["temperature": .init(state: .value, value: .number(0.9))],
            revision: current.revision + 1,
            mutationId: "remote-new-fact"
        )
        _ = GenerationParameterSyncContract.merge(
            .init(schemaVersion: 1, records: [newer], presets: [], tombstones: []),
            settings: settings,
            presets: presets,
            defaults: defaults
        )
        #expect(settings.modelDefaults(providerID: providerID, modelID: "gpt-test")?
            .values["temperature"]?.value == .number(0.9))
        let afterNewFactData = try #require(defaults.data(forKey: settingsKey))
        let afterNewFact = try #require(
            JSONSerialization.jsonObject(with: afterNewFactData) as? [[String: Any]]
        )
        #expect((afterNewFact[0]["updatedAt"] as? NSNumber)?.doubleValue ?? 0 > encodedExpired)
    }

    @Test("record ids match the shared cross client fixture byte for byte")
    func recordIDsMatchSharedFixture() throws {
        let fixture = try JSONDecoder().decode(CasingFixtureRoot.self, from: Data(contentsOf: Self.syncFixtureURL()))

        for testCase in fixture.idCasing.canonicalCases {
            let suiteName = "generation-parameter-canonical-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let merged = GenerationParameterSyncContract.merge(
                .init(schemaVersion: 1, records: [], presets: [], tombstones: [
                    .init(recordId: testCase.input, revision: 1, mutationId: "device-canonical"),
                ]),
                settings: GenerationParameterSettingsStore(defaults: defaults),
                presets: GenerationParameterPresetStore(defaults: defaults),
                defaults: defaults
            )
            #expect(merged.tombstones.map(\.recordId) == [testCase.canonical], "\(testCase.caseId)")
        }

        for testCase in fixture.idCasing.recordIdCases {
            let suiteName = "generation-parameter-recordid-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let settings = GenerationParameterSettingsStore(defaults: defaults)
            let presets = GenerationParameterPresetStore(defaults: defaults)
            let providerID = try #require(UUID(uuidString: testCase.providerId))
            let values = GenerationParameterOverrides(values: ["temperature": .init(state: .value, value: .number(0.5))])
            switch testCase.scope {
            case "connection_default":
                settings.setConnectionDefaults(values, providerID: providerID)
            case "conversation_override":
                settings.setSessionOverrides(values, providerID: providerID,
                                             modelID: testCase.modelId ?? "",
                                             conversationID: try #require(UUID(uuidString: testCase.conversationId ?? "")))
            default:
                settings.setModelDefaults(values, providerID: providerID, modelID: testCase.modelId ?? "")
            }
            let exported = GenerationParameterSyncContract.exportPayload(
                settings: settings, presets: presets, defaults: defaults
            )
            #expect(exported.records.map(\.recordId) == [testCase.recordId], "\(testCase.caseId)")
        }
    }

    @Test("legacy uppercase remote record converges into one and stays deletable")
    func legacyUppercaseRecordConverges() throws {
        let suiteName = "generation-parameter-legacy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = GenerationParameterSettingsStore(defaults: defaults)
        let presets = GenerationParameterPresetStore(defaults: defaults)
        let providerID = try #require(UUID(uuidString: Self.upperProvider))

        settings.setModelDefaults(.init(values: ["temperature": .init(state: .value, value: .number(0.4))]),
                                  providerID: providerID, modelID: "gpt-test")
        let canonicalRecordID = try #require(GenerationParameterSyncContract.exportPayload(
            settings: settings, presets: presets, defaults: defaults
        ).records.first?.recordId)
        let legacyRecordID = "scope:model:\(Self.upperProvider):gpt-test"
        #expect(legacyRecordID != canonicalRecordID)

        func legacyRemote(_ revision: Int) -> GenerationParameterSyncPayload {
            .init(schemaVersion: 1, records: [
                .init(recordId: legacyRecordID, scope: "model_default", providerId: Self.upperProvider,
                      modelId: "gpt-test", conversationId: nil, profileKey: nil,
                      values: ["temperature": .init(state: .value, value: .number(0.9))],
                      revision: revision, mutationId: "device-legacy"),
            ], presets: [], tombstones: [])
        }

        let merged = GenerationParameterSyncContract.merge(
            legacyRemote(5), settings: settings, presets: presets, defaults: defaults
        )
        #expect(merged.records.count == 1)
        #expect(merged.records.first?.recordId == canonicalRecordID)
        #expect(settings.modelDefaults(providerID: providerID, modelID: "gpt-test")?
            .values["temperature"]?.value == .number(0.9))

        let deleted = GenerationParameterSyncContract.merge(
            .init(schemaVersion: 1, records: [], presets: [], tombstones: [
                .init(recordId: legacyRecordID, revision: 6, mutationId: "device-legacy-delete"),
            ]),
            settings: settings, presets: presets, defaults: defaults
        )
        #expect(deleted.records.isEmpty)
        #expect(settings.modelDefaults(providerID: providerID, modelID: "gpt-test") == nil)

        let replay = GenerationParameterSyncContract.merge(
            legacyRemote(5), settings: settings, presets: presets, defaults: defaults
        )
        #expect(replay.records.isEmpty)
    }

    private static func syncFixtureURL() -> URL {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while current.path != "/" {
            let candidate = current
                .appendingPathComponent("shared")
                .appendingPathComponent("model-contracts")
                .appendingPathComponent("generation_parameter_sync.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            current.deleteLastPathComponent()
        }
        preconditionFailure("Unable to locate generation_parameter_sync.v1.json")
    }

    @Test("runtime parser preserves unavailable values as nil from production response parsing")
    func runtimeMeasurementsStayOptional() {
        let payload: [[String: Any]] = [["id": 0, "n_past": 128, "n_ctx": 4096]]
        let snapshot = LocalRuntimeParser.snapshot(
            engine: .llamacpp,
            statusJSON: payload,
            metricsText: "llamacpp:requests_waiting 2\n"
        )
        #expect(snapshot.contextUsed == 128)
        #expect(snapshot.contextLimit == 4096)
        #expect(snapshot.queueDepth == 2)
        #expect(snapshot.cpuPercent == nil)
        #expect(snapshot.gpuPercent == nil)
        #expect(snapshot.tokensPerSecond == nil)
    }

    @Test("local runtime preflight uses apply-template then tokenize and detects context overflow")
    func localRuntimePreflightUsesProductionEndpoints() async throws {
        var paths: [String] = []
        LocalRuntimeMockURLProtocol.requestHandler = { request in
            paths.append(request.url?.path ?? "")
            #expect(request.value(forHTTPHeaderField: relaySecurityModeHeader) == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let body: String
            switch request.url?.path {
            case "/apply-template": body = #"{"prompt":"templated prompt"}"#
            case "/tokenize": body = #"{"tokens":[1,2,3,4,5]}"#
            default: body = #"{}"#
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                Data(body.utf8)
            )
        }
        defer { LocalRuntimeMockURLProtocol.requestHandler = nil }

        let result = await LocalEngineRuntimeClient.preflight(
            endpoint: URL(string: "http://127.0.0.1:8080")!,
            engine: .llamacpp,
            prompt: "hello",
            contextLimit: 4,
            requested: localRuntimeSecurityConfig(),
            session: makeLocalRuntimeSession()
        )

        #expect(result == .supported(tokens: 5, contextLimit: 4, exceedsContext: true))
        #expect(paths == ["/apply-template", "/tokenize"])
    }

    @Test("local runtime status sends every probe through the secured executor")
    func localRuntimeStatusUsesProductionExecutor() async throws {
        var paths: [String] = []
        LocalRuntimeMockURLProtocol.requestHandler = { request in
            paths.append(request.url?.path ?? "")
            #expect(request.value(forHTTPHeaderField: relaySecurityModeHeader) == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let body = request.url?.path == "/slots"
                ? #"[{"n_ctx":4096}]"#
                : "llamacpp:prompt_tokens_total 12\n"
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: "HTTP/1.1", headerFields: nil
                )!,
                Data(body.utf8)
            )
        }
        defer { LocalRuntimeMockURLProtocol.requestHandler = nil }

        _ = await LocalEngineRuntimeClient.status(
            endpoint: URL(string: "http://127.0.0.1:8080")!,
            engine: .llamacpp,
            requested: localRuntimeSecurityConfig(),
            session: makeLocalRuntimeSession()
        )

        #expect(Set(paths) == ["/slots", "/metrics"])
    }

    @Test("preflight failure degrades to unavailable and prompt cache uses the slot action endpoint")
    func localRuntimeDegradesAndStoresPromptCache() async throws {
        LocalRuntimeMockURLProtocol.requestHandler = { request in
            if request.url?.path == "/apply-template" {
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
            #expect(request.url?.path == "/slots/3")
            #expect(request.url?.query?.contains("action=save") == true)
            #expect(request.url?.query?.contains("filename=chat-cache") == true)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{}"#.utf8))
        }
        defer { LocalRuntimeMockURLProtocol.requestHandler = nil }
        let session = makeLocalRuntimeSession()
        let unavailable = await LocalEngineRuntimeClient.preflight(
            endpoint: URL(string: "http://127.0.0.1:8080")!, engine: .llamacpp,
            prompt: "hello", contextLimit: nil,
            requested: localRuntimeSecurityConfig(), session: session
        )
        #expect(unavailable == .unavailable)
        try await LocalEngineRuntimeClient.promptCache(
            endpoint: URL(string: "http://127.0.0.1:8080")!, slotID: 3,
            action: "save", cacheName: "chat-cache",
            requested: localRuntimeSecurityConfig(), session: session
        )
    }

    @Test("local discovery has an explicit cancellable lifecycle and no upload path")
    func discoveryPrivacyContract() {
        let session = LocalEngineDiscoverySession()
        #expect(session.isActive == false)
        session.cancel()
        #expect(session.isActive == false)
        #expect(LocalEngineDiscoverySession.uploadsResults == false)
    }

    @Test("Open WebUI and local retrieval capability candidates remain formal contract entries")
    func localCapabilityContracts() throws {
        let openWebUI = try #require(LocalEngineTemplate.all[.openwebui])
        #expect(openWebUI.catalogPath == "/api/models")
        #expect(openWebUI.generationPaths == ["/api/chat/completions"])
        #expect(openWebUI.capabilityPaths["embedding"] == ["/api/embeddings"])
        #expect(LocalEngineTemplate.all[.llamacpp]?.capabilityPaths["rerank"] == ["/rerank", "/v1/rerank"])
        let fingerprint = LocalRuntimeSettingsStore.fingerprint(endpoint: "http://secret-box.local:8080", engine: .llamacpp)
        #expect(!fingerprint.contains("secret-box"))
    }

    @Test("Capability Display Read Preserves Existing Default")
    func capabilityDisplayReadPreservesExistingDefault() {
        let suiteName = "capability-display-read-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID()
        let identity = Self.runtimeIdentity("responses")
        let persisted = UUID()
        let untouched = UUID()

        store.setCapabilityPreferences(
            .init(web: .automatic, reasoningIntent: "off"), providerID: provider, modelID: "model",
            conversationID: persisted, transportIdentity: identity
        )

        let existing = store.displayCapabilityPreferences(
            providerID: provider, modelID: "model", conversationID: persisted,
            skillID: nil, transportIdentity: identity
        )
        #expect(existing.web == .automatic)
        #expect(existing.reasoningIntent == "off")

        let untouchedValues = store.displayCapabilityPreferences(
            providerID: provider, modelID: "model", conversationID: untouched,
            skillID: nil, transportIdentity: identity
        )
        #expect(untouchedValues.web == .off)
        #expect(untouchedValues.reasoningIntent == nil)

        #expect(store.capabilityPreferences(
            providerID: provider, modelID: "model", conversationID: untouched,
            transportIdentity: identity
        ) == nil)

        #expect(store.capabilityPreferences(
            providerID: provider, modelID: "model", conversationID: persisted,
            transportIdentity: "responses"
        ) == nil)
    }

    @Test("typed capability sync is transport-isolated and excludes local JSON")
    func capabilityPreferenceSyncExcludesLocalCustomFragment() {
        let suiteName = "capability-preference-sync-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID()
        let conversation = UUID()
        store.setCapabilityPreferences(
            .init(web: .force, reasoningIntent: "off"), providerID: provider, modelID: "same-model",
            conversationID: conversation, transportIdentity: Self.runtimeIdentity("openai_responses")
        )
        store.setLocalCustomFragment(
            #"{"tools":["private"]}"#, providerID: provider, modelID: "same-model",
            conversationID: conversation, transportIdentity: "openai_responses", namespace: "webPatch"
        )

        let payload = CapabilityPreferenceSyncContract.exportPayload(settings: store)
        #expect(payload.schemaVersion == 2)
        #expect(payload.records.count == 1)
        #expect(payload.records[0].scope == "conversation_connection_model")
        #expect(payload.records[0].transportIdentity == Self.runtimeIdentity("openai_responses"))
        #expect(
            CapabilityPreferenceRuntimeIdentity.decode(payload.records[0].transportIdentity)?.finalTransport
                == "openai_responses"
        )
        #expect(payload.records[0].web == .force)
        #expect(payload.records[0].reasoningIntent == "off")
        let encoded = try! JSONEncoder().encode(payload)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("private"))
        #expect(store.capabilityPreferences(
            providerID: provider, modelID: "same-model", conversationID: conversation,
            transportIdentity: Self.runtimeIdentity("anthropic_messages")
        ) == nil)
    }

    @Test("skill confirmation is typed sync scope and absent marker inherits")
    func skillCapabilityConfirmationRoundTrips() {
        let suiteName = "capability-skill-sync-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID()
        let skill = UUID()
        #expect(store.capabilityPreferences(
            providerID: provider, modelID: "model", conversationID: nil, skillID: skill,
            transportIdentity: Self.runtimeIdentity("responses")
        ) == nil)
        store.confirmSkillAgentCapabilityPreferences(
            .init(web: .automatic, reasoningIntent: "off"), skillID: skill,
            providerID: provider, modelID: "model", transportIdentity: Self.runtimeIdentity("responses")
        )
        let payload = CapabilityPreferenceSyncContract.exportPayload(settings: store)
        #expect(payload.records.first?.scope == "skill_agent")
        #expect(payload.records.first?.skillId == skill.uuidString.lowercased())
        let remote = GenerationParameterSettingsStore(defaults: UserDefaults(suiteName: "capability-skill-remote-\(UUID().uuidString)")!)
        _ = CapabilityPreferenceSyncContract.merge(payload, settings: remote)
        #expect(remote.capabilityPreferences(
            providerID: provider, modelID: "model", conversationID: nil, skillID: skill,
            transportIdentity: Self.runtimeIdentity("responses")
        )?.reasoningIntent == "off")
    }

    @Test("deleting typed scope exports a tombstone that prevents remote resurrection")
    func capabilityPreferenceDeletionTombstoneWins() {
        let suiteName = "capability-tombstone-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID()
        let conversation = UUID()
        store.setCapabilityPreferences(
            .init(web: .force, reasoningIntent: "off"), providerID: provider, modelID: "model",
            conversationID: conversation, transportIdentity: Self.runtimeIdentity("responses")
        )
        let oldRemote = CapabilityPreferenceSyncContract.exportPayload(settings: store)
        store.removeCapabilityScopes(conversationID: conversation)
        let deleted = CapabilityPreferenceSyncContract.exportPayload(settings: store)
        #expect(deleted.records.isEmpty)
        #expect(!(deleted.tombstones ?? []).isEmpty)
        let merged = CapabilityPreferenceSyncContract.merge(oldRemote, settings: store)
        #expect(merged.records.isEmpty)
        #expect(store.capabilityPreferences(
            providerID: provider, modelID: "model", conversationID: conversation, transportIdentity: Self.runtimeIdentity("responses")
        ) == nil)
    }

    @Test("ORIVEO-APP-2M: capability wire keeps a fixed top level, omits nil fields, and reads legacy Android envelopes")
    func capabilityWireInvariantsHold() throws {
        let contract = try JSONSerialization.jsonObject(
            with: Data(contentsOf: Self.capabilitySyncFixtureURL())
        ) as? [String: Any]
        let invariants = try #require(contract?["wireInvariants"] as? [String: Any])
        let expectedKeys = try #require(
            (invariants["alwaysPresentTopLevelKeys"] as? [String: Any])?["keys"] as? [String]
        )
        let omitWhenNull = try #require((invariants["omitWhenNull"] as? [String: Any])?["recordFields"] as? [String])

        let empty = try #require(CapabilityPreferenceSyncContract.foundationValue(
            .init(schemaVersion: 2, records: [], tombstones: [])
        ))
        #expect(Set(empty.keys) == Set(expectedKeys))

        let fixturePayload = try #require(contract?["payload"])
        let decodedFixture = try #require(CapabilityPreferenceSyncContract.decodeFirestore(fixturePayload))
        let reEncoded = try #require(CapabilityPreferenceSyncContract.foundationValue(decodedFixture))
        let connectionRecord = try #require(
            (reEncoded["records"] as? [[String: Any]])?.first { ($0["scope"] as? String) == "connection" }
        )
        for field in omitWhenNull {
            #expect(connectionRecord[field] == nil)
        }

        let legacyEnvelope: [String: Any] = [
            "records": [],
            "tombstones": [[
                "recordId": "scope:model:9a1195de-3af9-5888-abc8-b8177c458c07:legacy-model:r1.b3BlbmFpX2NoYXQ.cnVudGltZS1yNw",
                "revision": 2,
                "mutationId": "00000000-0000-4000-8000-000000000107",
            ]],
        ]
        let legacy = try #require(CapabilityPreferenceSyncContract.decodeFirestore(legacyEnvelope))
        #expect(legacy.schemaVersion == 2)
        #expect(legacy.tombstones?.count == 1)
    }

    @Test("ORIVEO-APP-2M: capability tombstone wire order is code-point order across the ~/z boundary")
    func capabilityTombstoneWireOrderIsCodePointOrdered() {
        let suiteName = "capability-wire-order-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID()
        let conversation = UUID()
        for model in ["~deepseek/deepseek-v4-flash", "z-ai/glm-5", "cohere/north-mini"] {
            store.setCapabilityPreferences(
                .init(web: .force, reasoningIntent: "off"), providerID: provider, modelID: model,
                conversationID: conversation, transportIdentity: Self.runtimeIdentity("responses")
            )
        }
        store.removeCapabilityScopes(conversationID: conversation)
        let tombstones = (CapabilityPreferenceSyncContract.exportPayload(settings: store).tombstones ?? [])
            .map(\.recordId)
        #expect(tombstones.count == 3)
        #expect(tombstones[0].contains(":cohere/"))
        #expect(tombstones[1].contains(":z-ai/"))
        #expect(tombstones[2].contains(":~deepseek/"))
    }

    @Test("process-local typed preferences never enter ChatCapabilitySelection Codable")
    func typedCapabilitySelectionDoesNotPersist() throws {
        var selection = ChatCapabilitySelection(reasoningMode: .automatic, webSearchEnabled: true)
        selection.typedPreferences = .init(web: .force, reasoningIntent: "off")
        let encoded = String(decoding: try JSONEncoder().encode(selection), as: UTF8.self)
        #expect(!encoded.contains("typedPreferences"))
        #expect(try JSONDecoder().decode(ChatCapabilitySelection.self, from: Data(encoded.utf8)).typedPreferences == nil)
    }

    @Test("raw custom fragments and retry disposition never enter a persisted request")
    func rawCustomFragmentNeverPersistsWithRequestOptions() throws {
        var options = ChatRequestOptions(systemPrompt: "brief")
        options.localSafeCustomBodyFragment = .init(
            raw: #"{"temperature":0.7}"#, owner: "generation", declaredOwners: ["/temperature": "generation"]
        )
        options.localCustomFragmentDisposition = .omitForExplicitRetry
        let encoded = String(decoding: try JSONEncoder().encode(options), as: UTF8.self)
        #expect(!encoded.contains("temperature"))
        #expect(!encoded.contains("omitForExplicitRetry"))
        let decoded = try JSONDecoder().decode(ChatRequestOptions.self, from: Data(encoded.utf8))
        #expect(decoded.localSafeCustomBodyFragment == nil)
        #expect(decoded.localCustomFragmentDisposition == .include)
    }

    @Test("disabling custom mode preserves an existing fragment until confirmed")
    func customModeRequiresExplicitDiscardConfirmation() {
        #expect(LocalCustomFragmentModeChange.requiresDiscardConfirmation(
            previousEnabled: true, newEnabled: false, raw: #"{"temperature":0.7}"#
        ))
        #expect(!LocalCustomFragmentModeChange.requiresDiscardConfirmation(
            previousEnabled: true, newEnabled: false, raw: "  \n"
        ))
        #expect(!LocalCustomFragmentModeChange.requiresDiscardConfirmation(
            previousEnabled: false, newEnabled: false, raw: #"{"temperature":0.7}"#
        ))
    }

    @Test("custom-only draft migrates locally without creating typed sync state")
    func customOnlyDraftMigratesToConversation() {
        let defaults = UserDefaults(suiteName: "capability-custom-draft-\(UUID().uuidString)")!
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID(), draft = UUID(), conversation = UUID()
        store.setLocalCustomFragment(
            #"{"private":true}"#, providerID: provider, modelID: "model", conversationID: draft,
            transportIdentity: "responses", namespace: "webPatch"
        )
        store.migrateCapabilitySession(
            providerID: provider, modelID: "model", from: draft, to: conversation,
            transportIdentity: "responses"
        )
        #expect(store.localCustomFragment(
            providerID: provider, modelID: "model", conversationID: conversation,
            transportIdentity: "responses", namespace: "webPatch"
        ) == #"{"private":true}"#)
        #expect(CapabilityPreferenceSyncContract.exportPayload(settings: store).records.isEmpty)
    }

    @Test("three local owner modes remain independent and never sync")
    func threeOwnerCustomModesRemainIndependent() {
        let suiteName = "capability-custom-modes-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID(), conversation = UUID()
        for namespace in ["webPatch", "reasoningPatch", "generationPatch"] {
            store.setLocalCustomConfiguration(
                .init(mode: namespace == "reasoningPatch" ? .automatic : .custom, rawJSON: "{\"owner\":\"\(namespace)\"}"),
                providerID: provider, modelID: "model", conversationID: conversation,
                transportIdentity: "responses", namespace: namespace
            )
        }
        #expect(store.localCustomConfiguration(
            providerID: provider, modelID: "model", conversationID: conversation,
            transportIdentity: "responses", namespace: "webPatch"
        ).mode == .custom)
        #expect(store.localCustomConfiguration(
            providerID: provider, modelID: "model", conversationID: conversation,
            transportIdentity: "responses", namespace: "reasoningPatch"
        ).mode == .automatic)
        #expect(store.localCustomConfiguration(
            providerID: provider, modelID: "model", conversationID: conversation,
            transportIdentity: "responses", namespace: "generationPatch"
        ).mode == .custom)
        #expect(CapabilityPreferenceSyncContract.exportPayload(settings: store).records.isEmpty)
    }

    @Test("draft-scope custom fragments follow the conversation on first send")
    func migratesLocalCustomConfigurationFromDraftScope() {
        let suiteName = "capability-custom-migrate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID(), draft = UUID(), conversation = UUID()

        store.setLocalCustomConfiguration(
            .init(mode: .custom, rawJSON: #"{"enable_search":true}"#),
            providerID: provider, modelID: "model", conversationID: draft,
            transportIdentity: "responses", namespace: "webPatch"
        )
        store.migrateLocalCustomConfiguration(
            providerID: provider, modelID: "model", from: draft, to: conversation,
            transportIdentity: "responses"
        )

        let moved = store.localCustomConfiguration(
            providerID: provider, modelID: "model", conversationID: conversation,
            transportIdentity: "responses", namespace: "webPatch"
        )
        #expect(moved.mode == .custom)
        #expect(moved.rawJSON == #"{"enable_search":true}"#)
        #expect(store.localCustomConfiguration(
            providerID: provider, modelID: "model", conversationID: draft,
            transportIdentity: "responses", namespace: "webPatch"
        ).rawJSON.isEmpty)
    }

    @Test("an existing conversation-scope fragment outranks the draft it migrates into")
    func migrationNeverOverwritesExistingConversationScope() {
        let suiteName = "capability-custom-migrate-conflict-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID(), draft = UUID(), conversation = UUID()

        store.setLocalCustomConfiguration(
            .init(mode: .custom, rawJSON: #"{"from":"draft"}"#),
            providerID: provider, modelID: "model", conversationID: draft,
            transportIdentity: "responses", namespace: "webPatch"
        )
        store.setLocalCustomConfiguration(
            .init(mode: .custom, rawJSON: #"{"from":"conversation"}"#),
            providerID: provider, modelID: "model", conversationID: conversation,
            transportIdentity: "responses", namespace: "webPatch"
        )
        store.migrateLocalCustomConfiguration(
            providerID: provider, modelID: "model", from: draft, to: conversation,
            transportIdentity: "responses"
        )

        #expect(store.localCustomConfiguration(
            providerID: provider, modelID: "model", conversationID: conversation,
            transportIdentity: "responses", namespace: "webPatch"
        ).rawJSON == #"{"from":"conversation"}"#)
    }

    @Test("Retired Gate Migration Disarms Custom When Gate Was Off")
    func retiredGateMigrationDisarmsCustomWhenGateWasOff() {
        let suiteName = "capability-custom-gate-migration-off-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = UUID(), conversation = UUID()

        let legacyKey = "capability_preference_local_custom_developer_mode.v1"
        let seed = GenerationParameterSettingsStore(defaults: defaults)
        seed.setLocalCustomConfiguration(
            .init(mode: .custom, rawJSON: #"{"enable_search":true}"#),
            providerID: provider, modelID: "model", conversationID: conversation,
            transportIdentity: "qwen_chat", namespace: "webPatch"
        )
        defaults.set(false, forKey: legacyKey)

        let migrated = GenerationParameterSettingsStore(defaults: defaults)
        #expect(defaults.object(forKey: legacyKey) == nil)
        let configuration = migrated.localCustomConfiguration(
            providerID: provider, modelID: "model", conversationID: conversation,
            transportIdentity: "qwen_chat", namespace: "webPatch"
        )
        #expect(configuration.mode == .automatic)
        #expect(configuration.rawJSON == #"{"enable_search":true}"#)
        #expect(migrated.activeLocalCustomFragments(
            providerID: provider, modelID: "model", conversationID: conversation,
            transportIdentity: "qwen_chat"
        ).isEmpty)

        let again = GenerationParameterSettingsStore(defaults: defaults)
        #expect(again.localCustomConfiguration(
            providerID: provider, modelID: "model", conversationID: conversation,
            transportIdentity: "qwen_chat", namespace: "webPatch"
        ) == configuration)
    }

    @Test("Retired Gate Migration Keeps Custom When Gate Was On")
    func retiredGateMigrationKeepsCustomWhenGateWasOn() {
        let suiteName = "capability-custom-gate-migration-on-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = UUID(), conversation = UUID()

        let legacyKey = "capability_preference_local_custom_developer_mode.v1"
        let seed = GenerationParameterSettingsStore(defaults: defaults)
        seed.setLocalCustomConfiguration(
            .init(mode: .custom, rawJSON: #"{"enable_search":true}"#),
            providerID: provider, modelID: "model", conversationID: conversation,
            transportIdentity: "qwen_chat", namespace: "webPatch"
        )
        seed.setLocalCustomConfiguration(
            .init(mode: .custom, rawJSON: ""), providerID: provider, modelID: "model",
            conversationID: conversation, transportIdentity: "qwen_chat", namespace: "generationPatch"
        )
        defaults.set(true, forKey: legacyKey)

        let migrated = GenerationParameterSettingsStore(defaults: defaults)
        #expect(defaults.object(forKey: legacyKey) == nil)
        let fragments = migrated.activeLocalCustomFragments(
            providerID: provider, modelID: "model", conversationID: conversation,
            transportIdentity: "qwen_chat"
        )
        #expect(fragments.map(\.owner) == ["web", "generation"])
        #expect(fragments.last?.raw.isEmpty == true)
    }

    @Test("Fresh Install Skips Migration And Sends Custom Without Any Gate")
    func freshInstallSkipsMigrationAndSendsCustomWithoutAnyGate() {
        let suiteName = "capability-custom-no-gate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID(), conversation = UUID()

        store.setLocalCustomConfiguration(
            .init(mode: .custom, rawJSON: #"{"enable_search":true}"#),
            providerID: provider, modelID: "model", conversationID: conversation,
            transportIdentity: "qwen_chat", namespace: "webPatch"
        )
        #expect(store.activeLocalCustomFragments(
            providerID: provider, modelID: "model", conversationID: conversation,
            transportIdentity: "qwen_chat"
        ).map(\.owner) == ["web"], "After the master switch is gone, custom must go outbound from mode alone")
        store.setLocalCustomConfiguration(
            .init(mode: .automatic, rawJSON: #"{"enable_search":true}"#),
            providerID: provider, modelID: "model", conversationID: conversation,
            transportIdentity: "qwen_chat", namespace: "webPatch"
        )
        #expect(store.activeLocalCustomFragments(
            providerID: provider, modelID: "model", conversationID: conversation,
            transportIdentity: "qwen_chat"
        ).isEmpty)
        #expect(CapabilityPreferenceSyncContract.exportPayload(settings: store).records.isEmpty)
    }

    @Test("unconfirming Skill creates a tombstone that defeats old remote record")
    func skillUnconfirmPreventsRemoteResurrection() {
        let defaults = UserDefaults(suiteName: "capability-skill-delete-\(UUID().uuidString)")!
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID(), skill = UUID()
        store.confirmSkillAgentCapabilityPreferences(
            .init(web: .automatic, reasoningIntent: nil), skillID: skill,
            providerID: provider, modelID: "model", transportIdentity: Self.runtimeIdentity("responses")
        )
        let oldRemote = CapabilityPreferenceSyncContract.exportPayload(settings: store)
        #expect(oldRemote.records.count == 1)
        store.setCapabilityPreferences(
            nil, providerID: provider, modelID: "model", conversationID: nil, skillID: skill,
            transportIdentity: Self.runtimeIdentity("responses")
        )
        let merged = CapabilityPreferenceSyncContract.merge(oldRemote, settings: store)
        #expect(merged.records.isEmpty)
        #expect(store.capabilityPreferences(
            providerID: provider, modelID: "model", conversationID: nil, skillID: skill,
            transportIdentity: Self.runtimeIdentity("responses")
        ) == nil)
    }

    @Test("reconfirming a Skill outranks its own tombstone in the typed envelope")
    func skillReconfirmSupersedesTombstone() {
        let defaults = UserDefaults(suiteName: "capability-skill-reconfirm-\(UUID().uuidString)")!
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID(), skill = UUID()
        store.confirmSkillAgentCapabilityPreferences(
            .init(web: .automatic, reasoningIntent: nil), skillID: skill,
            providerID: provider, modelID: "model", transportIdentity: Self.runtimeIdentity("responses")
        )
        store.setCapabilityPreferences(
            nil, providerID: provider, modelID: "model", conversationID: nil, skillID: skill,
            transportIdentity: Self.runtimeIdentity("responses")
        )
        let deleted = CapabilityPreferenceSyncContract.exportPayload(settings: store)
        let tombstoneRevision = try! #require(deleted.tombstones?.first?.revision)

        store.confirmSkillAgentCapabilityPreferences(
            .init(web: .force, reasoningIntent: "off"), skillID: skill,
            providerID: provider, modelID: "model", transportIdentity: Self.runtimeIdentity("responses")
        )
        let exported = CapabilityPreferenceSyncContract.exportPayload(settings: store)
        let record = try! #require(exported.records.first)
        #expect(exported.tombstones?.isEmpty ?? true)
        #expect(record.revision > tombstoneRevision)

        let remote = GenerationParameterSettingsStore(defaults: UserDefaults(suiteName: "capability-skill-reconfirm-remote-\(UUID().uuidString)")!)
        let merged = CapabilityPreferenceSyncContract.merge(exported, settings: remote)
        #expect(merged.records.first?.revision == record.revision)
        #expect(remote.capabilityPreferences(
            providerID: provider, modelID: "model", conversationID: nil, skillID: skill,
            transportIdentity: Self.runtimeIdentity("responses")
        )?.web == .force)
    }

    /// `capability_preference_sync.v1.json#payload.records[0]`(`canonicalModelId: "gpt-test"`)
    @Test("Connection Scope Round Trips Without Model ID")
    func connectionScopeRoundTripsWithoutModelID() {
        let defaults = UserDefaults(suiteName: "capability-connection-\(UUID().uuidString)")!
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID()
        let identityA = Self.runtimeIdentity("responses-a")
        let identityB = Self.runtimeIdentity("responses-b")
        store.setConnectionCapabilityPreferences(
            .init(web: .automatic, reasoningIntent: "off"), providerID: provider,
            modelID: "connection-model", transportIdentity: identityA
        )
        let payload = CapabilityPreferenceSyncContract.exportPayload(settings: store)
        #expect(payload.records.first?.scope == "connection")
        #expect(payload.records.first?.modelId == "connection-model")
        #expect(
            payload.records.first?.recordId
                == "scope:connection:\(provider.uuidString.lowercased()):connection-model:\(identityA)"
        )
        #expect(store.connectionCapabilityPreferences(
            providerID: provider, modelID: "connection-model", transportIdentity: identityA
        )?.web == .automatic)
        #expect(store.connectionCapabilityPreferences(
            providerID: provider, modelID: "connection-model", transportIdentity: identityB
        ) == nil)
        #expect(store.connectionCapabilityPreferences(
            providerID: provider, modelID: "other-model", transportIdentity: identityA
        ) == nil)
    }

    @Test("resetting a connection scope outranks its own tombstone")
    func connectionResetSupersedesTombstone() {
        let defaults = UserDefaults(suiteName: "capability-connection-reset-\(UUID().uuidString)")!
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID()
        store.setConnectionCapabilityPreferences(
            .init(web: .automatic, reasoningIntent: nil), providerID: provider,
            modelID: "connection-model", transportIdentity: Self.runtimeIdentity("responses")
        )
        store.setConnectionCapabilityPreferences(
            nil, providerID: provider, modelID: "connection-model",
            transportIdentity: Self.runtimeIdentity("responses")
        )
        let tombstoneRevision = try! #require(CapabilityPreferenceSyncContract.exportPayload(settings: store).tombstones?.first?.revision)
        store.setConnectionCapabilityPreferences(
            .init(web: .off, reasoningIntent: "off"), providerID: provider,
            modelID: "connection-model", transportIdentity: Self.runtimeIdentity("responses")
        )
        let exported = CapabilityPreferenceSyncContract.exportPayload(settings: store)
        let record = try! #require(exported.records.first)
        #expect(exported.tombstones?.isEmpty ?? true)
        #expect(record.modelId == "connection-model")
        #expect(record.revision > tombstoneRevision)
    }

    @Test("capability preference wire fixture is flat, typed, and decodes without raw custom")
    func capabilityPreferenceSharedFixtureRoundTrips() throws {
        let data = try Data(contentsOf: Self.capabilitySyncFixtureURL())
        let fixture = try JSONDecoder().decode(CapabilitySyncFixture.self, from: data)
        let payloadObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payloadJSON = try #require(payloadObject["payload"] as? [String: Any])
        let decoded = try #require(CapabilityPreferenceSyncContract.decodeFirestore(payloadJSON))
        #expect(decoded == fixture.payload)

        let suiteName = "capability-sync-fixture-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = try #require(UUID(uuidString: "9A1195DE-3AF9-5888-ABC8-B8177C458C07"))
        let conversation = try #require(UUID(uuidString: "7C9E6679-7425-40DE-944B-E07FC1F90AE7"))
        let skill = try #require(UUID(uuidString: "3FA85F64-5717-4562-B3FC-2C963F66AFA6"))
        store.setConnectionCapabilityPreferences(
            .init(web: .off), providerID: provider, modelID: "gpt-test",
            transportIdentity: Self.runtimeIdentity("openai_responses")
        )
        store.setCapabilityPreferences(
            .init(web: .automatic, reasoningIntent: "off"), providerID: provider,
            modelID: "Qwen/Qwen2.5-72B-Instruct", conversationID: nil,
            transportIdentity: Self.runtimeIdentity("openai_chat")
        )
        store.setCapabilityPreferences(
            .init(web: .force, reasoningIntent: "max"), providerID: provider, modelID: "gpt-test",
            conversationID: conversation, transportIdentity: Self.runtimeIdentity("openai_responses")
        )
        store.confirmSkillAgentCapabilityPreferences(
            .init(web: .automatic, reasoningIntent: "off"), skillID: skill, providerID: provider,
            modelID: "gpt-test", transportIdentity: Self.runtimeIdentity("anthropic_messages")
        )
        store.setLocalCustomFragment(
            #"{\"private\":true}"#, providerID: provider, modelID: "gpt-test", conversationID: conversation,
            transportIdentity: "openai_responses", namespace: "webPatch"
        )
        let exported = CapabilityPreferenceSyncContract.exportPayload(settings: store)
        let expectedIDs = Set(fixture.payload.records.map(\.recordId))
        #expect(Set(exported.records.map(\.recordId)) == expectedIDs)
        let encoded = String(decoding: try JSONEncoder().encode(exported), as: UTF8.self)
        #expect(!encoded.contains("custom"))
        #expect(!encoded.contains("private"))
        #expect(!encoded.contains("values"))
    }

    @Test("shared fixture resolves web and reasoning independently across all seven layers")
    func capabilityPreferenceSharedResolutionCases() throws {
        let fixture = try JSONDecoder().decode(
            CapabilitySyncFixture.self,
            from: Data(contentsOf: Self.capabilitySyncFixtureURL())
        )
        #expect(Set(fixture.resolutionCases.map(\.caseId)) == [
            "conversation_web_inherits_connection_reasoning",
            "provider_recipe_supplies_both_fields",
            "provider_recipe_web_inherits_provider_default_reasoning",
        ])
        for testCase in fixture.resolutionCases {
            let actual = CapabilityPreferenceValueResolver.resolve(
                singleSend: testCase.singleSend,
                conversation: testCase.conversation,
                skill: testCase.skillAgent,
                connectionModel: testCase.connectionModel,
                connection: testCase.connection,
                providerRecipe: testCase.providerRecipe,
                providerDefault: testCase.providerDefault
            )
            #expect(actual == testCase.expected, "\(testCase.caseId) did not follow the field-level ladder")
        }
    }

    @Test("store resolution includes connection without letting conversation web hide its reasoning")
    func capabilityPreferenceStoreResolvesFieldsAndConnectionScope() throws {
        let suiteName = "capability-field-resolution-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID()
        let conversation = UUID()
        store.setConnectionCapabilityPreferences(
            .init(web: .automatic, reasoningIntent: "max"),
            providerID: provider,
            modelID: "model",
            transportIdentity: Self.runtimeIdentity("openai_responses")
        )
        store.setCapabilityPreferences(
            .init(web: .off, reasoningIntent: nil),
            providerID: provider,
            modelID: "model",
            conversationID: nil,
            transportIdentity: Self.runtimeIdentity("openai_responses")
        )
        store.setCapabilityPreferences(
            .init(web: .force, reasoningIntent: nil),
            providerID: provider,
            modelID: "model",
            conversationID: conversation,
            transportIdentity: Self.runtimeIdentity("openai_responses")
        )

        let resolved = store.resolvedCapabilityPreferences(
            providerID: provider,
            modelID: "model",
            conversationID: conversation,
            skillID: nil,
            transportIdentity: Self.runtimeIdentity("openai_responses"),
            providerRecipe: .init(web: .automatic, reasoningIntent: "low"),
            providerDefault: .init(web: .off, reasoningIntent: "balanced")
        )
        #expect(resolved == .init(web: .force, reasoningIntent: "max"))
    }

    @Test("sync decoder rejects local custom and provider wire aliases")
    func capabilityPreferenceSyncRejectsNonWireIntents() throws {
        let provider = try #require(UUID(uuidString: "9A1195DE-3AF9-5888-ABC8-B8177C458C07"))
        let custom = CapabilityPreferenceSyncRecord(
            recordId: "scope:model:\(provider.uuidString.lowercased()):model:openai_responses",
            scope: "connection_model", providerId: provider.uuidString.lowercased(), modelId: "model",
            conversationId: nil, skillId: nil, transportIdentity: Self.runtimeIdentity("openai_responses"), web: .custom,
            reasoningIntent: nil, revision: 1, mutationId: "custom"
        )
        let wireAlias = CapabilityPreferenceSyncRecord(
            recordId: custom.recordId, scope: custom.scope, providerId: custom.providerId, modelId: custom.modelId,
            conversationId: nil, skillId: nil, transportIdentity: custom.transportIdentity, web: .automatic,
            reasoningIntent: "high", revision: 2, mutationId: "high"
        )
        let wrongRecordID = CapabilityPreferenceSyncRecord(
            recordId: "scope:model:wrong", scope: custom.scope, providerId: custom.providerId, modelId: custom.modelId,
            conversationId: nil, skillId: nil, transportIdentity: custom.transportIdentity, web: .automatic,
            reasoningIntent: "max", revision: 3, mutationId: "wrong-id"
        )
        let defaults = UserDefaults(suiteName: "capability-sync-invalid-\(UUID().uuidString)")!
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let merged = CapabilityPreferenceSyncContract.merge(
            .init(schemaVersion: 1, records: [custom, wireAlias, wrongRecordID], tombstones: nil), settings: store
        )
        #expect(merged.records.isEmpty)
        let rawInvalid: [String: Any] = [
            "schemaVersion": 1,
            "records": [[
                "recordId": custom.recordId, "scope": custom.scope, "providerId": custom.providerId,
                "modelId": custom.modelId!, "transportIdentity": custom.transportIdentity, "web": "custom",
                "revision": 1, "mutationId": "custom",
            ]],
            "tombstones": [],
        ]
        #expect(CapabilityPreferenceSyncContract.decodeFirestore(rawInvalid) == nil)
        let fixture = try JSONDecoder().decode(
            CapabilitySyncFixture.self,
            from: Data(contentsOf: Self.capabilitySyncFixtureURL())
        )
        for tombstone in fixture.invalidTombstoneCases {
            let rawTombstone = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(tombstone)) as? [String: Any]
            )
            let rawPayload: [String: Any] = [
                "schemaVersion": 1,
                "records": [],
                "tombstones": [rawTombstone],
            ]
            #expect(CapabilityPreferenceSyncContract.decodeFirestore(rawPayload) == nil)
            let mergedInvalid = CapabilityPreferenceSyncContract.merge(
                .init(schemaVersion: 1, records: [], tombstones: [tombstone]), settings: store
            )
            #expect(mergedInvalid.tombstones?.isEmpty ?? true)
        }

        store.setCapabilityPreferences(
            .init(web: .custom, reasoningIntent: "max"), providerID: provider, modelID: "model",
            conversationID: nil, transportIdentity: Self.runtimeIdentity("openai_responses")
        )
        #expect(CapabilityPreferenceSyncContract.exportPayload(settings: store).records.isEmpty)
    }

    @Test("tombstones preserve opaque colon-bearing model and transport identities")
    func capabilityPreferenceColonIdentityTombstonesRoundTrip() throws {
        let suiteName = "capability-sync-colon-tombstones-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID()
        let conversation = UUID()
        let skill = UUID()
        let model = "llama3:latest"
        let rawTransport = "ollama:http://127.0.0.1:11434:llama3:latest"
        let transport = Self.runtimeIdentity(rawTransport)
        #expect(
            CapabilityPreferenceRuntimeIdentity.decode(transport)?.finalTransport == rawTransport,
            "Colon transport must round-trip as-is"
        )
        let values = CapabilityPreferenceValues(web: .automatic, reasoningIntent: "deep")

        store.setConnectionCapabilityPreferences(
            values, providerID: provider, modelID: model, transportIdentity: transport
        )
        store.setCapabilityPreferences(
            values, providerID: provider, modelID: model, conversationID: nil,
            transportIdentity: transport
        )
        store.setCapabilityPreferences(
            values, providerID: provider, modelID: model, conversationID: conversation,
            transportIdentity: transport
        )
        store.confirmSkillAgentCapabilityPreferences(
            values, skillID: skill, providerID: provider, modelID: model, transportIdentity: transport
        )
        store.setConnectionCapabilityPreferences(
            nil, providerID: provider, modelID: model, transportIdentity: transport
        )
        store.setCapabilityPreferences(
            nil, providerID: provider, modelID: model, conversationID: nil,
            transportIdentity: transport
        )
        store.setCapabilityPreferences(
            nil, providerID: provider, modelID: model, conversationID: conversation,
            transportIdentity: transport
        )
        store.setCapabilityPreferences(
            nil, providerID: provider, modelID: model, conversationID: nil, skillID: skill,
            transportIdentity: transport
        )

        let exported = CapabilityPreferenceSyncContract.exportPayload(settings: store)
        let tombstones = try #require(exported.tombstones)
        #expect(tombstones.count == 4)
        let providerID = provider.uuidString.lowercased()
        let expectedIDs: Set<String> = [
            "scope:connection:\(providerID):\(model):\(transport)",
            "scope:model:\(providerID):\(model):\(transport)",
            "scope:conversation:\(providerID):\(model):\(transport):\(conversation.uuidString.lowercased())",
            "scope:skill:\(providerID):\(model):\(transport):\(skill.uuidString.lowercased())",
        ]
        #expect(Set(tombstones.map(\.recordId)) == expectedIDs)
        let rawPayload = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(exported)) as? [String: Any]
        )
        let decoded = try #require(CapabilityPreferenceSyncContract.decodeFirestore(rawPayload))
        #expect(decoded == exported)
        let merged = CapabilityPreferenceSyncContract.merge(decoded, settings: store)
        #expect(merged.records.isEmpty)
        #expect(Set((merged.tombstones ?? []).map(\.recordId)) == expectedIDs)
    }

    /// `r1.<base64url(finalTransport)>.<base64url(runtimeRevision)>`
    private static func runtimeIdentity(
        _ transport: String,
        revision: String = "runtime-r7"
    ) -> String {
        CapabilityPreferenceRuntimeIdentity(
            canonicalModelID: "", finalTransport: transport, runtimeRevision: revision
        ).wireValue
    }


    @Test("Capability Read Falls Back To The Model Default Scope")
    func capabilityReadFallsBackToTheModelDefaultScope() {
        let suiteName = "capability-read-ladder-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID()
        let identity = Self.runtimeIdentity("responses")
        let conversation = UUID()

        store.setCapabilityPreferences(
            .init(web: .automatic, reasoningIntent: "deep"), providerID: provider, modelID: "model",
            conversationID: nil, transportIdentity: identity
        )

        let read = store.displayCapabilityPreferences(
            providerID: provider, modelID: "model", conversationID: conversation,
            skillID: nil, transportIdentity: identity
        )
        #expect(read.web == .automatic)
        #expect(read.reasoningIntent == "deep")

        #expect(CapabilityPreferenceValueResolver.resolve().reasoningIntent == "off")
        #expect(CapabilityPreferenceValueResolver.displaySelection().reasoningIntent == nil)
        #expect(CapabilityPreferenceValueResolver.displaySelection(
            conversation: .init(web: .off, reasoningIntent: "off")
        ).reasoningIntent == "off", "An explicit user Off selection must read back as-is")

        store.setCapabilityPreferences(
            .init(web: .off, reasoningIntent: nil), providerID: provider, modelID: "model",
            conversationID: conversation, transportIdentity: identity
        )
        let overridden = store.displayCapabilityPreferences(
            providerID: provider, modelID: "model", conversationID: conversation,
            skillID: nil, transportIdentity: identity
        )
        #expect(overridden.web == .off)
    }

    @Test("Local Custom Falls Back To The Model Default Scope")
    func localCustomFallsBackToTheModelDefaultScope() {
        let suiteName = "local-custom-fallback-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID()
        let identity = Self.runtimeIdentity("openai_responses")
        let conversation = UUID()

        store.setLocalCustomConfiguration(
            .init(mode: .custom, rawJSON: "{\"reasoning\":{\"effort\":\"low\"}}"),
            providerID: provider, modelID: "model", conversationID: nil,
            transportIdentity: identity, namespace: "reasoningPatch"
        )

        let configuration = store.effectiveLocalCustomConfiguration(
            providerID: provider, modelID: "model", conversationID: conversation,
            transportIdentity: identity, namespace: "reasoningPatch"
        )
        #expect(configuration.mode == .custom)
        #expect(configuration.rawJSON.contains("effort"))
        #expect(store.activeLocalCustomFragments(
            providerID: provider, modelID: "model", conversationID: conversation,
            transportIdentity: identity
        ).contains { $0.owner == "reasoning" }, "Custom fields in the model-default scope did not go outbound")

        store.setLocalCustomConfiguration(
            .init(mode: .automatic, rawJSON: ""),
            providerID: provider, modelID: "model", conversationID: conversation,
            transportIdentity: identity, namespace: "reasoningPatch"
        )
        #expect(store.effectiveLocalCustomConfiguration(
            providerID: provider, modelID: "model", conversationID: conversation,
            transportIdentity: identity, namespace: "reasoningPatch"
        ).mode == .automatic, "A custom field explicitly turned off in the session was overwritten by model defaults")
        #expect(store.activeLocalCustomFragments(
            providerID: provider, modelID: "model", conversationID: conversation,
            transportIdentity: identity
        ).isEmpty)

        #expect(store.effectiveLocalCustomConfiguration(
            providerID: provider, modelID: "model", conversationID: nil,
            transportIdentity: identity, namespace: "reasoningPatch"
        ).mode == .custom)
    }

    @Test("Override Count Unions The Model Default Scope")
    func overrideCountUnionsTheModelDefaultScope() {
        let suiteName = "override-count-union-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID()
        let conversation = UUID()

        store.setModelDefaults(
            .init(values: [
                "temperature": .init(state: .value, value: .number(0.3)),
                "top_p": .init(state: .value, value: .number(0.8)),
            ]),
            providerID: provider, modelID: "model"
        )
        store.setSessionOverrides(
            .init(values: ["temperature": .init(state: .value, value: .number(0.9))]),
            providerID: provider, modelID: "model", conversationID: conversation
        )

        let ids = store.activeOverrideParameterIDs(
            providerID: provider, modelID: "model", conversationID: conversation
        )
        #expect(ids == ["temperature", "top_p"], "The model-default layer was not merged in")

        #expect(store.activeOverrideParameterIDs(
            providerID: provider, modelID: "model", conversationID: conversation,
            activeParameterIDs: ["temperature"]
        ) == ["temperature"])

        store.setSessionOverrides(
            .init(values: ["top_k": .init(state: .inherit, value: nil)]),
            providerID: provider, modelID: "model", conversationID: conversation
        )
        #expect(!store.activeOverrideParameterIDs(
            providerID: provider, modelID: "model", conversationID: conversation
        ).contains("top_k"))
    }


    @Test("Typed Preferences Forward Port Across Runtime Revisions")
    func typedPreferencesForwardPortAcrossRuntimeRevisions() {
        let suiteName = "capability-forward-port-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID()
        let conversation = UUID()
        let old = Self.runtimeIdentity("openai_responses", revision: "runtime-r7")
        let new = Self.runtimeIdentity("openai_responses", revision: "runtime-r8")

        store.setCapabilityPreferences(
            .init(web: .automatic, reasoningIntent: "deep"), providerID: provider, modelID: "model",
            conversationID: conversation, transportIdentity: old
        )
        store.setCapabilityPreferences(
            .init(web: .force, reasoningIntent: "low"), providerID: provider, modelID: "model",
            conversationID: nil, transportIdentity: old
        )
        store.setConnectionCapabilityPreferences(
            .init(web: .automatic, reasoningIntent: "balanced"), providerID: provider,
            modelID: "model", transportIdentity: old
        )

        let display = store.displayCapabilityPreferences(
            providerID: provider, modelID: "model", conversationID: conversation,
            skillID: nil, transportIdentity: new
        )
        #expect(display.reasoningIntent == "deep")
        #expect(display.web == .automatic)

        #expect(store.capabilityPreferences(
            providerID: provider, modelID: "model", conversationID: conversation, transportIdentity: new
        )?.reasoningIntent == "deep")
        #expect(store.capabilityPreferences(
            providerID: provider, modelID: "model", conversationID: nil, transportIdentity: new
        )?.reasoningIntent == "low", "The model-default scope did not follow the version line")
        #expect(store.connectionCapabilityPreferences(
            providerID: provider, modelID: "model", transportIdentity: new
        )?.reasoningIntent == "balanced", "The connection scope did not follow the version line")
        #expect(store.resolvedCapabilityPreferences(
            providerID: provider, modelID: "model", conversationID: conversation,
            skillID: nil, transportIdentity: new
        ).reasoningIntent == "deep", "Outbound and UI reads are not the same document")

        #expect(store.capabilityPreferences(
            providerID: provider, modelID: "model", conversationID: conversation, transportIdentity: old
        )?.reasoningIntent == "deep")

        let afterFirst = CapabilityPreferenceSyncContract.exportPayload(settings: store)
        for _ in 0..<3 {
            _ = store.displayCapabilityPreferences(
                providerID: provider, modelID: "model", conversationID: conversation,
                skillID: nil, transportIdentity: new
            )
        }
        let afterRepeat = CapabilityPreferenceSyncContract.exportPayload(settings: store)
        #expect(afterRepeat.records.count == afterFirst.records.count)
        #expect(
            afterRepeat.records.map(\.revision).sorted() == afterFirst.records.map(\.revision).sorted(),
            "Repeated reads kept bumping revision"
        )
    }

    @Test("Forward Port Is Limited To The Same Transport")
    func forwardPortIsLimitedToTheSameTransport() {
        let suiteName = "capability-forward-port-transport-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID()
        store.setCapabilityPreferences(
            .init(web: .automatic, reasoningIntent: "deep"), providerID: provider, modelID: "model",
            conversationID: nil, transportIdentity: Self.runtimeIdentity("openai_responses", revision: "r7")
        )
        let otherProtocol = Self.runtimeIdentity("openai_chat", revision: "r8")
        #expect(store.displayCapabilityPreferences(
            providerID: provider, modelID: "model", conversationID: nil, skillID: nil,
            transportIdentity: otherProtocol
        ).reasoningIntent == nil)
        #expect(store.capabilityPreferences(
            providerID: provider, modelID: "model", conversationID: nil, transportIdentity: otherProtocol
        ) == nil, "Switching protocols also moved values, which guesses a new contract for the user")
    }

    @Test("Forward Port Respects Tombstones")
    func forwardPortRespectsTombstones() {
        let suiteName = "capability-forward-port-tombstone-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID()
        let conversation = UUID()
        let old = Self.runtimeIdentity("openai_responses", revision: "r7")
        let new = Self.runtimeIdentity("openai_responses", revision: "r8")

        store.setCapabilityPreferences(
            .init(web: .automatic, reasoningIntent: "deep"), providerID: provider, modelID: "model",
            conversationID: conversation, transportIdentity: old
        )
        store.setCapabilityPreferences(
            nil, providerID: provider, modelID: "model",
            conversationID: conversation, transportIdentity: new
        )

        #expect(store.displayCapabilityPreferences(
            providerID: provider, modelID: "model", conversationID: conversation,
            skillID: nil, transportIdentity: new
        ).reasoningIntent == nil, "A deleted scope was resurrected by an older version's values")
        #expect(store.capabilityPreferences(
            providerID: provider, modelID: "model", conversationID: conversation, transportIdentity: new
        ) == nil)
    }

    @Test("Forward Port Is Safe Under Concurrent Reads")
    func forwardPortIsSafeUnderConcurrentReads() {
        let suiteName = "capability-forward-port-concurrent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID()
        let old = Self.runtimeIdentity("openai_responses", revision: "r7")
        let new = Self.runtimeIdentity("openai_responses", revision: "r8")
        store.setCapabilityPreferences(
            .init(web: .force, reasoningIntent: "max"), providerID: provider, modelID: "model",
            conversationID: nil, transportIdentity: old
        )

        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            _ = store.displayCapabilityPreferences(
                providerID: provider, modelID: "model", conversationID: nil,
                skillID: nil, transportIdentity: new
            )
        }

        let payload = CapabilityPreferenceSyncContract.exportPayload(settings: store)
        #expect(payload.records.filter { $0.transportIdentity == new }.count == 1)
        #expect(store.capabilityPreferences(
            providerID: provider, modelID: "model", conversationID: nil, transportIdentity: new
        )?.reasoningIntent == "max")
    }

    @Test("Skill Confirmation Read Forward Ports Across Runtime Revisions")
    func skillConfirmationReadForwardPortsAcrossRuntimeRevisions() {
        let suiteName = "capability-skill-confirm-forward-port-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID()
        let skill = UUID()
        let old = Self.runtimeIdentity("openai_responses", revision: "runtime-r7")
        let new = Self.runtimeIdentity("openai_responses", revision: "runtime-r8")

        store.confirmSkillAgentCapabilityPreferences(
            .init(web: .automatic, reasoningIntent: "deep"), skillID: skill, providerID: provider,
            modelID: "model", transportIdentity: old
        )

        #expect(store.capabilityPreferences(
            providerID: provider, modelID: "model", conversationID: nil, skillID: skill,
            transportIdentity: new
        ) == nil)

        #expect(
            store.isSkillAgentCapabilityConfirmed(
                providerID: provider, modelID: "model", skillID: skill, transportIdentity: new
            ),
            "After a recipe version change the edit page shows a confirmed Skill as unconfirmed (ASM-9 flip window)"
        )
        #expect(store.capabilityPreferences(
            providerID: provider, modelID: "model", conversationID: nil, skillID: skill,
            transportIdentity: new
        )?.reasoningIntent == "deep")
        #expect(store.resolvedCapabilityPreferences(
            providerID: provider, modelID: "model", conversationID: nil, skillID: skill,
            transportIdentity: new
        ).reasoningIntent == "deep")

        let afterFirst = CapabilityPreferenceSyncContract.exportPayload(settings: store)
        for _ in 0..<3 {
            _ = store.isSkillAgentCapabilityConfirmed(
                providerID: provider, modelID: "model", skillID: skill, transportIdentity: new
            )
        }
        let afterRepeat = CapabilityPreferenceSyncContract.exportPayload(settings: store)
        #expect(afterRepeat.records.count == afterFirst.records.count)
        #expect(
            afterRepeat.records.map(\.revision).sorted() == afterFirst.records.map(\.revision).sorted(),
            "Repeated reads kept bumping revision"
        )
    }

    @Test("Skill Confirmation Forward Port Respects Tombstone And Transport")
    func skillConfirmationForwardPortRespectsTombstoneAndTransport() {
        let suiteName = "capability-skill-confirm-bounds-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID()
        let skill = UUID()
        let old = Self.runtimeIdentity("openai_responses", revision: "runtime-r7")
        let new = Self.runtimeIdentity("openai_responses", revision: "runtime-r8")

        store.confirmSkillAgentCapabilityPreferences(
            .init(web: .automatic, reasoningIntent: "deep"), skillID: skill, providerID: provider,
            modelID: "model", transportIdentity: old
        )
        store.setCapabilityPreferences(
            nil, providerID: provider, modelID: "model", conversationID: nil, skillID: skill,
            transportIdentity: new
        )
        #expect(
            !store.isSkillAgentCapabilityConfirmed(
                providerID: provider, modelID: "model", skillID: skill, transportIdentity: new
            ),
            "A cancelled confirmation was resurrected by an older recipe-version record"
        )

        let otherSkill = UUID()
        store.confirmSkillAgentCapabilityPreferences(
            .init(web: .automatic, reasoningIntent: "deep"), skillID: otherSkill, providerID: provider,
            modelID: "model", transportIdentity: old
        )
        #expect(
            !store.isSkillAgentCapabilityConfirmed(
                providerID: provider, modelID: "model", skillID: otherSkill,
                transportIdentity: Self.runtimeIdentity("openai_chat", revision: "runtime-r8")
            ),
            "Switching protocols also moved confirmation, which accepts a new contract for the user"
        )
    }

    @Test("Skill Confirmation Read Is Inert Without Runtime Identity")
    func skillConfirmationReadIsInertWithoutRuntimeIdentity() {
        let suiteName = "capability-skill-confirm-empty-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID()
        let skill = UUID()
        store.confirmSkillAgentCapabilityPreferences(
            .init(web: .automatic, reasoningIntent: "deep"), skillID: skill, providerID: provider,
            modelID: "model", transportIdentity: Self.runtimeIdentity("openai_responses", revision: "r7")
        )
        let before = CapabilityPreferenceSyncContract.exportPayload(settings: store)
        #expect(!store.isSkillAgentCapabilityConfirmed(
            providerID: provider, modelID: "", skillID: skill, transportIdentity: ""
        ))
        let after = CapabilityPreferenceSyncContract.exportPayload(settings: store)
        #expect(after.records.count == before.records.count)
    }

    @Test("Skill Edit View Consumes The Forward Porting Confirmation Entry")
    func skillEditViewConsumesTheForwardPortingConfirmationEntry() throws {
        let view = try String(
            contentsOf: Self.sourceURL(["ios", "Oriveo", "Oriveo", "Features", "Skills", "SkillEditView.swift"]),
            encoding: .utf8
        )
        #expect(
            view.contains(".isSkillAgentCapabilityConfirmed("),
            "The edit page did not use the forward-porting confirmation entry"
        )
        #expect(
            !view.contains("GenerationParameterSettingsStore.shared.capabilityPreferences("),
            "The edit page fell back to a bare query that skips forward-porting — the ASM-9 flip window would return as-is"
        )
    }

    private static func sourceURL(_ components: [String]) -> URL {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while current.path != "/" {
            let candidate = components.reduce(current) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            current.deleteLastPathComponent()
        }
        preconditionFailure("Unable to locate \(components.joined(separator: "/"))")
    }


    @Test("Account Boundary Reset Clears Records And Tombstones")
    func accountBoundaryResetClearsRecordsAndTombstones() {
        let suiteName = "generation-parameter-account-boundary-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = GenerationParameterSettingsStore(defaults: defaults)
        let presets = GenerationParameterPresetStore(defaults: defaults)
        let provider = UUID()
        let conversation = UUID()
        let identity = Self.runtimeIdentity("responses")

        settings.setCapabilityPreferences(
            .init(web: .force, reasoningIntent: "off"), providerID: provider, modelID: "model-a",
            conversationID: conversation, transportIdentity: identity
        )
        settings.setCapabilityPreferences(
            nil, providerID: provider, modelID: "model-a",
            conversationID: conversation, transportIdentity: identity
        )
        settings.setCapabilityPreferences(
            .init(web: .force, reasoningIntent: "off"), providerID: provider, modelID: "model-b",
            conversationID: nil, transportIdentity: identity
        )
        settings.setSessionOverrides(
            .init(values: ["temperature": .init(state: .value, value: .number(0.3))]),
            providerID: provider, modelID: "model-a", conversationID: conversation
        )
        settings.setSessionOverrides(
            nil, providerID: provider, modelID: "model-a", conversationID: conversation
        )
        settings.setModelDefaults(
            .init(values: ["top_p": .init(state: .value, value: .number(0.9))]),
            providerID: provider, modelID: "model-a"
        )
        settings.setLocalCustomFragment(
            #"{"tools":["private"]}"#, providerID: provider, modelID: "model-a",
            conversationID: conversation, transportIdentity: "responses", namespace: "webPatch"
        )
        _ = presets.save(
            name: "A", providerID: provider, modelID: "model-a",
            profileFingerprint: "ep_deadbeef|template|engine|model-a",
            values: .init(values: ["temperature": .init(state: .value, value: .number(0.2))])
        )

        let beforeGeneration = GenerationParameterSyncContract.exportPayload(
            settings: settings, presets: presets, defaults: defaults
        )
        #expect(!beforeGeneration.records.isEmpty)
        #expect(!beforeGeneration.presets.isEmpty)
        #expect(!beforeGeneration.tombstones.isEmpty)
        let beforeCapability = CapabilityPreferenceSyncContract.exportPayload(settings: settings)
        #expect(!beforeCapability.records.isEmpty)
        #expect(!(beforeCapability.tombstones ?? []).isEmpty)

        GenerationParameterAccountBoundary.resetForSignOut(
            settings: settings, presets: presets, defaults: defaults
        )

        let afterGeneration = GenerationParameterSyncContract.exportPayload(
            settings: settings, presets: presets, defaults: defaults
        )
        #expect(afterGeneration.records.isEmpty)
        #expect(afterGeneration.presets.isEmpty)
        #expect(afterGeneration.tombstones.isEmpty)
        let afterCapability = CapabilityPreferenceSyncContract.exportPayload(settings: settings)
        #expect(afterCapability.records.isEmpty)
        #expect((afterCapability.tombstones ?? []).isEmpty)

        #expect(presets.list(
            providerID: provider, modelID: "model-a", profileFingerprint: "ep_deadbeef|template|engine|model-a"
        ).isEmpty)
        #expect(settings.modelDefaults(providerID: provider, modelID: "model-a") == nil)
        #expect(settings.localCustomFragment(
            providerID: provider, modelID: "model-a", conversationID: conversation,
            transportIdentity: "responses", namespace: "webPatch"
        ) == nil)
        #expect(defaults.string(forKey: GenerationParameterAccountBoundary.stampKey) == nil)
    }

    @Test("Account Boundary Reset Does Not Inherit Revision Baseline")
    func accountBoundaryResetDoesNotInheritRevisionBaseline() {
        let suiteName = "generation-parameter-revision-baseline-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = GenerationParameterSettingsStore(defaults: defaults)
        let presets = GenerationParameterPresetStore(defaults: defaults)
        let provider = UUID()
        let identity = Self.runtimeIdentity("responses")

        #expect(GenerationParameterAccountBoundary.applyLoginBoundary(
            uid: "uid-a", settings: settings, presets: presets, defaults: defaults
        ) == .adopted)

        for _ in 0..<2 {
            settings.setCapabilityPreferences(
                .init(web: .force, reasoningIntent: "off"), providerID: provider, modelID: "model-a",
                conversationID: nil, transportIdentity: identity
            )
            settings.setCapabilityPreferences(
                nil, providerID: provider, modelID: "model-a",
                conversationID: nil, transportIdentity: identity
            )
        }
        #expect(CapabilityPreferenceSyncContract.exportPayload(settings: settings)
            .tombstones?.first?.revision == 4)

        #expect(GenerationParameterAccountBoundary.applyLoginBoundary(
            uid: "uid-b", settings: settings, presets: presets, defaults: defaults
        ) == .reset)

        settings.setCapabilityPreferences(
            .init(web: .automatic, reasoningIntent: "off"), providerID: provider, modelID: "model-a",
            conversationID: nil, transportIdentity: identity
        )
        let exported = CapabilityPreferenceSyncContract.exportPayload(settings: settings)
        #expect(exported.records.count == 1)
        #expect(exported.records[0].revision == 1)
        #expect((exported.tombstones ?? []).isEmpty)
    }

    @Test("Account Stamp Adoption Semantics")
    func accountStampAdoptionSemantics() {
        let suiteName = "generation-parameter-account-stamp-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = GenerationParameterSettingsStore(defaults: defaults)
        let presets = GenerationParameterPresetStore(defaults: defaults)
        let provider = UUID()
        let identity = Self.runtimeIdentity("responses")
        func write() {
            settings.setCapabilityPreferences(
                .init(web: .force, reasoningIntent: "off"), providerID: provider, modelID: "model-a",
                conversationID: nil, transportIdentity: identity
            )
        }
        func recordCount() -> Int {
            CapabilityPreferenceSyncContract.exportPayload(settings: settings).records.count
        }

        write()
        #expect(GenerationParameterAccountBoundary.applyLoginBoundary(
            uid: "guest", settings: settings, presets: presets, defaults: defaults
        ) == .skippedGuest)
        #expect(defaults.string(forKey: GenerationParameterAccountBoundary.stampKey) == nil)
        #expect(recordCount() == 1)

        #expect(GenerationParameterAccountBoundary.applyLoginBoundary(
            uid: "uid-a", settings: settings, presets: presets, defaults: defaults
        ) == .adopted)
        #expect(defaults.string(forKey: GenerationParameterAccountBoundary.stampKey) == "uid-a")
        #expect(recordCount() == 1)

        #expect(GenerationParameterAccountBoundary.applyLoginBoundary(
            uid: "uid-a", settings: settings, presets: presets, defaults: defaults
        ) == .unchanged)
        #expect(recordCount() == 1)

        #expect(GenerationParameterAccountBoundary.applyLoginBoundary(
            uid: "uid-b", settings: settings, presets: presets, defaults: defaults
        ) == .reset)
        #expect(defaults.string(forKey: GenerationParameterAccountBoundary.stampKey) == "uid-b")
        #expect(recordCount() == 0)

        write()
        #expect(GenerationParameterAccountBoundary.applyLoginBoundary(
            uid: "guest", settings: settings, presets: presets, defaults: defaults
        ) == .skippedGuest)
        #expect(defaults.string(forKey: GenerationParameterAccountBoundary.stampKey) == "uid-b")
        #expect(recordCount() == 1)
    }

    @Test("Account Scope Invariants Are Contract Driven")
    func accountScopeInvariantsAreContractDriven() throws {
        for url in [Self.syncFixtureURL(), Self.capabilitySyncFixtureURL()] {
            let contract = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            let invariants = try #require(
                contract?["accountScopeInvariants"] as? [String: Any],
                "\(url.lastPathComponent) is missing accountScopeInvariants"
            )
            let boundaryReset = try #require(invariants["boundaryReset"] as? [String: Any])
            // bindWithMismatchedStamp / stampAdoption → applyLoginBoundary.
            #expect(boundaryReset["signOut"] is String)
            #expect(boundaryReset["bindWithMismatchedStamp"] is String)
            #expect(boundaryReset["stampAdoption"] is String)
            #expect(invariants["revisionBaselineNotInherited"] is String)
        }

        let suiteName = "generation-parameter-account-contract-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = GenerationParameterSettingsStore(defaults: defaults)
        let presets = GenerationParameterPresetStore(defaults: defaults)
        let provider = UUID()
        let identity = Self.runtimeIdentity("responses")

        GenerationParameterAccountBoundary.applyLoginBoundary(
            uid: "uid-a", settings: settings, presets: presets, defaults: defaults
        )
        settings.setModelDefaults(
            .init(values: ["top_p": .init(state: .value, value: .number(0.9))]),
            providerID: provider, modelID: "model-a"
        )
        settings.setModelDefaults(nil, providerID: provider, modelID: "model-a")
        settings.setCapabilityPreferences(
            .init(web: .force, reasoningIntent: "off"), providerID: provider, modelID: "model-a",
            conversationID: nil, transportIdentity: identity
        )
        _ = presets.save(
            name: "A", providerID: provider, modelID: "model-a",
            profileFingerprint: "ep_deadbeef|template|engine|model-a",
            values: .init(values: ["temperature": .init(state: .value, value: .number(0.2))])
        )
        #expect(!GenerationParameterSyncContract.exportPayload(
            settings: settings, presets: presets, defaults: defaults
        ).tombstones.isEmpty)

        GenerationParameterAccountBoundary.resetForSignOut(
            settings: settings, presets: presets, defaults: defaults
        )
        let signedOut = GenerationParameterSyncContract.exportPayload(
            settings: settings, presets: presets, defaults: defaults
        )
        #expect(signedOut.records.isEmpty)
        #expect(signedOut.presets.isEmpty)
        #expect(signedOut.tombstones.isEmpty)
        #expect(CapabilityPreferenceSyncContract.exportPayload(settings: settings).records.isEmpty)
        #expect(defaults.string(forKey: GenerationParameterAccountBoundary.stampKey) == nil)

        GenerationParameterAccountBoundary.applyLoginBoundary(
            uid: "uid-b", settings: settings, presets: presets, defaults: defaults
        )
        settings.setModelDefaults(
            .init(values: ["top_p": .init(state: .value, value: .number(0.5))]),
            providerID: provider, modelID: "model-a"
        )
        #expect(GenerationParameterSyncContract.exportPayload(
            settings: settings, presets: presets, defaults: defaults
        ).records.first?.revision == 1)
    }


    @MainActor
    private final class PublishCapture {
        var payloads: [[String: Any]] = []
        var count: Int { payloads.count }
    }

    @MainActor
    private static func drainPublisherQueue() async {
        for _ in 0..<8 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
    }

    @MainActor
    @Test("Empty Envelope Never Reaches Writer")
    func emptyEnvelopeNeverReachesWriter() async {
        let generationCapture = PublishCapture()
        let generation = GenerationParameterSyncPublisher(makePayload: {
            .init(schemaVersion: 1, records: [], presets: [], tombstones: [])
        })
        generation.bind { generationCapture.payloads.append($0) }

        let capabilityCapture = PublishCapture()
        let capability = CapabilityPreferenceSyncPublisher(makePayload: {
            .init(schemaVersion: 2, records: [], tombstones: [])
        })
        capability.bind { capabilityCapture.payloads.append($0) }

        await Self.drainPublisherQueue()
        #expect(generationCapture.count == 0)
        #expect(capabilityCapture.count == 0)

        let nilTombstoneCapture = PublishCapture()
        let nilTombstone = CapabilityPreferenceSyncPublisher(makePayload: {
            .init(schemaVersion: 2, records: [], tombstones: nil)
        })
        nilTombstone.bind { nilTombstoneCapture.payloads.append($0) }
        await Self.drainPublisherQueue()
        #expect(nilTombstoneCapture.count == 0)
    }

    @MainActor
    @Test("Non Empty Envelope Still Publishes")
    func nonEmptyEnvelopeStillPublishes() async {
        let record = GenerationParameterSyncRecord(
            recordId: "scope:model:9a1195de-3af9-5888-abc8-b8177c458c07:model-a",
            scope: "model_default", providerId: "9a1195de-3af9-5888-abc8-b8177c458c07",
            modelId: "model-a", conversationId: nil, profileKey: "template|engine|model-a",
            values: ["top_p": .init(state: .value, value: .number(0.9))],
            revision: 1, mutationId: "00000000-0000-4000-8000-000000000001"
        )
        let withRecord = PublishCapture()
        let recordPublisher = GenerationParameterSyncPublisher(makePayload: {
            .init(schemaVersion: 1, records: [record], presets: [], tombstones: [])
        })
        recordPublisher.bind { withRecord.payloads.append($0) }
        await Self.drainPublisherQueue()
        #expect(withRecord.count == 1)
        #expect((withRecord.payloads.first?["records"] as? [[String: Any]])?.count == 1)

        let generationTombstoneOnly = PublishCapture()
        let generationPublisher = GenerationParameterSyncPublisher(makePayload: {
            .init(
                schemaVersion: 1, records: [], presets: [],
                tombstones: [.init(
                    recordId: "scope:model:9a1195de-3af9-5888-abc8-b8177c458c07:model-a",
                    revision: 2, mutationId: "00000000-0000-4000-8000-000000000002"
                )]
            )
        })
        generationPublisher.bind { generationTombstoneOnly.payloads.append($0) }
        await Self.drainPublisherQueue()
        #expect(generationTombstoneOnly.count == 1)
        #expect((generationTombstoneOnly.payloads.first?["tombstones"] as? [[String: Any]])?.count == 1)

        let capabilityTombstoneOnly = PublishCapture()
        let capabilityPublisher = CapabilityPreferenceSyncPublisher(makePayload: {
            .init(
                schemaVersion: 2, records: [],
                tombstones: [.init(
                    recordId: "scope:model:9a1195de-3af9-5888-abc8-b8177c458c07:model-a:r1.cmVzcG9uc2Vz.cnVudGltZS1yNw",
                    revision: 2, mutationId: "00000000-0000-4000-8000-000000000003"
                )]
            )
        })
        capabilityPublisher.bind { capabilityTombstoneOnly.payloads.append($0) }
        await Self.drainPublisherQueue()
        #expect(capabilityTombstoneOnly.count == 1)
    }

    @Test("Empty Envelope Invariant Is Contract Driven")
    func emptyEnvelopeInvariantIsContractDriven() throws {
        for url in [Self.syncFixtureURL(), Self.capabilitySyncFixtureURL()] {
            let contract = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            let invariants = try #require(contract?["wireInvariants"] as? [String: Any])
            #expect(
                invariants["emptyEnvelopeNeverOutbound"] is String,
                "\(url.lastPathComponent)#wireInvariants is missing emptyEnvelopeNeverOutbound"
            )
        }

        #expect(GenerationParameterSyncPayload(
            schemaVersion: 1, records: [], presets: [], tombstones: []
        ).isEmptyEnvelope)
        #expect(!GenerationParameterSyncPayload(
            schemaVersion: 1, records: [], presets: [],
            tombstones: [.init(recordId: "scope:model:x", revision: 2, mutationId: "m")]
        ).isEmptyEnvelope)
        #expect(!GenerationParameterSyncPayload(
            schemaVersion: 1, records: [], presets: [.init(
                id: "00000000-0000-4000-8000-000000000004", name: "A",
                providerId: "9a1195de-3af9-5888-abc8-b8177c458c07", modelId: "model-a",
                profileKey: "template|engine|model-a",
                values: ["temperature": .init(state: .value, value: .number(0.2))],
                createdAt: "2026-08-28T00:00:00.000Z", revision: 1, mutationId: "m"
            )], tombstones: []
        ).isEmptyEnvelope)

        #expect(CapabilityPreferenceSyncPayload(schemaVersion: 2, records: [], tombstones: nil).isEmptyEnvelope)
        #expect(CapabilityPreferenceSyncPayload(schemaVersion: 2, records: [], tombstones: []).isEmptyEnvelope)
        #expect(!CapabilityPreferenceSyncPayload(
            schemaVersion: 2, records: [],
            tombstones: [.init(recordId: "scope:model:x", revision: 2, mutationId: "m")]
        ).isEmptyEnvelope)
    }

    private static func capabilitySyncFixtureURL() -> URL {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while current.path != "/" {
            let candidate = current
                .appendingPathComponent("shared")
                .appendingPathComponent("model-contracts")
                .appendingPathComponent("capability_preference_sync.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            current.deleteLastPathComponent()
        }
        preconditionFailure("Unable to locate capability_preference_sync.v1.json")
    }
}
