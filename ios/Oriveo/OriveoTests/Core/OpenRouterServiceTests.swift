import Foundation
import GRDB
import Testing
@testable import Oriveo

final class OpenRouterMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = OpenRouterMockURLProtocol.requestHandler else {
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

private func makeOpenRouterMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [OpenRouterMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func openRouterHTTPResponse(url: URL, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
}

private func openRouterRequestBody(from request: URLRequest) -> Data? {
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

private func makeOpenRouterContinuationStore() throws -> (RecipeContinuationStore, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("oriveo-openrouter-continuation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let pool = try DatabasePool(path: directory.appendingPathComponent("sidecar.sqlite").path)
    return (try RecipeContinuationStore(dbPool: pool), directory)
}

private func loadOpenRouterContinuationMetadata() async throws {
    await MetadataClient.shared.resetForTesting()
    try await MetadataClient.shared.loadForTesting(json: """
    {
      "version": 1,
      "providers": {
        "openRouter": {
          "resolveMap": {"openai/gpt-test":"openai/gpt-test"},
          "models": {
            "openai/gpt-test": {
              "canonicalModelId":"openai/gpt-test",
              "transport":"openai_chat",
              "capabilities":["text","reasoning"],
              "capabilityControls": {
                "reasoning":{"state":"auto_available","recipeRef":"openrouter.chat.reasoning.v1"}
              }
            }
          }
        }
      },
      "capabilityRuntime": {
        "schemaVersion":2,
        "revision":"openrouter-continuation-test",
        "generatedAt":"2026-08-23T00:00:00Z",
        "recipes": {
          "openrouter.chat.reasoning.v1": {
            "id":"openrouter.chat.reasoning.v1",
            "providerKind":"openRouter",
            "transport":{"protocol":"openai_chat"},
            "capability":"reasoning",
            "executionKind":"request_overlay",
            "requestOps":[{"op":"set","intent":"deep","pointer":"/reasoning/effort","value":"high"}],
            "responseParserKind":"openrouter_reasoning_v1",
            "continuationKind":"replay_reasoning",
            "fallbackPolicy":"remove_auto_patch_once_pre_token",
            "sourceRefs":["openrouter.reasoning"]
          }
        },
        "controlDefinitions":{},
        "sourceIndex":{"openrouter.reasoning":{"kind":"official_doc","url":"https://openrouter.ai/docs/","reviewedAt":"2026-08-23"}}
      }
    }
    """)
}

private func makeOpenRouterMessage(
    _ text: String, role: ChatRole = .user, id: UUID = UUID()
) -> ChatMessage {
    ChatMessage(
        id: id, role: role, text: text,
        providerKind: .openRouter, providerName: ProviderKind.openRouter.displayName,
        modelID: "openai/gpt-test", modelName: "GPT Test", state: .delivered
    )
}

@Suite("OpenRouter Service", .serialized)
struct OpenRouterServiceTests {

    @Test("Non Streaming Continuation Round Trips Reasoning Details And Tool Calls")
    func nonStreamingContinuationRoundTripsReasoningDetailsAndToolCalls() async throws {
        try await loadOpenRouterContinuationMetadata()
        OpenRouterMockURLProtocol.requestHandler = nil
        defer { OpenRouterMockURLProtocol.requestHandler = nil }
        let (store, directory) = try makeOpenRouterContinuationStore()
        defer {
            try? store.dbPoolForTesting.close()
            try? FileManager.default.removeItem(at: directory)
        }
        var capturedBodies: [[String: Any]] = []
        OpenRouterMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let data = try #require(openRouterRequestBody(from: request))
            capturedBodies.append(try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any]
            ))
            let response = capturedBodies.count == 1
                ? #"{"choices":[{"message":{"content":"answer","reasoning_details":[{"type":"reasoning.summary","summary":"first"},{"type":"reasoning.encrypted","data":"opaque"}],"tool_calls":[{"id":"call_nonstream","type":"function","function":{"name":"lookup","arguments":"{\"q\":\"news\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":2,"completion_tokens":3}}"#
                : #"{"choices":[{"message":{"content":"continued"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#
            return (openRouterHTTPResponse(url: url, statusCode: 200), Data(response.utf8))
        }

        let assistantID = UUID()
        var producerOptions = ChatRequestOptions()
        producerOptions.localContinuationMessageID = assistantID
        let service = OpenRouterService(session: makeOpenRouterMockSession())
        _ = try await RecipeContinuationRuntime.withStore(store) {
            try await service.sendMessage(
                apiKey: "sk-openrouter-test", modelID: "openai/gpt-test",
                messages: [makeOpenRouterMessage("produce")], reasoningMode: .deep,
                requestOptions: producerOptions
            )
        }

        var explicitOptions = ChatRequestOptions()
        explicitOptions.localExplicitContinuationMessageID = assistantID
        _ = try await RecipeContinuationRuntime.withStore(store) {
            try await service.sendMessage(
                apiKey: "sk-openrouter-test", modelID: "openai/gpt-test",
                messages: [
                    makeOpenRouterMessage("produce"),
                    makeOpenRouterMessage("flattened", role: .assistant, id: assistantID),
                    makeOpenRouterMessage("continue"),
                ],
                reasoningMode: .deep, requestOptions: explicitOptions
            )
        }

        let explicitBody = try #require(capturedBodies.last)
        let messages = try #require(explicitBody["messages"] as? [[String: Any]])
        let replay = try #require(messages.first { $0["role"] as? String == "assistant" })
        let details = try #require(replay["reasoning_details"] as? [[String: Any]])
        #expect(details.map { $0["type"] as? String }
            == ["reasoning.summary", "reasoning.encrypted"])
        #expect(details[0]["summary"] as? String == "first")
        #expect(details[1]["data"] as? String == "opaque")
        let call = try #require((replay["tool_calls"] as? [[String: Any]])?.first)
        #expect(call["id"] as? String == "call_nonstream")
        #expect((call["function"] as? [String: Any])?["arguments"] as? String
            == #"{"q":"news"}"#)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Streaming Continuation Globally Orders Details And Tool Calls")
    func streamingContinuationGloballyOrdersDetailsAndToolCalls() async throws {
        try await loadOpenRouterContinuationMetadata()
        OpenRouterMockURLProtocol.requestHandler = nil
        defer { OpenRouterMockURLProtocol.requestHandler = nil }
        let (store, directory) = try makeOpenRouterContinuationStore()
        defer {
            try? store.dbPoolForTesting.close()
            try? FileManager.default.removeItem(at: directory)
        }
        var capturedBodies: [[String: Any]] = []
        OpenRouterMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let data = try #require(openRouterRequestBody(from: request))
            let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            capturedBodies.append(body)
            if body["stream"] as? Bool == true {
                return (openRouterHTTPResponse(url: url, statusCode: 200), Data("""
                data: {"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.summary","summary":"first"}]}}]}

                data: {"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.summary","summary":"second"}]}}]}

                data: {"choices":[{"delta":{"reasoning_details":[{"index":7,"type":"reasoning.encrypted","data":"opa"}],"tool_calls":[{"index":0,"id":"call_stream","type":"function","function":{"name":"look","arguments":"{\\"q\\""}}]}}]}

                data: {"choices":[{"delta":{"reasoning_details":[{"index":7,"data":"que"}],"tool_calls":[{"index":0,"function":{"name":"up","arguments":":\\"news\\"}"}}]}}]}

                data: {"choices":[{"delta":{"content":"answer"},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":2,"completion_tokens":3}}

                data: [DONE]

                """.utf8))
            }
            return (
                openRouterHTTPResponse(url: url, statusCode: 200),
                Data(#"{"choices":[{"message":{"content":"continued"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
            )
        }

        let assistantID = UUID()
        var producerOptions = ChatRequestOptions()
        producerOptions.localContinuationMessageID = assistantID
        let service = OpenRouterService(session: makeOpenRouterMockSession())
        try await RecipeContinuationRuntime.withStore(store) {
            for try await _ in service.sendMessageStream(
                apiKey: "sk-openrouter-test", modelID: "openai/gpt-test",
                messages: [makeOpenRouterMessage("produce")], reasoningMode: .deep,
                requestOptions: producerOptions
            ) {}
        }

        var explicitOptions = ChatRequestOptions()
        explicitOptions.localExplicitContinuationMessageID = assistantID
        _ = try await RecipeContinuationRuntime.withStore(store) {
            try await service.sendMessage(
                apiKey: "sk-openrouter-test", modelID: "openai/gpt-test",
                messages: [
                    makeOpenRouterMessage("produce"),
                    makeOpenRouterMessage("flattened", role: .assistant, id: assistantID),
                    makeOpenRouterMessage("continue"),
                ],
                reasoningMode: .deep, requestOptions: explicitOptions
            )
        }

        let explicitBody = try #require(capturedBodies.last)
        let messages = try #require(explicitBody["messages"] as? [[String: Any]])
        let replay = try #require(messages.first { $0["role"] as? String == "assistant" })
        let details = try #require(replay["reasoning_details"] as? [[String: Any]])
        #expect(details.count == 3)
        #expect(details[0]["summary"] as? String == "first")
        #expect(details[1]["summary"] as? String == "second")
        #expect(details[2]["index"] as? Int == 7)
        #expect(details[2]["data"] as? String == "opaque")
        let call = try #require((replay["tool_calls"] as? [[String: Any]])?.first)
        #expect(call["id"] as? String == "call_stream")
        #expect((call["function"] as? [String: Any])?["name"] as? String == "lookup")
        #expect((call["function"] as? [String: Any])?["arguments"] as? String
            == #"{"q":"news"}"#)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Streaming Continuation Rejects Conflicting Indexed Detail")
    func streamingContinuationRejectsConflictingIndexedDetail() async throws {
        try await loadOpenRouterContinuationMetadata()
        OpenRouterMockURLProtocol.requestHandler = nil
        defer { OpenRouterMockURLProtocol.requestHandler = nil }
        let (store, directory) = try makeOpenRouterContinuationStore()
        defer {
            try? store.dbPoolForTesting.close()
            try? FileManager.default.removeItem(at: directory)
        }
        OpenRouterMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            return (openRouterHTTPResponse(url: url, statusCode: 200), Data("""
            data: {"choices":[{"delta":{"reasoning_details":[{"index":0,"type":"reasoning.encrypted","data":"opaque"}]}}]}

            data: {"choices":[{"delta":{"reasoning_details":[{"index":0,"type":"reasoning.summary","summary":"conflict"}]}}]}

            data: {"choices":[{"delta":{"content":"answer"},"finish_reason":"stop"}]}

            data: [DONE]

            """.utf8))
        }

        let assistantID = UUID()
        var options = ChatRequestOptions()
        options.localContinuationMessageID = assistantID
        let service = OpenRouterService(session: makeOpenRouterMockSession())
        try await RecipeContinuationRuntime.withStore(store) {
            for try await _ in service.sendMessageStream(
                apiKey: "sk-openrouter-test", modelID: "openai/gpt-test",
                messages: [makeOpenRouterMessage("produce")], reasoningMode: .deep,
                requestOptions: options
            ) {}
        }
        #expect(try store.load(messageID: assistantID) == nil)
        await MetadataClient.shared.resetForTesting()
    }


    @Test("Send Message Applies Safe Max Tokens For Mini Max M25 Free")
    func sendMessageAppliesSafeMaxTokensForMiniMaxM25Free() async throws {
        await MetadataClient.shared.resetForTesting()
        OpenRouterMockURLProtocol.requestHandler = nil
        defer {
            OpenRouterMockURLProtocol.requestHandler = nil
        }

        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-07-04T00:00:00Z",
          "providers": {
            "openRouter": {
              "transport": { "baseUrl": "https://openrouter.ai/api/v1", "endpoints": { "chat": "/chat/completions" } },
              "resolveMap": { "minimax/minimax-m2.5:free": "minimax/minimax-m2.5:free" },
              "models": {
                "minimax/minimax-m2.5:free": {
                  "canonicalModelId": "minimax/minimax-m2.5:free",
                  "maxOutputTokens": 4096,
                  "capabilities": ["text"],
                  "transport": "openai_chat",
                  "profiles": {}
                }
              }
            }
          }
        }
        """)

        OpenRouterMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            guard url.host == "openrouter.ai", url.path == "/api/v1/chat/completions" else {
                throw NSError(domain: "OpenRouterServiceTests", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "unexpected request url: \(url.absoluteString)",
                ])
            }

            let body = try #require(openRouterRequestBody(from: request))
            let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            guard payload["model"] as? String == "minimax/minimax-m2.5:free" else {
                throw NSError(domain: "OpenRouterServiceTests", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "unexpected model payload: \(payload)",
                ])
            }
            let maxTokens = (payload["max_tokens"] as? NSNumber)?.intValue
            guard maxTokens == 4096 else {
                throw NSError(domain: "OpenRouterServiceTests", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "unexpected max_tokens payload: \(String(describing: payload["max_tokens"]))",
                ])
            }

            return (
                openRouterHTTPResponse(url: url, statusCode: 200),
                Data(#"{"choices":[{"message":{"role":"assistant","content":"hi"}}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}"#.utf8)
            )
        }

        let service = OpenRouterService(session: makeOpenRouterMockSession())
        let result = try await service.sendMessage(
            apiKey: "sk-openrouter-live",
            modelID: "minimax/minimax-m2.5:free",
            messages: [
                ChatMessage(
                    id: UUID(),
                    role: .user,
                    text: "hello",
                    providerKind: .openRouter,
                    providerName: ProviderKind.openRouter.displayName,
                    modelID: "minimax/minimax-m2.5:free",
                    modelName: "MiniMax M2.5 free",
                    state: .delivered
                ),
            ]
        )

        #expect(result.text == "hi")
        #expect(result.promptTokens == 4)
        #expect(result.completionTokens == 2)
    }

    @Test("Send Message Accepts Image Only Response Without Content")
    func sendMessageAcceptsImageOnlyResponseWithoutContent() async throws {
        await MetadataClient.shared.resetForTesting()
        OpenRouterMockURLProtocol.requestHandler = nil
        defer {
            OpenRouterMockURLProtocol.requestHandler = nil
        }

        OpenRouterMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            guard url.host == "openrouter.ai", url.path == "/api/v1/chat/completions" else {
                throw NSError(domain: "OpenRouterServiceTests", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "unexpected request url: \(url.absoluteString)",
                ])
            }

            return (
                openRouterHTTPResponse(url: url, statusCode: 200),
                Data(#"{"choices":[{"message":{"role":"assistant","images":[{"image_url":{"url":"data:image/png;base64,YWJj"}}]}}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}"#.utf8)
            )
        }

        let service = OpenRouterService(session: makeOpenRouterMockSession())
        let result = try await service.sendMessage(
            apiKey: "sk-openrouter-live",
            modelID: "openai/gpt-5.4-image-2",
            messages: [
                ChatMessage(
                    id: UUID(),
                    role: .user,
                    text: "draw",
                    providerKind: .openRouter,
                    providerName: ProviderKind.openRouter.displayName,
                    modelID: "openai/gpt-5.4-image-2",
                    modelName: "OpenAI: GPT-5.4 Image 2",
                    state: .delivered
                ),
            ],
            supportsImageGen: true
        )

        #expect(result.text.isEmpty)
        #expect(result.attachments?.count == 1)
        #expect(result.attachments?.first?.kind == .image)
        #expect(result.promptTokens == 4)
        #expect(result.completionTokens == 2)
    }

    @Test("Send Message Uses Profile Modalities For Image Models")
    func sendMessageUsesProfileModalitiesForImageModels() async throws {
        await MetadataClient.shared.resetForTesting()
        OpenRouterMockURLProtocol.requestHandler = nil
        defer {
            OpenRouterMockURLProtocol.requestHandler = nil
        }

        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-07-04T00:00:00Z",
          "profiles": {
            "imageGen": {
              "or_chat": {
                "route": "chat_api",
                "streaming": true,
                "supportsContext": true,
                "mergeParams": { "modalities": ["text", "image"] }
              }
            }
          },
          "providers": {
            "openRouter": {
              "transport": { "baseUrl": "https://openrouter.ai/api/v1", "endpoints": { "chat": "/chat/completions" } },
              "resolveMap": { "openai/gpt-5.4-image-2": "openai/gpt-5.4-image-2" },
              "models": {
                "openai/gpt-5.4-image-2": {
                  "canonicalModelId": "openai/gpt-5.4-image-2",
                  "capabilities": ["text", "imageGeneration"],
                  "transport": "openai_chat",
                  "profiles": { "imageGen": "or_chat" }
                }
              }
            }
          }
        }
        """)

        OpenRouterMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            guard url.host == "openrouter.ai", url.path == "/api/v1/chat/completions" else {
                throw NSError(domain: "OpenRouterServiceTests", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "unexpected request url: \(url.absoluteString)",
                ])
            }

            let body = try #require(openRouterRequestBody(from: request))
            let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let modalities = try #require(payload["modalities"] as? [String])
            #expect(modalities == ["text", "image"])
            #expect(payload["max_tokens"] == nil)

            return (
                openRouterHTTPResponse(url: url, statusCode: 200),
                Data(#"{"choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}"#.utf8)
            )
        }

        let service = OpenRouterService(session: makeOpenRouterMockSession())
        let result = try await service.sendMessage(
            apiKey: "sk-openrouter-live",
            modelID: "openai/gpt-5.4-image-2",
            messages: [
                ChatMessage(
                    id: UUID(),
                    role: .user,
                    text: "draw",
                    providerKind: .openRouter,
                    providerName: ProviderKind.openRouter.displayName,
                    modelID: "openai/gpt-5.4-image-2",
                    modelName: "OpenAI: GPT-5.4 Image 2",
                    state: .delivered
                ),
            ],
            supportsImageGen: true
        )

        #expect(result.text == "ok")
    }

    @Test("Send Message Uses Open Router Server Web Search Tool")
    func sendMessageUsesOpenRouterServerWebSearchTool() async throws {
        await MetadataClient.shared.resetForTesting()
        OpenRouterMockURLProtocol.requestHandler = nil
        defer {
            OpenRouterMockURLProtocol.requestHandler = nil
        }

        let runtime = try CapabilityRuntimeFixtures.runtimeEnvelopeJSON()
        let controls = try CapabilityRuntimeFixtures.controlsJSON(
            .init(capability: "web", recipeRef: "openrouter.chat.web.v1")
        )
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-05-12T00:00:00Z",
          "capabilityRuntime": \(runtime),
          "profiles": {
            "webSearch": {
              "or_web": {
                "streamShape": {
                  "citationsArrayPath": "choices.0.delta.annotations",
                  "citationUrlField": "url_citation.url",
                  "citationTitleField": "url_citation.title",
                  "citationSnippetField": "url_citation.content"
                }
              }
            }
          },
          "providers": {
            "openRouter": {
              "defaultModelId": "anthropic/claude-sonnet-4",
              "resolveMap": {
                "anthropic/claude-sonnet-4": "anthropic/claude-sonnet-4"
              },
              "models": {
                "anthropic/claude-sonnet-4": {
                  "canonicalModelId": "anthropic/claude-sonnet-4",
                  "displayName": "Claude Sonnet 4",
                  "capabilities": ["text", "web"],
                  "transport": "openai_chat",
                  "profiles": {"webSearch": "or_web"},
                  "capabilityControls": \(controls),
                  "capabilityEvidenceView": {
                    "schema": "capability-evidence-view/v1",
                    "candidates": [{
                      "key": "web_search", "support": "supported",
                      "source": "server_profile", "grade": "effect_verified",
                      "scope": "provider_model_transport", "providerKind": "openRouter",
                      "modelId": "anthropic/claude-sonnet-4", "transport": "openai_chat"
                    }]
                  }
                }
              }
            }
          }
        }
        """, metadataETag: "openrouter-web-v1")

        let expectedTool = try #require(
            try CapabilityRuntimeFixtures.recipeValue(
                recipeRef: "openrouter.chat.web.v1", pointer: "/tools/-"
            ) as? [String: Any]
        )
        OpenRouterMockURLProtocol.requestHandler = { request in
            let body = try #require(openRouterRequestBody(from: request))
            let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let tools = try #require(payload["tools"] as? [[String: Any]])
            #expect(tools.count == 1)
            #expect(tools.first?["type"] as? String == expectedTool["type"] as? String)
            #expect(payload["plugins"] == nil)
            #expect(payload["web_search_options"] == nil)

            let url = try #require(request.url)
            return (
                openRouterHTTPResponse(url: url, statusCode: 200),
                Data(#"{"choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}"#.utf8)
            )
        }

        let service = OpenRouterService(session: makeOpenRouterMockSession())
        let model = MetadataClient.shared.syncCurrentCapabilityEvidenceModel(
            TestFactories.makeModel(id: "anthropic/claude-sonnet-4"), providerKind: .openRouter
        )
        let provider = TestFactories.makeProvider(kind: .openRouter, models: [model])
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: "openrouter-web-user",
            hasExplicitValue: true, metadataETag: "openrouter-web-v1"
        )
        var options = ChatRequestOptions()
        options.capabilityEvidenceModel = model
        let result = try await CapabilityEvidenceRequestContext.$current.withValue(identity) {
            try await service.sendMessage(
                apiKey: "sk-openrouter-live", modelID: "anthropic/claude-sonnet-4",
                messages: [ChatMessage(
                    id: UUID(), role: .user, text: "search", providerKind: .openRouter,
                    providerName: ProviderKind.openRouter.displayName,
                    modelID: "anthropic/claude-sonnet-4", modelName: "Claude Sonnet 4",
                    state: .delivered
                )],
                webSearchEnabled: true, requestOptions: options
            )
        }

        #expect(result.text == "ok")
    }

    @Test("Send Message Retries Once For Short Rate Limit Window")
    func sendMessageRetriesOnceForShortRateLimitWindow() async throws {
        await MetadataClient.shared.resetForTesting()
        OpenRouterMockURLProtocol.requestHandler = nil
        defer {
            OpenRouterMockURLProtocol.requestHandler = nil
        }

        var requestCount = 0
        OpenRouterMockURLProtocol.requestHandler = { request in
            requestCount += 1
            let url = try #require(request.url)
            guard url.host == "openrouter.ai", url.path == "/api/v1/chat/completions" else {
                throw NSError(domain: "OpenRouterServiceTests", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "unexpected request url: \(url.absoluteString)",
                ])
            }

            if requestCount == 1 {
                return (
                    openRouterHTTPResponse(url: url, statusCode: 200),
                    Data(
                        """
                        {
                          "error": {
                            "message": "Rate limit reached for gpt-5.4-2026-03-05 (for limit gpt-5.4) in organization org-test on tokens per min (TPM): Limit 40000000, Used 40000000, Requested 2980. Please try again in 4ms.",
                            "code": 429
                          }
                        }
                        """.utf8
                    )
                )
            }

            return (
                openRouterHTTPResponse(url: url, statusCode: 200),
                Data(#"{"choices":[{"message":{"role":"assistant","content":"ok after retry"}}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}"#.utf8)
            )
        }

        let service = OpenRouterService(session: makeOpenRouterMockSession())
        let result = try await service.sendMessage(
            apiKey: "sk-openrouter-live",
            modelID: "openai/gpt-5.4-image-2",
            messages: [
                ChatMessage(
                    id: UUID(),
                    role: .user,
                    text: "draw",
                    providerKind: .openRouter,
                    providerName: ProviderKind.openRouter.displayName,
                    modelID: "openai/gpt-5.4-image-2",
                    modelName: "OpenAI: GPT-5.4 Image 2",
                    state: .delivered
                ),
            ],
            supportsImageGen: true
        )

        #expect(requestCount == 2)
        #expect(result.text == "ok after retry")
    }

    @Test("Send Message Maps200 Error Envelope To Rate Limited")
    func sendMessageMaps200ErrorEnvelopeToRateLimited() async throws {
        await MetadataClient.shared.resetForTesting()
        OpenRouterMockURLProtocol.requestHandler = nil
        defer {
            OpenRouterMockURLProtocol.requestHandler = nil
        }

        let rateLimitMessage = "Request too large for gpt-5.4-2026-03-05 (for limit gpt-5.4)"

        OpenRouterMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            guard url.host == "openrouter.ai", url.path == "/api/v1/chat/completions" else {
                throw NSError(domain: "OpenRouterServiceTests", code: 7, userInfo: [
                    NSLocalizedDescriptionKey: "unexpected request url: \(url.absoluteString)",
                ])
            }

            return (
                openRouterHTTPResponse(url: url, statusCode: 200),
                Data(
                    """
                    {
                      "error": {
                        "message": "\(rateLimitMessage)",
                        "code": 429
                      }
                    }
                    """.utf8
                )
            )
        }

        let service = OpenRouterService(session: makeOpenRouterMockSession())
        let error = await #expect(throws: ProviderServiceError.self) {
            _ = try await service.sendMessage(
                apiKey: "sk-openrouter-live",
                modelID: "openai/gpt-5.4-image-2",
                messages: [
                    ChatMessage(
                        id: UUID(),
                        role: .user,
                        text: "draw",
                        providerKind: .openRouter,
                        providerName: ProviderKind.openRouter.displayName,
                        modelID: "openai/gpt-5.4-image-2",
                        modelName: "OpenAI: GPT-5.4 Image 2",
                        state: .delivered
                    ),
                ],
                supportsImageGen: true
            )
        }

        guard case let .rateLimited(detail) = error else {
            Issue.record("Expected rateLimited, got \(error)")
            return
        }
        #expect(detail == rateLimitMessage)
    }

    @Test("Send Message Stream Defers Citations Until Stream End")
    func sendMessageStreamDefersCitationsUntilStreamEnd() async throws {
        await MetadataClient.shared.resetForTesting()
        OpenRouterMockURLProtocol.requestHandler = nil
        defer {
            OpenRouterMockURLProtocol.requestHandler = nil
        }

        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-05-12T00:00:00Z",
          "profiles": {
            "webSearch": {
              "or_web": {
                "mergeParams": {
                  "plugins": [{"id": "web", "max_results": 5}]
                },
                "streamShape": {
                  "citationsArrayPath": "choices.0.delta.annotations",
                  "citationUrlField": "url_citation.url",
                  "citationTitleField": "url_citation.title",
                  "citationSnippetField": "url_citation.content"
                }
              }
            }
          },
          "providers": {
            "openRouter": {
              "defaultModelId": "moonshotai/kimi-k2.6",
              "resolveMap": {
                "moonshotai/kimi-k2.6": "moonshotai/kimi-k2.6"
              },
              "models": {
                "moonshotai/kimi-k2.6": {
                  "canonicalModelId": "moonshotai/kimi-k2.6",
                  "displayName": "Kimi K2.6",
                  "capabilities": ["text", "web"],
                  "profiles": {"webSearch": "or_web"}
                }
              }
            }
          }
        }
        """)

        OpenRouterMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let sse = """
            data: {"choices":[{"delta":{"role":"assistant","content":"","annotations":[{"type":"url_citation","url_citation":{"url":"https://a.example/1","title":"A","content":"snippet-a"}}]}}]}

            data: {"choices":[{"delta":{"content":"","annotations":[{"type":"url_citation","url_citation":{"url":"https://b.example/2","title":"B","content":"snippet-b"}}]}}]}

            data: {"choices":[{"delta":{"reasoning":"thinking..."}}]}

            data: {"choices":[{"delta":{"content":"hello"}}]}

            data: {"choices":[{"delta":{"content":" world"}}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}

            data: [DONE]

            """
            return (openRouterHTTPResponse(url: url, statusCode: 200), Data(sse.utf8))
        }

        let service = OpenRouterService(session: makeOpenRouterMockSession())
        var events: [StreamEvent] = []
        for try await event in service.sendMessageStream(
            apiKey: "sk-openrouter-live",
            modelID: "moonshotai/kimi-k2.6",
            messages: [
                ChatMessage(
                    id: UUID(),
                    role: .user,
                    text: "search",
                    providerKind: .openRouter,
                    providerName: ProviderKind.openRouter.displayName,
                    modelID: "moonshotai/kimi-k2.6",
                    modelName: "Kimi K2.6",
                    state: .delivered
                ),
            ],
            webSearchEnabled: true
        ) {
            events.append(event)
        }

        let citationIndexes = events.indices.filter {
            if case .citations = events[$0] { return true } else { return false }
        }
        let lastDeltaIndex = events.indices.last {
            if case .delta = events[$0] { return true } else { return false }
        }
        let lastReasoningIndex = events.indices.last {
            if case .reasoning = events[$0] { return true } else { return false }
        }

        #expect(citationIndexes.count == 1)
        let citationIndex = try #require(citationIndexes.first)
        #expect(citationIndex > (try #require(lastDeltaIndex)))
        #expect(citationIndex > (try #require(lastReasoningIndex)))

        guard case let .citations(citations) = events[citationIndex] else {
            Issue.record("Expected citations event at index \(citationIndex)")
            return
        }
        #expect(citations.map(\.url) == ["https://a.example/1", "https://b.example/2"])

        guard case let .done(result) = events.last else {
            Issue.record("Expected done as last event, got \(String(describing: events.last))")
            return
        }
        #expect(result.text == "hello world")
    }
}
