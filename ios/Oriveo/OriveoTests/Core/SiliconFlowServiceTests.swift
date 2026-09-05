import Foundation
import Testing
@testable import Oriveo

final class SiliconFlowMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = SiliconFlowMockURLProtocol.requestHandler else {
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

private func makeSiliconFlowMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SiliconFlowMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func siliconFlowHTTPResponse(url: URL, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
}

@Suite("SiliconFlow Service", .serialized)
struct SiliconFlowServiceTests {

    @Test("Attachment Support Matches Open AICompatible")
    func attachmentSupportMatchesOpenAICompatible() {
        let support = ProviderKind.siliconFlow.attachmentSupport
        #expect(support.image == true)
        #expect(support.nativeFile == false)
        #expect(support.textFileInline == true)
    }

    @Test("Vl Model Supports Image And File Attachment")
    func vlModelSupportsImageAndFileAttachment() async throws {
        await MetadataClient.shared.resetForTesting()

        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-04-10T00:00:00Z",
          "providers": {
            "siliconFlow": {
              "displayName": "SiliconFlow",
              "attachmentSupport": { "image": true, "nativeFile": false, "textFileInline": true },
              "defaultModelId": "Qwen/Qwen3-VL-32B-Instruct",
              "resolveMap": { "Qwen/Qwen3-VL-32B-Instruct": "Qwen/Qwen3-VL-32B-Instruct" },
              "models": {
                "Qwen/Qwen3-VL-32B-Instruct": {
                  "canonicalModelId": "Qwen/Qwen3-VL-32B-Instruct",
                  "displayName": "Qwen3 VL 32B",
                  "capabilities": ["text", "image", "file"]
                }
              }
            }
          }
        }
        """)

        let caps = await MetadataClient.shared.capabilities(
            modelID: "Qwen/Qwen3-VL-32B-Instruct",
            providerKind: .siliconFlow
        )
        #expect(caps != nil)
        #expect(caps!.contains(.image))
        #expect(caps!.contains(.file))

        let support = ProviderKind.siliconFlow.attachmentSupport
        #expect(support.image == true)
        #expect(support.nativeFile == false)
        #expect(support.textFileInline == true)
    }

    @Test("Sync Provider Uses Metadata Only Catalog")
    func syncProviderUsesMetadataOnlyCatalog() async throws {
        await MetadataClient.shared.resetForTesting()
        SiliconFlowMockURLProtocol.requestHandler = nil
        defer {
            SiliconFlowMockURLProtocol.requestHandler = nil
        }

        var requestedRoutes: [String] = []
        SiliconFlowMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedRoutes.append(url.path)
            return (
                siliconFlowHTTPResponse(url: url, statusCode: 404),
                Data("404 page not found".utf8)
            )
        }

        let service = SiliconFlowService(session: makeSiliconFlowMockSession())
        let result = try await service.syncProvider(
            apiKey: "sk-test",
            preferredModelID: nil
        )

        #expect(requestedRoutes.isEmpty)
        #expect(result.models.isEmpty)
    }

    @Test("International Endpoint Is Used For Chat")
    func internationalEndpointIsUsedForChat() async throws {
        await MetadataClient.shared.resetForTesting()
        defer {
            SiliconFlowMockURLProtocol.requestHandler = nil
        }

        var requestedURL: URL?
        SiliconFlowMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedURL = url
            return (
                siliconFlowHTTPResponse(url: url, statusCode: 200),
                Data(#"{"choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
            )
        }

        let service = SiliconFlowService(session: makeSiliconFlowMockSession())
        _ = try await service.sendMessage(
            apiKey: "sk-intl",
            modelID: "Qwen/Qwen3-8B",
            messages: [
                ChatMessage(
                    id: UUID(), role: .user, text: "hello",
                    providerKind: .siliconFlow, providerName: "SiliconFlow",
                    modelName: "Qwen/Qwen3-8B", state: .delivered
                ),
            ],
            baseURL: "api.siliconflow.com/v1"
        )

        #expect(requestedURL?.absoluteString == "https://api.siliconflow.com/v1/chat/completions")
    }

    @Test("International Balance Uses USD")
    func internationalBalanceUsesUSD() async throws {
        defer { SiliconFlowMockURLProtocol.requestHandler = nil }
        var requestedURL: URL?
        SiliconFlowMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedURL = url
            return (
                siliconFlowHTTPResponse(url: url, statusCode: 200),
                Data(#"{"data":{"balance":"0.5","chargeBalance":"8","totalBalance":"8.5"}}"#.utf8)
            )
        }

        let service = SiliconFlowService(session: makeSiliconFlowMockSession())
        let balance = try await service.fetchBalance(
            apiKey: "sk-intl",
            baseURL: "https://api.siliconflow.com/v1"
        )

        #expect(requestedURL?.absoluteString == "https://api.siliconflow.com/v1/user/info")
        #expect(balance.currency == "USD")
    }
}
