import Foundation
import Testing
@testable import Oriveo

final class GrokServiceMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = GrokServiceMockURLProtocol.requestHandler else {
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

private func makeGrokMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [GrokServiceMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func grokHTTPResponse(url: URL, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: [
        "Content-Type": "text/event-stream"
    ])!
}

private func grokRequestBodyData(_ request: URLRequest) -> Data? {
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

private func loadGrokMultiAgentMetadata(reasoningRecipeRef: String? = nil) async throws {
    await MetadataClient.shared.resetForTesting()
    let runtime = try CapabilityRuntimeFixtures.runtimeEnvelopeJSON()
    var controlsJson = ""
    if let reasoningRecipeRef {
        let controls = try CapabilityRuntimeFixtures.controlsJSON(
            .init(
                capability: "reasoning",
                recipeRef: reasoningRecipeRef,
                availableIntents: try CapabilityRuntimeFixtures.reasoningIntents(
                    ofRecipe: reasoningRecipeRef
                )
            )
        )
        controlsJson = #","capabilityControls":\#(controls)"#
    }
    try await MetadataClient.shared.loadForTesting(json: """
    {
      "version": 1,
      "updatedAt": "2026-07-03T00:00:00Z",
      "capabilityRuntime": \(runtime),
      "providers": {
        "grok": {
          "displayName": "Grok",
          "defaultModelId": "grok-4.20-multi-agent-0309",
          "resolveMap": {
            "grok-4.20-multi-agent-0309": "grok-4.20-multi-agent-0309"
          },
          "transport": {
            "baseUrl": "https://api.x.ai",
            "endpoints": {
              "chat": "/v1/chat/completions",
              "responses": "/v1/responses"
            }
          },
          "models": {
            "grok-4.20-multi-agent-0309": {
              "canonicalModelId": "grok-4.20-multi-agent-0309",
              "displayName": "Grok Multi-Agent",
              "capabilities": ["text"],
              "transport": "openai_responses"\(controlsJson)
            }
          }
        }
      }
    }
    """)
}

private func makeGrokUserMessage() -> ChatMessage {
    ChatMessage(
        id: UUID(),
        role: .user,
        text: "hello",
        providerKind: .grok,
        providerName: "Grok",
        modelName: "grok-4.20-multi-agent-0309",
        state: .delivered
    )
}

private func makeGrokCapabilityScope(
    modelID: String,
    hasExplicitValue: Bool
) -> (identity: CapabilityEvidenceRequestIdentity, options: ChatRequestOptions) {
    let persisted = TestFactories.makeModel(id: modelID)
    let model = MetadataClient.shared.syncCurrentCapabilityEvidenceModel(persisted, providerKind: .grok)
    let provider = TestFactories.makeProvider(kind: .grok, models: [model])
    var options = ChatRequestOptions()
    options.capabilityEvidenceModel = model
    return (
        CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: "grok-test-user",
            hasExplicitValue: hasExplicitValue
        ),
        options
    )
}

private func loadGrokChatVisionMetadata() async throws {
    await MetadataClient.shared.resetForTesting()
    try await MetadataClient.shared.loadForTesting(json: """
    {
      "version": 1,
      "updatedAt": "2026-07-03T00:00:00Z",
      "providers": {
        "grok": {
          "displayName": "Grok",
          "defaultModelId": "grok-4.5",
          "resolveMap": { "grok-4.5": "grok-4.5" },
          "transport": {
            "baseUrl": "https://api.x.ai",
            "endpoints": { "chat": "/v1/chat/completions", "responses": "/v1/responses" }
          },
          "models": {
            "grok-4.5": {
              "canonicalModelId": "grok-4.5",
              "displayName": "Grok 4.5",
              "capabilities": ["text", "image"],
              "transport": "openai_chat"
            }
          }
        }
      }
    }
    """)
}

@Suite("Grok Service", .serialized)
struct GrokServiceTests {
    @Test("Grok Subscription Sends Reasoning Effort From Declared Levels")
    func grokSubscriptionSendsReasoningEffortFromDeclaredLevels() async throws {
        try await loadGrokMultiAgentMetadata()
        GrokServiceMockURLProtocol.requestHandler = nil
        defer { GrokServiceMockURLProtocol.requestHandler = nil }

        var requestedURL: URL?
        var requestBody: [String: Any] = [:]
        GrokServiceMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedURL = url
            if let body = grokRequestBodyData(request),
               let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
                requestBody = object
            }
            return (
                grokHTTPResponse(url: url, statusCode: 200),
                Data("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\ndata: [DONE]\n\n".utf8)
            )
        }

        var model = TestFactories.makeModel(id: "grok-4.6", capabilities: [.text, .reasoning])
        model.reasoningModeAvailable = true
        model.upstreamReasoningLevels = ["low", "high"]
        var options = ChatRequestOptions()
        options.capabilityEvidenceModel = model
        options.grokSubscription = GrokSubscriptionRequestContext(
            chatURL: URL(string: "https://cli-chat-proxy.grok.com/v1/chat/completions")!,
            requiredHeaders: ["x-xai-token-auth": "xai-grok-cli"]
        )

        let service = GrokService(session: makeGrokMockSession())
        for try await _ in service.sendMessageStream(
            apiKey: "grok-subscription-token",
            modelID: "grok-4.6",
            messages: [makeGrokUserMessage()],
            reasoningMode: .deep,
            webSearchEnabled: false,
            requestOptions: options
        ) {}

        #expect(requestedURL?.absoluteString == "https://cli-chat-proxy.grok.com/v1/chat/completions")
        #expect(requestBody["reasoning_effort"] as? String == "high")
    }

    @Test("Grok Subscription Omits Undeclared Reasoning Effort")
    func grokSubscriptionOmitsUndeclaredReasoningEffort() async throws {
        try await loadGrokMultiAgentMetadata()
        GrokServiceMockURLProtocol.requestHandler = nil
        defer { GrokServiceMockURLProtocol.requestHandler = nil }

        var requestBody: [String: Any] = [:]
        GrokServiceMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            if let body = grokRequestBodyData(request),
               let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
                requestBody = object
            }
            return (
                grokHTTPResponse(url: url, statusCode: 200),
                Data("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\ndata: [DONE]\n\n".utf8)
            )
        }

        var model = TestFactories.makeModel(id: "grok-4.6", capabilities: [.text, .reasoning])
        model.reasoningModeAvailable = true
        model.upstreamReasoningLevels = ["high"]
        var options = ChatRequestOptions()
        options.capabilityEvidenceModel = model
        options.grokSubscription = GrokSubscriptionRequestContext(
            chatURL: URL(string: "https://cli-chat-proxy.grok.com/v1/chat/completions")!,
            requiredHeaders: [:]
        )

        let service = GrokService(session: makeGrokMockSession())
        for try await _ in service.sendMessageStream(
            apiKey: "grok-subscription-token",
            modelID: "grok-4.6",
            messages: [makeGrokUserMessage()],
            reasoningMode: .fast,
            webSearchEnabled: false,
            requestOptions: options
        ) {}

        #expect(requestBody["reasoning_effort"] == nil)
    }

    @Test("Multi Agent Stream Uses Responses Transport")
    func multiAgentStreamUsesResponsesTransport() async throws {
        try await loadGrokMultiAgentMetadata()
        GrokServiceMockURLProtocol.requestHandler = nil
        defer {
            GrokServiceMockURLProtocol.requestHandler = nil
        }

        var requestedURL: URL?
        var requestBody: [String: Any] = [:]
        GrokServiceMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedURL = url
            if let body = grokRequestBodyData(request),
               let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
                requestBody = object
            }
            return (
                grokHTTPResponse(url: url, statusCode: 200),
                Data("""
                event: response.output_text.delta
                data: {"delta":"hi"}

                event: response.completed
                data: {"response":{"usage":{"input_tokens":2,"output_tokens":1}}}

                data: [DONE]

                """.utf8)
            )
        }

        let service = GrokService(session: makeGrokMockSession())
        var events: [StreamEvent] = []
        for try await event in service.sendMessageStream(
            apiKey: "xai-test",
            modelID: "grok-4.20-multi-agent-0309",
            messages: [makeGrokUserMessage()],
            reasoningMode: .deep
        ) {
            events.append(event)
        }

        #expect(requestedURL?.absoluteString == "https://api.x.ai/v1/responses")
        #expect(requestBody["input"] != nil)
        #expect(requestBody["messages"] == nil)
        #expect(requestBody["reasoning"] == nil)
        #expect(requestBody["reasoning_effort"] == nil)
        #expect(events.contains { if case .delta("hi") = $0 { true } else { false } })
    }

    @Test("Multi Agent Send Message Uses Responses Transport")
    func multiAgentSendMessageUsesResponsesTransport() async throws {
        try await loadGrokMultiAgentMetadata()
        GrokServiceMockURLProtocol.requestHandler = nil
        defer {
            GrokServiceMockURLProtocol.requestHandler = nil
        }

        var requestedURL: URL?
        var requestBody: [String: Any] = [:]
        GrokServiceMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedURL = url
            if let body = grokRequestBodyData(request),
               let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
                requestBody = object
            }
            return (
                grokHTTPResponse(url: url, statusCode: 200),
                Data("""
                {"output_text":"hi","usage":{"input_tokens":2,"output_tokens":1}}
                """.utf8)
            )
        }

        let service = GrokService(session: makeGrokMockSession())
        let result = try await service.sendMessage(
            apiKey: "xai-test",
            modelID: "grok-4.20-multi-agent-0309",
            messages: [makeGrokUserMessage()],
            reasoningMode: .deep
        )

        #expect(requestedURL?.absoluteString == "https://api.x.ai/v1/responses")
        #expect(requestBody["input"] != nil)
        #expect(requestBody["messages"] == nil)
        #expect(requestBody["reasoning"] == nil)
        #expect(requestBody["reasoning_effort"] == nil)
        #expect(result.text == "hi")
    }

    @Test("Responses Transport Uses Server Reasoning Recipe")
    func responsesTransportUsesServerReasoningRecipe() async throws {
        try await loadGrokMultiAgentMetadata(reasoningRecipeRef: "grok.responses.reasoning.v1")
        GrokServiceMockURLProtocol.requestHandler = nil
        defer {
            GrokServiceMockURLProtocol.requestHandler = nil
        }

        var requestBody: [String: Any] = [:]
        GrokServiceMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            if let body = grokRequestBodyData(request),
               let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
                requestBody = object
            }
            return (
                grokHTTPResponse(url: url, statusCode: 200),
                Data("""
                event: response.output_text.delta
                data: {"delta":"hi"}

                event: response.completed
                data: {"response":{"usage":{"input_tokens":2,"output_tokens":1}}}

                data: [DONE]

                """.utf8)
            )
        }

        let service = GrokService(session: makeGrokMockSession())
        let scope = makeGrokCapabilityScope(
            modelID: "grok-4.20-multi-agent-0309", hasExplicitValue: true
        )
        let stream = CapabilityEvidenceRequestContext.$current.withValue(scope.identity) {
            service.sendMessageStream(
                apiKey: "xai-test",
                modelID: "grok-4.20-multi-agent-0309",
                messages: [makeGrokUserMessage()],
                reasoningMode: .deep,
                requestOptions: scope.options
            )
        }
        for try await _ in stream {}

        let expectedEffort = try #require(
            try CapabilityRuntimeFixtures.recipeValue(
                recipeRef: "grok.responses.reasoning.v1", intent: "deep", pointer: "/reasoning/effort"
            ) as? String
        )
        let reasoning = try #require(requestBody["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == expectedEffort)
        #expect(requestBody["reasoning_effort"] == nil)
    }

    @Test("Historical Image Stays Inlined On Follow Up Turn")
    func historicalImageStaysInlinedOnFollowUpTurn() async throws {
        try await loadGrokChatVisionMetadata()
        GrokServiceMockURLProtocol.requestHandler = nil
        defer {
            GrokServiceMockURLProtocol.requestHandler = nil
        }

        let imageID = "grok-history-\(UUID().uuidString)"
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        ImageStore.save(imageData: pngBytes, for: imageID)
        defer { ImageStore.deleteImage(for: imageID) }

        let imageAttachment = Attachment(
            id: UUID(),
            kind: .image,
            fileName: "image.jpg",
            mimeType: "image/jpeg",
            localImageID: imageID
        )
        let userTurn1 = ChatMessage(
            id: UUID(), role: .user, text: "What's in this picture?",
            providerKind: .grok, providerName: "Grok", modelName: "grok-4.5",
            state: .delivered, attachments: [imageAttachment]
        )
        let assistantTurn1 = ChatMessage(
            id: UUID(), role: .assistant, text: "There's a cat in the picture.",
            providerKind: .grok, providerName: "Grok", modelName: "grok-4.5",
            state: .delivered
        )
        let userTurn2 = ChatMessage(
            id: UUID(), role: .user, text: "What breed is it?",
            providerKind: .grok, providerName: "Grok", modelName: "grok-4.5",
            state: .delivered
        )

        var requestBody: [String: Any] = [:]
        GrokServiceMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            if let body = grokRequestBodyData(request),
               let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
                requestBody = object
            }
            return (
                grokHTTPResponse(url: url, statusCode: 200),
                Data("""
                {"choices":[{"message":{"content":"It's a British Shorthair"}}],"usage":{"prompt_tokens":10,"completion_tokens":2}}
                """.utf8)
            )
        }

        let service = GrokService(session: makeGrokMockSession())
        let scope = makeGrokCapabilityScope(modelID: "grok-4.5", hasExplicitValue: true)
        _ = try await CapabilityEvidenceRequestContext.$current.withValue(scope.identity) {
            try await service.sendMessage(
                apiKey: "xai-test",
                modelID: "grok-4.5",
                messages: [userTurn1, assistantTurn1, userTurn2],
                requestOptions: scope.options
            )
        }

        let messages = try #require(requestBody["messages"] as? [[String: Any]])
        let historicalUserMessage = try #require(messages.first { ($0["role"] as? String) == "user" })
        let parts = try #require(historicalUserMessage["content"] as? [[String: Any]])
        let imagePart = try #require(parts.first { ($0["type"] as? String) == "image_url" })
        let imageURLDict = try #require(imagePart["image_url"] as? [String: Any])
        let urlString = try #require(imageURLDict["url"] as? String)

        #expect(urlString.hasPrefix("data:image/jpeg;base64,"), "should inline a data URL, not an empty or remote URL")
        let b64 = urlString.replacingOccurrences(of: "data:image/jpeg;base64,", with: "")
        #expect(!b64.isEmpty)
        #expect(Data(base64Encoded: b64) == pngBytes)
    }

    @Test("Missing Local Image File Is Skipped Not Sent As Empty Data URL")
    func missingLocalImageFileIsSkippedNotSentAsEmptyDataURL() async throws {
        try await loadGrokChatVisionMetadata()
        GrokServiceMockURLProtocol.requestHandler = nil
        defer {
            GrokServiceMockURLProtocol.requestHandler = nil
        }

        let danglingImageID = "grok-dangling-\(UUID().uuidString)"
        let imageAttachment = Attachment(
            id: UUID(),
            kind: .image,
            fileName: "image.jpg",
            mimeType: "image/jpeg",
            localImageID: danglingImageID
        )
        let userMessage = ChatMessage(
            id: UUID(), role: .user, text: "Describe this picture",
            providerKind: .grok, providerName: "Grok", modelName: "grok-4.5",
            state: .delivered, attachments: [imageAttachment]
        )

        var requestBody: [String: Any] = [:]
        GrokServiceMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            if let body = grokRequestBodyData(request),
               let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
                requestBody = object
            }
            return (
                grokHTTPResponse(url: url, statusCode: 200),
                Data("""
                {"choices":[{"message":{"content":"I can't see the image"}}],"usage":{"prompt_tokens":5,"completion_tokens":2}}
                """.utf8)
            )
        }

        let service = GrokService(session: makeGrokMockSession())
        _ = try await service.sendMessage(
            apiKey: "xai-test",
            modelID: "grok-4.5",
            messages: [userMessage]
        )

        let messages = try #require(requestBody["messages"] as? [[String: Any]])
        let userPayload = try #require(messages.first { ($0["role"] as? String) == "user" })

        if let parts = userPayload["content"] as? [[String: Any]] {
            let imageParts = parts.filter { ($0["type"] as? String) == "image_url" }
            #expect(imageParts.isEmpty)
            for part in imageParts {
                let urlString = (part["image_url"] as? [String: Any])?["url"] as? String ?? ""
                #expect(!urlString.hasSuffix("base64,"), "must not send a malformed data URL with empty base64")
            }
        }
    }

    @Test("Prompt Tokens Uses Total Input Breakdown")
    func promptTokensUsesTotalInputBreakdown() async throws {
        try await loadGrokChatVisionMetadata()
        GrokServiceMockURLProtocol.requestHandler = nil
        defer {
            GrokServiceMockURLProtocol.requestHandler = nil
        }

        GrokServiceMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            return (
                grokHTTPResponse(url: url, statusCode: 200),
                Data("""
                {"choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":100,"completion_tokens":7,"prompt_tokens_details":{"cached_tokens":60},"cost_in_usd_ticks":12345}}
                """.utf8)
            )
        }

        let service = GrokService(session: makeGrokMockSession())
        let result = try await service.sendMessage(
            apiKey: "xai-test",
            modelID: "grok-4.5",
            messages: [makeGrokUserMessage()]
        )

        let breakdown = try #require(result.usageBreakdown)
        #expect(breakdown.promptTokens == 40)
        #expect(breakdown.cachedInputTokens == 60)
        #expect(breakdown.cacheReadObserved)
        #expect(result.promptTokens == breakdown.totalInputTokens)
        #expect(result.promptTokens == 100)
        #expect(result.completionTokens == 7)
    }
}
