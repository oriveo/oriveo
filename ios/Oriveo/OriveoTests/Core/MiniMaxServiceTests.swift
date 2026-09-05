import Foundation
import GRDB
import OriveoProviderKit
import Testing
@testable import Oriveo

final class MiniMaxMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MiniMaxMockURLProtocol.requestHandler else {
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

private func makeMiniMaxMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MiniMaxMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func miniMaxHTTPResponse(url: URL, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
}

private func miniMaxRequestBody(from request: URLRequest) -> Data? {
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

private func makeMiniMaxUserMessage(_ text: String = "hello") -> ChatMessage {
    ChatMessage(
        id: UUID(), role: .user, text: text,
        providerKind: .miniMax, providerName: "MiniMax",
        modelName: "MiniMax-M2.7", state: .delivered
    )
}

private func makeMiniMaxContinuationStore() throws -> (RecipeContinuationStore, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("oriveo-minimax-continuation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let pool = try DatabasePool(path: directory.appendingPathComponent("sidecar.sqlite").path)
    return (try RecipeContinuationStore(dbPool: pool), directory)
}

private func loadMiniMaxContinuationMetadata() async throws {
    await MetadataClient.shared.resetForTesting()
    try await MetadataClient.shared.loadForTesting(json: """
    {
      "version": 1,
      "providers": {
        "miniMax": {
          "resolveMap": {"MiniMax-M2.7":"MiniMax-M2.7"},
          "models": {
            "MiniMax-M2.7": {
              "canonicalModelId":"MiniMax-M2.7",
              "transport":"openai_chat",
              "capabilities":["text","reasoning"],
              "capabilityControls": {
                "reasoning":{"state":"auto_available","recipeRef":"minimax.chat.reasoning.v1"}
              }
            }
          }
        }
      },
      "capabilityRuntime": {
        "schemaVersion":2,
        "revision":"minimax-continuation-test",
        "generatedAt":"2026-08-23T00:00:00Z",
        "recipes": {
          "minimax.chat.reasoning.v1": {
            "id":"minimax.chat.reasoning.v1",
            "providerKind":"miniMax",
            "transport":{"protocol":"openai_chat"},
            "capability":"reasoning",
            "executionKind":"request_overlay",
            "requestOps":[{"op":"set","intent":"deep","pointer":"/reasoning_split","value":true}],
            "responseParserKind":"minimax_reasoning_v1",
            "continuationKind":"replay_reasoning",
            "fallbackPolicy":"remove_auto_patch_once_pre_token",
            "sourceRefs":["minimax.reasoning"]
          }
        },
        "controlDefinitions":{},
        "sourceIndex":{"minimax.reasoning":{"kind":"official_doc","url":"https://platform.minimax.io/","reviewedAt":"2026-08-23"}}
      }
    }
    """)
}

private func loadMiniMaxWebMetadata() async throws {
    await MetadataClient.shared.resetForTesting()
    try await MetadataClient.shared.loadForTesting(json: """
    {
      "version":1,
      "providers":{"miniMax":{"resolveMap":{"MiniMax-M3":"MiniMax-M3","MiniMax-M2":"MiniMax-M2"},"models":{
        "MiniMax-M3":{"canonicalModelId":"MiniMax-M3","transport":"openai_chat","pricing":{"promptPerMToken":1,"completionPerMToken":2},"capabilityControls":{"web":{"state":"auto_available","recipeRef":"minimax.messages.web.v1"}}},
        "MiniMax-M2":{"canonicalModelId":"MiniMax-M2","transport":"openai_chat","capabilities":["text","reasoning"]}
      }}},
      "capabilityRuntime":{"schemaVersion":2,"revision":"minimax-web-test","generatedAt":"2026-08-23T00:00:00Z","recipes":{
        "minimax.messages.web.v1":{"id":"minimax.messages.web.v1","providerKind":"miniMax","transport":{"protocol":"openai_chat"},"capability":"web","executionKind":"endpoint_route","requestOps":[{"op":"append","pointer":"/tools/-","value":{"type":"web_search_20250305","name":"web_search"}}],"route":{"sourceProtocol":"openai_chat","protocol":"anthropic_messages","endpointClass":"messages","path":"/anthropic/v1/messages","method":"POST","authMode":"x_api_key","authHeader":"x-api-key","headers":{"Content-Type":"application/json","anthropic-version":"2023-06-01"},"requestMapper":"minimax_anthropic_messages_v1"},"responseParserKind":"minimax_anthropic_web_v1","continuationKind":"replay_blocks","fallbackPolicy":"remove_auto_patch_once_pre_token","sourceRefs":["minimax.server_tools"]}
      },"controlDefinitions":{},"sourceIndex":{"minimax.server_tools":{"kind":"official_doc","url":"https://platform.minimax.io/","reviewedAt":"2026-08-23"}}}
    }
    """)
}

private func miniMaxWebOptions(messageID: UUID? = nil, explicitID: UUID? = nil) -> ChatRequestOptions {
    var options = ChatRequestOptions()
    options.capabilityPreferences = CapabilityPreferenceValues(web: .automatic)
    options.localContinuationMessageID = messageID
    options.localExplicitContinuationMessageID = explicitID
    return options
}

private func miniMaxJSON(_ value: Any) -> Data? {
    let envelope = ["value": value]
    guard JSONSerialization.isValidJSONObject(envelope) else { return nil }
    return try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
}

@Suite("MiniMax Service", .serialized)
struct MiniMaxServiceTests {

    @Test("Thinking Tag Parser Extracts Mini Max Reasoning")
    func thinkingTagParserExtractsMiniMaxReasoning() {
        var parser = ThinkingTagParser()
        #expect(parser.parse("A<think>r</think>B") == [
            .text("A"),
            .reasoning("r"),
            .text("B")
        ])

        parser = ThinkingTagParser()
        #expect(parser.parse("<think>a</think>x<think>b</think>y") == [
            .reasoning("a"),
            .text("x"),
            .reasoning("b"),
            .text("y")
        ])

        parser = ThinkingTagParser()
        #expect(parser.parse("<th").isEmpty)
        #expect(parser.parse("ink>a</thi") == [.reasoning("a")])
        #expect(parser.parse("nk>b") == [.text("b")])

        parser = ThinkingTagParser()
        #expect(parser.parse("A<think>unfinished") == [
            .text("A"),
            .reasoning("unfinished")
        ])
        #expect(parser.parse("", final: true).isEmpty)
    }

    @Test("Thinking Tag Parser Keeps Code Fence Literals")
    func thinkingTagParserKeepsCodeFenceLiterals() {
        var parser = ThinkingTagParser()
        let content = "```xml\n<think>literal</think>\n```\nOK"
        #expect(parser.parse(content) == [.text(content)])
    }

    @Test("Sync Provider Uses Metadata Only Catalog")
    func syncProviderUsesMetadataOnlyCatalog() async throws {
        await MetadataClient.shared.resetForTesting()
        MiniMaxMockURLProtocol.requestHandler = nil
        defer { MiniMaxMockURLProtocol.requestHandler = nil }

        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-04-08T00:00:00Z",
          "providers": {
            "miniMax": {
              "displayName": "MiniMax",
              "defaultModelId": "MiniMax-M2.5",
              "validation": {
                "modelId": "MiniMax-M2.5",
                "transport": "openai_chat_completions",
                "authMode": "bearer",
                "headerProfile": "none",
                "maxTokens": 24
              },
              "resolveMap": {
                "MiniMax-M2.5": "MiniMax-M2.5",
                "MiniMax-M2.7": "MiniMax-M2.7",
                "image-01": "image-01"
              },
              "models": {
                "MiniMax-M2.5": {
                  "canonicalModelId": "MiniMax-M2.5",
                  "displayName": "MiniMax-M2.5",
                  "contextLength": 1000000,
                  "pricing": {
                    "promptPerMToken": 1.1,
                    "completionPerMToken": 8.0
                  },
                  "capabilities": ["text", "reasoning"],
                  "profiles": {
                    "reasoning": "mm_chat"
                  },
                  "uiHints": {
                    "groupKey": "m2.5",
                    "groupName": "MiniMax-M2.5",
                    "rank": 120,
                    "recommended": true
                  }
                },
                "MiniMax-M2.7": {
                  "canonicalModelId": "MiniMax-M2.7",
                  "displayName": "MiniMax-M2.7",
                  "contextLength": 1000000,
                  "pricing": {
                    "promptPerMToken": 1.8,
                    "completionPerMToken": 12.0
                  },
                  "capabilities": ["text", "reasoning"],
                  "profiles": {
                    "reasoning": "mm_chat"
                  },
                  "uiHints": {
                    "groupKey": "m2.7",
                    "groupName": "MiniMax-M2.7",
                    "rank": 130,
                    "recommended": true
                  }
                },
                "image-01": {
                  "canonicalModelId": "image-01",
                  "displayName": "MiniMax Image",
                  "capabilities": ["imageGeneration"],
                  "profiles": {
                    "reasoning": null,
                    "webSearch": null,
                    "imageGen": "mm_images"
                  },
                  "uiHints": {
                    "groupKey": "minimax-image",
                    "groupName": "MiniMax Image",
                    "rank": 60
                  }
                }
              }
            }
          }
        }
        """)

        var requestedPaths: [String] = []
        MiniMaxMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedPaths.append(url.path)
            return (
                miniMaxHTTPResponse(url: url, statusCode: 404),
                Data("404 page not found".utf8)
            )
        }

        let service = MiniMaxService(session: makeMiniMaxMockSession())
        let result = try await service.syncProvider(
            apiKey: "sk-api-test",
            preferredModelID: nil,
            baseURL: "https://api.minimax.io/v1"
        )

        #expect(requestedPaths.isEmpty)
        #expect(result.models.isEmpty)
    }


    @Test("Send Message Suppresses Mini Max Reasoning Block")
    func sendMessageSuppressesMiniMaxReasoningBlock() async throws {
        await MetadataClient.shared.resetForTesting()
        MiniMaxMockURLProtocol.requestHandler = nil
        defer { MiniMaxMockURLProtocol.requestHandler = nil }

        var capturedBody: [String: Any] = [:]
        MiniMaxMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let bodyData = try #require(miniMaxRequestBody(from: request))
            capturedBody = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            let response = """
            {
              "choices": [
                { "message": { "content": "<think>hidden reasoning</think>Final answer" } }
              ],
              "usage": { "prompt_tokens": 3, "completion_tokens": 5 }
            }
            """
            return (
                miniMaxHTTPResponse(url: url, statusCode: 200),
                Data(response.utf8)
            )
        }

        let service = MiniMaxService(session: makeMiniMaxMockSession())
        let result = try await service.sendMessage(
            apiKey: "sk-api-test",
            modelID: "MiniMax-M2.7",
            messages: [
                ChatMessage(
                    id: UUID(),
                    role: .user,
                    text: "hello",
                    providerKind: .miniMax,
                    providerName: "MiniMax",
                    modelName: "MiniMax-M2.7",
                    state: .delivered
                )
            ],
            baseURL: "https://api.minimax.io/v1"
        )

        #expect(capturedBody["reasoning_split"] as? Bool == true)
        #expect(result.text == "Final answer",
                Comment(rawValue: "visible body must strip <think> cleanly (mixing in reasoning is the 5c2bbec6-era overlay root cause)"))
        #expect(result.reasoningText == "hidden reasoning",
                Comment(rawValue: "reasoning must surface as thinking (all three clients), not be dropped"))
    }

    @Test("Send Message Stream Suppresses Mini Max Reasoning Block")
    func sendMessageStreamSuppressesMiniMaxReasoningBlock() async throws {
        await MetadataClient.shared.resetForTesting()
        MiniMaxMockURLProtocol.requestHandler = nil
        defer { MiniMaxMockURLProtocol.requestHandler = nil }

        var capturedBody: [String: Any] = [:]
        MiniMaxMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let bodyData = try #require(miniMaxRequestBody(from: request))
            capturedBody = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            let response = """
            data: {"choices":[{"delta":{"content":"<think>hidden"}}]}
            data: {"choices":[{"delta":{"content":" reasoning</think>Final"}}]}
            data: {"choices":[{"delta":{"content":" answer"}}],"usage":{"prompt_tokens":3,"completion_tokens":5}}
            data: [DONE]

            """
            return (
                miniMaxHTTPResponse(url: url, statusCode: 200),
                Data(response.utf8)
            )
        }

        let service = MiniMaxService(session: makeMiniMaxMockSession())
        var visibleText = ""
        var exposedReasoning = ""
        var finalResult: ProviderChatResult?

        for try await event in service.sendMessageStream(
            apiKey: "sk-api-test",
            modelID: "MiniMax-M2.7",
            messages: [
                ChatMessage(
                    id: UUID(),
                    role: .user,
                    text: "hello",
                    providerKind: .miniMax,
                    providerName: "MiniMax",
                    modelName: "MiniMax-M2.7",
                    state: .delivered
                )
            ],
            baseURL: "https://api.minimax.io/v1"
        ) {
            switch event {
            case let .delta(text):
                visibleText += text
            case let .reasoning(text):
                exposedReasoning += text
            case let .done(result):
                finalResult = result
            case .imagePart, .citations, .toolCallDeltas:
                break
            }
        }

        #expect(capturedBody["reasoning_split"] as? Bool == true)
        #expect(visibleText == "Final answer",
                Comment(rawValue: "streaming body must strip <think> that spans chunks"))
        #expect(exposedReasoning == "hidden reasoning",
                Comment(rawValue: "streaming reasoning must be exposed incrementally to the thinking block (all three clients), not dropped"))
        #expect(try #require(finalResult).reasoningText == "hidden reasoning")
    }

    @Test("Non Streaming Split Reasoning Round Trips Exact Assistant Frame")
    func nonStreamingSplitReasoningRoundTripsExactAssistantFrame() async throws {
        try await loadMiniMaxContinuationMetadata()
        defer { MiniMaxMockURLProtocol.requestHandler = nil }
        let (store, directory) = try makeMiniMaxContinuationStore()
        defer {
            try? store.dbPoolForTesting.close()
            try? FileManager.default.removeItem(at: directory)
        }

        var capturedBodies: [[String: Any]] = []
        MiniMaxMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let bodyData = try #require(miniMaxRequestBody(from: request))
            let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            capturedBodies.append(body)
            let response = capturedBodies.count == 1
                ? #"{"choices":[{"message":{"role":"assistant","content":null,"reasoning_details":[{"index":0,"type":"reasoning.encrypted","data":"opaque"}],"tool_calls":[{"id":"call_1","type":"function","function":{"name":"lookup","arguments":"{\"q\":\"news\"}"}}]}}],"usage":{"prompt_tokens":2,"completion_tokens":3}}"#
                : #"{"choices":[{"message":{"role":"assistant","content":"continued"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#
            return (miniMaxHTTPResponse(url: url, statusCode: 200), Data(response.utf8))
        }

        let assistantID = UUID()
        var producerOptions = ChatRequestOptions()
        producerOptions.localContinuationMessageID = assistantID
        let service = MiniMaxService(session: makeMiniMaxMockSession())
        let first = try await RecipeContinuationRuntime.withStore(store) {
            try await service.sendMessage(
                apiKey: "minimax-test-key", modelID: "MiniMax-M2.7",
                messages: [makeMiniMaxUserMessage("produce")],
                baseURL: "https://api.minimax.io/v1", reasoningMode: .deep,
                requestOptions: producerOptions
            )
        }
        #expect(first.text.isEmpty)
        #expect(first.toolCalls?.count == 1)

        var explicitOptions = ChatRequestOptions()
        explicitOptions.localExplicitContinuationMessageID = assistantID
        let partial = ChatMessage(
            id: assistantID, role: .assistant, text: "flattened partial",
            providerKind: .miniMax, providerName: "MiniMax",
            modelName: "MiniMax-M2.7", state: .delivered
        )
        _ = try await RecipeContinuationRuntime.withStore(store) {
            try await service.sendMessage(
                apiKey: "minimax-test-key", modelID: "MiniMax-M2.7",
                messages: [makeMiniMaxUserMessage("produce"), partial, makeMiniMaxUserMessage("continue")],
                baseURL: "https://api.minimax.io/v1", reasoningMode: .deep,
                requestOptions: explicitOptions
            )
        }

        #expect(capturedBodies.allSatisfy { $0["reasoning_split"] as? Bool == true })
        let messages = try #require(capturedBodies.last?["messages"] as? [[String: Any]])
        let replay = try #require(messages.first { $0["role"] as? String == "assistant" })
        #expect(replay["content"] is NSNull)
        #expect(replay["reasoning_content"] == nil)
        #expect(miniMaxJSON(replay["reasoning_details"] as Any) == miniMaxJSON([
            ["index": 0, "type": "reasoning.encrypted", "data": "opaque"],
        ]))
        #expect((replay["tool_calls"] as? [[String: Any]])?.first?["id"] as? String == "call_1")
        #expect(messages.contains { $0["content"] as? String == "flattened partial" } == false)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Streaming Split Reasoning Round Trips Through Production Parser")
    func streamingSplitReasoningRoundTripsThroughProductionParser() async throws {
        try await loadMiniMaxContinuationMetadata()
        defer { MiniMaxMockURLProtocol.requestHandler = nil }
        let (store, directory) = try makeMiniMaxContinuationStore()
        defer {
            try? store.dbPoolForTesting.close()
            try? FileManager.default.removeItem(at: directory)
        }

        var capturedBodies: [[String: Any]] = []
        MiniMaxMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let bodyData = try #require(miniMaxRequestBody(from: request))
            let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            capturedBodies.append(body)
            if body["stream"] as? Bool == true {
                return (miniMaxHTTPResponse(url: url, statusCode: 200), Data("""
                data: {"choices":[{"delta":{"role":"assistant","content":""}}]}
                data: {"choices":[{"delta":{"reasoning_details":[{"index":0,"type":"reasoning.text","text":"think-"}]}}]}
                data: {"choices":[{"delta":{"reasoning_details":[{"index":0,"type":"reasoning.text","text":"trace"}],"content":"answer"}}]}
                data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_stream","type":"function","function":{"name":"lookup","arguments":"{\\"q\\":\\""}}]}}]}
                data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"news\\"}"}}]}}]}
                data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":2,"completion_tokens":3}}
                data: [DONE]

                """.utf8))
            }
            return (miniMaxHTTPResponse(url: url, statusCode: 200), Data(
                #"{"choices":[{"message":{"role":"assistant","content":"continued"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8
            ))
        }

        let assistantID = UUID()
        var producerOptions = ChatRequestOptions()
        producerOptions.localContinuationMessageID = assistantID
        let service = MiniMaxService(session: makeMiniMaxMockSession())
        var reasoning = ""
        try await RecipeContinuationRuntime.withStore(store) {
            for try await event in service.sendMessageStream(
                apiKey: "minimax-test-key", modelID: "MiniMax-M2.7",
                messages: [makeMiniMaxUserMessage("produce")],
                baseURL: "https://api.minimax.io/v1", reasoningMode: .deep,
                requestOptions: producerOptions
            ) {
                if case let .reasoning(text) = event { reasoning += text }
            }
        }
        #expect(reasoning == "think-trace")

        var explicitOptions = ChatRequestOptions()
        explicitOptions.localExplicitContinuationMessageID = assistantID
        _ = try await RecipeContinuationRuntime.withStore(store) {
            try await service.sendMessage(
                apiKey: "minimax-test-key", modelID: "MiniMax-M2.7",
                messages: [makeMiniMaxUserMessage("produce"), makeMiniMaxUserMessage("continue")],
                baseURL: "https://api.minimax.io/v1", reasoningMode: .deep,
                requestOptions: explicitOptions
            )
        }

        let messages = try #require(capturedBodies.last?["messages"] as? [[String: Any]])
        let replay = try #require(messages.first { $0["role"] as? String == "assistant" })
        #expect(replay["content"] as? String == "answer")
        #expect(miniMaxJSON(replay["reasoning_details"] as Any) == miniMaxJSON([
            ["index": 0, "type": "reasoning.text", "text": "think-trace"],
        ]))
        let call = try #require((replay["tool_calls"] as? [[String: Any]])?.first)
        #expect(call["id"] as? String == "call_stream")
        #expect((call["function"] as? [String: Any])?["arguments"] as? String == #"{"q":"news"}"#)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Malformed Split Reasoning Does Not Persist Continuation")
    func malformedSplitReasoningDoesNotPersistContinuation() async throws {
        try await loadMiniMaxContinuationMetadata()
        defer { MiniMaxMockURLProtocol.requestHandler = nil }
        let (store, directory) = try makeMiniMaxContinuationStore()
        defer {
            try? store.dbPoolForTesting.close()
            try? FileManager.default.removeItem(at: directory)
        }
        MiniMaxMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            return (miniMaxHTTPResponse(url: url, statusCode: 200), Data("""
            data: {"choices":[{"delta":{"content":"answer","reasoning_details":[{"index":"0","data":"opaque"}]}}]}
            data: {"choices":[{"delta":{},"finish_reason":"stop"}]}
            data: [DONE]

            """.utf8))
        }

        let assistantID = UUID()
        var options = ChatRequestOptions()
        options.localContinuationMessageID = assistantID
        let service = MiniMaxService(session: makeMiniMaxMockSession())
        let saved = try await RecipeContinuationRuntime.withStore(store) {
            for try await _ in service.sendMessageStream(
                apiKey: "minimax-test-key", modelID: "MiniMax-M2.7",
                messages: [makeMiniMaxUserMessage()], baseURL: "https://api.minimax.io/v1",
                reasoningMode: .deep, requestOptions: options
            ) {}
            return RecipeContinuationRuntime.load(messageID: assistantID)
        }
        #expect(saved == nil)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Non Streaming Official Web Route Preserves Citations And Replay Blocks")
    func nonStreamingOfficialWebRoutePreservesCitationsAndReplayBlocks() async throws {
        try await loadMiniMaxWebMetadata()
        defer { MiniMaxMockURLProtocol.requestHandler = nil }
        let (store, directory) = try makeMiniMaxContinuationStore()
        defer {
            try? store.dbPoolForTesting.close()
            try? FileManager.default.removeItem(at: directory)
        }
        var requests: [URLRequest] = []
        var bodies: [[String: Any]] = []
        MiniMaxMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requests.append(request)
            let bodyData = try #require(miniMaxRequestBody(from: request))
            bodies.append(try #require(
                try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            ))
            let payload = requests.count == 1 ? JoinedContinuationFixture.miniMaxAnthropicWebResponse() : Data(
                #"{"content":[{"type":"text","text":"continued"}],"usage":{"input_tokens":1,"output_tokens":1}}"#.utf8
            )
            return (miniMaxHTTPResponse(url: url, statusCode: 200), payload)
        }
        let assistantID = UUID()
        let service = MiniMaxService(session: makeMiniMaxMockSession())
        let first = try await RecipeContinuationRuntime.withStore(store) {
            try await service.sendMessage(
                apiKey: "web-key", modelID: "MiniMax-M3", messages: [makeMiniMaxUserMessage("search")],
                baseURL: "https://api.minimax.io/v1", requestOptions: miniMaxWebOptions(messageID: assistantID)
            )
        }
        #expect(first.text == JoinedContinuationFixture.joinedText)
        #expect(first.reasoningText == JoinedContinuationFixture.opaqueThinking)
        #expect(first.citations?.count == 1)
        #expect(first.citations?.first?.url == JoinedContinuationFixture.citationURL)
        #expect(first.citations?.first?.snippet == "joined citation")

        _ = try await RecipeContinuationRuntime.withStore(store) {
            try await service.sendMessage(
                apiKey: "web-key", modelID: "MiniMax-M3", messages: [makeMiniMaxUserMessage("continue")],
                baseURL: "https://api.minimax.io/v1", requestOptions: miniMaxWebOptions(explicitID: assistantID)
            )
        }
        #expect(requests.map { $0.url?.path } == ["/anthropic/v1/messages", "/anthropic/v1/messages"])
        #expect(requests.first?.value(forHTTPHeaderField: "x-api-key") == "web-key")
        #expect(requests.first?.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(bodies.first?["reasoning_split"] == nil)
        #expect(((bodies.first?["tools"] as? [[String: Any]])?.first?["type"] as? String) == "web_search_20250305")
        #expect(JoinedContinuationFixture.hasExplicitContinuationWire(
            try JSONSerialization.data(withJSONObject: bodies.last ?? [:]),
            continuationKind: "replay_blocks", recipeRef: "minimax.messages.web.v1"
        ))
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Streaming Official Web Route Uses Production Anthropic Parser")
    func streamingOfficialWebRouteUsesProductionAnthropicParser() async throws {
        try await loadMiniMaxWebMetadata()
        defer { MiniMaxMockURLProtocol.requestHandler = nil }
        let (store, directory) = try makeMiniMaxContinuationStore()
        defer {
            try? store.dbPoolForTesting.close()
            try? FileManager.default.removeItem(at: directory)
        }
        var captured: URLRequest?
        MiniMaxMockURLProtocol.requestHandler = { request in
            captured = request
            return (miniMaxHTTPResponse(url: try #require(request.url), statusCode: 200),
                    JoinedContinuationFixture.miniMaxAnthropicWebStream())
        }
        let assistantID = UUID()
        var text = ""; var reasoning = ""; var citations: [Citation] = []
        try await RecipeContinuationRuntime.withStore(store) {
            for try await event in MiniMaxService(session: makeMiniMaxMockSession()).sendMessageStream(
                apiKey: "web-key", modelID: "MiniMax-M3", messages: [makeMiniMaxUserMessage("search")],
                baseURL: "https://api.minimax.io/v1", requestOptions: miniMaxWebOptions(messageID: assistantID)
            ) {
                switch event {
                case let .delta(value): text += value
                case let .reasoning(value): reasoning += value
                case let .citations(value): citations = value
                case .toolCallDeltas, .done, .imagePart: break
                }
            }
        }
        #expect(text == JoinedContinuationFixture.joinedText)
        #expect(reasoning == JoinedContinuationFixture.opaqueThinking)
        #expect(citations.count == 1)
        #expect(citations.first?.url == JoinedContinuationFixture.citationURL)
        let snapshot = try #require(try store.load(messageID: assistantID))
        #expect(snapshot.kind == "replay_blocks")
        let stateJSON = String(decoding: try JSONEncoder().encode(snapshot.state), as: UTF8.self)
        #expect(stateJSON.contains("server_tool_use"))
        #expect(stateJSON.contains("web_search_tool_result"))
        #expect(captured?.url?.path == "/anthropic/v1/messages")
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Official Web Route Negative Gates And Malformed Blocks Fail Closed")
    func officialWebRouteNegativeGatesAndMalformedBlocksFailClosed() async throws {
        try await loadMiniMaxWebMetadata()
        defer { MiniMaxMockURLProtocol.requestHandler = nil }
        let (store, directory) = try makeMiniMaxContinuationStore()
        defer {
            try? store.dbPoolForTesting.close()
            try? FileManager.default.removeItem(at: directory)
        }
        var paths: [String] = []; var bodies: [[String: Any]] = []; var malformed = false
        MiniMaxMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            paths.append(url.path)
            let bodyData = try #require(miniMaxRequestBody(from: request))
            bodies.append(try #require(
                try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            ))
            if malformed {
                if bodies.last?["stream"] as? Bool != true {
                    return (miniMaxHTTPResponse(url: url, statusCode: 200), Data(
                        #"{"content":[{"type":"unknown","payload":"opaque"}],"usage":{"input_tokens":1,"output_tokens":1}}"#.utf8
                    ))
                }
                return (miniMaxHTTPResponse(url: url, statusCode: 200), Data("""
                event: content_block_start
                data: {"type":"content_block_start","index":0,"content_block":{"type":"unknown","payload":"opaque"}}

                event: message_stop
                data: {"type":"message_stop"}

                """.utf8))
            }
            return (miniMaxHTTPResponse(url: url, statusCode: 200), Data(
                #"{"choices":[{"message":{"content":"fallback"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8
            ))
        }
        let service = MiniMaxService(session: makeMiniMaxMockSession())
        _ = try await service.sendMessage(
            apiKey: "key", modelID: "MiniMax-M3", messages: [makeMiniMaxUserMessage()],
            baseURL: "https://api.minimax.io/v1", requestOptions: ChatRequestOptions()
        )
        _ = try await service.sendMessage(
            apiKey: "key", modelID: "MiniMax-M2", messages: [makeMiniMaxUserMessage()],
            baseURL: "https://api.minimax.io/v1", requestOptions: miniMaxWebOptions()
        )
        #expect(paths == ["/v1/chat/completions", "/v1/chat/completions"])
        #expect(bodies.allSatisfy { $0["reasoning_split"] as? Bool == true && $0["tools"] == nil })

        malformed = true
        let nonstreamID = UUID()
        do {
            _ = try await RecipeContinuationRuntime.withStore(store) {
                try await service.sendMessage(
                    apiKey: "key", modelID: "MiniMax-M3", messages: [makeMiniMaxUserMessage()],
                    baseURL: "https://api.minimax.io/v1",
                    requestOptions: miniMaxWebOptions(messageID: nonstreamID)
                )
            }
            Issue.record("malformed nonstream MiniMax block was accepted")
        } catch is ProviderServiceError {}
        #expect(try store.load(messageID: nonstreamID) == nil)

        let assistantID = UUID()
        try await RecipeContinuationRuntime.withStore(store) {
            for try await _ in service.sendMessageStream(
                apiKey: "key", modelID: "MiniMax-M3", messages: [makeMiniMaxUserMessage()],
                baseURL: "https://api.minimax.io/v1", requestOptions: miniMaxWebOptions(messageID: assistantID)
            ) {}
        }
        #expect(try store.load(messageID: assistantID) == nil)
        await MetadataClient.shared.resetForTesting()
    }
}
