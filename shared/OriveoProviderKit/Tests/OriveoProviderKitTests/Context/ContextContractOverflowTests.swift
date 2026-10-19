import Foundation
import OriveoProviderKit
import Testing

// Runs `shared/context-contracts/overflow-errors.v1.json` case by case: when body is an object it is serialized to a JSON string and passed to the production classifier,
// and failure messages carry the fixture case id.

private struct OverflowCase {
    var id: String
    var family: String
    var status: Int
    var body: String
    var overflow: Bool
    var via: String?
}

private struct OverflowContract {
    var patterns: [String: String]
    var cases: [OverflowCase]

    init() throws {
        let data = try ContextContractFixture.data("overflow-errors.v1.json")
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        patterns = try #require(root["patterns"] as? [String: String])
        let rawCases = try #require(root["cases"] as? [[String: Any]])
        cases = try rawCases.map { raw in
            let id = try #require(raw["id"] as? String)
            let input = try #require(raw["input"] as? [String: Any], "\(id)")
            let expected = try #require(raw["expected"] as? [String: Any], "\(id)")
            let body: String
            if let text = input["body"] as? String {
                body = text
            } else {
                let object = try #require(input["body"], "\(id)")
                body = try #require(String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8), "\(id)")
            }
            return OverflowCase(
                id: id,
                family: try #require(input["family"] as? String, "\(id)"),
                status: try #require(input["status"] as? Int, "\(id)"),
                body: body,
                overflow: try #require(expected["overflow"] as? Bool, "\(id)"),
                via: expected["via"] as? String
            )
        }
    }
}

@Suite("ContextContractOverflow")
struct ContextContractOverflowTests {
    private let contract: OverflowContract

    init() throws {
        contract = try OverflowContract()
    }

    @Test("cases")
    func cases() throws {
        #expect(contract.cases.count == 16)
        for item in contract.cases {
            let family = try #require(OverflowFamily(rawValue: item.family), "\(item.id)")
            let result = ContextOverflowClassifier.classify(family: family, status: item.status, body: item.body)
            #expect(result.overflow == item.overflow, "\(item.id)")
            #expect(result.via?.rawValue == item.via, "\(item.id)")
        }
    }

    @Test("default_patterns_equal_fixture")
    func defaultPatternsMatchFixture() {
        #expect(ContextOverflowClassifier.defaultPatterns == contract.patterns)
    }

    @Test("extra_patterns_append")
    func extraPatternsAppend() {
        let body = #"{"error":{"message":"Input exceeds model budget of 8192 units"}}"#
        #expect(!ContextOverflowClassifier.classify(family: .openaiChat, status: 400, body: body).overflow)
        let extra = ["openai_compatible": ["(?i)EXCEEDS MODEL BUDGET"]]
        let result = ContextOverflowClassifier.classify(family: .openaiChat, status: 400, body: body, extraPatterns: extra)
        #expect(result.overflow)
        #expect(result.via == .statusRegex)
        // Appended regexes of other groups do not affect this family.
        let otherGroup = ["gemini": ["exceeds model budget"]]
        #expect(!ContextOverflowClassifier.classify(family: .openaiChat, status: 400, body: body, extraPatterns: otherGroup).overflow)
    }

    @Test("extra_patterns_invalid_skipped")
    func invalidExtraPatternIsSkipped() {
        let body = #"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 215000 tokens > 200000 maximum"}}"#
        let extra = ["anthropic": ["(unclosed", "[z-a]"]]
        let result = ContextOverflowClassifier.classify(family: .anthropic, status: 400, body: body, extraPatterns: extra)
        #expect(result.overflow)
        #expect(result.via == .typeRegex)
        let other = #"{"type":"error","error":{"type":"invalid_request_error","message":"roles must alternate"}}"#
        #expect(!ContextOverflowClassifier.classify(family: .anthropic, status: 400, body: other, extraPatterns: extra).overflow)
    }

    @Test("isOverflow is true only for context_window_exceeded")
    func isOverflowStopReason() {
        for reason in StopReason.allCases {
            #expect(ContextOverflowClassifier.isOverflow(reason) == (reason == .contextWindowExceeded), "\(reason.rawValue)")
        }
        #expect(!ContextOverflowClassifier.isOverflow(nil))
    }
}
