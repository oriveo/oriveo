import Foundation
import Testing
@testable import Oriveo

final class ZhipuMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = ZhipuMockURLProtocol.requestHandler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeZhipuMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ZhipuMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func zhipuHTTPResponse(url: URL, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
}

@Suite("Zhipu Service", .serialized)
struct ZhipuServiceTests {

    @Test("Sync Provider Uses Metadata Only Catalog")
    func syncProviderUsesMetadataOnlyCatalog() async throws {
        await MetadataClient.shared.resetForTesting()
        ZhipuMockURLProtocol.requestHandler = nil
        defer {
            ZhipuMockURLProtocol.requestHandler = nil
        }

        var requestedPaths: [String] = []
        ZhipuMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedPaths.append(url.path)
            return (
                zhipuHTTPResponse(url: url, statusCode: 404),
                Data("404 page not found".utf8)
            )
        }

        let service = ZhipuService(session: makeZhipuMockSession())
        let result = try await service.syncProvider(
            apiKey: "sk-test",
            preferredModelID: nil
        )

        #expect(requestedPaths.isEmpty)
        #expect(result.models.isEmpty)
    }
}
