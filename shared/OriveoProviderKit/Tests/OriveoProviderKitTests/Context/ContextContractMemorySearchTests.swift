import Foundation
@testable import OriveoProviderKit
import Testing

// Runs `shared/context-contracts/memory-search.v1.json` case by case: tool / fixed text / constants equal the production constants item by item,
// and searchCases / modeCases call only production MemorySearch. projections are compared in the app against each platform's four ToolAdapters
// (the function names here are not a projection of a chat request).

private struct MemorySearchFixture: Decodable {
    struct Constants: Decodable {
        let topK: Int
        let coverageMin: Double
        let minMatchedTerms: Int
        let maxQueryCodePoints: Int
        let maxCallsPerTurn: Int
    }

    struct Hit: Decodable {
        let id: String
        let text: String
        let date: String?
        let score: Double
        let coverage: Double
    }

    struct SearchCase: Decodable {
        struct Context: Decodable {
            let conversationId: String
            let folderId: String?
            let now: String
            let excludeIds: [String]
        }

        struct Input: Decodable {
            let items: [MemoryItem]
            let arguments: String
            let context: Context
            let priorInTurn: Int
            let maxTokens: Int?
            let rho: Double
        }

        struct Outcome: Decodable {
            let action: String
            let reason: String?
            let hits: [Hit]
        }

        struct Expected: Decodable {
            let outcome: Outcome
            let toolResult: String
            let returnedIds: [String]
        }

        let id: String
        let input: Input
        let expected: Expected
    }

    struct ModeCase: Decodable {
        let id: String
        let input: MemorySearch.ModeInput
        let expected: MemorySearch.Mode
    }

    let constants: Constants
    let note: String
    let emptyResult: String
    let limitResult: String
    let skipReasons: [String]
    let modes: [String]
    let searchCases: [SearchCase]
    let modeCases: [ModeCase]
}

private let fixtureName = "memory-search.v1.json"

private func epochMs(_ text: String) throws -> Int64 {
    let date = try #require(MemoryItems.instant(text), "\(text)")
    return Int64((date.timeIntervalSince1970 * 1000).rounded())
}

private func describe(_ hits: [MemoryRecallHit]) -> String {
    hits.map { "\($0.id) \($0.date ?? "nil") \($0.score) \($0.coverage)" }.joined(separator: "; ")
}

@Suite("ContextContractMemorySearch")
struct ContextContractMemorySearchTests {
    private let fixture: MemorySearchFixture
    private let root: [String: Any]

    init() throws {
        fixture = try ContextContractFixture.load(fixtureName)
        let data = try ContextContractFixture.data(fixtureName)
        root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("tool")
    func tool() throws {
        let expected = try #require(root["tool"] as? NSObject)
        let actual = try #require(JSONSerialization.jsonObject(with: Data(MemorySearch.toolJSON.utf8)) as? NSObject)
        #expect(actual.isEqual(expected))
        let actualCanonical = try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys])
        let expectedCanonical = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
        #expect(actualCanonical == expectedCanonical)
        let function = try #require((actual as? [String: Any])?["function"] as? [String: Any])
        #expect(function["name"] as? String == MemorySearch.toolName)
    }

    @Test("constants")
    func constants() {
        let c = fixture.constants
        #expect(MemorySearch.topK == c.topK)
        #expect(MemorySearch.coverageMin == c.coverageMin)
        #expect(MemorySearch.minMatchedTerms == c.minMatchedTerms)
        #expect(MemorySearch.maxQueryCodePoints == c.maxQueryCodePoints)
        #expect(MemorySearch.maxCallsPerTurn == c.maxCallsPerTurn)
        #expect(Data(MemorySearch.note.utf8) == Data(fixture.note.utf8))
        #expect(Data(MemorySearch.emptyResult.utf8) == Data(fixture.emptyResult.utf8))
        #expect(Data(MemorySearch.limitResult.utf8) == Data(fixture.limitResult.utf8))
        #expect(MemorySearchSkipReason.allCases.map(\.rawValue) == fixture.skipReasons)
        #expect(MemorySearch.Mode.allCases.map(\.rawValue) == fixture.modes)
    }

    @Test("searchCases")
    func searchCases() throws {
        #expect(fixture.searchCases.count >= 14)
        var failures: [String] = []
        for item in fixture.searchCases {
            let context = MemoryRecallContext(
                conversationId: item.input.context.conversationId,
                folderId: item.input.context.folderId,
                nowMs: try epochMs(item.input.context.now)
            )
            let index = MemoryRecall.buildIndex(item.input.items)
            let outcome = MemorySearch.search(
                index,
                arguments: item.input.arguments,
                context: context,
                excludeIds: item.input.context.excludeIds,
                priorInTurn: item.input.priorInTurn
            )
            let want = item.expected.outcome
            let hitsMatch = outcome.hits.count == want.hits.count && zip(outcome.hits, want.hits).allSatisfy { hit, w in
                hit.id == w.id && hit.text == w.text && hit.date == w.date
                    && MemoryRecall.round6(hit.score) == MemoryRecall.round6(w.score)
                    && MemoryRecall.round6(hit.coverage) == MemoryRecall.round6(w.coverage)
            }
            let text = MemorySearch.toolResult(outcome, maxTokens: item.input.maxTokens, rhoHi: item.input.rho)
            let returned = MemorySearch.fittedHits(outcome, maxTokens: item.input.maxTokens, rhoHi: item.input.rho).map(\.id)
            let matches = outcome.action.rawValue == want.action && outcome.reason?.rawValue == want.reason
                && hitsMatch && Data(text.utf8) == Data(item.expected.toolResult.utf8)
                && returned == item.expected.returnedIds
            if !matches {
                failures.append("\(item.id): got \(outcome.action.rawValue) \(outcome.reason?.rawValue ?? "-") [\(describe(outcome.hits))] returned \(returned) \(text)")
            }
        }
        #expect(failures.isEmpty, "\(failures.count) failed:\n\(failures.joined(separator: "\n"))")
    }

    @Test("modeCases")
    func modeCases() {
        #expect(fixture.modeCases.count >= 8)
        let failures = fixture.modeCases.compactMap { item -> String? in
            let actual = MemorySearch.mode(item.input)
            return actual == item.expected ? nil : "\(item.id): got \(actual.rawValue) want \(item.expected.rawValue)"
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    @Test("fittedHits are the ids returned to the model")
    func fittedHitsMatchToolResult() throws {
        let item = try #require(fixture.searchCases.first { $0.id == "budget_drops_whole_entries" })
        let context = MemoryRecallContext(conversationId: "conv-1", folderId: nil, nowMs: try epochMs(item.input.context.now))
        let outcome = MemorySearch.search(
            MemoryRecall.buildIndex(item.input.items), arguments: item.input.arguments, context: context,
            excludeIds: [], priorInTurn: 0
        )
        let kept = MemorySearch.fittedHits(outcome, maxTokens: item.input.maxTokens, rhoHi: item.input.rho)
        #expect(kept.map(\.id) == ["40000000-0000-4000-8000-000000000022"])
        #expect(MemoryRecall.visibleCount(MemoryRecall.buildIndex(item.input.items), context: context) == 2)
    }
}
