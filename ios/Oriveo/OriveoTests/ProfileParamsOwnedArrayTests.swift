import Testing
@testable import Oriveo

@Suite("Owned parameter array identity")
struct ProfileParamsOwnedArrayTests {
    @Test func reorderedKeysDoNotDuplicateAnonymousTool() {
        let base: [Any] = [["type": "web_search", "config": ["b": 2, "a": 1]]]
        let incoming: [Any] = [["config": ["a": 1, "b": 2], "type": "web_search"]]
        #expect(ProfileParamsResolver.composeOwnedArray(base: base, contribution: incoming).count == 1)
    }
}
