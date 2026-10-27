import Foundation
import Testing
@testable import Oriveo

/// Together usage shape contract shared across platforms (`shared/test-fixtures/provider-usage/together-usage-shapes.v1.json`):
/// cached tokens nested under `prompt_tokens_details` or flat at the top level of usage both count as cache reads;
/// reasoning tokens come from `completion_tokens_details.reasoning_tokens`. Parsing goes through the production
/// `TogetherService.legUsageBreakdown` and the tool-loop leg dispatch `ToolLoopUsage.openAIChatLeg`.
@Suite("Together usage shapes")
struct TogetherUsageShapesTests {

    private static func cases() throws -> [[String: Any]] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/test-fixtures/provider-usage/together-usage-shapes.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                let root = try #require(object as? [String: Any])
                return try #require(root["cases"] as? [[String: Any]])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func usage(_ id: String) throws -> [String: Any] {
        let found = try #require(try cases().first { $0["id"] as? String == id }, "fixture is missing \(id)")
        return try #require(found["usage"] as? [String: Any])
    }

    @Test("all 4 Together usage fixture cases pass")
    func fixtureCases() throws {
        let all = try Self.cases()
        #expect(Set(all.compactMap { $0["id"] as? String }) == [
            "reasoning-model-nested", "non-reasoning-flat-cached", "flat-cached-zero-is-observed", "no-cache-field",
        ])
        for item in all {
            let id = try #require(item["id"] as? String)
            let usage = try #require(item["usage"] as? [String: Any])
            let expect = try #require(item["expect"] as? [String: Any])
            let breakdown = try #require(TogetherService.legUsageBreakdown(usageJSON: usage), "\(id) failed to parse")
            #expect(breakdown.promptTokens == expect["promptTokens"] as? Int, "\(id) promptTokens")
            #expect(breakdown.cachedInputTokens == expect["cachedInputTokens"] as? Int, "\(id) cachedInputTokens")
            #expect(breakdown.completionTokens == expect["completionTokens"] as? Int, "\(id) completionTokens")
            #expect(breakdown.reasoningTokens == expect["reasoningTokens"] as? Int, "\(id) reasoningTokens")
            #expect(breakdown.cacheReadObserved == expect["cacheReadObserved"] as? Bool, "\(id) cacheReadObserved")
        }
    }

    @Test("tool-loop leg usage goes through the Together parser")
    func toolLoopLegUsesTogetherParser() throws {
        let leg = try #require(ToolLoopUsage.openAIChatLeg(
            usageJSON: try Self.usage("non-reasoning-flat-cached"), providerKind: .together
        ))
        let breakdown = try #require(leg.breakdown)
        #expect(breakdown.cachedInputTokens == 512)
        #expect(breakdown.promptTokens == 388)
        #expect(breakdown.cacheReadObserved == true)
    }
}
