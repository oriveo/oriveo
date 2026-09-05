import Foundation
import Testing
@testable import Oriveo

final class TogetherMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = TogetherMockURLProtocol.requestHandler else {
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

private func makeTogetherMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [TogetherMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func togetherHTTPResponse(url: URL, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
}

private func togetherRequestBody(from request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var buffer = Data()
    let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
    defer { pointer.deallocate() }
    while stream.hasBytesAvailable {
        let count = stream.read(pointer, maxLength: 4096)
        if count <= 0 { break }
        buffer.append(pointer, count: count)
    }
    return buffer
}

private func togetherUserMessage(_ text: String, modelID: String) -> ChatMessage {
    officialUserMessage(text, providerKind: .together, modelID: modelID)
}

private func officialUserMessage(
    _ text: String,
    providerKind: ProviderKind,
    modelID: String
) -> ChatMessage {
    ChatMessage(
        id: UUID(),
        role: .user,
        text: text,
        providerKind: providerKind,
        providerName: providerKind.displayName,
        modelName: modelID,
        state: .delivered
    )
}

@Suite("Together Service", .serialized)
struct TogetherServiceTests {

    private static let imageMetadataJSON = """
    {
      "version": 1,
      "updatedAt": "2026-08-05T00:00:00Z",
      "providers": {
        "togetherAI": {
          "resolveMap": {
            "Qwen/Qwen-Image-2.0": "Qwen/Qwen-Image-2.0",
            "google/gemini-3-pro-image": "google/gemini-3-pro-image",
            "openai/gpt-oss-120b": "openai/gpt-oss-120b"
          },
          "models": {
            "Qwen/Qwen-Image-2.0": {
              "canonicalModelId": "Qwen/Qwen-Image-2.0",
              "capabilities": ["imageGeneration"],
              "profiles": { "imageGen": "together_images" }
            },
            "google/gemini-3-pro-image": {
              "canonicalModelId": "google/gemini-3-pro-image",
              "capabilities": ["imageGeneration"],
              "profiles": { "imageGen": "together_images_no_n" }
            },
            "openai/gpt-oss-120b": {
              "canonicalModelId": "openai/gpt-oss-120b",
              "capabilities": ["text"]
            }
          }
        }
      },
      "profiles": {
        "imageGen": {
          "together_images": {
            "route": "images_api",
            "requestDefaults": { "size": "1024x1024", "n": 1 }
          },
          "together_images_no_n": {
            "route": "images_api",
            "requestDefaults": { "size": "1024x1024" }
          }
        }
      }
    }
    """

    @Test("Image Gen Routes To Images Endpoint With Defaults")
    func imageGenRoutesToImagesEndpointWithDefaults() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: Self.imageMetadataJSON)
        TogetherMockURLProtocol.requestHandler = nil
        defer { TogetherMockURLProtocol.requestHandler = nil }

        var requestedURL: URL?
        var requestBody: [String: Any]?
        TogetherMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            if url.path == "/v1/images/generations" {
                requestedURL = url
                if let data = togetherRequestBody(from: request),
                   let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    requestBody = json
                }
                return (
                    togetherHTTPResponse(url: url, statusCode: 200),
                    Data(#"{"data":[{"url":"https://api.together.ai/imgproxy/abc123"}]}"#.utf8)
                )
            }
            return (togetherHTTPResponse(url: url, statusCode: 404), Data("404 page not found".utf8))
        }

        let dispatch = try await BaseAPIService(session: makeTogetherMockSession()).dispatchOfficialImageGeneration(
            providerKind: .together,
            userBaseURL: nil,
            apiKey: "sk-test",
            modelID: "Qwen/Qwen-Image-2.0",
            messages: [togetherUserMessage("draw a cat", modelID: "Qwen/Qwen-Image-2.0")],
            selectedModelSupportsImageGeneration: true
        )
        guard case let .handled(result) = dispatch else {
            Issue.record("images_api must be handled by the shared dispatcher")
            return
        }

        #expect(requestedURL?.absoluteString == "https://api.together.xyz/v1/images/generations")
        #expect(requestBody?["model"] as? String == "Qwen/Qwen-Image-2.0")
        #expect(requestBody?["prompt"] as? String == "draw a cat")
        #expect(requestBody?["size"] as? String == "1024x1024")
        #expect(requestBody?["n"] as? Int == 1)
        #expect(requestBody?["messages"] == nil)
        #expect(result.text.isEmpty)
        #expect(result.attachments?.count == 1)
        #expect(result.attachments?.first?.base64Data == "https://api.together.ai/imgproxy/abc123")
    }

    @Test("No NVariant Never Adds N")
    func noNVariantNeverAddsN() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: Self.imageMetadataJSON)
        TogetherMockURLProtocol.requestHandler = nil
        defer { TogetherMockURLProtocol.requestHandler = nil }

        var requestedURL: URL?
        var requestBody: [String: Any]?
        TogetherMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            if url.path == "/v1/images/generations" {
                requestedURL = url
                if let data = togetherRequestBody(from: request),
                   let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    requestBody = json
                }
                return (
                    togetherHTTPResponse(url: url, statusCode: 200),
                    Data(#"{"data":[{"b64_json":"AQID"}]}"#.utf8)
                )
            }
            return (togetherHTTPResponse(url: url, statusCode: 404), Data("404 page not found".utf8))
        }

        let dispatch = try await BaseAPIService(session: makeTogetherMockSession()).dispatchOfficialImageGeneration(
            providerKind: .together,
            userBaseURL: nil,
            apiKey: "sk-test",
            modelID: "google/gemini-3-pro-image",
            messages: [togetherUserMessage("draw a dog", modelID: "google/gemini-3-pro-image")],
            selectedModelSupportsImageGeneration: true
        )
        guard case let .handled(result) = dispatch else {
            Issue.record("images_api must be handled by the shared dispatcher")
            return
        }

        #expect(requestedURL?.absoluteString == "https://api.together.xyz/v1/images/generations")
        #expect(requestBody?["size"] as? String == "1024x1024")
        #expect(requestBody?["n"] == nil)
        #expect(result.attachments?.first?.base64Data == "AQID")
    }

    @Test("Text Model Still Uses Chat Endpoint")
    func textModelStillUsesChatEndpoint() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: Self.imageMetadataJSON)
        TogetherMockURLProtocol.requestHandler = nil
        defer { TogetherMockURLProtocol.requestHandler = nil }

        var requestedURL: URL?
        TogetherMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedURL = url
            return (
                togetherHTTPResponse(url: url, statusCode: 200),
                Data(#"{"choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
            )
        }

        let service = TogetherService(session: makeTogetherMockSession())
        _ = try await service.sendMessage(
            apiKey: "sk-test",
            modelID: "openai/gpt-oss-120b",
            messages: [togetherUserMessage("hello", modelID: "openai/gpt-oss-120b")]
        )

        #expect(requestedURL?.absoluteString == "https://api.together.xyz/v1/chat/completions")
    }

    @Test("Missing Route Fails Loud")
    func missingRouteFailsLoud() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-08-05T00:00:00Z",
          "providers": {
            "togetherAI": {
              "resolveMap": { "Qwen/Qwen-Image-2.0": "Qwen/Qwen-Image-2.0" },
              "models": {
                "Qwen/Qwen-Image-2.0": {
                  "canonicalModelId": "Qwen/Qwen-Image-2.0",
                  "capabilities": ["imageGeneration"],
                  "profiles": { "imageGen": "together_images" }
                }
              }
            }
          },
          "profiles": { "imageGen": {} }
        }
        """)
        TogetherMockURLProtocol.requestHandler = nil
        defer { TogetherMockURLProtocol.requestHandler = nil }

        var issuedPaths: [String] = []
        TogetherMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            issuedPaths.append(url.path)
            return (togetherHTTPResponse(url: url, statusCode: 200), Data("{}".utf8))
        }

        await #expect(throws: ProviderServiceError.self) {
            _ = try await BaseAPIService(session: makeTogetherMockSession()).dispatchOfficialImageGeneration(
                providerKind: .together,
                userBaseURL: nil,
                apiKey: "sk-test",
                modelID: "Qwen/Qwen-Image-2.0",
                messages: [togetherUserMessage("draw a cat", modelID: "Qwen/Qwen-Image-2.0")],
                selectedModelSupportsImageGeneration: true
            )
        }
        #expect(issuedPaths.isEmpty)
    }

    @Test("Unknown Route Fails Loud")
    func unknownRouteFailsLoud() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-08-05T00:00:00Z",
          "providers": {
            "togetherAI": {
              "resolveMap": { "future-image-model": "future-image-model" },
              "models": {
                "future-image-model": {
                  "canonicalModelId": "future-image-model",
                  "capabilities": ["imageGeneration"],
                  "profiles": { "imageGen": "future_images" }
                }
              }
            }
          },
          "profiles": {
            "imageGen": {
              "future_images": { "route": "future_images_v2" }
            }
          }
        }
        """)
        TogetherMockURLProtocol.requestHandler = nil
        defer { TogetherMockURLProtocol.requestHandler = nil }

        var requestCount = 0
        TogetherMockURLProtocol.requestHandler = { request in
            requestCount += 1
            let url = try #require(request.url)
            return (togetherHTTPResponse(url: url, statusCode: 200), Data("{}".utf8))
        }

        await #expect(throws: ProviderServiceError.self) {
            _ = try await BaseAPIService(session: makeTogetherMockSession()).dispatchOfficialImageGeneration(
                providerKind: .together,
                userBaseURL: nil,
                apiKey: "sk-test",
                modelID: "future-image-model",
                messages: [togetherUserMessage("draw", modelID: "future-image-model")],
                selectedModelSupportsImageGeneration: true
            )
        }
        #expect(requestCount == 0)
    }

    @Test("Future Compatible Provider Inherits Images Route")
    func futureCompatibleProviderInheritsImagesRoute() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-08-05T00:00:00Z",
          "providers": {
            "fireworksAI": {
              "transport": {
                "baseUrl": "https://api.fireworks.ai",
                "endpoints": {
                  "chat": "/inference/v1/chat/completions",
                  "images": "/inference/v1/images/generations"
                }
              },
              "resolveMap": { "future-image-model": "future-image-model" },
              "models": {
                "future-image-model": {
                  "canonicalModelId": "future-image-model",
                  "capabilities": ["imageGeneration"],
                  "profiles": { "imageGen": "future_images" }
                }
              }
            }
          },
          "profiles": {
            "imageGen": {
              "future_images": {
                "route": "images_api",
                "requestDefaults": { "size": "1024x1024" }
              }
            }
          }
        }
        """)
        TogetherMockURLProtocol.requestHandler = nil
        defer { TogetherMockURLProtocol.requestHandler = nil }

        var requestedURL: URL?
        var requestBody: [String: Any]?
        TogetherMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedURL = url
            if let data = togetherRequestBody(from: request) {
                requestBody = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            return (
                togetherHTTPResponse(url: url, statusCode: 200),
                Data(#"{"data":[{"b64_json":"AQID"}]}"#.utf8)
            )
        }

        let dispatch = try await BaseAPIService(session: makeTogetherMockSession()).dispatchOfficialImageGeneration(
            providerKind: .fireworks,
            userBaseURL: nil,
            apiKey: "sk-test",
            modelID: "future-image-model",
            messages: [officialUserMessage("draw", providerKind: .fireworks, modelID: "future-image-model")],
            selectedModelSupportsImageGeneration: true
        )

        guard case .handled = dispatch else {
            Issue.record("future compatible provider must be handled centrally")
            return
        }
        #expect(requestedURL?.absoluteString == "https://api.fireworks.ai/inference/v1/images/generations")
        #expect(requestBody?.count == 3)
        #expect(requestBody?["size"] as? String == "1024x1024")
        #expect(requestBody?["model"] as? String == "future-image-model")
        #expect(requestBody?["prompt"] as? String == "draw")
        #expect(requestBody?["n"] == nil)
        #expect(requestBody?["stream"] == nil)
        #expect(requestBody?["messages"] == nil)
    }

    @Test("Relay Bypasses Official Image Dispatch")
    func relayBypassesOfficialImageDispatch() async throws {
        await MetadataClient.shared.resetForTesting()
        TogetherMockURLProtocol.requestHandler = nil
        defer { TogetherMockURLProtocol.requestHandler = nil }
        var requestCount = 0
        TogetherMockURLProtocol.requestHandler = { request in
            requestCount += 1
            let url = try #require(request.url)
            return (togetherHTTPResponse(url: url, statusCode: 200), Data())
        }

        let dispatch = try await BaseAPIService(session: makeTogetherMockSession()).dispatchOfficialImageGeneration(
            providerKind: .relay,
            userBaseURL: "https://relay.example/v1",
            apiKey: "sk-test",
            modelID: "relay-image-model",
            messages: [officialUserMessage("draw", providerKind: .relay, modelID: "relay-image-model")],
            selectedModelSupportsImageGeneration: true
        )

        guard case .notApplicable = dispatch else {
            Issue.record("Relay must bypass official image dispatch")
            return
        }
        #expect(requestCount == 0)
    }
}
