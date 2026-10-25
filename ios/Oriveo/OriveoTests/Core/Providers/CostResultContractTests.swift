import Foundation
import Testing
@testable import Oriveo

/// Shared fixture `shared/test-fixtures/provider-pricing/cost-result.v1.json`: with legacy single-tier pricing the cache-read rate resolves as
/// new field > old field > input x 0.5. All amounts come from real metadata JSON through the production `MetadataClient.calcCost` (which uses `CostCalculator` internally).
/// Currency handling is covered by `CostCurrencyContractTests`.
@Suite("CostResultContract", .sharedProcessState)
struct CostResultContractTests {
    private static let modelID = "cost-result-model"

    @Test("fixture legacyCacheReadCases ids match the COST_RESULT_ tests one to one")
    func fixtureIDsMatchTests() throws {
        let ids = Set((try Self.fixture()["legacyCacheReadCases"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue })
        let tests: Set<String> = ["new_field_wins", "old_field_when_new_missing", "half_input_when_both_missing"]
        #expect(ids == tests)
    }

    @Test func COST_RESULT_new_field_wins() async throws { try await assertLegacyCacheRead("new_field_wins") }
    @Test func COST_RESULT_old_field_when_new_missing() async throws { try await assertLegacyCacheRead("old_field_when_new_missing") }
    @Test func COST_RESULT_half_input_when_both_missing() async throws { try await assertLegacyCacheRead("half_input_when_both_missing") }

    // MARK: - Helpers

    /// Decodes legacy single-tier pricing through production metadata, then prices 1M cache-read tokens to get the effective cache-read rate.
    private func assertLegacyCacheRead(_ id: String) async throws {
        let item = try Self.item("legacyCacheReadCases", id)
        let pricing = try #require(item["pricing"])
        let (cost, source) = try await calcCost(
            pricing: String(decoding: try JSONSerialization.data(withJSONObject: pricing.anyValue), as: UTF8.self),
            pricingV2: nil,
            breakdown: UsageBreakdown(promptTokens: 0, cachedInputTokens: 1_000_000, completionTokens: 0)
        )
        let expected = try #require(item["expect"]?["cacheReadPerMToken"]?.doubleValue)
        #expect(source == .localEstimate, "\(id)")
        #expect(abs(cost - expected) < 1e-12, "\(id): got \(cost), want \(expected)")
    }

    private func calcCost(
        pricing: String = #"{ "promptPerMToken": 2.0, "completionPerMToken": 8.0 }"#,
        pricingV2: String?,
        breakdown: UsageBreakdown
    ) async throws -> (cost: Double, source: CostSource) {
        let client = MetadataClient()
        await client.resetForTesting()
        let v2Line = pricingV2.map { #""pricingV2": \#($0),"# } ?? ""
        let json = """
        {
          "version": 1,
          "updatedAt": "2026-10-19T00:00:00Z",
          "providers": {
            "anthropic": {
              "displayName": "Anthropic",
              "defaultModelId": "\(Self.modelID)",
              "resolveMap": { "\(Self.modelID)": "\(Self.modelID)" },
              "models": {
                "\(Self.modelID)": {
                  "canonicalModelId": "\(Self.modelID)",
                  "displayName": "Cost Result",
                  "pricingUnit": "per_token",
                  "pricingStatus": "priced",
                  "pricing": \(pricing),
                  \(v2Line)
                  "capabilities": ["text"]
                }
              }
            }
          }
        }
        """
        try await client.loadForTesting(json: json)
        return await client.calcCost(breakdown: breakdown, modelID: Self.modelID, providerKind: .anthropic, at: Date())
    }

    private static func fixture() throws -> JSONValue {
        try JSONValue(data: Data(contentsOf: sharedFixtureURL("provider-pricing/cost-result.v1.json")))
    }

    private static func item(_ group: String, _ id: String) throws -> JSONValue {
        try #require(try fixture()[group]?.arrayValue?.first { $0["id"]?.stringValue == id }, "\(group).\(id)")
    }
}
