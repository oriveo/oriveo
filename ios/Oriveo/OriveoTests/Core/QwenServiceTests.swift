import Foundation
import Testing
@testable import Oriveo

final class QwenMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = QwenMockURLProtocol.requestHandler else {
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

private func makeQwenMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [QwenMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func qwenHTTPResponse(
    url: URL,
    statusCode: Int,
    headers: [String: String]? = nil
) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: headers)!
}

private func qwenRequestBody(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }

    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }

    let bufferSize = 1_024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    var data = Data()
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufferSize)
        guard read > 0 else { break }
        data.append(buffer, count: read)
    }
    return data.isEmpty ? nil : data
}

@Suite("Qwen Service", .serialized)
struct QwenServiceTests {

    @Test("Sync Provider Uses Metadata Only Catalog")
    func syncProviderUsesMetadataOnlyCatalog() async throws {
        await MetadataClient.shared.resetForTesting()
        QwenMockURLProtocol.requestHandler = nil
        defer { QwenMockURLProtocol.requestHandler = nil }

        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-04-08T00:00:00Z",
          "providers": {
            "qwen": {
              "displayName": "Qwen",
              "defaultModelId": "qwen-plus",
              "resolveMap": {
                "qwen-plus": "qwen-plus"
              },
              "models": {
                "qwen-plus": {
                  "canonicalModelId": "qwen-plus",
                  "displayName": "Qwen Plus",
                  "contextLength": 131072,
                  "pricing": {
                    "promptPerMToken": 0.4,
                    "completionPerMToken": 1.2
                  },
                  "capabilities": ["text", "reasoning"],
                  "profiles": {
                    "reasoning": "qwen_hybrid"
                  },
                  "uiHints": {
                    "groupKey": "qwen-plus",
                    "groupName": "Qwen Plus",
                    "rank": 120,
                    "recommended": true
                  }
                }
              }
            }
          }
        }
        """)

        var requestedPaths: [String] = []
        QwenMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedPaths.append(url.path)
            return (
                qwenHTTPResponse(url: url, statusCode: 404),
                Data("404 page not found".utf8)
            )
        }

        let service = QwenService(session: makeQwenMockSession())
        let result = try await service.syncProvider(
            apiKey: "sk-api-test",
            preferredModelID: nil,
            baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        )

        #expect(requestedPaths.isEmpty)
        #expect(result.models.isEmpty)

        await MetadataClient.shared.resetForTesting()
    }

    @Test("Chat Endpoint Forces Compatible Even When Metadata Sends Native Path")
    func chatEndpointForcesCompatibleEvenWhenMetadataSendsNativePath() async throws {
        await MetadataClient.shared.resetForTesting()

        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-04-08T00:00:00Z",
          "providers": {
            "qwen": {
              "transport": {
                "baseUrl": "https://dashscope-intl.aliyuncs.com",
                "endpoints": {
                  "chat": "/api/v1/services/aigc/text-generation/generation"
                }
              },
              "models": {}
            }
          }
        }
        """)

        let service = QwenService(session: makeQwenMockSession())
        let compatBase = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        let url = service.chatEndpointURL(baseURL: compatBase)

        #expect(!url.path.contains("/services/aigc/text-generation/generation"))
        #expect(
            url.absoluteString
                == "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions"
        )

        await MetadataClient.shared.resetForTesting()
    }

    @Test("Send Message Downloads Generated Image Via Injected Session")
    func sendMessageDownloadsGeneratedImageViaInjectedSession() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-07-04T00:00:00Z",
          "providers": {
            "qwen": {
              "resolveMap": { "qwen-image-2.0": "qwen-image-2.0" },
              "models": {
                "qwen-image-2.0": {
                  "canonicalModelId": "qwen-image-2.0",
                  "capabilities": ["imageGeneration"],
                  "transport": "qwen_image",
                  "profiles": { "imageGen": "qwen_images" }
                }
              }
            }
          },
          "profiles": {
            "imageGen": {
              "qwen_images": {
                "route": "dashscope_multimodal",
                "requestDefaults": { "size": "1024*1024", "n": 1, "prompt_extend": true }
              }
            }
          }
        }
        """)
        QwenMockURLProtocol.requestHandler = nil
        defer {
            QwenMockURLProtocol.requestHandler = nil
        }

        var requestedPaths: [String] = []
        QwenMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedPaths.append(url.path)

            switch url.absoluteString {
            case "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation":
                return (
                    qwenHTTPResponse(url: url, statusCode: 200),
                    Data(#"{"output":{"choices":[{"message":{"content":[{"image":"https://temp.qwen.test/generated.png"}]}}]}}"#.utf8)
                )
            default:
                return (
                    qwenHTTPResponse(url: url, statusCode: 404),
                    Data("404 page not found".utf8)
                )
            }
        }

        let service = QwenService(session: makeQwenMockSession())
        let result = try await service.sendMessage(
            apiKey: "sk-test",
            modelID: "qwen-image-2.0",
            messages: [
                ChatMessage(
                    id: UUID(),
                    role: .user,
                    text: "draw a fox",
                    providerKind: .qwen,
                    providerName: "Qwen",
                    modelName: "qwen-image-2.0",
                    state: .delivered
                ),
            ],
            baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        )

        #expect(requestedPaths == ["/api/v1/services/aigc/multimodal-generation/generation"])
        #expect(result.text.isEmpty)
        #expect(result.attachments?.count == 1)
        #expect(result.attachments?.first?.mimeType == "image/png")
        #expect(result.attachments?.first?.fileName == "generated_image.png")
        #expect(result.attachments?.first?.base64Data == "https://temp.qwen.test/generated.png")
    }

    @Test("Send Message Preserves Generated Image URLWhen Download Fails")
    func sendMessagePreservesGeneratedImageURLWhenDownloadFails() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-07-04T00:00:00Z",
          "providers": {
            "qwen": {
              "resolveMap": { "qwen-image-2.0": "qwen-image-2.0" },
              "models": {
                "qwen-image-2.0": {
                  "canonicalModelId": "qwen-image-2.0",
                  "capabilities": ["imageGeneration"],
                  "transport": "qwen_image",
                  "profiles": { "imageGen": "qwen_images" }
                }
              }
            }
          },
          "profiles": {
            "imageGen": {
              "qwen_images": {
                "route": "dashscope_multimodal",
                "requestDefaults": { "size": "1024*1024", "n": 1, "prompt_extend": true }
              }
            }
          }
        }
        """)
        QwenMockURLProtocol.requestHandler = nil
        defer {
            QwenMockURLProtocol.requestHandler = nil
        }

        var imageGenRequestBody: [String: Any]?
        QwenMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)

            switch url.absoluteString {
            case "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation":
                if let data = qwenRequestBody(from: request),
                   let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    imageGenRequestBody = json
                }

                return (
                    qwenHTTPResponse(url: url, statusCode: 200),
                    Data(#"{"output":{"choices":[{"message":{"content":[{"image":"https://temp.qwen.test/generated.png"}]}}]}}"#.utf8)
                )

            case "https://temp.qwen.test/generated.png":
                return (
                    qwenHTTPResponse(url: url, statusCode: 404),
                    Data("not found".utf8)
                )

            default:
                return (
                    qwenHTTPResponse(url: url, statusCode: 404),
                    Data("404 page not found".utf8)
                )
            }
        }

        let service = QwenService(session: makeQwenMockSession())
        let result = try await service.sendMessage(
            apiKey: "sk-test",
            modelID: "qwen-image-2.0",
            messages: [
                ChatMessage(
                    id: UUID(),
                    role: .user,
                    text: "draw a fox",
                    providerKind: .qwen,
                    providerName: "Qwen",
                    modelName: "qwen-image-2.0",
                    state: .delivered
                ),
            ],
            baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        )

        let parameters = try #require(imageGenRequestBody?["parameters"] as? [String: Any])
        #expect(parameters["size"] as? String == "1024*1024")
        #expect(result.text.isEmpty)
        #expect(result.attachments?.count == 1)
        #expect(result.attachments?.first?.mimeType == "image/png")
        #expect(result.attachments?.first?.base64Data == "https://temp.qwen.test/generated.png")
    }

    @Test("Send Message Stream Falls Back To Choice Message Content")
    func sendMessageStreamFallsBackToChoiceMessageContent() async throws {
        QwenMockURLProtocol.requestHandler = nil
        defer { QwenMockURLProtocol.requestHandler = nil }

        QwenMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            #expect(url.path == "/compatible-mode/v1/chat/completions")

            let body = """
            data: {"choices":[{"delta":{"role":"assistant"}}]}
            data: {"choices":[{"message":{"content":"final answer from message"}}]}
            data: {"usage":{"prompt_tokens":3,"completion_tokens":5}}
            data: [DONE]

            """

            return (
                qwenHTTPResponse(url: url, statusCode: 200),
                Data(body.utf8)
            )
        }

        let service = QwenService(session: makeQwenMockSession())
        var events: [StreamEvent] = []

        for try await event in service.sendMessageStream(
            apiKey: "sk-test",
            modelID: "qwen3.5-plus",
            messages: [
                ChatMessage(
                    id: UUID(),
                    role: .user,
                    text: "hello",
                    providerKind: .qwen,
                    providerName: "Qwen",
                    modelName: "qwen3.5-plus",
                    state: .delivered
                ),
            ],
            baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        ) {
            events.append(event)
        }

        if case let .done(result) = try #require(events.last) {
            #expect(result.text == "final answer from message")
            #expect(result.promptTokens == 3)
            #expect(result.completionTokens == 5)
        } else {
            Issue.record("expected final done event")
        }
    }

    @Test("Send Message Stream Falls Back To Choice Message Content Parts")
    func sendMessageStreamFallsBackToChoiceMessageContentParts() async throws {
        QwenMockURLProtocol.requestHandler = nil
        defer { QwenMockURLProtocol.requestHandler = nil }

        QwenMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            #expect(url.path == "/compatible-mode/v1/chat/completions")

            let body = """
            data: {"choices":[{"delta":{"role":"assistant"}}]}
            data: {"choices":[{"message":{"content":[{"type":"text","text":"final answer from parts"}]}}]}
            data: {"usage":{"prompt_tokens":3,"completion_tokens":5}}
            data: [DONE]

            """

            return (
                qwenHTTPResponse(url: url, statusCode: 200),
                Data(body.utf8)
            )
        }

        let service = QwenService(session: makeQwenMockSession())
        var events: [StreamEvent] = []

        for try await event in service.sendMessageStream(
            apiKey: "sk-test",
            modelID: "qwen3.6-plus",
            messages: [
                ChatMessage(
                    id: UUID(),
                    role: .user,
                    text: "hello",
                    providerKind: .qwen,
                    providerName: "Qwen",
                    modelName: "qwen3.6-plus",
                    state: .delivered
                ),
            ],
            baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        ) {
            events.append(event)
        }

        if case let .done(result) = try #require(events.last) {
            #expect(result.text == "final answer from parts")
            #expect(result.promptTokens == 3)
            #expect(result.completionTokens == 5)
        } else {
            Issue.record("expected final done event")
        }
    }

    @Test("Compat Stream Parses Reasoning Then Content")
    func compatStreamParsesReasoningThenContent() async throws {
        QwenMockURLProtocol.requestHandler = nil
        defer { QwenMockURLProtocol.requestHandler = nil }

        let compatSSE = """
        data: {"choices":[{"delta":{"content":null,"reasoning_content":"ThinkA","role":"assistant"},"index":0}]}
        data: {"choices":[{"delta":{"content":null,"reasoning_content":"ThinkB"},"index":0}]}
        data: {"choices":[{"delta":{"content":"Hello","role":"assistant"},"index":0}]}
        data: {"choices":[{"delta":{},"finish_reason":"stop","index":0}],"usage":{"prompt_tokens":9,"completion_tokens":12,"total_tokens":21}}
        data: [DONE]

        """

        QwenMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            #expect(url.path.contains("/compatible-mode/v1/chat/completions"))
            #expect(!url.path.contains("/services/aigc/text-generation/generation"))
            return (
                qwenHTTPResponse(url: url, statusCode: 200, headers: ["Content-Type": "text/event-stream"]),
                Data(compatSSE.utf8)
            )
        }

        let service = QwenService(session: makeQwenMockSession())
        var collected = ""
        var reasoning = ""
        var doneText: String?

        for try await event in service.sendMessageStream(
            apiKey: "sk-test",
            modelID: "qwen3.6-flash",
            messages: [
                ChatMessage(
                    id: UUID(),
                    role: .user,
                    text: "Say two characters",
                    providerKind: .qwen,
                    providerName: "Qwen",
                    modelName: "qwen3.6-flash",
                    state: .delivered
                ),
            ],
            baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        ) {
            switch event {
            case let .delta(text): collected += text
            case let .reasoning(text): reasoning += text
            case let .done(result): doneText = result.text
            default: break
            }
        }

        #expect(collected == "Hello")
        #expect(reasoning == "ThinkAThinkB")
        #expect(doneText == "Hello")
    }

    @Test("Compat Stream Preserves Markdown Whitespace In Chunks")
    func compatStreamPreservesMarkdownWhitespaceInChunks() async throws {
        QwenMockURLProtocol.requestHandler = nil
        defer { QwenMockURLProtocol.requestHandler = nil }

        let compatSSE = """
        data: {"choices":[{"delta":{"role":"assistant"}}]}
        data: {"choices":[{"delta":{"content":"# Title"}}]}
        data: {"choices":[{"delta":{"content":"\\n\\n"}}]}
        data: {"choices":[{"delta":{"content":"- Item one"}}]}
        data: {"choices":[{"delta":{"content":"\\n- Item two"}}]}
        data: {"choices":[{"delta":{"content":"\\n\\n```swift\\nlet x = 1\\n```"}}]}
        data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":7}}
        data: [DONE]

        """

        QwenMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            return (
                qwenHTTPResponse(url: url, statusCode: 200, headers: ["Content-Type": "text/event-stream"]),
                Data(compatSSE.utf8)
            )
        }

        let service = QwenService(session: makeQwenMockSession())
        var collected = ""
        var doneText: String?

        for try await event in service.sendMessageStream(
            apiKey: "sk-test",
            modelID: "qwen3.5-plus",
            messages: [
                ChatMessage(
                    id: UUID(),
                    role: .user,
                    text: "Write some markdown",
                    providerKind: .qwen,
                    providerName: "Qwen",
                    modelName: "qwen3.5-plus",
                    state: .delivered
                ),
            ],
            baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        ) {
            switch event {
            case let .delta(text): collected += text
            case let .done(result): doneText = result.text
            default: break
            }
        }

        let expected = "# Title\n\n- Item one\n- Item two\n\n```swift\nlet x = 1\n```"
        #expect(collected == expected)
        #expect(doneText == expected)
    }

    @Test("Compat Stream Surfaces In Stream Upstream Error")
    func compatStreamSurfacesInStreamUpstreamError() async throws {
        QwenMockURLProtocol.requestHandler = nil
        defer { QwenMockURLProtocol.requestHandler = nil }

        let errorSSE = """
        data: {"error":{"message":"Model not exist: qwen-fake","type":"invalid_request_error"}}
        data: [DONE]

        """

        QwenMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            return (
                qwenHTTPResponse(url: url, statusCode: 200, headers: ["Content-Type": "text/event-stream"]),
                Data(errorSSE.utf8)
            )
        }

        let service = QwenService(session: makeQwenMockSession())

        await #expect(throws: ProviderServiceError.self) {
            for try await _ in service.sendMessageStream(
                apiKey: "sk-test",
                modelID: "qwen-fake",
                messages: [
                    ChatMessage(
                        id: UUID(),
                        role: .user,
                        text: "hi",
                        providerKind: .qwen,
                        providerName: "Qwen",
                        modelName: "qwen-fake",
                        state: .delivered
                    ),
                ],
                baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
            ) {}
        }
    }

    @Test("Stream Error Message Extraction")
    func streamErrorMessageExtraction() {
        #expect(
            QwenService.streamErrorMessage(
                from: Data(#"{"error":{"message":"boom"}}"#.utf8)
            ) == "boom"
        )
        #expect(
            QwenService.streamErrorMessage(
                from: Data(#"{"code":"InvalidParameter","message":"url error"}"#.utf8)
            ) == "url error"
        )
        #expect(
            QwenService.streamErrorMessage(
                from: Data(#"{"choices":[{"delta":{"content":"hi"}}]}"#.utf8)
            ) == nil
        )
        #expect(
            QwenService.streamErrorMessage(
                from: Data(#"{"usage":{"prompt_tokens":1,"completion_tokens":2}}"#.utf8)
            ) == nil
        )
    }

    @Test("Zhipu Send Message Includes Square Size")
    func zhipuSendMessageIncludesSquareSize() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-07-04T00:00:00Z",
          "providers": {
            "zhipu": {
              "resolveMap": { "cogview-4": "cogview-4" },
              "models": {
                "cogview-4": {
                  "canonicalModelId": "cogview-4",
                  "capabilities": ["imageGeneration"],
                  "transport": "zhipu_image",
                  "profiles": { "imageGen": "zhipu_images" }
                }
              }
            }
          },
          "profiles": {
            "imageGen": {
              "zhipu_images": {
                "route": "images_api",
                "requestDefaults": { "size": "1024x1024" }
              }
            }
          }
        }
        """)
        QwenMockURLProtocol.requestHandler = nil
        defer {
            QwenMockURLProtocol.requestHandler = nil
        }

        var imageGenRequestBody: [String: Any]?
        QwenMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)

            if url.absoluteString == "https://open.bigmodel.cn/api/paas/v4/images/generations" {
                if let data = qwenRequestBody(from: request),
                   let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    imageGenRequestBody = json
                }

                return (
                    qwenHTTPResponse(url: url, statusCode: 200),
                    Data(#"{"data":[{"b64_json":"AQID"}]}"#.utf8)
                )
            }

            return (
                qwenHTTPResponse(url: url, statusCode: 404),
                Data("404 page not found".utf8)
            )
        }

        let dispatch = try await BaseAPIService(session: makeQwenMockSession()).dispatchOfficialImageGeneration(
            providerKind: .zhipu,
            userBaseURL: nil,
            apiKey: "sk-test",
            modelID: "cogview-4",
            messages: [
                ChatMessage(
                    id: UUID(),
                    role: .user,
                    text: "draw a panda",
                    providerKind: .zhipu,
                    providerName: "Zhipu",
                    modelName: "cogview-4",
                    state: .delivered
                ),
            ],
            selectedModelSupportsImageGeneration: true
        )
        guard case let .handled(result) = dispatch else {
            Issue.record("zhipu images_api must be handled centrally")
            return
        }

        #expect(imageGenRequestBody?["size"] as? String == "1024x1024")
        #expect(result.text.isEmpty)
        #expect(result.attachments?.count == 1)
        #expect(result.attachments?.first?.base64Data == "AQID")
    }

    @Test("Silicon Flow Preserves Generated Image URLWhen Download Fails")
    func siliconFlowPreservesGeneratedImageURLWhenDownloadFails() async throws {
        await MetadataClient.shared.resetForTesting()
        QwenMockURLProtocol.requestHandler = nil
        defer {
            QwenMockURLProtocol.requestHandler = nil
        }

        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-04-08T00:00:00Z",
          "providers": {
            "siliconFlow": {
              "resolveMap": {
                "Kwai-Kolors/Kolors": "Kwai-Kolors/Kolors"
              },
              "models": {
                "Kwai-Kolors/Kolors": {
                  "canonicalModelId": "Kwai-Kolors/Kolors",
                  "capabilities": ["text", "imageGeneration"],
                  "profiles": {
                    "imageGen": "sf_images"
                  }
                }
              }
            }
          },
          "profiles": {
            "imageGen": {
              "sf_images": {
                "route": "images_api",
                "requestDefaults": { "size": "1024x1024", "n": 1 }
              }
            }
          }
        }
        """)

        var imageGenRequestBody: [String: Any]?
        QwenMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)

            switch url.absoluteString {
            case "https://api.siliconflow.com/v1/images/generations":
                if let data = qwenRequestBody(from: request),
                   let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    imageGenRequestBody = json
                }

                return (
                    qwenHTTPResponse(url: url, statusCode: 200),
                    Data(#"{"data":[{"url":"https://temp.siliconflow.test/image.png"}]}"#.utf8)
                )

            case "https://temp.siliconflow.test/image.png":
                return (
                    qwenHTTPResponse(url: url, statusCode: 404),
                    Data("not found".utf8)
                )

            default:
                return (
                    qwenHTTPResponse(url: url, statusCode: 404),
                    Data("404 page not found".utf8)
                )
            }
        }

        let dispatch = try await BaseAPIService(session: makeQwenMockSession()).dispatchOfficialImageGeneration(
            providerKind: .siliconFlow,
            userBaseURL: "https://api.siliconflow.com/v1",
            apiKey: "sk-test",
            modelID: "Kwai-Kolors/Kolors",
            messages: [
                ChatMessage(
                    id: UUID(),
                    role: .user,
                    text: "draw a wave",
                    providerKind: .siliconFlow,
                    providerName: "SiliconFlow",
                    modelName: "Kwai-Kolors/Kolors",
                    state: .delivered
                ),
            ],
            selectedModelSupportsImageGeneration: true
        )
        guard case let .handled(result) = dispatch else {
            Issue.record("siliconFlow images_api must be handled centrally")
            return
        }

        #expect(imageGenRequestBody?["size"] as? String == "1024x1024")
        #expect(result.text.isEmpty)
        #expect(result.attachments?.count == 1)
        #expect(result.attachments?.first?.base64Data == "https://temp.siliconflow.test/image.png")
    }
}
