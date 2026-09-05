import Testing
@testable import Oriveo

@Suite("Capability action candidates")
struct CapabilityControlActionCandidatesTests {
    private struct Candidate: Equatable, Identifiable {
        let id: String
    }

    @Test("only exact-transport auto_available models are kept")
    func exactTransportAutoAvailableOnly() {
        let models = [Candidate(id: "a"), Candidate(id: "b"), Candidate(id: "c"), Candidate(id: "d")]
        let lookups: [String: CapabilityControlActionCandidates.ModelCapabilityLookup] = [
            // auto_available + exact transport match → kept
            "a": .init(state: "auto_available", recipeTransport: "openai_chat", modelTransport: "openai_chat"),
            // auto_available but recipe transport differs from this model's route → dropped
            "b": .init(state: "auto_available", recipeTransport: "openai_chat", modelTransport: "anthropic_messages"),
            // not auto_available at all → dropped
            "c": .init(state: "unknown", recipeTransport: nil, modelTransport: "openai_chat"),
            // auto_available but missing recipe/model transport (unresolved runtime) → dropped
            "d": .init(state: "auto_available", recipeTransport: nil, modelTransport: nil),
        ]

        let result = CapabilityControlActionCandidates.supportingModels(
            capability: "web", models: models
        ) { lookups[$0.id]! }

        #expect(result == [Candidate(id: "a")])
    }

    @Test("no supporting model yields an empty array, never a fabricated candidate")
    func noCandidatesIsEmpty() {
        let models = [Candidate(id: "a"), Candidate(id: "b")]

        let result = CapabilityControlActionCandidates.supportingModels(
            capability: "reasoning", models: models
        ) { _ in .init(state: "unknown", recipeTransport: nil, modelTransport: "openai_chat") }

        #expect(result.isEmpty)
    }

    @Test("Gemini's sole transport alias still resolves as an exact match")
    func geminiTransportAliasMatches() {
        let models = [Candidate(id: "a")]

        let result = CapabilityControlActionCandidates.supportingModels(
            capability: "web", models: models
        ) { _ in .init(state: "auto_available", recipeTransport: "gemini_generate_content", modelTransport: "gemini_generate") }

        #expect(result == [Candidate(id: "a")])
    }
}
