import Foundation
import Testing
@testable import Oriveo

/// A resolved value carries its source. The mapping to the three source words comes from the
/// shared contract `generation_parameter_contract.v1.json#outboundRules.valueSources.presentation`.
@Suite("generation parameter resolution sources")
struct GenerationParameterResolutionSourceTests {

    @Test("each layer maps to the source word the contract declares")
    func presentationMatchesContract() throws {
        let contract = try GenerationOutboundPerItemContractTests.loadContract()
        let rules = try #require(contract["outboundRules"] as? [String: Any])
        let sources = try #require(rules["valueSources"] as? [String: Any])
        let presentation = try #require(sources["presentation"] as? [String: String])
        let schema = try #require(contract["schema"] as? [String: Any])
        let priority = try #require(schema["overridePriority"] as? [String])

        var covered: Set<String> = []
        for (layerName, expected) in presentation {
            let expectedSource = try #require(GenerationParameterResolution.Source(rawValue: expected))
            if layerName == "provider_default" {
                #expect(GenerationParameterResolution.source(for: nil) == expectedSource)
            } else {
                let layer = try #require(
                    GenerationParameterResolution.Layer(rawValue: layerName), "\(layerName) is missing from the client layer enum"
                )
                #expect(priority.contains(layerName), "\(layerName) is not a layer name in the contract overridePriority")
                #expect(GenerationParameterResolution.source(for: layer) == expectedSource)
                covered.insert(layerName)
            }
        }
        #expect(covered == Set(GenerationParameterResolution.Layer.allCases.map(\.rawValue)))
    }

    @Test("resolveWithSources reports the layer of every value and agrees with resolve")
    func storeResolutionCarriesLayers() {
        let suiteName = "generation-parameter-resolution-sources-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let providerID = UUID()
        let conversationID = UUID()
        let modelID = "local-model"

        store.setConnectionDefaults(.init(values: [
            "temperature": .init(state: .value, value: .number(0.3)),
            "top_k": .init(state: .value, value: .number(40)),
        ]), providerID: providerID)
        store.setModelDefaults(.init(values: [
            "top_p": .init(state: .value, value: .number(0.9)),
            "seed": .init(state: .omit),
        ]), providerID: providerID, modelID: modelID)
        store.setSessionOverrides(.init(values: [
            "temperature": .init(state: .value, value: .number(0.7)),
        ]), providerID: providerID, modelID: modelID, conversationID: conversationID)
        let transient = GenerationParameterOverrides(values: [
            "max_output_tokens": .init(state: .value, value: .number(64)),
        ])

        let resolution = store.resolveWithSources(
            transient: transient, providerID: providerID, modelID: modelID, conversationID: conversationID
        )
        #expect(resolution.entries["temperature"]?.layer == .conversation)
        #expect(resolution.entries["temperature"]?.override.value == .number(0.7))
        #expect(resolution.entries["top_p"]?.layer == .connectionModel)
        #expect(resolution.entries["top_k"]?.layer == .connection)
        #expect(resolution.entries["max_output_tokens"]?.layer == .singleSend)
        // An explicit "do not send" carries its layer too, so it is never shown as left to the model.
        #expect(resolution.entries["seed"]?.override.state == .omit)
        #expect(resolution.entries["seed"]?.layer == .connectionModel)

        #expect(resolution.source(for: "temperature") == .conversation)
        #expect(resolution.source(for: "max_output_tokens") == .conversation)
        #expect(resolution.source(for: "top_p") == .modelDefault)
        #expect(resolution.source(for: "top_k") == .modelDefault)
        #expect(resolution.source(for: "min_p") == .providerDecides)

        #expect(resolution.overrides == store.resolve(
            transient: transient, providerID: providerID, modelID: modelID, conversationID: conversationID
        ))
    }
}
