import Foundation
import Testing
@testable import Oriveo

/// Shared fixture `shared/test-fixtures/provider-pricing/region-pricing.v1.json`:
/// models go through production metadata decoding (`MetadataClient.loadForTesting` → `resolveCatalogModel`), then production price selection
/// `RegionPricingSelector.select` and estimation `CostCalculator.estimate`. One `REGION_PRICING_<id>` test per case.
@Suite("RegionPricingContract", .serialized, .sharedProcessState)
struct RegionPricingContractTests {
    private static let providerKey = "anthropic"

    @Test("fixture cases ids match the REGION_PRICING_ tests one to one")
    func fixtureIDsMatchTests() throws {
        let ids = Set((try Self.fixture()["cases"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue })
        let tests: Set<String> = [
            "cn_connection_uses_cny_entry", "intl_connection_uses_model_level", "no_stored_choice_matches_base_url",
            "no_choice_no_match_takes_first_option", "malformed_entry_dropped_model_kept",
            "unlisted_region_falls_back_to_model_level", "cn_only_entry_prices_otherwise_unknown_model",
            "cn_only_model_outside_cn_is_unavailable", "relay_connection_ignores_region_pricing",
            "unknown_payload_keys_ignored",
        ]
        #expect(ids == tests)
    }

    @Test func REGION_PRICING_cn_connection_uses_cny_entry() async throws { try await assertCase("cn_connection_uses_cny_entry") }
    @Test func REGION_PRICING_intl_connection_uses_model_level() async throws { try await assertCase("intl_connection_uses_model_level") }
    @Test func REGION_PRICING_no_stored_choice_matches_base_url() async throws { try await assertCase("no_stored_choice_matches_base_url") }
    @Test func REGION_PRICING_no_choice_no_match_takes_first_option() async throws { try await assertCase("no_choice_no_match_takes_first_option") }
    @Test func REGION_PRICING_unlisted_region_falls_back_to_model_level() async throws { try await assertCase("unlisted_region_falls_back_to_model_level") }
    @Test func REGION_PRICING_cn_only_entry_prices_otherwise_unknown_model() async throws { try await assertCase("cn_only_entry_prices_otherwise_unknown_model") }
    @Test func REGION_PRICING_cn_only_model_outside_cn_is_unavailable() async throws { try await assertCase("cn_only_model_outside_cn_is_unavailable") }
    @Test func REGION_PRICING_relay_connection_ignores_region_pricing() async throws { try await assertCase("relay_connection_ignores_region_pricing") }
    @Test func REGION_PRICING_unknown_payload_keys_ignored() async throws { try await assertCase("unknown_payload_keys_ignored") }

    /// A malformed region entry drops only that entry: both production chains (Codable decoding of the lean snapshot and schema 2 catalog validation) keep the model.
    @Test func REGION_PRICING_malformed_entry_dropped_model_kept() async throws {
        try await assertCase("malformed_entry_dropped_model_kept")

        let item = try Self.item("malformed_entry_dropped_model_kept")
        let model = try Self.model(for: item)
        let body = try JSONSerialization.data(withJSONObject: [
            "metadataSchema": 2,
            "metadataRevision": 7,
            "generatedAt": "2026-10-19T00:00:00Z",
            "view": "catalog",
            "provider": Self.providerKey,
            "catalogRevision": "sha256:" + String(repeating: "1", count: 64),
            "models": ["kimi-example": model],
            "resolveMap": ["kimi-example": "kimi-example"],
        ] as [String: Any])
        // The same bundled schema the production client reads.
        let schemaURL = try #require(
            Bundle.main.url(forResource: "metadata_payload.v2.schema", withExtension: "json")
                ?? Bundle.main.url(
                    forResource: "metadata_payload.v2.schema", withExtension: "json", subdirectory: "BundledMetadata"
                )
        )
        let schema = try Data(contentsOf: schemaURL)
        let outcome = try #require(MetadataClient.schemaV2CatalogOutcomeForTesting(body, schemaData: schema))
        #expect(outcome.kept == ["kimi-example"])
    }

    // MARK: - Helpers

    private func assertCase(_ id: String) async throws {
        let item = try Self.item(id)
        let model = try Self.model(for: item)
        let modelID = try #require(model["id"] as? String)
        let resolved = try await Self.resolve(model: model, modelID: modelID)

        let options = (item["regionOptions"]?.arrayValue ?? []).compactMap { option -> ProviderEndpointOption? in
            guard let id = option["id"]?.stringValue, let baseURL = option["baseURL"]?.stringValue else { return nil }
            return ProviderEndpointOption(id: id, label: id, baseURLText: baseURL)
        }
        let kind: ProviderKind = item["connectionKind"]?.stringValue == "relay" ? .relay : .moonshot
        let selection = RegionPricingSelector.select(
            resolved,
            regionOptions: options,
            endpointSource: item["connectionRegion"]?.stringValue.map { ProviderEndpointSource.region($0) },
            baseURLText: item["connectionBaseURL"]?.stringValue,
            kind: kind
        )
        let usage = try #require(item["usage"])
        let estimate = CostCalculator.estimate(
            breakdown: UsageBreakdown(
                promptTokens: usage["inputTokens"]?.intValue ?? 0,
                completionTokens: usage["outputTokens"]?.intValue ?? 0
            ),
            pricing: selection.pricing,
            at: Date(),
            units: usage["images"]?.intValue ?? 1
        )

        let expect = try #require(item["expect"])
        switch expect["status"]?.stringValue {
        case "estimated":
            #expect(!estimate.isUnavailable, "\(id)")
            let amount = try #require(expect["amount"]?.doubleValue)
            #expect(abs(estimate.amount - amount) < 1e-9, "\(id): got \(estimate.amount), want \(amount)")
            #expect(estimate.currencyCode == expect["currencyCode"]?.stringValue, "\(id): got \(estimate.currencyCode)")
        case "unavailable":
            // Price unknown (shown as not available), not zero.
            #expect(estimate.isUnavailable, "\(id): got \(estimate)")
        default:
            Issue.record("\(id): unknown expect.status")
        }
    }

    /// The fixture model (`modelRef`), with the first region entry rewritten by `entryOverride` / `entryExtraKeys`.
    private static func model(for item: JSONValue) throws -> [String: Any] {
        let ref = try #require(item["modelRef"]?.stringValue)
        var model = try #require(try fixture()[ref]?.anyValue as? [String: Any])
        var entries = try #require(model["regionPricing"] as? [[String: Any]])
        if let override = item["entryOverride"]?.anyValue as? [String: Any] {
            entries[0] = override
        }
        if let extra = item["entryExtraKeys"]?.anyValue as? [String: Any] {
            entries[0].merge(extra) { _, new in new }
        }
        model["regionPricing"] = entries
        model["displayName"] = model["id"]
        return model
    }

    private static func resolve(model: [String: Any], modelID: String) async throws -> MetadataClient.ResolvedModelMetadata {
        var entry = model
        entry["id"] = nil
        entry["canonicalModelId"] = modelID
        entry["capabilities"] = ["text"]
        let payload: [String: Any] = [
            "version": 1,
            "updatedAt": "2026-10-19T00:00:00Z",
            "providers": [
                providerKey: [
                    "displayName": "Region Pricing",
                    "defaultModelId": modelID,
                    "resolveMap": [modelID: modelID],
                    "models": [modelID: entry],
                ],
            ],
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let client = MetadataClient()
        await client.resetForTesting()
        try await client.loadForTesting(json: json)
        return try #require(client.resolveCatalogModel(modelID: modelID, providerKind: .anthropic))
    }

    private static func fixture() throws -> JSONValue {
        try JSONValue(data: Data(contentsOf: sharedFixtureURL("provider-pricing/region-pricing.v1.json")))
    }

    private static func item(_ id: String) throws -> JSONValue {
        try #require(try fixture()["cases"]?.arrayValue?.first { $0["id"]?.stringValue == id }, "cases.\(id)")
    }
}
