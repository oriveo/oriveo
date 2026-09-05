import Foundation
import GRDB
import Testing
@testable import Oriveo

final class MistralServiceMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MistralServiceMockURLProtocol.requestHandler else {
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

private func makeMistralMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MistralServiceMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func mistralHTTPResponse(url: URL, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: [
        "Content-Type": "text/event-stream"
    ])!
}

private func mistralRequestBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else { return nil }

    stream.open()
    defer { stream.close() }

    var data = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: 4_096)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return data
}

private func makeMistralUserMessage(_ text: String = "hello") -> ChatMessage {
    ChatMessage(
        id: UUID(),
        role: .user,
        text: text,
        providerKind: .mistral,
        providerName: "Mistral",
        modelName: "magistral-medium-latest",
        state: .delivered
    )
}

private func makeMistralContinuationStore() throws -> (RecipeContinuationStore, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("oriveo-mistral-continuation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let pool = try DatabasePool(path: directory.appendingPathComponent("sidecar.sqlite").path)
    return (try RecipeContinuationStore(dbPool: pool), directory)
}

private func loadMistralContinuationMetadata() async throws {
    await MetadataClient.shared.resetForTesting()
    try await MetadataClient.shared.loadForTesting(json: """
    {
      "version": 1,
      "providers": {
        "mistral": {
          "resolveMap": {"magistral-medium-latest":"magistral-medium-latest"},
          "models": {
            "magistral-medium-latest": {
              "canonicalModelId":"magistral-medium-latest",
              "transport":"openai_chat",
              "capabilities":["text","reasoning"],
              "capabilityControls": {
                "reasoning":{"state":"auto_available","recipeRef":"mistral.chat.reasoning.v1"}
              }
            }
          }
        }
      },
      "capabilityRuntime": {
        "schemaVersion":2,
        "revision":"mistral-continuation-test",
        "generatedAt":"2026-08-23T00:00:00Z",
        "recipes": {
          "mistral.chat.reasoning.v1": {
            "id":"mistral.chat.reasoning.v1",
            "providerKind":"mistral",
            "transport":{"protocol":"openai_chat"},
            "capability":"reasoning",
            "executionKind":"request_overlay",
            "requestOps":[{"op":"set","intent":"deep","pointer":"/reasoning_effort","value":"high"}],
            "responseParserKind":"mistral_reasoning_v1",
            "continuationKind":"replay_reasoning",
            "fallbackPolicy":"remove_auto_patch_once_pre_token",
            "sourceRefs":["mistral.reasoning"]
          }
        },
        "controlDefinitions":{},
        "sourceIndex":{"mistral.reasoning":{"kind":"official_doc","url":"https://docs.mistral.ai/","reviewedAt":"2026-08-23"}}
      }
    }
    """)
}

private func mistralJSON(_ value: Any) -> Data? {
    let envelope = ["value": value]
    guard JSONSerialization.isValidJSONObject(envelope) else { return nil }
    return try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
}

@Suite("Mistral Service", .serialized)
struct MistralServiceTests {

    @Test("Non Streaming Continuation Round Trips Native Content Shapes")
    func nonStreamingContinuationRoundTripsNativeContentShapes() async throws {
        try await loadMistralContinuationMetadata()
        defer { MistralServiceMockURLProtocol.requestHandler = nil }

        let cases: [(responseContent: String, expectedContent: Any, toolCalls: String?)] = [
            (#""prior answer""#, "prior answer", nil),
            (
                #"[{"type":"thinking","thinking":[{"type":"text","text":"opaque"}],"closed":true},{"type":"text","text":"answer"}]"#,
                [
                    ["type": "thinking", "thinking": [["type": "text", "text": "opaque"]], "closed": true],
                    ["type": "text", "text": "answer"],
                ] as [[String: Any]],
                #"[{"id":"call_1","type":"function","function":{"name":"lookup","arguments":"{\"q\":\"news\"}"}}]"#
            ),
        ]

        for item in cases {
            let (store, directory) = try makeMistralContinuationStore()
            defer {
                try? store.dbPoolForTesting.close()
                try? FileManager.default.removeItem(at: directory)
            }
            var capturedBodies: [[String: Any]] = []
            MistralServiceMockURLProtocol.requestHandler = { request in
                let url = try #require(request.url)
                let body = try #require(mistralRequestBodyData(request))
                let object = try #require(
                    try JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                capturedBodies.append(object)
                let responseBody: String
                if capturedBodies.count == 1 {
                    let toolCalls = item.toolCalls.map { ",\"tool_calls\":\($0)" } ?? ""
                    responseBody = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\(item.responseContent)\(toolCalls)}}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}"
                } else {
                    responseBody = #"{"choices":[{"message":{"role":"assistant","content":"continued"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#
                }
                return (mistralHTTPResponse(url: url, statusCode: 200), Data(responseBody.utf8))
            }

            let assistantID = UUID()
            var producerOptions = ChatRequestOptions()
            producerOptions.localContinuationMessageID = assistantID
            let service = MistralService(session: makeMistralMockSession())
            _ = try await RecipeContinuationRuntime.withStore(store) {
                try await service.sendMessage(
                    apiKey: "mistral-test-key", modelID: "magistral-medium-latest",
                    messages: [makeMistralUserMessage("produce")], reasoningMode: .deep,
                    requestOptions: producerOptions
                )
            }

            var explicitOptions = ChatRequestOptions()
            explicitOptions.localExplicitContinuationMessageID = assistantID
            let partial = ChatMessage(
                id: assistantID, role: .assistant, text: "flattened partial",
                providerKind: .mistral, providerName: "Mistral",
                modelName: "magistral-medium-latest", state: .delivered
            )
            _ = try await RecipeContinuationRuntime.withStore(store) {
                try await service.sendMessage(
                    apiKey: "mistral-test-key", modelID: "magistral-medium-latest",
                    messages: [makeMistralUserMessage("produce"), partial, makeMistralUserMessage("continue")],
                    reasoningMode: .deep, requestOptions: explicitOptions
                )
            }

            let explicitBody = try #require(capturedBodies.last)
            let messages = try #require(explicitBody["messages"] as? [[String: Any]])
            let replay = try #require(messages.first { $0["role"] as? String == "assistant" })
            #expect(mistralJSON(replay["content"] as Any) == mistralJSON(item.expectedContent))
            #expect(replay["content"] as? String != "flattened partial")
            if item.toolCalls == nil {
                #expect(replay["tool_calls"] == nil)
            } else {
                #expect((replay["tool_calls"] as? [[String: Any]])?.first?["id"] as? String == "call_1")
            }
        }
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Streaming Continuation Round Trips Ordered Blocks And Tool Calls")
    func streamingContinuationRoundTripsOrderedBlocksAndToolCalls() async throws {
        try await loadMistralContinuationMetadata()
        defer { MistralServiceMockURLProtocol.requestHandler = nil }
        let (store, directory) = try makeMistralContinuationStore()
        defer {
            try? store.dbPoolForTesting.close()
            try? FileManager.default.removeItem(at: directory)
        }
        var capturedBodies: [[String: Any]] = []
        MistralServiceMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let body = try #require(mistralRequestBodyData(request))
            let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            capturedBodies.append(object)
            if object["stream"] as? Bool == true {
                return (
                    mistralHTTPResponse(url: url, statusCode: 200),
                    Data("""
                    data: {"choices":[{"delta":{"role":"assistant","content":""}}]}
                    data: {"choices":[{"delta":{"content":[{"type":"thinking","thinking":[{"type":"text","text":"think-1"}]}]}}]}
                    data: {"choices":[{"delta":{"content":[{"type":"thinking","thinking":[{"type":"text","text":"think-2"}]},{"type":"text","text":"First"}]}}]}
                    data: {"choices":[{"delta":{"content":" answer"}}]}
                    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_stream","type":"function","function":{"name":"lookup","arguments":"{\\"q\\":\\""}}]}}]}
                    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"news\\"}"}}]}}]}
                    data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":2,"completion_tokens":3}}
                    data: [DONE]

                    """.utf8)
                )
            }
            return (
                mistralHTTPResponse(url: url, statusCode: 200),
                Data(#"{"choices":[{"message":{"role":"assistant","content":"continued"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
            )
        }

        let assistantID = UUID()
        var producerOptions = ChatRequestOptions()
        producerOptions.localContinuationMessageID = assistantID
        let service = MistralService(session: makeMistralMockSession())
        var result: ProviderChatResult?
        try await RecipeContinuationRuntime.withStore(store) {
            for try await event in service.sendMessageStream(
                apiKey: "mistral-test-key", modelID: "magistral-medium-latest",
                messages: [makeMistralUserMessage("produce")], reasoningMode: .deep,
                requestOptions: producerOptions
            ) {
                if case let .done(done) = event { result = done }
            }
        }
        #expect(result?.text == "First answer")

        var explicitOptions = ChatRequestOptions()
        explicitOptions.localExplicitContinuationMessageID = assistantID
        let partial = ChatMessage(
            id: assistantID, role: .assistant, text: "flattened partial",
            providerKind: .mistral, providerName: "Mistral",
            modelName: "magistral-medium-latest", state: .delivered
        )
        _ = try await RecipeContinuationRuntime.withStore(store) {
            try await service.sendMessage(
                apiKey: "mistral-test-key", modelID: "magistral-medium-latest",
                messages: [makeMistralUserMessage("produce"), partial, makeMistralUserMessage("continue")],
                reasoningMode: .deep, requestOptions: explicitOptions
            )
        }

        let explicitBody = try #require(capturedBodies.last)
        let messages = try #require(explicitBody["messages"] as? [[String: Any]])
        let replay = try #require(messages.first { $0["role"] as? String == "assistant" })
        let content = try #require(replay["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["thinking", "thinking", "text", "text"])
        #expect(((content[0]["thinking"] as? [[String: Any]])?.first?["text"] as? String) == "think-1")
        #expect(((content[1]["thinking"] as? [[String: Any]])?.first?["text"] as? String) == "think-2")
        #expect(content[2]["text"] as? String == "First")
        #expect(content[3]["text"] as? String == " answer")
        let call = try #require((replay["tool_calls"] as? [[String: Any]])?.first)
        #expect(call["id"] as? String == "call_stream")
        #expect((call["function"] as? [String: Any])?["arguments"] as? String == #"{"q":"news"}"#)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Plain String Streaming Deltas")
    func plainStringStreamingDeltas() async throws {
        MistralServiceMockURLProtocol.requestHandler = nil
        defer { MistralServiceMockURLProtocol.requestHandler = nil }

        var requestedURL: URL?
        MistralServiceMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedURL = url
            return (
                mistralHTTPResponse(url: url, statusCode: 200),
                Data("""
                data: {"choices":[{"delta":{"role":"assistant","content":""}}]}
                data: {"choices":[{"delta":{"content":"Hello"}}]}
                data: {"choices":[{"delta":{"content":" world"}}]}
                data: {"choices":[{"delta":{"content":""},"finish_reason":"stop"}],"usage":{"prompt_tokens":8,"completion_tokens":2,"total_tokens":10}}
                data: [DONE]

                """.utf8)
            )
        }

        let service = MistralService(session: makeMistralMockSession())
        var deltas: [String] = []
        var doneResult: ProviderChatResult?
        for try await event in service.sendMessageStream(
            apiKey: "mistral-test-key",
            modelID: "mistral-medium-3-5",
            messages: [makeMistralUserMessage()]
        ) {
            switch event {
            case let .delta(text): deltas.append(text)
            case let .done(result): doneResult = result
            case .reasoning: Issue.record("a normal model must not emit reasoning events")
            default: break
            }
        }

        #expect(requestedURL?.absoluteString == "https://api.mistral.ai/v1/chat/completions")
        #expect(deltas == ["Hello", " world"])
        let result = try #require(doneResult)
        #expect(result.text == "Hello world")
        #expect(result.reasoningText == nil)
        #expect(result.promptTokens == 8)
        #expect(result.completionTokens == 2)
    }

    @Test("Thinking Block Streaming Splits Reasoning And Text")
    func thinkingBlockStreamingSplitsReasoningAndText() async throws {
        MistralServiceMockURLProtocol.requestHandler = nil
        defer { MistralServiceMockURLProtocol.requestHandler = nil }

        MistralServiceMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            return (
                mistralHTTPResponse(url: url, statusCode: 200),
                Data("""
                data: {"p":"abc","choices":[{"delta":{"role":"assistant","content":""}}]}
                data: {"p":"def","choices":[{"delta":{"content":[{"type":"thinking","thinking":[{"type":"text","text":"Let me"}]}]}}]}
                data: {"choices":[{"delta":{"content":[{"type":"thinking","thinking":[{"type":"text","text":" think"}]}]}}]}
                data: {"choices":[{"delta":{"content":[{"type":"thinking","thinking":[]}]}}]}
                data: {"p":"ghi","choices":[{"delta":{"content":"The answer"}}]}
                data: {"choices":[{"delta":{"content":" is 42."}}]}
                data: {"choices":[{"delta":{"content":""},"finish_reason":"stop"}],"usage":{"prompt_tokens":20,"completion_tokens":15,"total_tokens":35,"prompt_tokens_details":{"cached_tokens":5}}}
                data: [DONE]

                """.utf8)
            )
        }

        let service = MistralService(session: makeMistralMockSession())
        var reasoningChunks: [String] = []
        var deltas: [String] = []
        var doneResult: ProviderChatResult?
        for try await event in service.sendMessageStream(
            apiKey: "mistral-test-key",
            modelID: "magistral-medium-latest",
            messages: [makeMistralUserMessage()]
        ) {
            switch event {
            case let .reasoning(chunk): reasoningChunks.append(chunk)
            case let .delta(text): deltas.append(text)
            case let .done(result): doneResult = result
            default: break
            }
        }

        #expect(reasoningChunks == ["Let me", " think"])
        #expect(deltas == ["The answer", " is 42."])
        let result = try #require(doneResult)
        #expect(result.text == "The answer is 42.")
        #expect(result.reasoningText == "Let me think")
        #expect(result.usageBreakdown?.promptTokens == 15)
        #expect(result.usageBreakdown?.cachedInputTokens == 5)
        #expect(result.completionTokens == 15)
    }

    @Test("Streaming Usage Arrives Without Stream Options")
    func streamingUsageArrivesWithoutStreamOptions() async throws {
        MistralServiceMockURLProtocol.requestHandler = nil
        defer { MistralServiceMockURLProtocol.requestHandler = nil }

        var requestBody: [String: Any] = [:]
        MistralServiceMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            if let body = mistralRequestBodyData(request),
               let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
                requestBody = object
            }
            return (
                mistralHTTPResponse(url: url, statusCode: 200),
                Data("""
                data: {"choices":[{"delta":{"role":"assistant","content":""}}]}
                data: {"choices":[{"delta":{"content":"Hi"}}]}
                data: {"choices":[{"delta":{"content":""},"finish_reason":"stop"}],"usage":{"prompt_tokens":30,"completion_tokens":4,"total_tokens":34,"prompt_tokens_details":{"cached_tokens":12}}}
                data: [DONE]

                """.utf8)
            )
        }

        let service = MistralService(session: makeMistralMockSession())
        var doneResult: ProviderChatResult?
        for try await event in service.sendMessageStream(
            apiKey: "mistral-test-key",
            modelID: "mistral-medium-3-5",
            messages: [makeMistralUserMessage()]
        ) {
            if case let .done(result) = event { doneResult = result }
        }

        #expect(requestBody["stream"] as? Bool == true)
        #expect(requestBody["stream_options"] == nil)

        let result = try #require(doneResult)
        let breakdown = try #require(result.usageBreakdown)
        #expect(breakdown.promptTokens == 18)
        #expect(breakdown.cachedInputTokens == 12)
        #expect(breakdown.cacheReadObserved)
        #expect(result.promptTokens == breakdown.totalInputTokens)
        #expect(result.promptTokens == 30)
        #expect(result.completionTokens == 4)
    }

    @Test("Non Streaming Block Array Folds")
    func nonStreamingBlockArrayFolds() async throws {
        MistralServiceMockURLProtocol.requestHandler = nil
        defer { MistralServiceMockURLProtocol.requestHandler = nil }

        MistralServiceMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            return (
                mistralHTTPResponse(url: url, statusCode: 200),
                Data("""
                {"choices":[{"message":{"role":"assistant","content":[{"type":"thinking","thinking":[{"type":"text","text":"reasoning process"}],"closed":true},{"type":"text","text":"final answer"}]}}],"usage":{"prompt_tokens":12,"completion_tokens":6,"total_tokens":18}}
                """.utf8)
            )
        }

        let service = MistralService(session: makeMistralMockSession())
        let result = try await service.sendMessage(
            apiKey: "mistral-test-key",
            modelID: "magistral-medium-latest",
            messages: [makeMistralUserMessage()]
        )

        #expect(result.text == "final answer")
        #expect(result.reasoningText == "reasoning process")
        #expect(result.promptTokens == 12)
        #expect(result.completionTokens == 6)
    }

    @Test("Usage Parsing Subtracts Cached Tokens")
    func usageParsingSubtractsCachedTokens() {
        let breakdown = MistralService.parseUsageForTesting(
            promptTokens: 100,
            completionTokens: 20,
            cachedTokens: 30
        )
        #expect(breakdown.promptTokens == 70)
        #expect(breakdown.cachedInputTokens == 30)
        #expect(breakdown.totalInputTokens == 100)
        #expect(breakdown.completionTokens == 20)

        let plain = MistralService.parseUsageForTesting(
            promptTokens: 40,
            completionTokens: 8,
            cachedTokens: nil
        )
        #expect(plain.promptTokens == 40)
        #expect(plain.cachedInputTokens == 0)
    }

    @Test("Bad Key401 Maps To Invalid APIKey")
    func badKey401MapsToInvalidAPIKey() async throws {
        MistralServiceMockURLProtocol.requestHandler = nil
        defer { MistralServiceMockURLProtocol.requestHandler = nil }

        MistralServiceMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            return (
                mistralHTTPResponse(url: url, statusCode: 401),
                Data(#"{"message":"Unauthorized","request_id":"req-1"}"#.utf8)
            )
        }

        let service = MistralService(session: makeMistralMockSession())
        var caught: Error?
        do {
            for try await _ in service.sendMessageStream(
                apiKey: "bad-key",
                modelID: "mistral-medium-3-5",
                messages: [makeMistralUserMessage()]
            ) {}
        } catch {
            caught = error
        }

        let error = try #require(caught as? ProviderServiceError)
        guard case .invalidAPIKey = error else {
            Issue.record("expected invalidAPIKey, got \(error)")
            return
        }
    }
}
