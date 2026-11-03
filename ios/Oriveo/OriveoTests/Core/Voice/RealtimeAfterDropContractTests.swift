import Foundation
import Testing
@testable import Oriveo

/// Replays RealtimeModelPolicy.afterDrop against shared/voice-contracts/realtime-model.v1.json afterDropCases.
@Suite("Realtime after-drop contract")
struct RealtimeAfterDropContractTests {
    private typealias Policy = RealtimeModelPolicy

    @Test("after-drop cases match the fixture")
    func afterDropCases() throws {
        let cases = try RealtimeModelContractTests.cases("afterDropCases")
        #expect(cases.count == 12)
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any], "\(id)")
            let expected = try #require(item["expected"] as? [String: Any], "\(id)")
            let stage = try #require(Policy.DropStage(rawValue: input["stage"] as? String ?? "drop"), "\(id)")
            let category = try #require(Policy.FailureCategory(rawValue: input["category"] as? String ?? "unknown"), "\(id)")
            let provider = try #require(input["provider"] as? String, "\(id)")
            let outcome = Policy.afterDrop(
                stage: stage, provider: provider, category: category,
                muted: input["muted"] as? Bool ?? false,
                reopenedWithoutProgress: input["reopenedWithoutProgress"] as? Bool ?? false
            )
            #expect(outcome.action.rawValue == expected["action"] as? String, "\(id)")
            #expect(outcome.code == expected["code"] as? String, "\(id)")
            #expect(outcome.refetchCatalog == expected["refetchCatalog"] as? Bool, "\(id)")
        }
    }
}
