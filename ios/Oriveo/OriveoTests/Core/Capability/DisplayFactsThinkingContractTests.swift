import Foundation
import Testing
@testable import Oriveo

// Shared fixture `shared/test-fixtures/capability/display-facts.v1.json#thinkingCases`:
// "show thinking" is a thinking fact under the facade's `reasoning` key, produced by each form only from that
// form's own source; a missing source = not shown.
// Each case sets up that form's source per the fixture's source and takes the fact through production
// `CapabilityDisplayFacts`; thinkingRow is derived from the fact and the tiers per the fixture: with tiers =
// switchable, a model that thinks with nothing to choose = fixed, otherwise none.
@Suite("display-facts.v1 thinkingCases (iOS)", .serialized, .sharedProcessState)
struct DisplayFactsThinkingContractTests {
    private static let fixtureName = "display-facts.v1.json"
    private static let metadataETag = "display-facts-thinking"
    private static let coveredIDs: Set<String> = [
        "official_catalog_reasoning_switchable",
        "official_catalog_no_reasoning",
        "official_catalog_miss_model_facts",
        "subscription_first_hand_efforts",
        "relay_declared_reasoning",
    ]

    private struct Case {
        let id: String
        let form: String
        let modelID: String
        let source: [String: Any]
        let tiers: [String]
        let showsThinking: Bool
        let thinkingRow: String
    }

    private static func cases() throws -> [Case] {
        let fixture = try CapabilitySharedFixture.load(fixtureName)
        let raw = try #require(fixture["thinkingCases"] as? [[String: Any]])
        return try raw.map { item in
            let expect = try #require(item["expect"] as? [String: Any])
            return Case(
                id: try #require(item["id"] as? String),
                form: try #require(item["form"] as? String),
                modelID: try #require(item["modelId"] as? String),
                source: try #require(item["source"] as? [String: Any]),
                tiers: try #require(item["tiers"] as? [String]),
                showsThinking: try #require(expect["showsThinking"] as? Bool),
                thinkingRow: try #require(expect["thinkingRow"] as? String)
            )
        }
    }

    private static func thinkingCase(_ id: String) throws -> Case {
        try #require(try cases().first { $0.id == id }, "The fixture has no \(id)")
    }

    private static func thinkingRow(thinks: Bool, tiers: [String]) -> String {
        if !tiers.isEmpty { return "switchable" }
        return thinks ? "fixed" : "none"
    }

    private static func capabilities(_ raw: Any?) -> [ModelCapability] {
        ((raw as? [String]) ?? []).compactMap(ModelCapability.init(rawValue:))
    }

    /// Official catalog hit: puts the entry into the metadata snapshot and goes through the production read point that holds a Provider.
    private static func installOfficialCatalog(modelID: String, capabilities: [String]) async throws {
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: capabilities), as: UTF8.self)
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "providers": {"qwen": {"resolveMap": {"\(modelID)": "\(modelID)"},
            "models": {"\(modelID)": {
              "canonicalModelId": "\(modelID)", "transport": "openai_chat",
              "capabilities": \(encoded), "profiles": {}
            }}
          }}
        }
        """, metadataETag: metadataETag)
    }

    private static func thinks(_ item: Case) async throws -> Bool {
        let source = item.source
        switch item.form {
        case "official":
            let model = TestFactories.makeModel(id: item.modelID, capabilities: [.text])
            if let catalogCapabilities = source["catalogCapabilities"] as? [String] {
                try await installOfficialCatalog(modelID: item.modelID, capabilities: catalogCapabilities)
                let provider = TestFactories.makeProvider(kind: .qwen, models: [model])
                return CapabilityDisplayFacts.thinking(provider: provider, model: model)
            }
            // Catalog miss: the entry is empty and the only source left is model-facts.
            let facts = try #require(source["modelFacts"] as? [String: Any])
            let decoded = try JSONDecoder().decode(
                MetadataClient.ModelFacts.self, from: JSONSerialization.data(withJSONObject: facts)
            )
            return CapabilityDisplayFacts.thinking(
                form: .official, source: .init(model: model, officialEntry: nil, modelFacts: decoded)
            )
        case "subscription":
            var model = TestFactories.makeModel(id: item.modelID, capabilities: [.text])
            model.upstreamReasoningLevels = (source["firstHandEfforts"] as? [String]) ?? []
            var provider = TestFactories.makeProvider(kind: .grok, models: [model], catalogModels: [model])
            provider.authMode = .subscription
            return CapabilityDisplayFacts.thinking(provider: provider, model: model)
        case "relay":
            let model = TestFactories.makeModel(
                id: item.modelID, capabilities: [.text] + capabilities(source["declaredCapabilities"])
            )
            let provider = TestFactories.makeProvider(kind: .relay, models: [model])
            return CapabilityDisplayFacts.thinking(provider: provider, model: model)
        default:
            Issue.record("\(item.id): unknown form \(item.form)")
            throw CancellationError()
        }
    }

    private static func check(_ id: String) async throws {
        let item = try thinkingCase(id)
        let thinks = try await thinks(item)
        #expect(thinks == item.showsThinking, "\(id) showsThinking")
        #expect(thinkingRow(thinks: thinks, tiers: item.tiers) == item.thinkingRow, "\(id) thinkingRow")
    }

    @Test("The fixture's thinkingCases id set == the list covered by this file")
    func coversEveryFixtureCase() throws {
        #expect(Set(try Self.cases().map(\.id)) == Self.coveredIDs)
    }

    @Test func DISPLAY_FACTS_official_catalog_reasoning_switchable() async throws {
        try await Self.check("official_catalog_reasoning_switchable")
    }

    @Test func DISPLAY_FACTS_official_catalog_no_reasoning() async throws {
        try await Self.check("official_catalog_no_reasoning")
    }

    @Test func DISPLAY_FACTS_official_catalog_miss_model_facts() async throws {
        try await Self.check("official_catalog_miss_model_facts")
    }

    @Test func DISPLAY_FACTS_subscription_first_hand_efforts() async throws {
        try await Self.check("subscription_first_hand_efforts")
    }

    @Test func DISPLAY_FACTS_relay_declared_reasoning() async throws {
        try await Self.check("relay_declared_reasoning")
    }

    // Regression outside the fixture: on a subscription cold start (the first-hand tier table is always empty),
    // the thinking display falls back to model-facts.reasoning; a non-empty first-hand list still wins, and
    // having neither = not shown.
    @Test("With first-hand absent, the subscription thinking display falls back to modelFacts.reasoning")
    func subscriptionThinkingFallsBackToModelFacts() async throws {
        let modelID = "display-facts-sub-cold"
        let key = try #require(MetadataClient.modelFactsKey(providerKind: .grok, modelID: modelID))
        let payload: [String: Any] = [
            "version": 83, "view": "lean", "contractVersion": 1, "capabilityContractVersion": 2,
            "providers": [String: Any](),
            "modelFacts": [key: ["reasoning": true, "source": "models.dev"]],
            "modelFactsRevision": "display-facts-thinking-sub",
        ]
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        )

        let model = TestFactories.makeModel(id: modelID, capabilities: [.text])
        #expect(model.upstreamReasoningLevels.isEmpty, "Cold-start shape: the first-hand tier table is empty")
        var provider = TestFactories.makeProvider(kind: .grok, models: [model], catalogModels: [model])
        provider.authMode = .subscription
        #expect(ProviderForm.of(provider) == .subscription)
        #expect(CapabilityDisplayFacts.thinking(provider: provider, model: model), "First-hand absent -> modelFacts.reasoning")

        let unknown = TestFactories.makeModel(id: "display-facts-sub-unknown", capabilities: [.text])
        var unknownProvider = TestFactories.makeProvider(kind: .grok, models: [unknown], catalogModels: [unknown])
        unknownProvider.authMode = .subscription
        #expect(!CapabilityDisplayFacts.thinking(provider: unknownProvider, model: unknown), "Having neither = not shown")
        await MetadataClient.shared.resetForTesting()
    }
}
