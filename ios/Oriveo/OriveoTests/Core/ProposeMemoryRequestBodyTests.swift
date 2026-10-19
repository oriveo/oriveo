import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Intercepts the request body the official builder actually sends (the official builder is private, reachable only through sendMessage).
private final class ProposeBodyURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodies: [[String: Any]] = []
    private static let lock = NSLock()

    static func reset() { lock.withLock { bodies = [] } }
    static func snapshot() -> [[String: Any]] { lock.withLock { bodies } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&chunk, maxLength: chunk.count)
                if read <= 0 { break }
                buffer.append(chunk, count: read)
            }
            data = buffer
        }
        if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            Self.lock.withLock { Self.bodies.append(json) }
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// When an ordinary chat request carries a client tool (propose_memory), the tools / tool_choice of each protocol's request body
/// have the same shape as the projections of fixture `memory-propose.v2.json`; without it there is no tools key.
@Suite("Propose memory request body (client tools injection)", .serialized)
struct ProposeMemoryRequestBodyTests {

    // MARK: Fixtures and shared builders

    private static func proposeFixture() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/context-contracts/memory-propose.v2.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func projection(_ key: String) throws -> NSArray {
        let projections = try #require(try proposeFixture()["projections"] as? [String: Any])
        return try #require(projections[key] as? NSArray, "\(key)")
    }

    private static func toolOptions(_ choice: ClientToolChoice = .auto) throws -> ChatRequestOptions {
        var options = ChatRequestOptions()
        options.clientTools = [try JSONDecoder().decode(ToolLoopToolDefinition.self, from: Data(MemoryPropose.toolJSON.utf8))]
        options.clientToolChoice = choice
        return options
    }

    private static func message(_ kind: ProviderKind) -> ChatMessage {
        ChatMessage(
            id: UUID(), role: .user, text: "\u{8BB0}\u{4F4F}\u{6211}\u{559C}\u{6B22}\u{7B80}\u{6D01}\u{56DE}\u{7B54}",
            providerKind: kind, providerName: kind.rawValue, modelName: "m", state: .delivered
        )
    }

    private static func json(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProposeBodyURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// The last tools entry (count = projection length) equals the fixture projection; the existing tools before it are kept as is.
    private static func expectTrailingProjection(
        _ body: [String: Any], _ key: String, preceding: NSArray = []
    ) throws {
        let expected = try projection(key)
        let tools = try #require(body["tools"] as? [Any], "\(key): tools missing in \(body.keys.sorted())")
        #expect(tools.count == preceding.count + expected.count, "\(key): \(tools)")
        let tail = Array(tools.suffix(expected.count)) as NSArray
        #expect(tail.isEqual(expected), "\(key): \(tail)")
        let head = Array(tools.prefix(preceding.count)) as NSArray
        #expect(head.isEqual(preceding), "\(key): \(head)")
    }

    private static func expectNoTools(_ body: [String: Any]) {
        #expect(body["tools"] == nil)
        #expect(body["tool_choice"] == nil)
        #expect(body["toolConfig"] == nil)
    }

    private static func capture(_ run: () async throws -> Void) async throws -> [String: Any] {
        ProposeBodyURLProtocol.reset()
        try? await run()
        return try #require(ProposeBodyURLProtocol.snapshot().first, "no request captured")
    }

    private static func loadOpenAIResponsesMetadata() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-10-17T00:00:00Z",
          "providers": {
            "openAI": {
              "transport": {
                "baseUrl": "https://api.openai.com/v1",
                "endpoints": { "chat": "/chat/completions", "responses": "/responses" }
              },
              "resolveMap": { "gpt-resp-fixture": "gpt-resp-fixture" },
              "models": {
                "gpt-resp-fixture": {
                  "canonicalModelId": "gpt-resp-fixture",
                  "capabilities": ["text"],
                  "transport": "openai_responses"
                }
              }
            }
          }
        }
        """)
    }

    // MARK: OpenAI Chat Completions (official)

    @Test func openai_chat_official_carries_projection() async throws {
        await MetadataClient.shared.resetForTesting()
        let options = try Self.toolOptions()
        let body = try await Self.capture {
            _ = try await OpenAIService(session: Self.session()).sendMessage(
                apiKey: "sk-test", modelID: "gpt-chat-fixture",
                messages: [Self.message(.openAI)], requestOptions: options
            )
        }
        try Self.expectTrailingProjection(body, "openai_chat")
        #expect(body["tool_choice"] as? String == "auto")
    }

    @Test func openai_chat_official_without_tools_has_no_tools_key() async throws {
        await MetadataClient.shared.resetForTesting()
        let body = try await Self.capture {
            _ = try await OpenAIService(session: Self.session()).sendMessage(
                apiKey: "sk-test", modelID: "gpt-chat-fixture", messages: [Self.message(.openAI)]
            )
        }
        Self.expectNoTools(body)
    }

    // MARK: OpenAI Responses (official / Codex subscription / Relay)

    @Test func openai_responses_official_carries_projection() async throws {
        try await Self.loadOpenAIResponsesMetadata()
        let options = try Self.toolOptions()
        let body = try await Self.capture {
            _ = try await OpenAIService(session: Self.session()).sendMessage(
                apiKey: "sk-test", modelID: "gpt-resp-fixture",
                messages: [Self.message(.openAI)], requestOptions: options
            )
        }
        await MetadataClient.shared.resetForTesting()
        #expect(body["input"] != nil)
        try Self.expectTrailingProjection(body, "openai_responses")
        #expect(body["tool_choice"] as? String == "auto")
    }

    @Test func openai_responses_official_without_tools_has_no_tools_key() async throws {
        try await Self.loadOpenAIResponsesMetadata()
        let body = try await Self.capture {
            _ = try await OpenAIService(session: Self.session()).sendMessage(
                apiKey: "sk-test", modelID: "gpt-resp-fixture", messages: [Self.message(.openAI)]
            )
        }
        await MetadataClient.shared.resetForTesting()
        #expect(body["input"] != nil)
        Self.expectNoTools(body)
    }

    private static func codexOptions(_ base: ChatRequestOptions, web: Bool) -> ChatRequestOptions {
        var options = base
        options.capabilityEvidenceModel = TestFactories.makeModel(
            id: "gpt-5.6-sol", capabilities: web ? [.text, .web] : [.text]
        )
        options.openAISubscription = OpenAISubscriptionRequestContext(
            responsesURL: URL(string: "https://chatgpt.com/backend-api/codex/responses")!,
            accountID: "acct-1",
            requiredHeaders: [:]
        )
        return options
    }

    private static func drain(_ stream: AsyncThrowingStream<StreamEvent, Error>) async {
        do { for try await _ in stream {} } catch {}
    }

    @Test func codex_subscription_appends_projection_after_server_tools() async throws {
        let options = Self.codexOptions(try Self.toolOptions(), web: true)
        let body = try await Self.capture {
            await Self.drain(OpenAIService(session: Self.session()).sendMessageStream(
                apiKey: "codex-token", modelID: "gpt-5.6-sol", messages: [Self.message(.openAI)],
                reasoningMode: .automatic, webSearchEnabled: true, requestOptions: options
            ))
        }
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.first?["type"] as? String == "web_search", "\(tools)")
        try Self.expectTrailingProjection(body, "openai_responses", preceding: [tools[0]] as NSArray)
        #expect(body["tool_choice"] as? String == "auto")
    }

    @Test func codex_subscription_without_tools_has_no_tools_key() async throws {
        let options = Self.codexOptions(ChatRequestOptions(), web: false)
        let body = try await Self.capture {
            await Self.drain(OpenAIService(session: Self.session()).sendMessageStream(
                apiKey: "codex-token", modelID: "gpt-5.6-sol", messages: [Self.message(.openAI)],
                reasoningMode: .automatic, webSearchEnabled: false, requestOptions: options
            ))
        }
        Self.expectNoTools(body)
    }

    @Test func relay_responses_appends_projection_after_existing_tools() throws {
        let existing: [Any] = [["type": "function", "name": "library_search", "parameters": ["type": "object"]]]
        let request = try OpenAIService().buildRelayResponsesRequest(
            modelID: "relay-model", messages: [Self.message(.relay)], apiKey: "sk-test",
            baseURL: "https://relay.example.com", stream: true, reasoningMode: .automatic,
            requestOptions: try Self.toolOptions(), relayRequested: RelayRequestedConfig(transport: .openaiResponses),
            functionTools: existing
        )
        let body = try Self.json(request)
        try Self.expectTrailingProjection(body, "openai_responses", preceding: existing as NSArray)
        #expect(body["tool_choice"] as? String == "auto")
    }

    @Test func relay_responses_without_tools_has_no_tools_key() throws {
        let request = try OpenAIService().buildRelayResponsesRequest(
            modelID: "relay-model", messages: [Self.message(.relay)], apiKey: "sk-test",
            baseURL: "https://relay.example.com", stream: true, reasoningMode: .automatic,
            relayRequested: RelayRequestedConfig(transport: .openaiResponses),
            // Turn off the builder's own image_generation server tool so "no client tool means no tools key" is visible.
            removeTools: true
        )
        Self.expectNoTools(try Self.json(request))
    }

    @Test func relay_chat_completions_carries_projection_and_choice_none() throws {
        let request = try OpenAIService().buildChatCompletionsRequest(
            modelID: "relay-model", messages: [Self.message(.relay)], apiKey: "sk-test", stream: true,
            baseURL: "https://relay.example.com", reasoningMode: .automatic,
            requestOptions: try Self.toolOptions(.none), relayRequested: RelayRequestedConfig(transport: .openaiChatCompletions)
        )
        let body = try Self.json(request)
        try Self.expectTrailingProjection(body, "openai_chat")
        #expect(body["tool_choice"] as? String == "none")
    }

    @Test func relay_chat_completions_without_tools_has_no_tools_key() throws {
        let request = try OpenAIService().buildChatCompletionsRequest(
            modelID: "relay-model", messages: [Self.message(.relay)], apiKey: "sk-test", stream: true,
            baseURL: "https://relay.example.com", reasoningMode: .automatic,
            relayRequested: RelayRequestedConfig(transport: .openaiChatCompletions)
        )
        Self.expectNoTools(try Self.json(request))
    }

    // MARK: Anthropic (official / Relay)

    @Test func anthropic_official_carries_projection() async throws {
        await MetadataClient.shared.resetForTesting()
        let options = try Self.toolOptions()
        let body = try await Self.capture {
            _ = try await AnthropicService(session: Self.session()).sendMessage(
                apiKey: "sk-ant-test", modelID: "claude-fixture",
                messages: [Self.message(.anthropic)], requestOptions: options
            )
        }
        try Self.expectTrailingProjection(body, "anthropic_messages")
        #expect((body["tool_choice"] as? [String: Any])?["type"] as? String == "auto")
    }

    @Test func anthropic_official_without_tools_has_no_tools_key() async throws {
        await MetadataClient.shared.resetForTesting()
        let body = try await Self.capture {
            _ = try await AnthropicService(session: Self.session()).sendMessage(
                apiKey: "sk-ant-test", modelID: "claude-fixture", messages: [Self.message(.anthropic)]
            )
        }
        Self.expectNoTools(body)
    }

    @Test func anthropic_relay_carries_projection() throws {
        let request = try AnthropicService().buildRelayMessagesRequest(
            modelID: "relay-model", messages: [Self.message(.relay)], apiKey: "sk-test",
            baseURL: "https://relay.example.com", stream: true, reasoningMode: .automatic,
            requestOptions: try Self.toolOptions(), relayRequested: RelayRequestedConfig(transport: .anthropicMessages)
        )
        let body = try Self.json(request)
        try Self.expectTrailingProjection(body, "anthropic_messages")
        #expect((body["tool_choice"] as? [String: Any])?["type"] as? String == "auto")
    }

    @Test func anthropic_relay_without_tools_has_no_tools_key() throws {
        let request = try AnthropicService().buildRelayMessagesRequest(
            modelID: "relay-model", messages: [Self.message(.relay)], apiKey: "sk-test",
            baseURL: "https://relay.example.com", stream: true, reasoningMode: .automatic,
            relayRequested: RelayRequestedConfig(transport: .anthropicMessages)
        )
        Self.expectNoTools(try Self.json(request))
    }

    // MARK: Gemini generateContent (official / Relay)

    @Test func gemini_official_carries_projection() async throws {
        await MetadataClient.shared.resetForTesting()
        let options = try Self.toolOptions()
        let body = try await Self.capture {
            _ = try await GeminiService(session: Self.session()).sendMessage(
                apiKey: "gem-key", modelID: "gemini-fixture",
                messages: [Self.message(.gemini)], requestOptions: options
            )
        }
        try Self.expectTrailingProjection(body, "gemini_generate")
        let config = (body["toolConfig"] as? [String: Any])?["functionCallingConfig"] as? [String: Any]
        #expect(config?["mode"] as? String == "AUTO")
    }

    @Test func gemini_official_without_tools_has_no_tools_key() async throws {
        await MetadataClient.shared.resetForTesting()
        let body = try await Self.capture {
            _ = try await GeminiService(session: Self.session()).sendMessage(
                apiKey: "gem-key", modelID: "gemini-fixture", messages: [Self.message(.gemini)]
            )
        }
        Self.expectNoTools(body)
    }

    @Test func gemini_relay_carries_projection() throws {
        let request = try GeminiService().buildRelayGenerateContentRequest(
            modelID: "relay-model", messages: [Self.message(.relay)], apiKey: "sk-test",
            baseURL: "https://relay.example.com", stream: false, reasoningMode: .automatic,
            supportsImageGen: false, requestOptions: try Self.toolOptions(),
            relayRequested: RelayRequestedConfig(transport: .geminiGenerateContent)
        )
        let body = try Self.json(request)
        try Self.expectTrailingProjection(body, "gemini_generate")
        let config = (body["toolConfig"] as? [String: Any])?["functionCallingConfig"] as? [String: Any]
        #expect(config?["mode"] as? String == "AUTO")
    }

    @Test func gemini_relay_without_tools_has_no_tools_key() throws {
        let request = try GeminiService().buildRelayGenerateContentRequest(
            modelID: "relay-model", messages: [Self.message(.relay)], apiKey: "sk-test",
            baseURL: "https://relay.example.com", stream: false, reasoningMode: .automatic,
            supportsImageGen: false, relayRequested: RelayRequestedConfig(transport: .geminiGenerateContent)
        )
        Self.expectNoTools(try Self.json(request))
    }

    // MARK: OpenAI-compatible providers (encodeChatBody funnel)

    @Test func encode_chat_body_carries_projection_for_compatible_providers() throws {
        var body: [String: Any] = ["model": "m", "messages": [["role": "user", "content": "hi"]]]
        let data = try BaseAPIService().encodeChatBody(&body, options: try Self.toolOptions(), resolved: nil)
        let encoded = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        try Self.expectTrailingProjection(encoded, "openai_chat")
        #expect(encoded["tool_choice"] as? String == "auto")

        var plain: [String: Any] = ["model": "m", "messages": [["role": "user", "content": "hi"]]]
        let plainData = try BaseAPIService().encodeChatBody(&plain, options: ChatRequestOptions(), resolved: nil)
        let plainEncoded = try #require(try JSONSerialization.jsonObject(with: plainData) as? [String: Any])
        Self.expectNoTools(plainEncoded)
    }

    @Test func encode_chat_body_uses_responses_projection_for_input_bodies() throws {
        var body: [String: Any] = ["model": "grok", "input": [["role": "user", "content": "hi"]]]
        let data = try BaseAPIService().encodeChatBody(&body, options: try Self.toolOptions(), resolved: nil)
        let encoded = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        try Self.expectTrailingProjection(encoded, "openai_responses")
    }

    // MARK: search_memory (memory-search.v1 projections; legRules 1: placed after propose_memory)

    private static func searchFixture() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/context-contracts/memory-search.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func searchProjection(_ key: String) throws -> NSArray {
        let projections = try #require(try searchFixture()["projections"] as? [String: Any])
        return try #require(projections[key] as? NSArray, "\(key)")
    }

    @Test func search_tool_projections_match_fixture() throws {
        let projections = try #require(try Self.searchFixture()["projections"] as? [String: Any])
        let definition = try #require(SearchMemoryEntry.toolDefinition)
        let adapters: [(String, any ToolProtocolAdapter)] = [
            ("openai_chat", OpenAIChatToolAdapter()),
            ("openai_responses", OpenAIResponsesToolAdapter()),
            ("anthropic_messages", AnthropicToolAdapter()),
            ("gemini_generate", GeminiToolAdapter()),
        ]
        #expect(Set(projections.keys) == Set(adapters.map(\.0)))
        for (key, adapter) in adapters {
            let actual = try adapter.encodeTools([definition]) as NSArray
            #expect(actual.isEqual(try Self.searchProjection(key)), "\(key): \(actual)")
        }
    }

    /// Request body produced by the production send path: host tools = propose first, search after, both projections identical item by item to the fixtures.
    @Test func openai_chat_official_carries_propose_then_search() async throws {
        await MetadataClient.shared.resetForTesting()
        var options = try Self.toolOptions()
        options.clientTools.append(try #require(SearchMemoryEntry.toolDefinition))
        let body = try await Self.capture {
            _ = try await OpenAIService(session: Self.session()).sendMessage(
                apiKey: "sk-test", modelID: "gpt-chat-fixture",
                messages: [Self.message(.openAI)], requestOptions: options
            )
        }
        let tools = try #require(body["tools"] as? [Any])
        let expected = (try Self.projection("openai_chat") as! [Any]) + (try Self.searchProjection("openai_chat") as! [Any])
        #expect((tools as NSArray).isEqual(expected as NSArray), "\(tools)")
        #expect(body["tool_choice"] as? String == "auto")
    }
}
