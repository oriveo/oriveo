import Foundation
import Testing
@testable import Oriveo

/// Case-by-case run of `subscription-facts.v1.json` inputCases: the input verdict of the subscription form
/// (first-hand > model-facts > catalog_silent) goes through production `capabilityProjection(provider:)` and
/// the subscription branch of `inputCapabilityProjections`, projected per the contract table.
/// firstHand is written into the catalog entry's `upstreamInputModalities`, and modelFacts are delivered through
/// the `modelFacts` dictionary of `/api/metadata`; endImplements is decided by the subscription's final transport
/// (Codex = Responses, no video family; Grok declaring a chat backend = Chat, with the video family).
@Suite("SubscriptionFactsContract", .serialized, .sharedProcessState)
struct SubscriptionFactsContractTests {
    private static let modelID = "sub-facts-model"

    private static func inputCase(_ id: String) throws -> [String: Any] {
        let fixture = try CapabilitySharedFixture.load("subscription-facts.v1.json")
        let cases = try #require(fixture["inputCases"] as? [[String: Any]])
        return try #require(cases.first { $0["id"] as? String == id }, "Fixture is missing \(id)")
    }

    private static func loadModelFacts(
        providerKind: ProviderKind, input: [String]? = nil, reasoningEfforts: [String]? = nil
    ) async throws {
        var facts: [String: Any] = [:]
        if input != nil || reasoningEfforts != nil,
           let key = MetadataClient.modelFactsKey(providerKind: providerKind, modelID: modelID) {
            var fact: [String: Any] = ["source": "models.dev"]
            if let input { fact["modalities"] = ["input": input] }
            if let reasoningEfforts {
                fact["reasoning"] = true
                fact["reasoningEfforts"] = reasoningEfforts
            }
            facts[key] = fact
        }
        let payload: [String: Any] = [
            "version": 83,
            "view": "lean",
            "contractVersion": 1,
            "capabilityContractVersion": 2,
            "providers": [String: Any](),
            "modelFacts": facts,
            "modelFactsRevision": "subscription-facts-contract",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: String(decoding: data, as: UTF8.self))
    }

    private func run(_ id: String) async throws {
        let item = try Self.inputCase(id)
        let key = try #require(item["key"] as? String, "\(id) key")
        let firstHand = item["firstHand"] as? [String]
        let modelFacts = item["modelFacts"] as? [String]
        let endImplements = try #require(item["endImplements"] as? Bool, "\(id) endImplements")
        let expect = try #require(item["expect"] as? [String: Any], "\(id) expect")

        // The video family exists only on the Chat transport: video cases that need "implemented by this end"
        // use the Grok chat backend, everything else uses Codex (Responses).
        let useChat = key == CapabilityEvidenceFacade.videoInputKey && endImplements
        let kind: ProviderKind = useChat ? .grok : .openAI
        var model = TestFactories.makeModel(id: Self.modelID, capabilities: [.text])
        model.upstreamInputModalities = firstHand
        model.upstreamAPIBackend = useChat ? "chat" : nil
        var provider = TestFactories.makeProvider(kind: kind, models: [])
        provider.authMode = .subscription
        provider.catalogModels = [model]
        #expect(ProviderForm.of(provider) == .subscription, "\(id) form")
        try await Self.loadModelFacts(providerKind: kind, input: modelFacts)

        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: "subscription-facts", hasExplicitValue: false
        )
        let projection = CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: provider, model: model, identity: identity, keys: [key]
        )
        let transport = projection.identity?.query.effectiveTransport
        let wireFamily = CapabilityEvidenceFacade.inputWireFamily(key: key, transport: transport)
        #expect(
            (wireFamily.map(CapabilityEvidenceFacade.implementsWireFamily) ?? false) == endImplements,
            "\(id) precondition: this end's implementation of transport \(transport ?? "nil") matches the fixture"
        )

        let verdict = SubscriptionTruthAdapter.inputVerdict(
            key: key, resolution: projection.resolution(for: key), transport: transport
        )
        #expect(verdict.state.rawValue == expect["state"] as? String, "\(id) state")
        if let reasonCode = expect["reasonCode"] as? String {
            #expect(verdict.reasonCode == reasonCode, "\(id) reasonCode")
        }
        let input = try #require(projection.inputProjection(for: key), "\(id) a subscription must have a projection")
        #expect(input.visible == expect["visible"] as? Bool, "\(id) visible")
        #expect(input.editable == expect["editable"] as? Bool, "\(id) editable")
        #expect(input.outbound.rawValue == expect["outbound"] as? String, "\(id) outbound")
        #expect(input.disabledReason?.rawValue == expect["disabledReason"] as? String
            || expect["disabledReason"] == nil, "\(id) disabledReason")
        #expect(projection.permitsOutbound(key) == (expect["outbound"] as? String == "native_part"), "\(id) outbound permission")
        await MetadataClient.shared.resetForTesting()
    }

    @Test func SUBSCRIPTION_FACTS_inputCases_id_set() throws {
        let fixture = try CapabilitySharedFixture.load("subscription-facts.v1.json")
        let cases = try #require(fixture["inputCases"] as? [[String: Any]])
        #expect(Set(cases.compactMap { $0["id"] as? String }) == [
            "first_hand_image_auto",
            "first_hand_without_video_unavailable",
            "model_facts_image_auto",
            "model_facts_without_file_unknown",
            "model_facts_pdf_is_file",
            "no_source_unknown",
            "end_not_implemented_disabled",
        ])
    }

    @Test func SUBSCRIPTION_FACTS_first_hand_image_auto() async throws { try await run("first_hand_image_auto") }
    @Test func SUBSCRIPTION_FACTS_first_hand_without_video_unavailable() async throws {
        try await run("first_hand_without_video_unavailable")
    }
    @Test func SUBSCRIPTION_FACTS_model_facts_image_auto() async throws { try await run("model_facts_image_auto") }
    @Test func SUBSCRIPTION_FACTS_model_facts_without_file_unknown() async throws {
        try await run("model_facts_without_file_unknown")
    }
    @Test func SUBSCRIPTION_FACTS_model_facts_pdf_is_file() async throws { try await run("model_facts_pdf_is_file") }
    @Test func SUBSCRIPTION_FACTS_no_source_unknown() async throws { try await run("no_source_unknown") }
    @Test func SUBSCRIPTION_FACTS_end_not_implemented_disabled() async throws {
        try await run("end_not_implemented_disabled")
    }

    // MARK: - reasoningLevelCases: subscription thinking levels, first-hand > model-facts (only when first-hand is absent) > empty

    private static func reasoningLevelCase(_ id: String) throws -> [String: Any] {
        let fixture = try CapabilitySharedFixture.load("subscription-facts.v1.json")
        let cases = try #require(fixture["reasoningLevelCases"] as? [[String: Any]])
        return try #require(cases.first { $0["id"] as? String == id }, "Fixture is missing \(id)")
    }

    /// First-hand is written into the catalog entry's `upstreamReasoningLevels` (null = first-hand absent = empty
    /// list), and model-facts are delivered through `/api/metadata`; the levels come from the single production
    /// source `subscriptionDeclaredReasoningLevels` (shared by the UI verdict and the outbound request).
    private func runReasoningLevels(_ id: String) async throws {
        let item = try Self.reasoningLevelCase(id)
        let firstHand = item["firstHandEfforts"] as? [String]
        let modelFactsEfforts = item["modelFactsEfforts"] as? [String]
        let expect = try #require(item["expect"] as? [String], "\(id) expect")

        var model = TestFactories.makeModel(id: Self.modelID, capabilities: [.text])
        model.upstreamReasoningLevels = firstHand ?? []
        var provider = TestFactories.makeProvider(kind: .grok, models: [])
        provider.authMode = .subscription
        provider.catalogModels = [model]
        #expect(ProviderForm.of(provider) == .subscription, "\(id) form")
        try await Self.loadModelFacts(providerKind: .grok, reasoningEfforts: modelFactsEfforts)

        let levels = CapabilityControlResolution.subscriptionDeclaredReasoningLevels(
            providerKind: provider.kind, model: model
        )
        #expect(levels == expect, "\(id) levels")
        await MetadataClient.shared.resetForTesting()
    }

    @Test func SUBSCRIPTION_FACTS_reasoningLevelCases_id_set() throws {
        let fixture = try CapabilitySharedFixture.load("subscription-facts.v1.json")
        let cases = try #require(fixture["reasoningLevelCases"] as? [[String: Any]])
        #expect(Set(cases.compactMap { $0["id"] as? String }) == [
            "first_hand_wins",
            "model_facts_when_first_hand_absent",
            "none_empty",
        ])
    }

    @Test func SUBSCRIPTION_FACTS_first_hand_wins() async throws { try await runReasoningLevels("first_hand_wins") }
    @Test func SUBSCRIPTION_FACTS_model_facts_when_first_hand_absent() async throws {
        try await runReasoningLevels("model_facts_when_first_hand_absent")
    }
    @Test func SUBSCRIPTION_FACTS_none_empty() async throws { try await runReasoningLevels("none_empty") }

    // MARK: - modelFactsLookupCases: subscription model-facts lookup, model.id > resolveMap canonical

    private static func lookupCase(_ id: String) throws -> [String: Any] {
        let fixture = try CapabilitySharedFixture.load("subscription-facts.v1.json")
        let cases = try #require(fixture["modelFactsLookupCases"] as? [[String: Any]])
        return try #require(cases.first { $0["id"] as? String == id }, "Fixture is missing \(id)")
    }

    /// The canonical id is delivered through the metadata `resolveMap` (null = not found in resolveMap), and every
    /// id in modelFactsKeys gets one dictionary fact; usedKey comes from the single production lookup
    /// `modelFactsLookup`, and the tool_call and levels consumers are then checked to follow it.
    private func runLookup(_ id: String) async throws {
        let item = try Self.lookupCase(id)
        let modelID = try #require(item["modelId"] as? String, "\(id) modelId")
        let canonical = item["canonicalModelId"] as? String
        let keys = try #require(item["modelFactsKeys"] as? [String], "\(id) modelFactsKeys")
        let expect = try #require(item["expect"] as? [String: Any], "\(id) expect")
        let usedKey = expect["usedKey"] as? String
        let kind: ProviderKind = .openAI

        var facts: [String: Any] = [:]
        for key in keys {
            let factKey = try #require(MetadataClient.modelFactsKey(providerKind: kind, modelID: key), "\(id) key")
            facts[factKey] = [
                "source": "models.dev", "toolCall": true,
                "reasoning": true, "reasoningEfforts": ["low", "high"],
            ]
        }
        var providers: [String: Any] = [:]
        if let canonical {
            providers["openAI"] = [
                "resolveMap": [modelID: canonical],
                "models": [canonical: ["canonicalModelId": canonical, "capabilities": ["text"]]],
            ]
        }
        let payload: [String: Any] = [
            "version": 83,
            "view": "lean",
            "contractVersion": 1,
            "capabilityContractVersion": 2,
            "providers": providers,
            "modelFacts": facts,
            "modelFactsRevision": "subscription-facts-lookup",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: String(decoding: data, as: UTF8.self))

        let model = TestFactories.makeModel(id: modelID, capabilities: [.text])
        if let canonical {
            #expect(
                MetadataClient.shared.syncResolveCatalogModel(modelID: modelID, providerKind: kind)?.canonicalModelId
                    == canonical,
                "\(id) precondition: resolveMap resolves to the canonical id"
            )
        }
        let lookup = SubscriptionTruthAdapter.modelFactsLookup(providerKind: kind, model: model)
        #expect(lookup?.usedModelID == usedKey, "\(id) usedKey")
        #expect(
            SubscriptionTruthAdapter.toolCallModelFact(providerKind: kind, model: model) == (usedKey == nil ? nil : true),
            "\(id) tool_call uses the same lookup"
        )
        #expect(
            CapabilityControlResolution.subscriptionDeclaredReasoningLevels(providerKind: kind, model: model)
                == (usedKey == nil ? [] : ["low", "high"]),
            "\(id) levels use the same lookup"
        )
        await MetadataClient.shared.resetForTesting()
    }

    @Test func SUBSCRIPTION_FACTS_modelFactsLookupCases_id_set() throws {
        let fixture = try CapabilitySharedFixture.load("subscription-facts.v1.json")
        let cases = try #require(fixture["modelFactsLookupCases"] as? [[String: Any]])
        #expect(Set(cases.compactMap { $0["id"] as? String }) == [
            "lookup_by_model_id",
            "lookup_falls_back_to_canonical",
            "lookup_none_when_both_missing",
            "lookup_no_canonical_only_model_id",
        ])
    }

    @Test func SUBSCRIPTION_FACTS_lookup_by_model_id() async throws { try await runLookup("lookup_by_model_id") }
    @Test func SUBSCRIPTION_FACTS_lookup_falls_back_to_canonical() async throws {
        try await runLookup("lookup_falls_back_to_canonical")
    }
    @Test func SUBSCRIPTION_FACTS_lookup_none_when_both_missing() async throws {
        try await runLookup("lookup_none_when_both_missing")
    }
    @Test func SUBSCRIPTION_FACTS_lookup_no_canonical_only_model_id() async throws {
        try await runLookup("lookup_no_canonical_only_model_id")
    }
}
