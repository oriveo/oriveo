import Foundation
import Testing
@testable import Oriveo

@Suite("Relay Error Snippet")
struct RelayErrorSnippetTests {
    @Test("Base APIService Uses Moved Production Snippet")
    func baseAPIServiceUsesMovedProductionSnippet() {
        let service = BaseAPIService()
        let body = Data(#"{"error":{"message":"bad key secret-123","type":"invalid_request"}}"#.utf8)
        var request = URLRequest(url: URL(string: "https://example.com")!)
        request.setValue("Bearer secret-123", forHTTPHeaderField: "Authorization")

        let result = service.decodeErrorMessage(from: body, request: request)

        #expect(result == "bad key ***hidden")
        #expect(!result!.contains("invalid_request"))
    }
}
