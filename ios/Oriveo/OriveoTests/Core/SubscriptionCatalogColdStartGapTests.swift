import Testing
@testable import Oriveo

@Suite("Subscription Catalog Cold Start Gap Tests")
struct SubscriptionCatalogColdStartGapTests {
    private func model(reasoning: Bool, levels: [String], apiBackend: String?) -> AIModel {
        var m = TestFactories.makeModel(id: "grok-4.6", capabilities: reasoning ? [.text, .reasoning] : [.text])
        m.reasoningModeAvailable = reasoning
        m.upstreamReasoningLevels = levels
        m.upstreamAPIBackend = apiBackend
        return m
    }

    private func provider(authMode: ProviderAuthMode, models: [AIModel], kind: ProviderKind = .grok) -> Provider {
        var p = TestFactories.makeProvider(kind: kind, models: models)
        p.authMode = authMode
        return p
    }

    @Test("Empty Reasoning Levels Is Gap")
    func emptyReasoningLevelsIsGap() {
        let p = provider(authMode: .subscription, models: [model(reasoning: true, levels: [], apiBackend: "responses")])
        #expect(AppState.subscriptionCatalogColdStartGap(provider: p))
    }

    @Test("Nil Api Backend Is Gap")
    func nilApiBackendIsGap() {
        let p = provider(authMode: .subscription, models: [model(reasoning: false, levels: [], apiBackend: nil)])
        #expect(AppState.subscriptionCatalogColdStartGap(provider: p))
    }

    @Test("Fully Populated Is Not Gap")
    func fullyPopulatedIsNotGap() {
        let p = provider(authMode: .subscription, models: [model(reasoning: true, levels: ["high", "low"], apiBackend: "responses")])
        #expect(!AppState.subscriptionCatalogColdStartGap(provider: p))
    }

    @Test("Codex With Levels Is Not Gap")
    func codexWithLevelsIsNotGap() {
        let m = model(reasoning: true, levels: ["low", "medium", "high"], apiBackend: nil)
        let p = provider(authMode: .subscription, models: [m], kind: .openAI)
        #expect(!AppState.subscriptionCatalogColdStartGap(provider: p))
    }

    @Test("Codex With Empty Levels Is Gap")
    func codexWithEmptyLevelsIsGap() {
        let m = model(reasoning: true, levels: [], apiBackend: nil)
        let p = provider(authMode: .subscription, models: [m], kind: .openAI)
        #expect(AppState.subscriptionCatalogColdStartGap(provider: p))
    }

    @Test("Api Key Link Never Gap")
    func apiKeyLinkNeverGap() {
        let p = provider(authMode: .apiKey, models: [model(reasoning: true, levels: [], apiBackend: nil)])
        #expect(!AppState.subscriptionCatalogColdStartGap(provider: p))
    }
}
