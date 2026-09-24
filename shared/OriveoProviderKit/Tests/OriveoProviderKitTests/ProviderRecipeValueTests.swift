import Foundation
import Testing

@testable import OriveoProviderKit

// JSONSerialization hands back NSNumber for both numbers and booleans. A number that happens to be
// 0 or 1 must stay an integer; only a real JSON `true` / `false` may become a boolean.

@Suite("Provider recipe value bridging")
struct ProviderRecipeValueTests {
    @Test("0 and 1 from JSONSerialization stay integers; true and false stay booleans")
    func zeroAndOneAreNotBooleans() throws {
        let data = Data(#"{"one":1,"zero":0,"yes":true,"no":false,"half":1.5,"two":2}"#.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        guard case .object(let fields) = try #require(ProviderRecipeValue.fromFoundation(object)) else {
            Issue.record("expected an object")
            return
        }
        #expect(fields["one"] == .integer(1))
        #expect(fields["zero"] == .integer(0))
        #expect(fields["yes"] == .bool(true))
        #expect(fields["no"] == .bool(false))
        #expect(fields["half"] == .number(Decimal(string: "1.5")!))
        #expect(fields["two"] == .integer(2))
    }
}
