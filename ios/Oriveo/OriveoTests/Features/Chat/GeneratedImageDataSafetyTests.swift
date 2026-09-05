import Foundation
import Testing
@testable import Oriveo

@Suite("GeneratedImageDataSafety", .serialized)
struct GeneratedImageDataSafetyTests {
    @Test("Base64 Budget")
    func base64Budget() {
        let normal = Data("image".utf8)
        #expect(ChatManager.decodeImageBase64(normal.base64EncodedString()) == normal)
        #expect(ChatManager.decodeImageBase64("data:image/png;base64,\(normal.base64EncodedString())") == normal)

        let oversizedEncoded = String(
            repeating: "A",
            count: ((ChatAttachmentImportPolicy.maxAttachmentBytes + 2) / 3) * 4 + 257
        )
        #expect(ChatManager.decodeImageBase64(oversizedEncoded) == nil)
    }

    @Test("Network Data Within Budget")
    func networkDataWithinBudget() async throws {
        StubURLProtocol.responseData = Data(repeating: 0x61, count: 8)
        StubURLProtocol.declaredLength = 8
        let loader = BoundedNetworkDataLoader(maxBytes: 8, configuration: makeConfiguration())

        #expect(try await loader.data(from: URL(string: "https://example.test/image")!).count == 8)
    }

    @Test("Network Data Over Budget")
    func networkDataOverBudget() async {
        StubURLProtocol.responseData = Data(repeating: 0x61, count: 9)
        StubURLProtocol.declaredLength = 9
        await expectTooLarge(maxBytes: 8)

        StubURLProtocol.responseData = Data(repeating: 0x61, count: 9)
        StubURLProtocol.declaredLength = nil
        await expectTooLarge(maxBytes: 8)
    }

    private func expectTooLarge(maxBytes: Int) async {
        let loader = BoundedNetworkDataLoader(maxBytes: maxBytes, configuration: makeConfiguration())
        do {
            _ = try await loader.data(from: URL(string: "https://example.test/image")!)
            Issue.record("Expected tooLarge")
        } catch let error as BoundedNetworkDataError {
            #expect(error == .tooLarge)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static var responseData = Data()
    static var declaredLength: Int?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var headers: [String: String] = [:]
        if let declaredLength = Self.declaredLength {
            headers["Content-Length"] = String(declaredLength)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
