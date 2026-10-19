import Foundation
import OriveoProviderKit
import Testing

// Runs `shared/context-contracts/memory-recall.v1.json` case by case: constants equal the production constants item by item;
// tokenizeCases / recallCases / conflictCases / resolveCases call only production MemoryRecall. Floating point is compared after round6.

private struct MemoryRecallFixture: Decodable {
    struct Constants: Decodable {
        struct ScopeFactor: Decodable {
            let conversation: Double
            let folder: Double
            let global: Double
        }

        let k1: Double
        let b: Double
        let topK: Int
        let coverageMin: Double
        let minMatchedTerms: Int
        let idfPriorDocs: Int
        let scopeFactor: ScopeFactor
        let pinnedFactor: Double
        let halfLifeDays: Double
        let timeFloor: Double
        let confidenceFloor: Double
        let maxQueryCodePoints: Int
        let conflictJaccardMin: Double
        let joiners: String
        let cjkRanges: [[UInt32]]
    }

    struct TokenizeCase: Decodable {
        let id: String
        let text: String
        let expected: [String]
    }

    struct RecallContext: Decodable {
        let conversationId: String
        let folderId: String?
        let now: String
    }

    struct Hit: Decodable {
        let id: String
        let text: String
        let date: String?
        let score: Double
        let coverage: Double
    }

    struct RecallCase: Decodable {
        struct Input: Decodable {
            let items: [MemoryItem]
            let query: String
            let context: RecallContext
        }

        let id: String
        let input: Input
        let expected: [Hit]
    }

    struct ConflictCase: Decodable {
        struct Input: Decodable {
            let saved: MemoryItem
            let items: [MemoryItem]
        }

        struct Expected: Decodable {
            let conflictWith: String?
        }

        let id: String
        let input: Input
        let expected: Expected
    }

    struct ResolveCase: Decodable {
        struct Input: Decodable {
            let newer: MemoryItem
            let older: MemoryItem
            let resolution: MemoryConflictResolution
        }

        let id: String
        let input: Input
        let expected: [MemoryRecallPatch]
    }

    let constants: Constants
    let tokenizeCases: [TokenizeCase]
    let recallCases: [RecallCase]
    let conflictCases: [ConflictCase]
    let resolveCases: [ResolveCase]
}

private let fixtureName = "memory-recall.v1.json"

private func epochMs(_ text: String) throws -> Int64 {
    let date = try #require(MemoryItems.instant(text), "\(text)")
    return Int64((date.timeIntervalSince1970 * 1000).rounded())
}

private func describe(_ hits: [MemoryRecallHit]) -> String {
    hits.map { "\($0.id) \($0.date ?? "nil") \($0.score) \($0.coverage)" }.joined(separator: "; ")
}

@Suite("ContextContractMemoryRecall")
struct ContextContractMemoryRecallTests {
    private let fixture: MemoryRecallFixture

    init() throws {
        fixture = try ContextContractFixture.load(fixtureName)
    }

    @Test("constants")
    func constants() {
        let c = fixture.constants
        #expect(MemoryRecall.k1 == c.k1)
        #expect(MemoryRecall.b == c.b)
        #expect(MemoryRecall.topK == c.topK)
        #expect(MemoryRecall.coverageMin == c.coverageMin)
        #expect(MemoryRecall.minMatchedTerms == c.minMatchedTerms)
        #expect(MemoryRecall.idfPriorDocs == c.idfPriorDocs)
        #expect(MemoryRecall.scopeFactorConversation == c.scopeFactor.conversation)
        #expect(MemoryRecall.scopeFactorFolder == c.scopeFactor.folder)
        #expect(MemoryRecall.scopeFactorGlobal == c.scopeFactor.global)
        #expect(MemoryRecall.pinnedFactor == c.pinnedFactor)
        #expect(MemoryRecall.halfLifeDays == c.halfLifeDays)
        #expect(MemoryRecall.timeFloor == c.timeFloor)
        #expect(MemoryRecall.confidenceFloor == c.confidenceFloor)
        #expect(MemoryRecall.maxQueryCodePoints == c.maxQueryCodePoints)
        #expect(MemoryRecall.conflictJaccardMin == c.conflictJaccardMin)
        #expect(MemoryRecall.joiners == c.joiners)
        #expect(MemoryRecall.cjkRanges.map { [$0.lowerBound, $0.upperBound] } == c.cjkRanges)
    }

    @Test("tokenizeCases")
    func tokenizeCases() {
        #expect(!fixture.tokenizeCases.isEmpty)
        let failures = fixture.tokenizeCases.compactMap { item -> String? in
            let actual = MemoryRecall.tokens(item.text)
            return actual == item.expected ? nil : "\(item.id): got \(actual)"
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    @Test("recallCases")
    func recallCases() throws {
        #expect(!fixture.recallCases.isEmpty)
        var failures: [String] = []
        for item in fixture.recallCases {
            let context = MemoryRecallContext(
                conversationId: item.input.context.conversationId,
                folderId: item.input.context.folderId,
                nowMs: try epochMs(item.input.context.now)
            )
            let index = MemoryRecall.buildIndex(item.input.items)
            let actual = MemoryRecall.recall(index, query: item.input.query, context: context)
            let matches = actual.count == item.expected.count && zip(actual, item.expected).allSatisfy { hit, want in
                hit.id == want.id && hit.text == want.text && hit.date == want.date
                    && MemoryRecall.round6(hit.score) == MemoryRecall.round6(want.score)
                    && MemoryRecall.round6(hit.coverage) == MemoryRecall.round6(want.coverage)
            }
            if !matches { failures.append("\(item.id): got \(describe(actual))") }
        }
        #expect(failures.isEmpty, "\(failures.count) failed:\n\(failures.joined(separator: "\n"))")
    }

    @Test("conflictCases")
    func conflictCases() {
        #expect(!fixture.conflictCases.isEmpty)
        let failures = fixture.conflictCases.compactMap { item -> String? in
            let actual = MemoryRecall.conflict(saved: item.input.saved, items: item.input.items)
            return actual == item.expected.conflictWith ? nil : "\(item.id): got \(actual ?? "nil")"
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    @Test("resolveCases")
    func resolveCases() throws {
        #expect(!fixture.resolveCases.isEmpty)
        let data = try ContextContractFixture.data(fixtureName)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let raw = try #require(root["resolveCases"] as? [[String: Any]]).map { $0["expected"] as? NSObject }
        var failures: [String] = []
        for (item, expectedTree) in zip(fixture.resolveCases, raw) {
            let actual = MemoryRecall.resolve(
                newer: item.input.newer, older: item.input.older, resolution: item.input.resolution
            )
            let tree = try JSONSerialization.jsonObject(with: JSONEncoder().encode(actual)) as? NSObject
            if actual != item.expected || tree?.isEqual(expectedTree) != true {
                failures.append("\(item.id): got \(actual)")
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }
}
