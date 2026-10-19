import Foundation
import OriveoProviderKit
import Testing

// Runs `shared/context-contracts/conversation-instructions.v1.json` case by case, calling only production functions; failure messages carry the fixture case id.

private struct InstructionsContract {
    var root: [String: Any]

    init() throws {
        let data = try ContextContractFixture.data("conversation-instructions.v1.json")
        root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// parts: each segment's text is repeated `repeat` times (default 1) and concatenated in order.
private func joined(_ raw: Any?, id: String) throws -> String {
    let parts = try #require(raw as? [[String: Any]], "\(id)")
    return try parts.map { part in
        let text = try #require(part["text"] as? String, "\(id)")
        let count = part["repeat"] as? Int ?? 1
        return String(repeating: text, count: count)
    }.joined()
}

@Suite("ContextContractConversationInstructions")
struct ContextContractConversationInstructionsTests {
    private let contract: InstructionsContract

    init() throws {
        contract = try InstructionsContract()
    }

    @Test("max_code_points_matches_fixture")
    func maxCodePointsMatchesFixture() {
        #expect(ConversationInstructions.maxCodePoints == contract.root["maxCodePoints"] as? Int)
    }

    @Test("cases")
    func cases() throws {
        let cases = try #require(contract.root["cases"] as? [[String: Any]])
        #expect(cases.count == 12)
        for raw in cases {
            let id = try #require(raw["id"] as? String)
            let input = try joined(raw["input"], id: id)
            let expected = try joined(raw["expected"], id: id)
            let actual = ConversationInstructions.normalize(input)
            #expect(
                Array(actual.unicodeScalars) == Array(expected.unicodeScalars),
                "\(id): got \(actual.unicodeScalars.count) code points, expected \(expected.unicodeScalars.count)"
            )
        }
    }
}
