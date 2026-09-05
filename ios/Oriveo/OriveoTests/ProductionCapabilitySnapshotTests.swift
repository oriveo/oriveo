import Foundation
import Testing
@testable import Oriveo

@Suite("Production Capability Snapshot Tests", .serialized)
struct ProductionCapabilitySnapshotTests {
    private static let capabilities = ["web", "reasoning"]

    // MARK: - Fixture

    private struct Snapshot: Decodable {
        struct ReasoningProfile: Decodable { let levels: [String] }
        struct Profiles: Decodable { let reasoning: [String: ReasoningProfile] }
        struct Control: Decodable {
            let state: String?
            let recipeRef: String?
            let reasonCode: String?
            let availableIntents: [String]?
        }
        struct Model: Decodable {
            let providerKind: String
            let modelId: String
            let capabilities: [String]
            let profiles: ModelProfiles
            let capabilityControls: [String: Control]
            let transport: String
        }
        struct ModelProfiles: Decodable {
            let reasoning: String?
            let webSearch: String?
        }
        struct ExpectedVerdict: Decodable {
            let state: String
            let viaLegacyProfile: Bool
            let intents: [String]?
        }
        struct OptionalExpectations: Decodable {
            let capabilities: [String: ExpectedVerdict]?
            init(from decoder: Decoder) throws {
                capabilities = try? [String: ExpectedVerdict](from: decoder)
            }
        }
        let profiles: Profiles
        let models: [String: Model]
        let expectedVerdicts: [String: [String: ExpectedVerdict]]

        private enum CodingKeys: String, CodingKey { case profiles, models, expectedVerdicts }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            profiles = try container.decode(Profiles.self, forKey: .profiles)
            models = try container.decode([String: Model].self, forKey: .models)
            expectedVerdicts = try container
                .decode([String: OptionalExpectations].self, forKey: .expectedVerdicts)
                .compactMapValues(\.capabilities)
        }
    }

    private static func loadSnapshot() throws -> Snapshot {
        let url = findFile(["shared", "model-contracts", "production-capability-snapshot.json"])
        return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
    }

    private static func findFile(_ components: [String]) -> URL {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while current.path != current.deletingLastPathComponent().path {
            let candidate = components.reduce(current) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            current = current.deletingLastPathComponent()
        }
        fatalError("production capability snapshot not found")
    }

    private static func metadataJSON(_ snapshot: Snapshot) throws -> String {
        var providers: [String: Any] = [:]
        for (_, model) in snapshot.models {
            var provider = providers[model.providerKind] as? [String: Any]
                ?? ["resolveMap": [String: String](), "models": [String: Any]()]
            var resolveMap = provider["resolveMap"] as? [String: String] ?? [:]
            var models = provider["models"] as? [String: Any] ?? [:]
            resolveMap[model.modelId] = model.modelId
            var controls: [String: Any] = [:]
            for (capability, control) in model.capabilityControls {
                var encoded: [String: Any] = [:]
                if let state = control.state { encoded["state"] = state }
                if let recipeRef = control.recipeRef { encoded["recipeRef"] = recipeRef }
                if let reasonCode = control.reasonCode { encoded["reasonCode"] = reasonCode }
                if let intents = control.availableIntents { encoded["availableIntents"] = intents }
                controls[capability] = encoded
            }
            var profiles: [String: Any] = [:]
            if let reasoning = model.profiles.reasoning { profiles["reasoning"] = reasoning }
            if let webSearch = model.profiles.webSearch { profiles["webSearch"] = webSearch }
            models[model.modelId] = [
                "canonicalModelId": model.modelId,
                "transport": model.transport,
                "capabilities": model.capabilities,
                "profiles": profiles,
                "capabilityControls": controls,
            ]
            provider["resolveMap"] = resolveMap
            provider["models"] = models
            providers[model.providerKind] = provider
        }
        var reasoningProfiles: [String: Any] = [:]
        for (name, definition) in snapshot.profiles.reasoning {
            reasoningProfiles[name] = ["levels": definition.levels]
        }
        let payload: [String: Any] = [
            "version": 1,
            "providers": providers,
            "profiles": ["reasoning": reasoningProfiles],
            "capabilityRuntime": [
                "schemaVersion": RequestPreferenceResolver.runtimeSchemaVersion,
                "revision": "sha256:production-capability-snapshot",
                "generatedAt": "2026-08-13T02:00:00Z",
                "recipes": [String: Any](),
                "controlDefinitions": [String: Any](),
                "sourceIndex": [String: Any](),
            ],
        ]
        return String(
            decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            as: UTF8.self
        )
    }

    private static let metadataETag = "production-capability-snapshot"

    private static func install(_ snapshot: Snapshot) async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: try metadataJSON(snapshot), metadataETag: metadataETag
        )
    }

    private struct Subject {
        let provider: Provider
        let model: AIModel
        let identity: CapabilityEvidenceRequestIdentity
    }

    private static func subject(for entry: Snapshot.Model) throws -> Subject {
        let kind = try #require(ProviderKind(rawValue: entry.providerKind))
        let capabilities = entry.capabilities.compactMap(ModelCapability.init(rawValue:))
        let persisted = TestFactories.makeModel(id: entry.modelId, capabilities: capabilities)
        let model = MetadataClient.shared.syncCurrentCapabilityEvidenceModel(persisted, providerKind: kind)
        let provider = TestFactories.makeProvider(id: UUID(), kind: kind, models: [model])
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: "u1",
            hasExplicitValue: true, metadataETag: metadataETag
        )
        return Subject(provider: provider, model: model, identity: identity)
    }


    @Test("Expected Verdicts Cover Every Model")
    func expectedVerdictsCoverEveryModel() throws {
        let snapshot = try Self.loadSnapshot()
        #expect(Set(snapshot.expectedVerdicts.keys) == Set(snapshot.models.keys))
        for (key, expectations) in snapshot.expectedVerdicts {
            #expect(Set(expectations.keys) == Set(Self.capabilities))
        }
    }

    @Test("Every Model Verdict In The Slice Matches The Slice's Own Expectation Table", arguments: capabilities)
    func verdictsMatchSharedExpectations(capability: String) async throws {
        let snapshot = try Self.loadSnapshot()
        try await Self.install(snapshot)
        var available = 0
        var unavailable = 0
        for (key, entry) in snapshot.models {
            let expected = try #require(
                snapshot.expectedVerdicts[key]?[capability], "\(key)/\(capability) has no expected value"
            )
            let subject = try Self.subject(for: entry)
            let verdict = CapabilityControlResolution.resolve(
                provider: subject.provider, model: subject.model, capability: capability
            )
            #expect(verdict.state.rawValue == expected.state, "\(key)/\(capability) state")
            #expect(
                verdict.viaLegacyProfile == expected.viaLegacyProfile,
                "\(key)/\(capability) viaLegacyProfile"
            )
            if let intents = expected.intents {
                #expect(verdict.intents == intents, "\(key)/\(capability) intents")
            }
            verdict.isAvailable ? (available += 1) : (unavailable += 1)
        }
        #expect(available > 0)
        #expect(unavailable > 0)
        await MetadataClient.shared.resetForTesting()
    }


    @Test("Every Slice-Unavailable Side: Outbound Gate And Chip Must Both Turn Off", arguments: capabilities)
    func unavailableSideStaysDarkOnBothSides(capability: String) async throws {
        let snapshot = try Self.loadSnapshot()
        try await Self.install(snapshot)
        var covered = 0
        for (key, entry) in snapshot.models {
            let expected = try #require(snapshot.expectedVerdicts[key]?[capability])
            guard expected.state != "auto_available", expected.state != "managed_only" else { continue }
            covered += 1
            let subject = try Self.subject(for: entry)
            let verdict = CapabilityControlResolution.resolve(
                provider: subject.provider, model: subject.model, capability: capability
            )
            if capability == "web" {
                let projection = CapabilityEvidenceProductionAdapter.capabilityProjection(
                    provider: subject.provider, model: subject.model, identity: subject.identity,
                    keys: ["web_search"], explicitKeys: []
                )
                #expect(!projection.permitsOutbound("web_search"))
                let decision = ChatCapabilityOutboundDecision.resolve(
                    webRequested: true,
                    webPermitted: projection.permitsOutbound("web_search"),
                    reasoningModeRequested: .automatic,
                    reasoningModePermitted: true,
                    reasoningIntentRequested: nil,
                    reasoningIntentPermitted: false
                )
                #expect(!decision.webSearchEnabled)
                #expect(!decision.activeCapabilityGlyphs.contains("globe"))
            } else {
                let decision = ChatCapabilityOutboundDecision.resolve(
                    webRequested: false,
                    webPermitted: false,
                    reasoningModeRequested: .automatic,
                    reasoningModePermitted: true,
                    reasoningIntentRequested: "deep",
                    reasoningIntentPermitted: verdict.isAvailable && verdict.intents.contains("deep")
                )
                #expect(decision.reasoningIntent == nil)
                #expect(!decision.activeCapabilityGlyphs.contains("brain"))
            }
        }
        #expect(covered > 0)
        await MetadataClient.shared.resetForTesting()
    }


    @Test(
        "Models With Auto Config But No Ladder Honestly Say The Gear Is Fixed Instead Of Leaving An Empty Panel",
        arguments: ["openAI/gpt-5-pro", "openAI/gpt-5.2-chat-latest"]
    )
    func fixedTierReasoningExplainsItself(key: String) async throws {
        let snapshot = try Self.loadSnapshot()
        try await Self.install(snapshot)
        let entry = try #require(snapshot.models[key])
        #expect(entry.capabilityControls["reasoning"]?.state == "auto_available")
        #expect(
            entry.capabilityControls["reasoning"]?.availableIntents == nil,
            "\(key) slice should not have availableIntents"
        )
        #expect(entry.profiles.reasoning == nil)

        let subject = try Self.subject(for: entry)
        let verdict = CapabilityControlResolution.resolve(
            provider: subject.provider, model: subject.model, capability: "reasoning"
        )
        #expect(verdict.state == .autoAvailable)
        #expect(verdict.intents.isEmpty)
        #expect(!verdict.viaLegacyProfile)

        #expect(
            ModelControlReasoningNotes.all(isConfigurable: true, intents: verdict.intents)
                .map(\.kind) == [.fixedTier],
            "\(key) panel copy"
        )

        let tiered = try Self.subject(for: try #require(snapshot.models["anthropic/claude-fable-5"]))
        let tieredIntents = CapabilityControlResolution.resolve(
            provider: tiered.provider, model: tiered.model, capability: "reasoning"
        ).intents
        #expect(!tieredIntents.isEmpty)
        #expect(
            !ModelControlReasoningNotes.all(isConfigurable: true, intents: tieredIntents)
                .map(\.kind).contains(.fixedTier)
        )
        await MetadataClient.shared.resetForTesting()
    }


    @Test("Explicit V2 Unavailable Outranks Legacy Profile")
    func explicitV2UnavailableOutranksLegacyProfile() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "capabilityRuntime": {
            "schemaVersion": \(RequestPreferenceResolver.runtimeSchemaVersion),
            "revision": "sha256:ladder-rung-2", "generatedAt": "2026-08-13T02:00:00Z",
            "recipes": {}, "controlDefinitions": {}, "sourceIndex": {}
          },
          "providers": {"qwen": {"resolveMap": {"ladder-model": "ladder-model"},
            "models": {"ladder-model": {
              "canonicalModelId": "ladder-model", "transport": "openai_chat",
              "capabilities": ["text", "web"],
              "profiles": {"webSearch": "qwen_web"},
              "capabilityControls": {"web": {
                "state": "unavailable", "reasonCode": "transport_not_supported"
              }}
            }}
          }}
        }
        """, metadataETag: Self.metadataETag)

        let persisted = TestFactories.makeModel(id: "ladder-model", capabilities: [.text, .web])
        let model = MetadataClient.shared.syncCurrentCapabilityEvidenceModel(persisted, providerKind: .qwen)
        let provider = TestFactories.makeProvider(id: UUID(), kind: .qwen, models: [model])
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: "u1",
            hasExplicitValue: true, metadataETag: Self.metadataETag
        )

        let verdict = CapabilityControlResolution.resolve(
            provider: provider, model: model, capability: "web"
        )
        #expect(verdict.state == .unavailable)
        #expect(!verdict.viaLegacyProfile)

        let projection = CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: provider, model: model, identity: identity,
            keys: ["web_search"], explicitKeys: ["web_search"]
        )
        #expect(!projection.permitsOutbound("web_search"))
        #expect(projection.resolution(for: "web_search")?.support == .unsupported)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Published Recipe Outranks Missing Legacy Profile")
    func publishedRecipeOutranksMissingLegacyProfile() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "capabilityRuntime": {
            "schemaVersion": \(RequestPreferenceResolver.runtimeSchemaVersion),
            "revision": "sha256:ladder-rung-1", "generatedAt": "2026-08-13T02:00:00Z",
            "recipes": {}, "controlDefinitions": {}, "sourceIndex": {}
          },
          "providers": {"openAI": {"resolveMap": {"recipe-only-model": "recipe-only-model"},
            "models": {"recipe-only-model": {
              "canonicalModelId": "recipe-only-model", "transport": "openai_responses",
              "capabilities": ["text", "web"],
              "profiles": {},
              "capabilityControls": {"web": {
                "state": "auto_available", "recipeRef": "openai.responses.web.v1"
              }}
            }}
          }}
        }
        """, metadataETag: Self.metadataETag)

        let persisted = TestFactories.makeModel(id: "recipe-only-model", capabilities: [.text, .web])
        let model = MetadataClient.shared.syncCurrentCapabilityEvidenceModel(persisted, providerKind: .openAI)
        let provider = TestFactories.makeProvider(id: UUID(), kind: .openAI, models: [model])
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: "u1",
            hasExplicitValue: true, metadataETag: Self.metadataETag
        )
        #expect(CapabilityControlResolution.resolve(
            provider: provider, model: model, capability: "web"
        ).state == .autoAvailable)

        let projection = CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: provider, model: model, identity: identity,
            keys: ["web_search"], explicitKeys: ["web_search"]
        )
        #expect(projection.permitsOutbound("web_search"))
        await MetadataClient.shared.resetForTesting()
    }


    @Test("Chip Matches Outbound For Every Production Model")
    func chipMatchesOutboundForEveryProductionModel() async throws {
        let snapshot = try Self.loadSnapshot()
        try await Self.install(snapshot)
        var availableWeb = 0
        var unavailableWeb = 0
        for (key, entry) in snapshot.models {
            let subject = try Self.subject(for: entry)
            let projection = CapabilityEvidenceProductionAdapter.capabilityProjection(
                provider: subject.provider, model: subject.model, identity: subject.identity,
                keys: ["web_search"], explicitKeys: []
            )
            let outbound = projection.permitsOutbound("web_search")
            let merged = CapabilityControlResolution.resolve(
                provider: subject.provider, model: subject.model, capability: "web"
            ).isAvailable
            #expect(outbound == merged)

            let decision = ChatCapabilityOutboundDecision.resolve(
                webRequested: true,
                webPermitted: outbound,
                reasoningModeRequested: .automatic,
                reasoningModePermitted: true,
                reasoningIntentRequested: nil,
                reasoningIntentPermitted: false
            )
            #expect(
                decision.activeCapabilityGlyphs.contains("globe") == outbound,
                "\(key): chip globe vs actual outbound"
            )
            outbound ? (availableWeb += 1) : (unavailableWeb += 1)
        }
        #expect(availableWeb > 0)
        #expect(unavailableWeb > 0)
        await MetadataClient.shared.resetForTesting()
    }
}
