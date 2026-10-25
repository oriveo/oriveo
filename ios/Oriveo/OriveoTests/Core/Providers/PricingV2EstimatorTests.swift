import Foundation
import Testing
@testable import Oriveo

/// Pricing v2 estimation: a shared fixture with the same answers on every client, plus real metadata JSON through the production entry points.
@Suite("PricingV2Estimator", .sharedProcessState)
struct PricingV2EstimatorTests {
    @Test("shared fixture pricing-v2-estimate.v1 runs all 24 cases")
    func sharedFixtureHasAllCases() throws {
        #expect(try PricingV2SharedFixture.load().cases.count == 24)
    }

    @Test("shared fixture pricing-v2-estimate.v1 gives the same answer case by case", arguments: PricingV2SharedFixture.caseNames)
    func sharedFixtureCase(_ name: String) throws {
        let item = try #require(try PricingV2SharedFixture.load().cases.first { $0.name == name })
        let usage = PricingV2Usage(
            uncachedInputTokens: item.usage.uncachedInputTokens,
            cacheReadTokens: item.usage.cacheReadTokens,
            cacheWrite5mTokens: item.usage.cacheWrite5mTokens,
            cacheWrite1hTokens: item.usage.cacheWrite1hTokens,
            outputTokens: item.usage.outputTokens
        )
        let result = PricingV2Estimator.estimate(item.pricingV2, usage: usage, at: try date(item.at))
        switch (item.expected.status, result) {
        case ("estimated", .estimated(let amount, let currency)):
            let expectedAmount = try #require(item.expected.amount)
            #expect(abs(amount - expectedAmount) < 1e-9, "got \(amount), want \(expectedAmount)")
            #expect(currency == item.expected.currencyCode)
        case ("unavailable", .unavailable), ("not_applicable", .notApplicable):
            break
        default:
            Issue.record("status want \(item.expected.status), got \(result)")
        }
    }

    private func date(_ iso: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: iso), "bad at: \(iso)")
    }

    // MARK: - Real metadata JSON through the production entry points

    private func payload(pricingV2: String) -> String {
        """
        {
          "version": 1,
          "updatedAt": "2026-10-19T00:00:00Z",
          "providers": {
            "anthropic": {
              "displayName": "Anthropic",
              "defaultModelId": "claude-v2-priced",
              "resolveMap": { "claude-v2-priced": "claude-v2-priced" },
              "models": {
                "claude-v2-priced": {
                  "canonicalModelId": "claude-v2-priced",
                  "displayName": "Claude V2 Priced",
                  "pricingUnit": "per_token",
                  "pricingStatus": "priced",
                  "pricing": { "promptPerMToken": 2.0, "completionPerMToken": 8.0 },
                  "pricingV2": \(pricingV2),
                  "capabilities": ["text"]
                }
              }
            }
          }
        }
        """
    }

    private let tieredWindowedV2 = """
    {
      "currencyCode": "USD",
      "unit": "per_token",
      "base": { "inputPerMToken": 2.0, "outputPerMToken": 8.0 },
      "cache": { "readPerMToken": 0.5, "writes": [ { "ttl": "5m", "perMToken": 2.5 } ] },
      "contextTiers": [
        { "aboveInputTokens": 1000, "semantics": "whole_request", "inputPerMToken": 4.0, "outputPerMToken": 12.0 }
      ],
      "timeWindows": [
        { "timezone": "UTC", "start": "00:00", "end": "06:00", "multiplier": 0.5 }
      ]
    }
    """

    @Test("real JSON decodes pricingV2 and MetadataClient.calcCost applies the context tier and time window")
    func metadataCalcCostUsesPricingV2() async throws {
        let client = MetadataClient()
        await client.resetForTesting()
        try await client.loadForTesting(json: payload(pricingV2: tieredWindowedV2))

        let breakdown = UsageBreakdown(
            promptTokens: 1500,
            cachedInputTokens: 1000,
            cacheCreation5mTokens: 200,
            completionTokens: 1000
        )
        // Total input 2700 > 1000 enters the tier: 1500×4 + 1000×0.5 + 200×2.5 + 1000×12 = 19000 → 0.019
        let noon = try date("2026-10-19T12:00:00Z")
        let (cost, source) = await client.calcCost(
            breakdown: breakdown, modelID: "claude-v2-priced", providerKind: .anthropic, at: noon
        )
        #expect(source == .localEstimate)
        #expect(abs(cost - 0.019) < 1e-9, "got \(cost)")

        // Inside the window everything is ×0.5
        let night = try date("2026-10-19T03:00:00Z")
        let (nightCost, _) = await client.calcCost(
            breakdown: breakdown, modelID: "claude-v2-priced", providerKind: .anthropic, at: night
        )
        #expect(abs(nightCost - 0.0095) < 1e-9, "got \(nightCost)")

        // The cost reported by the upstream wins
        var upstream = breakdown
        upstream.upstreamCost = 0.123
        let (upstreamCost, upstreamSource) = await client.calcCost(
            breakdown: upstream, modelID: "claude-v2-priced", providerKind: .anthropic, at: noon
        )
        #expect(upstreamCost == 0.123)
        #expect(upstreamSource == .upstream)
    }

    @Test("pricingV2 missing the output price: the cost is unknown (.unknown), not estimated from the old price")
    func metadataCalcCostUnavailableIsUnknown() async throws {
        let client = MetadataClient()
        await client.resetForTesting()
        let v2 = #"{ "currencyCode": "USD", "unit": "per_token", "base": { "inputPerMToken": 2.0, "outputPerMToken": null } }"#
        try await client.loadForTesting(json: payload(pricingV2: v2))

        let (_, source) = await client.calcCost(
            breakdown: UsageBreakdown(promptTokens: 1000, completionTokens: 1000),
            modelID: "claude-v2-priced", providerKind: .anthropic, at: Date()
        )
        #expect(source == .unknown)
    }

    @Test("pricingStatus unknown with pricingV2 present: the cost is unknown (.unknown) and v2 is not read")
    func unknownLegacyStatusIgnoresPricingV2() async throws {
        let client = MetadataClient()
        await client.resetForTesting()
        let json = payload(pricingV2: tieredWindowedV2)
            .replacingOccurrences(of: #""pricingStatus": "priced""#, with: #""pricingStatus": "unknown""#)
        try await client.loadForTesting(json: json)

        let resolved = try #require(
            client.resolveCatalogModel(modelID: "claude-v2-priced", providerKind: .anthropic)
        )
        #expect(resolved.pricingStatus == "unknown")
        #expect(resolved.pricingV2 != nil)
        let (cost, source) = await client.calcCost(
            breakdown: UsageBreakdown(promptTokens: 1000, completionTokens: 1000),
            modelID: "claude-v2-priced", providerKind: .anthropic, at: Date()
        )
        #expect(source == .unknown)
        #expect(cost == 0)
    }

    @Test("malformed pricingV2: the model still decodes, v2 counts as missing and the cost uses the legacy path")
    func malformedPricingV2DropsOnlyThatKey() async throws {
        let client = MetadataClient()
        await client.resetForTesting()
        let bad = #"{ "unit": "per_token", "base": { "inputPerMToken": 2.0, "outputPerMToken": 8.0 }, "contextTiers": "oops" }"#
        try await client.loadForTesting(json: payload(pricingV2: bad))

        let resolved = try #require(
            await client.resolveCatalogModel(modelID: "claude-v2-priced", providerKind: .anthropic)
        )
        #expect(resolved.pricingV2 == nil)
        #expect(resolved.displayName == "Claude V2 Priced")

        let (cost, source) = await client.calcCost(
            breakdown: UsageBreakdown(promptTokens: 1000, completionTokens: 1000),
            modelID: "claude-v2-priced", providerKind: .anthropic, at: Date()
        )
        // Legacy path: 1000×2 + 1000×8 = 10000 → 0.01
        #expect(source == .localEstimate)
        #expect(abs(cost - 0.01) < 1e-9, "got \(cost)")
    }

    @Test("a malformed pricingV2 time format likewise drops only that key")
    func malformedWindowTimeDropsOnlyThatKey() throws {
        let json = #"{ "canonicalModelId": "m", "pricingV2": { "unit": "per_token", "base": { "inputPerMToken": 1, "outputPerMToken": 1 }, "timeWindows": [ { "timezone": "UTC", "start": "25:00", "end": "06:00" } ] } }"#
        let entry = try JSONDecoder().decode(MetadataClient.ModelMetadataEntry.self, from: Data(json.utf8))
        #expect(entry.canonicalModelId == "m")
        #expect(entry.pricingV2 == nil)

        let good = #"{ "canonicalModelId": "m", "pricingV2": { "unit": "per_token", "base": { "inputPerMToken": 1, "outputPerMToken": 1 } } }"#
        let goodEntry = try JSONDecoder().decode(MetadataClient.ModelMetadataEntry.self, from: Data(good.utf8))
        #expect(goodEntry.pricingV2?.base?.inputPerMToken == 1)
    }
}

/// Reads the shared fixture like RelayPortableConfigTests.loadContract: walks up from the test file to the repository root and its shared/ directory.
private enum PricingV2SharedFixture {
    struct Fixture: Decodable {
        let cases: [Case]
    }

    struct Case: Decodable {
        struct Usage: Decodable {
            let uncachedInputTokens: Int
            let cacheReadTokens: Int
            let cacheWrite5mTokens: Int
            let cacheWrite1hTokens: Int
            let outputTokens: Int
        }

        struct Expected: Decodable {
            let status: String
            let amount: Double?
            let currencyCode: String?
        }

        let name: String
        let pricingV2: PricingV2
        let usage: Usage
        let at: String
        let expected: Expected
    }

    static func load() throws -> Fixture {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor
                .appendingPathComponent("shared")
                .appendingPathComponent("test-fixtures")
                .appendingPathComponent("provider-pricing")
                .appendingPathComponent("pricing-v2-estimate.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: candidate))
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// Parameterized case names; when the fixture cannot be read, return a placeholder name so the test itself fails instead of silently running 0 cases.
    static var caseNames: [String] {
        (try? load().cases.map(\.name)) ?? ["<fixture missing>"]
    }
}
