import Foundation
@testable import OriveoProviderKit
import Testing

// Runs `shared/context-contracts/memory-propose.v2.json` case by case: tool / toolResult equal the production constants item by item,
// and proposeCases / modeCases / degradeCases call only production functions. For degradeCases, "does the rejection match" is taken from the expect with the same id in
// `shared/test-fixtures/provider-toolcall/tool-unsupported-4xx.json`.

private struct MemoryProposeFixture: Decodable {
    struct ProposeCase: Decodable {
        let id: String
        let context: MemoryProposeContext
        let priorInTurn: Int
        let priorInstructInTurn: Int
        let arguments: String
        let expected: MemoryProposeDecision
    }

    struct ModeCase: Decodable {
        let id: String
        let input: MemoryPropose.ModeInput
        let expected: MemoryPropose.Mode
    }

    struct DegradeCase: Decodable {
        struct Expected: Decodable {
            let degrade: Bool
        }

        let id: String
        let rejection: String
        let legIndex: Int
        let streamStarted: Bool
        let receivedStructuredToolCalls: Bool
        let expected: Expected
    }

    struct Constants: Decodable {
        let maxProposalsPerTurn: Int
        let maxInstructPerTurn: Int
    }

    struct InstructBarCase: Decodable {
        struct Expected: Decodable {
            let show: Bool
        }

        let id: String
        let sentence: String
        let instructions: String
        let ignoreCount: Int
        let expected: Expected
    }

    let scopes: [String]
    let skipReasons: [String]
    let instructBarCases: [InstructBarCase]

    let toolResult: String
    let constants: Constants
    let proposeCases: [ProposeCase]
    let modeCases: [ModeCase]
    let degradeCases: [DegradeCase]
}

private struct ToolUnsupportedFixture: Decodable {
    struct Case: Decodable {
        let id: String
        let expect: Bool
    }

    let cases: [Case]
}

private let fixtureName = "memory-propose.v3.json"

private func scalars(_ value: String?) -> [Unicode.Scalar]? {
    value.map { Array($0.unicodeScalars) }
}

private func encodedTree<T: Encodable>(_ value: T) throws -> NSObject {
    let data = try JSONEncoder().encode(value)
    return try #require(JSONSerialization.jsonObject(with: data) as? NSObject)
}

/// Raw bytes of `shared/test-fixtures/provider-toolcall/<name>`.
private func toolCallFixtureData(_ name: String) throws -> Data {
    var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while folder.path != "/" {
        let candidate = folder.appendingPathComponent("shared/test-fixtures/provider-toolcall/\(name)")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return try Data(contentsOf: candidate)
        }
        folder.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}

@Suite("ContextContractMemoryPropose")
struct ContextContractMemoryProposeTests {
    private let fixture: MemoryProposeFixture
    private let root: [String: Any]

    init() throws {
        fixture = try ContextContractFixture.load(fixtureName)
        let data = try ContextContractFixture.data(fixtureName)
        root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("tool")
    func tool() throws {
        let expected = try #require(root["tool"] as? NSObject)
        let actual = try #require(JSONSerialization.jsonObject(with: Data(MemoryPropose.toolJSON.utf8)) as? NSObject)
        #expect(actual.isEqual(expected))
        // Strings compared by code point: description etc. must not slip through canonical equivalence
        let actualCanonical = try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys])
        let expectedCanonical = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
        #expect(actualCanonical == expectedCanonical)
        let function = try #require((actual as? [String: Any])?["function"] as? [String: Any])
        #expect(function["name"] as? String == MemoryPropose.toolName)
    }

    @Test("toolResult")
    func toolResult() {
        #expect(scalars(MemoryPropose.toolResult) == scalars(fixture.toolResult))
        #expect(Data(MemoryPropose.toolResult.utf8) == Data(fixture.toolResult.utf8))
        #expect(MemoryPropose.maxProposalsPerTurn == fixture.constants.maxProposalsPerTurn)
        #expect(MemoryPropose.maxInstructPerTurn == fixture.constants.maxInstructPerTurn)
        #expect(MemoryProposeSkipReason.allCases.map(\.rawValue).sorted() == fixture.skipReasons.sorted())
    }

    @Test("proposeCases")
    func proposeCases() throws {
        #expect(!fixture.proposeCases.isEmpty)
        let raw = try #require(root["proposeCases"] as? [[String: Any]]).map { $0["expected"] }
        #expect(raw.count == fixture.proposeCases.count)
        var failures: [String] = []
        for (item, expectedTree) in zip(fixture.proposeCases, raw) {
            let actual = MemoryPropose.propose(
                item.arguments, context: item.context, priorInTurn: item.priorInTurn,
                priorInstructInTurn: item.priorInstructInTurn
            )
            let tree = try encodedTree(actual)
            let matches = actual == item.expected
                && tree.isEqual(expectedTree as? NSObject)
                && scalars(actual.candidate?.content) == scalars(item.expected.candidate?.content)
                && scalars(actual.sentence) == scalars(item.expected.sentence)
            if !matches {
                failures.append("\(item.id): got \(actual.action.rawValue) \(actual.reason?.rawValue ?? "-") \(tree)")
            }
        }
        #expect(failures.isEmpty, "\(failures.count) failed:\n\(failures.joined(separator: "\n"))")
    }

    @Test("instructBarCases")
    func instructBarCases() {
        #expect(!fixture.instructBarCases.isEmpty)
        let failures = fixture.instructBarCases.compactMap { item -> String? in
            let actual = MemoryPropose.instructionBarShows(
                sentence: item.sentence, instructions: item.instructions, ignoreCount: item.ignoreCount
            )
            return actual == item.expected.show ? nil : "\(item.id): got \(actual)"
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    @Test("modeCases")
    func modeCases() {
        #expect(!fixture.modeCases.isEmpty)
        let failures = fixture.modeCases.compactMap { item -> String? in
            let actual = MemoryPropose.mode(item.input)
            return actual == item.expected ? nil : "\(item.id): got \(actual.rawValue) want \(item.expected.rawValue)"
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    @Test("degradeCases")
    func degradeCases() throws {
        #expect(!fixture.degradeCases.isEmpty)
        let matcher = try JSONDecoder().decode(ToolUnsupportedFixture.self, from: toolCallFixtureData("tool-unsupported-4xx.json"))
        for item in fixture.degradeCases {
            let matches = try #require(matcher.cases.first { $0.id == item.rejection }, "\(item.id): \(item.rejection)").expect
            let actual = MemoryPropose.degrade(
                rejectionMatches: matches,
                legIndex: item.legIndex,
                streamStarted: item.streamStarted,
                receivedStructuredToolCalls: item.receivedStructuredToolCalls
            )
            #expect(actual == item.expected.degrade, "\(item.id)")
        }
        #expect(MemoryPropose.degradedKey(connectionId: "conn-1", modelId: "gpt-x") == "conn-1\ngpt-x")
    }
}
