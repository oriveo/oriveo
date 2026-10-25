import Foundation
import Testing
@testable import Oriveo

/// The price label picks the price by the connection's effective region: the model goes through production metadata decoding and `enrichStoredModel`
/// to get the stored model-level price, then through `CatalogModelBuilder.connectionPriced` (the same `RegionPricingSelector` as billing)
/// and the production label projections (`providerModelSpecifications` / `ModelPickerPricePresentation` / `normalizedPriceTier`) to produce the text.
@Suite("RegionPriceLabel", .serialized, .sharedProcessState)
struct RegionPriceLabelTests {
    @Test("moonshot cn connection labels the CNY region price")
    func cnConnectionShowsCny() async throws {
        try await loadCatalog()
        let priced = CatalogModelBuilder.connectionPriced(storedMoonshotModel("kimi-example"), provider: moonshot(region: "cn"))

        #expect(priced.priceCurrencyCode == "CNY")
        #expect(labelTier(storedMoonshotModel("kimi-example"), moonshot(region: "cn")) == "CN¥4/M")
        // The input / output breakdown, the picker and the price label use the same currency and the same notation.
        #expect(prices(priced).first == priced.normalizedPriceTier)
        #expect(prices(priced).count == 2)
        #expect(prices(priced).allSatisfy { $0.contains("¥") && !$0.contains("$") })
        let picker = ModelPickerPricePresentation(model: priced)
        #expect(picker.input == prices(priced).first)
        #expect(picker.output == prices(priced).last)
    }

    @Test("moonshot intl connection keeps the model-level USD price")
    func intlConnectionShowsUsd() async throws {
        try await loadCatalog()
        let stored = storedMoonshotModel("kimi-example")
        let priced = CatalogModelBuilder.connectionPriced(stored, provider: moonshot(region: "intl"))

        #expect(priced == stored)
        #expect(priced.priceCurrencyCode == nil)
        #expect(prices(priced) == ["$0.6/M", "$2.5/M"])
    }

    @Test("without a connection the label stays the model-level price")
    func noConnectionShowsModelLevel() async throws {
        try await loadCatalog()
        let stored = storedMoonshotModel("kimi-example")

        #expect(stored.priceCurrencyCode == nil)
        #expect(stored.normalizedPriceTier == "$0.6/M")
        #expect(prices(stored) == ["$0.6/M", "$2.5/M"])
    }

    @Test("cn-only model on an intl connection shows price unknown, not $0")
    func cnOnlyOutsideCnIsUnknown() async throws {
        try await loadCatalog()
        let priced = CatalogModelBuilder.connectionPriced(storedMoonshotModel("image-cn-only"), provider: moonshot(region: "intl"))

        #expect(priced.normalizedPriceTier == L10n.tr("Price unknown"))
        #expect(prices(priced).isEmpty)
        #expect(ModelPickerPricePresentation(model: priced).fallback == L10n.tr("Price unknown"))
    }

    @Test("relay matched to an official CNY model labels in CNY")
    func relayMatchedCnyShowsCny() async throws {
        try await loadCatalog()
        var stored = TestFactories.makeModel(id: "other-model")
        stored.promptPrice = 0.000_004
        stored.completionPrice = 0.000_016
        let relay = TestFactories.makeProvider(kind: .relay, models: [])
        let priced = CatalogModelBuilder.connectionPriced(stored, provider: relay)

        #expect(priced.priceCurrencyCode == "CNY")
        #expect(labelTier(stored, relay) == "CN¥4/M")
        #expect(prices(priced).first == priced.normalizedPriceTier)
        #expect(prices(priced).allSatisfy { $0.contains("¥") && !$0.contains("$") })
    }

    @Test("a connection without region pricing labels a CNY model-level price in CNY from the catalog, not $")
    func cnyModelLevelShowsCny() async throws {
        try await loadCatalog()
        let stored = CatalogModelBuilder.enrichStoredModel(TestFactories.makeModel(id: "other-model"), providerKind: .anthropic)
        let anthropic = TestFactories.makeProvider(kind: .anthropic, models: [])

        // Storage keeps only the USD string: a non-USD price is stored empty with no currency; display reads the catalog model-level price and currency through the same price-selection entry.
        #expect(stored.priceTier.isEmpty)
        #expect(stored.priceCurrencyCode == nil)
        let priced = CatalogModelBuilder.connectionPriced(stored, provider: anthropic)
        #expect(priced.priceCurrencyCode == "CNY")
        #expect(labelTier(stored, anthropic) == "CN¥4/M")
        #expect(prices(priced).first == priced.normalizedPriceTier)
        #expect(prices(priced).count == 2)
        #expect(prices(priced).allSatisfy { $0.contains("¥") && !$0.contains("$") })
    }

    @Test("a model missing from the catalog keeps its stored price string")
    func catalogMissKeepsStoredTier() async throws {
        try await loadCatalog()
        var manual = TestFactories.makeModel(id: "relay-hand-priced")
        manual.priceTier = "$9/M"

        let priced = CatalogModelBuilder.connectionPriced(manual, provider: moonshot(region: "intl"))
        #expect(priced == manual)
        #expect(priced.normalizedPriceTier == "$9/M")
    }

    @Test("metadata arriving after cold start changes the row refresh key and relabels the price")
    func lateMetadataRefreshesLabel() async throws {
        await MetadataClient().resetForTesting()
        let stored = TestFactories.makeModel(id: "other-model")
        let anthropic = TestFactories.makeProvider(kind: .anthropic, models: [])
        #expect(CatalogModelBuilder.connectionPriced(stored, provider: anthropic) == stored)
        let coldRow = ModelListMetadataRow(model: stored, provider: anthropic, capabilityEvidenceRevision: 1)
        let coldStrip = ModelMetadataInlineStrip(model: stored, provider: anthropic, capabilityEvidenceRevision: 1)

        try await loadCatalog()
        // A row rebuilt for the same model / provider carries a new generation; SwiftUI re-runs body and re-selects the price only when it sees a difference.
        let warmRow = ModelListMetadataRow(model: stored, provider: anthropic, capabilityEvidenceRevision: 1)
        let warmStrip = ModelMetadataInlineStrip(model: stored, provider: anthropic, capabilityEvidenceRevision: 1)
        #expect(warmRow.metadataGeneration != coldRow.metadataGeneration)
        #expect(warmStrip.metadataGeneration != coldStrip.metadataGeneration)
        #expect(labelTier(stored, anthropic) == "CN¥4/M")
    }

    // MARK: - Helpers

    private func prices(_ model: AIModel) -> [String] {
        providerModelSpecifications(for: model).filter { $0.id == "input" || $0.id == "output" }.map(\.value)
    }

    /// Pins the price label to en_US and asserts literals; how the UI locale writes it is locked by the "breakdown == label" consistency checks above.
    private func labelTier(_ model: AIModel, _ provider: Provider) -> String {
        CatalogModelBuilder.connectionPriced(model, provider: provider, locale: Locale(identifier: "en_US")).normalizedPriceTier
    }

    private func storedMoonshotModel(_ id: String) -> AIModel {
        CatalogModelBuilder.enrichStoredModel(TestFactories.makeModel(id: id), providerKind: .moonshot)
    }

    private func moonshot(region: String) -> Provider {
        var provider = TestFactories.makeProvider(kind: .moonshot, models: [])
        provider.endpointSource = .region(region)
        return provider
    }

    /// moonshot uses the two models from the shared fixture; anthropic holds one official model with a model-level CNY price so a Relay can match across providers.
    private func loadCatalog() async throws {
        let fixture = try JSONValue(data: Data(contentsOf: sharedFixtureURL("provider-pricing/region-pricing.v1.json")))
        var moonshotModels: [String: Any] = [:]
        for ref in ["model", "cnOnlyModel"] {
            var model = try #require(fixture[ref]?.anyValue as? [String: Any])
            let id = try #require(model["id"] as? String)
            model["id"] = nil
            model["canonicalModelId"] = id
            model["displayName"] = id
            model["capabilities"] = ["text"]
            moonshotModels[id] = model
        }
        let payload: [String: Any] = [
            "version": 1,
            "updatedAt": "2026-10-19T00:00:00Z",
            "providers": [
                "moonshot": [
                    "displayName": "Moonshot",
                    "defaultModelId": "kimi-example",
                    "resolveMap": ["kimi-example": "kimi-example", "image-cn-only": "image-cn-only"],
                    "models": moonshotModels,
                ],
                "anthropic": [
                    "displayName": "Anthropic",
                    "defaultModelId": "other-model",
                    "resolveMap": ["other-model": "other-model"],
                    "models": [
                        "other-model": [
                            "canonicalModelId": "other-model",
                            "displayName": "Other",
                            "pricingUnit": "per_token",
                            "pricingStatus": "priced",
                            "currencyCode": "CNY",
                            "pricing": ["promptPerMToken": 4.0, "completionPerMToken": 16.0],
                            "capabilities": ["text"],
                        ],
                    ],
                ],
            ],
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let client = MetadataClient()
        await client.resetForTesting()
        try await client.loadForTesting(json: json)
    }
}
