import Foundation
import Testing
@testable import Oriveo

/// Relay quick setup main-thread hang: relay catalog grouping never reads
/// priority scores, so building the projection input must not run the per-model
/// capability evidence scoring for a relay provider.
@Suite("Relay catalog projection input budget", .serialized)
@MainActor
struct RelayCatalogProjectionBudgetTests {

    private static let families = ["gpt-5", "claude-sonnet", "gemini-2.5", "deepseek-v3", "qwen3", "my-custom"]

    private static func relayProvider(modelCount: Int) -> Provider {
        let catalog = (0..<modelCount).map { index -> AIModel in
            let id = "\(families[index % families.count])-\(index)"
            return TestFactories.makeModel(id: id, name: id)
        }
        return TestFactories.makeProvider(
            kind: .relay,
            models: [],
            catalogModels: catalog,
            baseURLText: "https://relay.example.com/v1"
        )
    }

    @Test("2000 relay catalog models: no priority scores, grouping unchanged, input built under 300 ms")
    func relayInputSkipsPriorityScores() {
        let provider = Self.relayProvider(modelCount: 2000)

        let clock = ContinuousClock()
        var input: ProviderCatalogProjectionInput?
        let elapsed = clock.measure {
            input = makeProviderCatalogProjectionInput(for: provider)
        }
        guard let input else { Issue.record("input not built"); return }

        #expect(input.priorityScores.isEmpty)
        #expect(input.catalogModels.count == 2000)
        #expect(elapsed < .milliseconds(300), "makeProviderCatalogProjectionInput took \(elapsed)")

        // Same input with the scores the old path computed: the relay projection must not change.
        var scored = ProviderCatalogProjectionInput(
            providerID: input.providerID,
            providerKind: input.providerKind,
            providerDisplayName: input.providerDisplayName,
            enabledModels: input.enabledModels,
            catalogModels: input.catalogModels,
            priorityScores: Dictionary(
                input.catalogModels.prefix(200).map { ($0.id, catalogPriorityScore(for: $0, provider: provider)) },
                uniquingKeysWith: { first, _ in first }
            )
        )
        scored.relayFamilies = input.relayFamilies
        scored.relayOtherTitle = input.relayOtherTitle

        let current = projectProviderCatalogGroups(input: input, searchText: "")
        let previous = projectProviderCatalogGroups(input: scored, searchText: "")
        #expect(current.map(\.id) == previous.map(\.id))
        #expect(current.map { $0.models.map(\.id) } == previous.map { $0.models.map(\.id) })
        #expect(current.flatMap(\.models).count == 2000)
    }
}
