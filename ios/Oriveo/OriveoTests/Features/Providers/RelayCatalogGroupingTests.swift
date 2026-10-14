import Foundation
import Testing
@testable import Oriveo

/// Relay model catalog grouping (contract card B1): fixture `shared/test-fixtures/relay/catalog-groups.v1.json`.
/// Family = the fixture's serverFamilies (standing in for the cached server by-model family) -> production `RelayFamilyHeuristics`;
/// it also asserts that the production catalog projection and step 2 of adding use the same grouping for relays (BOARD-CATALOG-09).
@Suite("Relay 2.0 · model catalog grouping", .serialized)
@MainActor
struct RelayCatalogGroupingTests {

    // MARK: - Fixture

    private static func fixture() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/test-fixtures/relay/catalog-groups.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func cases() throws -> [[String: Any]] {
        try #require(try fixture()["cases"] as? [[String: Any]])
    }

    private static func item(_ caseId: String) throws -> [String: Any] {
        try #require(try cases().first { $0["id"] as? String == caseId }, "fixture is missing \(caseId)")
    }

    private func runCase(_ caseId: String) throws {
        let item = try Self.item(caseId)
        let models = try #require(item["models"] as? [String])
        let serverFamilies = item["serverFamilies"] as? [String: String] ?? [:]
        let expected = try #require(item["expected"] as? [[String: Any]])

        let groups = RelayCatalogGrouping.groups(models: models) { id in
            serverFamilies[id] ?? RelayFamilyHeuristics.infer(modelID: id)?.rawValue
        }
        #expect(groups.map(\.id) == expected.compactMap { $0["id"] as? String }, "\(caseId) group order")
        #expect(groups.map(\.label) == expected.map { $0["label"] as? String }, "\(caseId) group names")
        #expect(groups.map(\.models) == expected.map { $0["models"] as? [String] ?? [] }, "\(caseId) order within groups")
    }

    @Test("RD3-GROUP-heuristic_families_in_catalog_order") func heuristicFamiliesInCatalogOrder() throws {
        try runCase("heuristic_families_in_catalog_order")
    }
    @Test("RD3-GROUP-server_family_first") func serverFamilyFirst() throws { try runCase("server_family_first") }
    @Test("RD3-GROUP-other_always_last") func otherAlwaysLast() throws { try runCase("other_always_last") }
    @Test("RD3-GROUP-unlabeled_server_family_uses_id") func unlabeledServerFamilyUsesID() throws {
        try runCase("unlabeled_server_family_uses_id")
    }
    @Test("RD3-GROUP-vendor_prefixed_ids_use_last_segment") func vendorPrefixedIDsUseLastSegment() throws {
        try runCase("vendor_prefixed_ids_use_last_segment")
    }
    @Test("RD3-GROUP-empty_catalog") func emptyCatalog() throws { try runCase("empty_catalog") }

    @Test("RD3-GROUP every fixture case has a test of the same name; the group name table matches the fixture labels item by item; other group names use localization keys")
    func fixtureCoveredAndLabelsMatch() throws {
        let root = try Self.fixture()
        #expect(Set(try Self.cases().compactMap { $0["id"] as? String }) == [
            "heuristic_families_in_catalog_order", "server_family_first", "other_always_last",
            "unlabeled_server_family_uses_id", "vendor_prefixed_ids_use_last_segment", "empty_catalog",
        ])
        #expect(RelayCatalogGrouping.labels == (root["labels"] as? [String: String]))
        #expect(RelayCatalogGrouping.otherID == "other")
        #expect(RelayCatalogGrouping.otherTitleKey == "Other")
    }

    // MARK: - BOARD-CATALOG-09

    @Test("BOARD-CATALOG-09 the production catalog projection yields the first fixture case's group order and names for a relay; step 2 of adding uses the same projection; official providers do not")
    func board09ProductionProjection() throws {
        let item = try Self.item("heuristic_families_in_catalog_order")
        let models = try #require(item["models"] as? [String])
        let expected = try #require(item["expected"] as? [[String: Any]])
        let expectedTitles = expected.map { ($0["label"] as? String) ?? L10n.tr("Other", table: .providers) }

        let provider = TestFactories.makeProvider(
            kind: .relay,
            models: [],
            catalogModels: models.map { TestFactories.makeModel(id: $0, name: $0) },
            baseURLText: "https://relay.example.com/v1"
        )
        let groups = buildProviderCatalogGroups(for: provider, searchText: "")
        #expect(groups.map(\.id) == expected.compactMap { $0["id"] as? String })
        #expect(groups.map(\.title) == expectedTitles)
        #expect(groups.map { $0.models.map(\.id) } == expected.map { $0["models"] as? [String] ?? [] })

        // Enabled models do not enter the catalog groups; the remaining rows are regrouped by first appearance in the catalog (gpt-5 now appears first).
        var withEnabled = provider
        withEnabled.models = [TestFactories.makeModel(id: "claude-sonnet-4-5", name: "claude-sonnet-4-5")]
        let remaining = buildProviderCatalogGroups(for: withEnabled, searchText: "")
        #expect(remaining.map(\.id) == ["openai", "anthropic", "google", "deepseek", "other"])
        #expect(remaining.first { $0.id == "anthropic" }?.models.map(\.id) == ["claude-opus-4"])

        // Step 2 of adding: manually added models are grouped through the same projection (no request is sent).
        let flow = RelayQuickSetupFlow.stubbed(RelaySetupHTTPStub())
        for id in ["gpt-5", "claude-opus-4", "my-custom-model"] { flow.addManualModel(id) }
        #expect(flow.modelGroups.map(\.id) == ["openai", "anthropic", "other"])
        #expect(flow.modelGroups.map(\.title) == ["OpenAI", "Anthropic", L10n.tr("Other", table: .providers)])
    }
}
