import Foundation
import Testing
@testable import Oriveo

@Suite("InputRejectionSignatures")
struct InputRejectionSignatureTests {
    @Test func appMirrorIsLoaded() {
        let table = InputRejectionSignatures.shared
        #expect(table.byWireFamily["openai_chat.image_url"]?.count == 2)
        #expect(table.byProtocol["anthropic"]?.count == 3)
        #expect(table.byProtocol["openai_chat"]?.count == 2)
    }

    @Test func fixtureCasesMatchSignatureIds() throws {
        let fixture = try CapabilitySharedFixture.load("rejection-signatures.v1.json")
        let cases = try #require(fixture["cases"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let wireProtocol = try #require(item["protocol"] as? String, "\(id)")
            let response = try #require(item["response"] as? [String: Any], "\(id)")
            let status = try #require(response["status"] as? Int, "\(id)")
            let rawBody = try #require(response["body"], "\(id)")
            let body = try JSONSerialization.data(withJSONObject: rawBody)
            let expect = try #require(item["expect"] as? [String: Any], "\(id)")
            let expected = expect["signatureId"] as? String
            let families = (item["wireFamily"] as? String).map { [$0] } ?? []
            let actual = InputRejectionSignatures.shared.signatureId(
                status: status, body: body, protocol: wireProtocol, wireFamilies: families
            )
            #expect(actual == expected, "\(id)")
        }
    }
}
