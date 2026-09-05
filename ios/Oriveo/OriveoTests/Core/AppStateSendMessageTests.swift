import Foundation
import Testing
@testable import Oriveo

final class AppStateSendMessageURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = AppStateSendMessageURLProtocol.requestHandler else {
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

private func registerAppStateSendMessageMock() {
    AppStateSendMessageURLProtocol.requestHandler = nil
}

private func unregisterAppStateSendMessageMock() {
    AppStateSendMessageURLProtocol.requestHandler = nil
}

private func appStateSendMessageSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AppStateSendMessageURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func appStateSendMessageHTTPResponse(
    url: URL,
    statusCode: Int,
    headers: [String: String]? = nil
) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: headers)!
}

private func appStateSendMessageRequestBody(from request: URLRequest) -> Data? {
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

@Suite("AppState sendMessage", .serialized)
@MainActor
struct AppStateSendMessageTests {

    private func loadRelayReasoningEvidence() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-08-09T00:00:00Z",
          "profiles": {
            "reasoning": {
              "relay_reasoning_retry_test": {
                "transport": "openai_responses",
                "levels": ["max"],
                "params": { "max": { "reasoning_effort": "xhigh" } }
              }
            },
            "webSearch": {},
            "imageGen": {}
          },
          "providers": {}
        }
        """, metadataETag: "relay-reasoning-retry-etag")
    }

    private func relayReasoningRetryModel() -> AIModel {
        var model = TestFactories.makeModel(
            id: "gpt-5.4",
            name: "GPT-5.4",
            capabilities: [.text, .reasoning],
            reasoningModeAvailable: true,
            isDefault: true
        )
        model.reasoningProfile = "relay_reasoning_retry_test"
        return model
    }

    @MainActor
    private func makeIsolatedAppState(
        prefix: String = "app-state-send-message-"
    ) -> AppState {
        AppState(
            seedDemoData: false,
            sessionUID: "\(prefix)\(UUID().uuidString)",
            providerSession: appStateSendMessageSession()
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 3_000_000_000,
        intervalNanoseconds: UInt64 = 20_000_000,
        condition: @MainActor @escaping () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while await condition() == false {
            if ContinuousClock.now >= deadline {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: intervalNanoseconds)
        }
    }

    @Test("Existing Conversation With Missing Provider Returns Nil")
    func existingConversationWithMissingProviderReturnsNil() async throws {
        let state = AppState(seedDemoData: true)
        let conversationID = try #require(state.conversations.first?.id)

        state.providers = []

        let returnedID = await state.sendMessage("Hello", in: conversationID)

        #expect(returnedID == nil)
    }

    @Test("Prepare Conversation Selection For Send Repairs Conversation Selection")
    func prepareConversationSelectionForSendRepairsConversationSelection() {
        let state = makeIsolatedAppState(prefix: "repair-selection-")
        let fallbackProvider = TestFactories.makeProvider(
            kind: .openAI,
            models: [
                TestFactories.makeModel(
                    id: "gpt-4o",
                    name: "GPT-4o",
                    isDefault: true,
                    canonicalModelId: "gpt-4o"
                )
            ]
        )
        let conversation = TestFactories.makeConversation(
            providerID: UUID(),
            modelID: "missing-model"
        )

        state.providers = [fallbackProvider]
        state.upsertConversationProjection(conversation)

        state.prepareConversationSelectionForSend(
            conversationID: conversation.id,
            providerID: fallbackProvider.id,
            modelID: "gpt-4o",
            needsRepair: true
        )

        let repaired = state.conversation(for: conversation.id)
        #expect(repaired?.providerID == fallbackProvider.id)
        #expect(repaired?.modelID == "gpt-4o")
    }

    @Test("Existing Conversation Send Uses Selected Model After Switch")
    func existingConversationSendUsesSelectedModelAfterSwitch() async throws {
        registerAppStateSendMessageMock()
        defer {
            AppStateSendMessageURLProtocol.requestHandler = nil
            unregisterAppStateSendMessageMock()
        }
        AppStateSendMessageURLProtocol.requestHandler = { request in
            (
                appStateSendMessageHTTPResponse(url: request.url!, statusCode: 503),
                Data()
            )
        }

        let state = makeIsolatedAppState(prefix: "switch-model-send-")
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [
                TestFactories.makeModel(id: "model-a", name: "Model A", isDefault: true),
                TestFactories.makeModel(id: "model-b", name: "Model B")
            ]
        )
        let conversation = TestFactories.makeConversation(
            providerID: provider.id,
            providerKind: provider.kind,
            modelID: "model-a"
        )
        state.providers = [provider]
        state.upsertConversationProjection(conversation)

        state.selectModel(modelID: "model-b", providerID: provider.id, for: conversation.id)
        let returnedID = await state.sendMessage("Hello after switching", in: conversation.id)

        let updated = try #require(state.conversation(for: conversation.id))
        #expect(returnedID == conversation.id)
        #expect(updated.modelID == "model-b")
        #expect(updated.messages.count == 2)
        #expect(updated.messages.allSatisfy { $0.modelID == "model-b" })

        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    @Test("Qwen Send Message Survives Reasoning Only Chunks Before Final Content")
    func qwenSendMessageSurvivesReasoningOnlyChunksBeforeFinalContent() async throws {
        registerAppStateSendMessageMock()
        defer {
            AppStateSendMessageURLProtocol.requestHandler = nil
            unregisterAppStateSendMessageMock()
        }

        var requestedModelID: String?
        var requestedStream: Bool?
        AppStateSendMessageURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            #expect(url.absoluteString == "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions")

            if let body = appStateSendMessageRequestBody(from: request),
               let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
                requestedModelID = json["model"] as? String
                requestedStream = json["stream"] as? Bool
            }

            let responseBody = """
            data: {"choices":[{"delta":{"content":null,"role":"assistant","reasoning_content":""},"index":0,"finish_reason":null}]}
            data: {"choices":[{"delta":{"content":null,"reasoning_content":"Here"},"index":0,"finish_reason":null}]}
            data: {"choices":[{"delta":{"content":null,"reasoning_content":"'s a thinking process"},"index":0,"finish_reason":null}]}
            data: {"choices":[{"delta":{"content":"Hello"},"index":0,"finish_reason":null}]}
            data: {"choices":[{"delta":{"content":"! How can I help"},"index":0,"finish_reason":null}]}
            data: {"choices":[{"delta":{"content":" you?"},"index":0,"finish_reason":null}]}
            data: {"usage":{"prompt_tokens":8,"completion_tokens":12}}
            data: [DONE]

            """

            return (
                appStateSendMessageHTTPResponse(
                    url: url,
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                Data(responseBody.utf8)
            )
        }

        let state = makeIsolatedAppState(prefix: "qwen-reasoning-stream-")
        let qwenProvider = TestFactories.makeProvider(
            kind: .qwen,
            models: [
                TestFactories.makeModel(
                    id: "qwen3.6-plus",
                    name: "Qwen3.6 Plus",
                    capabilities: [.text, .reasoning],
                    reasoningModeAvailable: true,
                    isDefault: true,
                    canonicalModelId: "qwen3.6-plus"
                )
            ]
        )
        state.providers = [qwenProvider]
        state.setActiveModel(providerID: qwenProvider.id, modelID: "qwen3.6-plus")

        let conversationID = try #require(await state.sendMessage("Hello", in: nil))

        try await waitUntil {
            guard let conversation = state.conversation(for: conversationID),
                  let assistant = conversation.messages.last(where: { $0.role == .assistant }) else {
                return false
            }
            return assistant.state != .generating
        }

        let conversation = try #require(state.conversation(for: conversationID))
        let assistant = try #require(conversation.messages.last(where: { $0.role == .assistant }))
        #expect(requestedModelID == "qwen3.6-plus")
        #expect(requestedStream == true)
        #expect(assistant.state == .delivered)
        #expect(assistant.text == "Hello! How can I help you?")
        #expect(assistant.errorTitle == nil)
        #expect(assistant.errorDetail == nil)
    }

    @Test("Relay Anthropic Explicit Transport Uses Messages Endpoint")
    func relayAnthropicExplicitTransportUsesMessagesEndpoint() async throws {
        registerAppStateSendMessageMock()
        defer {
            AppStateSendMessageURLProtocol.requestHandler = nil
            unregisterAppStateSendMessageMock()
        }

        var capturedRequest: URLRequest?
        AppStateSendMessageURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            capturedRequest = request
            let responseBody = """
            event: message_start
            data: {"message":{"usage":{"input_tokens":5}}}

            event: content_block_delta
            data: {"delta":{"type":"text_delta","text":"hello"}}

            event: message_delta
            data: {"usage":{"output_tokens":3}}
            """

            return (
                appStateSendMessageHTTPResponse(
                    url: url,
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                Data(responseBody.utf8)
            )
        }

        let state = makeIsolatedAppState(prefix: "relay-anthropic-stream-")
        var relayProvider = TestFactories.makeProvider(
            kind: .relay,
            models: [
                TestFactories.makeModel(
                    id: "claude-sonnet-4-5",
                    name: "Claude Sonnet 4.5",
                    capabilities: [.text],
                    isDefault: true
                )
            ],
            catalogModels: [
                TestFactories.makeModel(
                    id: "claude-sonnet-4-5",
                    name: "Claude Sonnet 4.5",
                    capabilities: [.text],
                    isDefault: true
                )
            ],
            apiKey: "relay-key",
            apiKeyPreview: "relay...",
            baseURLText: "https://relay.example.com",
            customName: "Claude Relay"
        )
        relayProvider.relayRequested = RelayRequestedConfig(
            transport: .anthropicMessages,
            authMode: .auto,
            modelID: "claude-sonnet-4-5"
        )
        state.providers = [relayProvider]
        state.setActiveModel(providerID: relayProvider.id, modelID: "claude-sonnet-4-5")

        let conversationID = try #require(await state.sendMessage("Hello", in: nil))

        try await waitUntil {
            guard let conversation = state.conversation(for: conversationID),
                  let assistant = conversation.messages.last(where: { $0.role == .assistant }) else {
                return false
            }
            return assistant.state != .generating
        }

        let request = try #require(capturedRequest)
        #expect(request.url?.path == "/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "relay-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Relay Gemini Explicit Transport Uses Generate Content Endpoint")
    func relayGeminiExplicitTransportUsesGenerateContentEndpoint() async throws {
        registerAppStateSendMessageMock()
        defer {
            AppStateSendMessageURLProtocol.requestHandler = nil
            unregisterAppStateSendMessageMock()
        }

        var capturedRequest: URLRequest?
        AppStateSendMessageURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            capturedRequest = request
            let responseBody = """
            data: {"candidates":[{"content":{"parts":[{"text":"hello"}]}}],"usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":3}}

            """

            return (
                appStateSendMessageHTTPResponse(
                    url: url,
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                Data(responseBody.utf8)
            )
        }

        let state = makeIsolatedAppState(prefix: "relay-gemini-stream-")
        var relayProvider = TestFactories.makeProvider(
            kind: .relay,
            models: [
                TestFactories.makeModel(
                    id: "gemini-2.5-pro",
                    name: "Gemini 2.5 Pro",
                    capabilities: [.text],
                    isDefault: true
                )
            ],
            catalogModels: [
                TestFactories.makeModel(
                    id: "gemini-2.5-pro",
                    name: "Gemini 2.5 Pro",
                    capabilities: [.text],
                    isDefault: true
                )
            ],
            apiKey: "goog-key",
            apiKeyPreview: "goog...",
            baseURLText: "https://relay.example.com",
            customName: "Gemini Relay"
        )
        relayProvider.relayRequested = RelayRequestedConfig(
            transport: .geminiGenerateContent,
            authMode: .auto,
            modelID: "gemini-2.5-pro"
        )
        state.providers = [relayProvider]
        state.setActiveModel(providerID: relayProvider.id, modelID: "gemini-2.5-pro")

        let conversationID = try #require(await state.sendMessage("Hello", in: nil))

        try await waitUntil {
            guard let conversation = state.conversation(for: conversationID),
                  let assistant = conversation.messages.last(where: { $0.role == .assistant }) else {
                return false
            }
            return assistant.state != .generating
        }

        let request = try #require(capturedRequest)
        let url = try #require(request.url)
        #expect(url.path == "/v1beta/models/gemini-2.5-pro:streamGenerateContent")
        #expect(url.query?.contains("alt=sse") == true)
        #expect(url.query?.contains("key=") != true)
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "goog-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }


    @Test("Relay + openai_chat_completions transport + imageGen → /v1/images/generations")
    func relayImageGenRoutesToImagesEndpointOnChatCompletions() async throws {
        registerAppStateSendMessageMock()
        defer {
            AppStateSendMessageURLProtocol.requestHandler = nil
            unregisterAppStateSendMessageMock()
        }

        var capturedRequest: URLRequest?
        AppStateSendMessageURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            capturedRequest = request
            return (
                appStateSendMessageHTTPResponse(
                    url: url,
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"]
                ),
                Data(
                    """
                    {
                      "data": [ {"b64_json": "AAAACATIMG"} ],
                      "usage": {"input_tokens": 4, "output_tokens": 0}
                    }
                    """.utf8
                )
            )
        }

        let state = makeIsolatedAppState(prefix: "relay-imagegen-chat-")
        var relayProvider = TestFactories.makeProvider(
            kind: .relay,
            models: [
                TestFactories.makeModel(
                    id: "gpt-image-2",
                    name: "gpt-image-2",
                    capabilities: [.text, .imageGen],
                    isDefault: true
                )
            ],
            catalogModels: [
                TestFactories.makeModel(
                    id: "gpt-image-2",
                    name: "gpt-image-2",
                    capabilities: [.text, .imageGen],
                    isDefault: true
                )
            ],
            apiKey: "relay-key",
            apiKeyPreview: "relay...",
            baseURLText: "https://relay.example.com/v1",
            customName: "OpenAI Relay"
        )
        relayProvider.relayRequested = RelayRequestedConfig(
            transport: .openaiChatCompletions,
            authMode: .bearer,
            modelID: "gpt-image-2",
            stream: true
        )
        state.providers = [relayProvider]
        state.setActiveModel(providerID: relayProvider.id, modelID: "gpt-image-2")

        let conversationID = try #require(await state.sendMessage("Draw a cat", in: nil))

        try await waitUntil {
            guard let conversation = state.conversation(for: conversationID),
                  let assistant = conversation.messages.last(where: { $0.role == .assistant }) else {
                return false
            }
            return assistant.state != .generating
        }

        let request = try #require(capturedRequest)
        let body = try #require(appStateSendMessageRequestBody(from: request))
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(request.url?.path == "/v1/images/generations")
        #expect(payload["model"] as? String == "gpt-image-2")
        #expect(payload["response_format"] as? String == nil)

        let conversation = try #require(state.conversation(for: conversationID))
        let assistant = try #require(conversation.messages.last(where: { $0.role == .assistant }))
        #expect(assistant.attachments?.count == 1)
        #expect(assistant.attachments?.first?.kind == .image)
    }

    @Test("Relay Image Gen On Responses Uses Inline Tool With Chat Driver")
    func relayImageGenOnResponsesUsesInlineToolWithChatDriver() async throws {
        registerAppStateSendMessageMock()
        defer {
            AppStateSendMessageURLProtocol.requestHandler = nil
            unregisterAppStateSendMessageMock()
        }

        var capturedRequest: URLRequest?
        AppStateSendMessageURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            capturedRequest = request
            return (
                appStateSendMessageHTTPResponse(
                    url: url,
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                Data("data: [DONE]\n\n".utf8)
            )
        }

        let state = makeIsolatedAppState(prefix: "relay-imagegen-responses-")
        var relayProvider = TestFactories.makeProvider(
            kind: .relay,
            models: [
                TestFactories.makeModel(
                    id: "gpt-5.4",
                    name: "gpt-5.4",
                    capabilities: [.text],
                    isDefault: true
                ),
                TestFactories.makeModel(
                    id: "gpt-image-2",
                    name: "gpt-image-2",
                    capabilities: [.text, .imageGen]
                )
            ],
            catalogModels: [],
            apiKey: "relay-key",
            apiKeyPreview: "relay...",
            baseURLText: "https://code.example.com/codex",
            customName: "Codex Relay"
        )
        relayProvider.relayRequested = RelayRequestedConfig(
            transport: .openaiResponses,
            authMode: .bearer,
            modelID: "gpt-5.4",
            stream: true
        )
        state.providers = [relayProvider]
        state.setActiveModel(providerID: relayProvider.id, modelID: "gpt-image-2")

        let conversationID = try #require(await state.sendMessage("Draw a cat", in: nil))

        try await waitUntil {
            guard let conversation = state.conversation(for: conversationID),
                  let assistant = conversation.messages.last(where: { $0.role == .assistant }) else {
                return false
            }
            return assistant.state != .generating
        }

        let request = try #require(capturedRequest)
        #expect(request.url?.path.hasSuffix("/responses") == true)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("codex_cli_rs/") == true)
        #expect(request.value(forHTTPHeaderField: "Originator") == "codex_cli_rs")

        let body = try #require(appStateSendMessageRequestBody(from: request))
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["model"] as? String == "gpt-5.4")
        let tools = payload["tools"] as? [[String: Any]] ?? []
        #expect(tools.count == 1)
        #expect(tools.first?["type"] as? String == "image_generation")
        #expect(tools.first?["model"] as? String == "gpt-image-2")
        #expect(payload["stream"] as? Bool == true)
    }

    @Test("Relay Image Gen On Anthropic Throws Friendly Error")
    func relayImageGenOnAnthropicThrowsFriendlyError() async throws {
        registerAppStateSendMessageMock()
        defer {
            AppStateSendMessageURLProtocol.requestHandler = nil
            unregisterAppStateSendMessageMock()
        }

        var requestFired = false
        AppStateSendMessageURLProtocol.requestHandler = { request in
            requestFired = true
            return (
                appStateSendMessageHTTPResponse(url: request.url!, statusCode: 500),
                Data()
            )
        }

        let state = makeIsolatedAppState(prefix: "relay-imagegen-anthropic-")
        var relayProvider = TestFactories.makeProvider(
            kind: .relay,
            models: [
                TestFactories.makeModel(
                    id: "gpt-image-2",
                    name: "gpt-image-2",
                    capabilities: [.text, .imageGen],
                    isDefault: true
                )
            ],
            catalogModels: [],
            apiKey: "relay-key",
            apiKeyPreview: "relay...",
            baseURLText: "https://claude.example.com",
            customName: "Anthropic Relay"
        )
        relayProvider.relayRequested = RelayRequestedConfig(
            transport: .anthropicMessages,
            authMode: .xApiKey,
            modelID: "gpt-image-2",
            stream: true
        )
        state.providers = [relayProvider]
        state.setActiveModel(providerID: relayProvider.id, modelID: "gpt-image-2")

        let conversationID = try #require(await state.sendMessage("Draw", in: nil))

        try await waitUntil {
            guard let conversation = state.conversation(for: conversationID),
                  let assistant = conversation.messages.last(where: { $0.role == .assistant }) else {
                return false
            }
            return assistant.state != .generating
        }

        let conversation = try #require(state.conversation(for: conversationID))
        let assistant = try #require(conversation.messages.last(where: { $0.role == .assistant }))
        #expect(assistant.state == .failed)
        #expect(requestFired == false)
    }

    @Test("Relay Stream False Uses Non Streaming Chat Completions Runtime")
    func relayStreamFalseUsesNonStreamingChatCompletionsRuntime() async throws {
        registerAppStateSendMessageMock()
        defer {
            AppStateSendMessageURLProtocol.requestHandler = nil
            unregisterAppStateSendMessageMock()
        }

        var capturedRequest: URLRequest?
        AppStateSendMessageURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            capturedRequest = request

            return (
                appStateSendMessageHTTPResponse(
                    url: url,
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"]
                ),
                Data(
                    """
                    {
                      "choices": [
                        {
                          "message": {
                            "content": "non-stream ok"
                          }
                        }
                      ],
                      "usage": {
                        "prompt_tokens": 5,
                        "completion_tokens": 2
                      }
                    }
                    """.utf8
                )
            )
        }

        let state = makeIsolatedAppState(prefix: "relay-openai-non-stream-")
        var relayProvider = TestFactories.makeProvider(
            kind: .relay,
            models: [
                TestFactories.makeModel(
                    id: "gpt-4o",
                    name: "GPT-4o",
                    capabilities: [.text],
                    isDefault: true
                )
            ],
            catalogModels: [
                TestFactories.makeModel(
                    id: "gpt-4o",
                    name: "GPT-4o",
                    capabilities: [.text],
                    isDefault: true
                )
            ],
            apiKey: "relay-key",
            apiKeyPreview: "relay...",
            baseURLText: "https://relay.example.com/v1",
            customName: "OpenAI Relay"
        )
        relayProvider.relayRequested = RelayRequestedConfig(
            transport: .openaiChatCompletions,
            authMode: .bearer,
            modelID: "gpt-4o",
            stream: false
        )
        state.providers = [relayProvider]
        state.setActiveModel(providerID: relayProvider.id, modelID: "gpt-4o")

        let conversationID = try #require(await state.sendMessage("Hello", in: nil))

        try await waitUntil {
            guard let conversation = state.conversation(for: conversationID),
                  let assistant = conversation.messages.last(where: { $0.role == .assistant }) else {
                return false
            }
            return assistant.state != .generating
        }

        let request = try #require(capturedRequest)
        let body = try #require(appStateSendMessageRequestBody(from: request))
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let conversation = try #require(state.conversation(for: conversationID))
        let assistant = try #require(conversation.messages.last(where: { $0.role == .assistant }))

        #expect(request.url?.path == "/v1/chat/completions")
        #expect(payload["stream"] as? Bool != true)
        #expect(assistant.text == "non-stream ok")
    }

    /// `BaseAPIService.performRawWithUnsupportedParamSelfHeal`("sends the production body
    /// exactly once; the runtime never pre-strips or retries after a 400").
    @Test("Relay Open AIResponses Never Downgrades Xhigh After Rejection")
    func relayOpenAIResponsesNeverDowngradesXhighAfterRejection() async throws {
        try await loadRelayReasoningEvidence()
        registerAppStateSendMessageMock()
        defer {
            AppStateSendMessageURLProtocol.requestHandler = nil
            unregisterAppStateSendMessageMock()
        }

        let lock = NSLock()
        var capturedEfforts: [String?] = []
        AppStateSendMessageURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let body = try #require(appStateSendMessageRequestBody(from: request))
            let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let reasoning = payload["reasoning"] as? [String: Any]
            let effort = reasoning?["effort"] as? String
            lock.lock()
            capturedEfforts.append(effort)
            lock.unlock()

            return (
                appStateSendMessageHTTPResponse(
                    url: url,
                    statusCode: 400,
                    headers: ["Content-Type": "application/json"]
                ),
                Data(
                    """
                    {
                      "error": {
                        "message": "xhigh is not supported"
                      }
                    }
                    """.utf8
                )
            )
        }

        let state = makeIsolatedAppState(prefix: "relay-openai-xhigh-no-downgrade-")
        var relayProvider = TestFactories.makeProvider(
            kind: .relay,
            models: [relayReasoningRetryModel()],
            catalogModels: [relayReasoningRetryModel()],
            apiKey: "relay-key",
            apiKeyPreview: "relay...",
            baseURLText: "https://relay.example.com/v1",
            customName: "OpenAI Relay"
        )
        relayProvider.relayRequested = RelayRequestedConfig(
            transport: .openaiResponses,
            authMode: .bearer,
            modelID: "gpt-5.4",
            stream: false
        )
        state.providers = [relayProvider]
        state.setActiveModel(providerID: relayProvider.id, modelID: "gpt-5.4")

        let conversationID = try #require(await state.sendMessage(
            "Need max reasoning",
            in: nil,
            capabilitySelection: ChatCapabilitySelection(
                reasoningMode: .max,
                webSearchEnabled: false
            )
        ))

        try await waitUntil {
            guard let conversation = state.conversation(for: conversationID),
                  let assistant = conversation.messages.last(where: { $0.role == .assistant }) else {
                return false
            }
            return assistant.state != .generating
        }

        let conversation = try #require(state.conversation(for: conversationID))
        let assistant = try #require(conversation.messages.last(where: { $0.role == .assistant }))

        await MetadataClient.shared.resetForTesting()
        #expect(capturedEfforts == ["xhigh"])
        #expect(assistant.state == .failed)
        #expect(!assistant.text.isEmpty)
        #expect(assistant.capabilityExecution?.recoveryDescriptors == nil)
    }

    @Test("Relay Open AIResponses Never Downgrades Xhigh After Rate Limit Mapping")
    func relayOpenAIResponsesNeverDowngradesXhighAfterRateLimitMapping() async throws {
        try await loadRelayReasoningEvidence()
        registerAppStateSendMessageMock()
        defer {
            AppStateSendMessageURLProtocol.requestHandler = nil
            unregisterAppStateSendMessageMock()
        }

        let lock = NSLock()
        var capturedEfforts: [String?] = []
        AppStateSendMessageURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let body = try #require(appStateSendMessageRequestBody(from: request))
            let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let reasoning = payload["reasoning"] as? [String: Any]
            let effort = reasoning?["effort"] as? String
            lock.lock()
            capturedEfforts.append(effort)
            lock.unlock()

            return (
                appStateSendMessageHTTPResponse(
                    url: url,
                    statusCode: 429,
                    headers: ["Content-Type": "application/json"]
                ),
                Data(
                    """
                    {
                      "error": {
                        "message": "xhigh is not supported yet"
                      }
                    }
                    """.utf8
                )
            )
        }

        let state = makeIsolatedAppState(prefix: "relay-openai-xhigh-429-no-downgrade-")
        var relayProvider = TestFactories.makeProvider(
            kind: .relay,
            models: [relayReasoningRetryModel()],
            catalogModels: [relayReasoningRetryModel()],
            apiKey: "relay-key",
            apiKeyPreview: "relay...",
            baseURLText: "https://relay.example.com/v1",
            customName: "OpenAI Relay"
        )
        relayProvider.relayRequested = RelayRequestedConfig(
            transport: .openaiResponses,
            authMode: .bearer,
            modelID: "gpt-5.4",
            stream: false
        )
        state.providers = [relayProvider]
        state.setActiveModel(providerID: relayProvider.id, modelID: "gpt-5.4")

        let conversationID = try #require(await state.sendMessage(
            "Need max reasoning",
            in: nil,
            capabilitySelection: ChatCapabilitySelection(
                reasoningMode: .max,
                webSearchEnabled: false
            )
        ))

        try await waitUntil {
            guard let conversation = state.conversation(for: conversationID),
                  let assistant = conversation.messages.last(where: { $0.role == .assistant }) else {
                return false
            }
            return assistant.state != .generating
        }

        let conversation = try #require(state.conversation(for: conversationID))
        let assistant = try #require(conversation.messages.last(where: { $0.role == .assistant }))

        await MetadataClient.shared.resetForTesting()
        #expect(capturedEfforts == ["xhigh"])
        #expect(assistant.state == .failed)
        #expect(!assistant.text.isEmpty)
        #expect(assistant.capabilityExecution?.recoveryDescriptors == nil)
    }

    @Test("Relay Local Reasoning Mapping Reaches The Wire")
    func relayLocalReasoningMappingReachesTheWire() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-08-09T00:00:00Z",
          "profiles": {
            "reasoning": {},
            "webSearch": {},
            "imageGen": {}
          },
          "providers": {}
        }
        """, metadataETag: "relay-local-mapping-etag")
        registerAppStateSendMessageMock()
        defer {
            AppStateSendMessageURLProtocol.requestHandler = nil
            unregisterAppStateSendMessageMock()
        }

        let lock = NSLock()
        var capturedPayloads: [[String: Any]] = []
        AppStateSendMessageURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let body = try #require(appStateSendMessageRequestBody(from: request))
            let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            lock.lock()
            capturedPayloads.append(payload)
            lock.unlock()

            return (
                appStateSendMessageHTTPResponse(
                    url: url,
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"]
                ),
                Data(
                    """
                    {
                      "output_text": "local mapping ok",
                      "usage": { "input_tokens": 3, "output_tokens": 2 }
                    }
                    """.utf8
                )
            )
        }

        let localModel = TestFactories.makeModel(
            id: "local-reasoner",
            name: "Local Reasoner",
            capabilities: [.text, .reasoning],
            reasoningModeAvailable: true,
            isDefault: true
        )
        let state = makeIsolatedAppState(prefix: "relay-local-reasoning-wire-")
        var relayProvider = TestFactories.makeProvider(
            kind: .relay,
            models: [localModel],
            catalogModels: [localModel],
            apiKey: "relay-key",
            apiKeyPreview: "relay...",
            baseURLText: "https://relay.example.com/v1",
            customName: "OpenAI Relay"
        )
        relayProvider.relayRequested = RelayRequestedConfig(
            transport: .openaiResponses,
            authMode: .bearer,
            modelID: "local-reasoner",
            stream: false
        )
        state.providers = [relayProvider]
        state.setActiveModel(providerID: relayProvider.id, modelID: "local-reasoner")

        let conversationID = try #require(await state.sendMessage(
            "Think deeply",
            in: nil,
            capabilitySelection: ChatCapabilitySelection(
                reasoningMode: .deep,
                webSearchEnabled: false
            )
        ))

        try await waitUntil {
            guard let conversation = state.conversation(for: conversationID),
                  let assistant = conversation.messages.last(where: { $0.role == .assistant }) else {
                return false
            }
            return assistant.state != .generating
        }

        let conversation = try #require(state.conversation(for: conversationID))
        let assistant = try #require(conversation.messages.last(where: { $0.role == .assistant }))

        lock.lock()
        let payloads = capturedPayloads
        lock.unlock()
        await MetadataClient.shared.resetForTesting()

        #expect(payloads.count == 1)
        let payload = try #require(payloads.first)
        let reasoning = try #require(
            payload["reasoning"] as? [String: Any],
            "When the user picks Deep Thinking, the final request body must actually contain a reasoning section"
        )
        #expect(reasoning["effort"] as? String == "high")
        #expect(assistant.text == "local mapping ok")
        #expect(assistant.state == .delivered)
    }
}
