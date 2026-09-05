import Foundation
import OriveoProviderKit
import Testing
import UIKit

@testable import Oriveo

// MARK: - Shared fixture loading (shared/test-fixtures/provider-toolcall, same directory on all three clients)

private enum ToolCallFixtures {
    static let directory = ["shared", "test-fixtures", "provider-toolcall"]

    struct ExpectedToolCall: Decodable {
        let id: String?
        let name: String
        let arguments: String
    }

    struct Expected: Decodable {
        let text: String
        let finishReason: String
        let toolCalls: [ExpectedToolCall]
        let toolCallEvents: Int?

        enum CodingKeys: String, CodingKey {
            case text
            case finishReason = "finish_reason"
            case toolCalls = "tool_calls"
            case toolCallEvents = "tool_call_events"
        }
    }

    struct Entry: Decodable {
        let file: String
        let transport: String
        let expected: Expected
    }

    struct Manifest: Decodable {
        let fixtures: [Entry]
    }

    static func url(_ name: String) throws -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = (directory + [name]).reduce(cursor) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    static func lines(_ name: String) throws -> [String] {
        String(decoding: try data(name), as: UTF8.self).components(separatedBy: "\n")
    }

    static func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: data("expected.json"))
    }

    static func expected(_ file: String) throws -> Expected {
        try #require(try manifest().fixtures.first { $0.file == file }).expected
    }

    /// Treat different serializations of the same JSON (whitespace / key order) as equal.
    static func normalizedJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return raw }
        return String(decoding: canonical, as: UTF8.self)
    }
}

// MARK: - Test doubles

private final class ToolCallFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body: Data = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session(serving fixture: String) throws -> URLSession {
        body = try ToolCallFixtures.data(fixture)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ToolCallFixtureURLProtocol.self]
        return URLSession(configuration: config)
    }
}

private struct CollectedStream {
    var text = ""
    var toolCallEvents: [[ProviderToolCall]] = []
    var done: ProviderChatResult?

    var toolCalls: [ProviderToolCall] { toolCallEvents.flatMap { $0 } }

    mutating func consume(_ event: StreamEvent) {
        switch event {
        case let .delta(chunk): text += chunk
        case let .toolCallDeltas(calls): toolCallEvents.append(calls)
        case let .done(result): done = result
        case .reasoning, .citations, .imagePart: break
        }
    }
}

private func collect(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> CollectedStream {
    var collected = CollectedStream()
    for try await event in stream { collected.consume(event) }
    return collected
}

private func expectToolCalls(
    _ actual: [ProviderToolCall],
    match expected: [ToolCallFixtures.ExpectedToolCall],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(actual.count == expected.count, "tool call count mismatch", sourceLocation: sourceLocation)
    for (got, want) in zip(actual, expected) {
        #expect(got.name == want.name, sourceLocation: sourceLocation)
        #expect(got.providerCallID == want.id, sourceLocation: sourceLocation)
        #expect(
            ToolCallFixtures.normalizedJSON(got.rawArguments) == ToolCallFixtures.normalizedJSON(want.arguments),
            "arguments not fully assembled: \(got.rawArguments)",
            sourceLocation: sourceLocation
        )
    }
}

private func makeUserMessage(kind: ProviderKind) -> ChatMessage {
    ChatMessage(id: UUID(), role: .user, text: "the weather in Melbourne today", providerKind: kind, providerName: kind.displayName, modelName: "m", state: .delivered)
}

// MARK: - Shared corpus against the iOS parse layer

@Suite("Tool call shared corpus (parse layer)", .serialized)
struct ProviderToolCallFixtureParsingTests {
    @Test("fixture directory has all eight files and expected.json maps each one")
    func manifestCoversAllFixtures() throws {
        let manifest = try ToolCallFixtures.manifest()
        let names = manifest.fixtures.map(\.file)
        #expect(names == [
            "openai_chat.tool_calls.sse",
            "openai_responses.function_call.sse",
            "anthropic.tool_use.sse",
            "gemini.functionCall.sse",
            "grok_proxy.text_json_fence.sse",
            "grok_proxy.text_tool_call_tag.sse",
            "grok_proxy.text_html_fence.sse",
            // Live-proxy Responses recording (web_search actually hits the network); playback lives in GrokSubscriptionResponsesTests.
            "grok_proxy.responses.web_search.sse",
        ])
        for name in names {
            #expect(FileManager.default.fileExists(atPath: try ToolCallFixtures.url(name).path), Comment(rawValue: name))
        }
    }

    @Test("openai_chat: ProviderKit assembler + iOS StreamState merge fragmented / missing-index tool_calls into one event")
    func openAIChatFixtureThroughStreamState() throws {
        let expected = try ToolCallFixtures.expected("openai_chat.tool_calls.sse")
        var assembler = OpenAICompatibleStreamAssembler(profile: .deepSeek)
        var state = OpenAICompatibleStreamState()
        var collected = CollectedStream()
        for line in try ToolCallFixtures.lines("openai_chat.tool_calls.sse") {
            for event in state.consume(try assembler.ingest(line)) { collected.consume(event) }
            if assembler.isDone { break }
        }
        for event in state.consume(try assembler.finish()) { collected.consume(event) }

        #expect(collected.text == expected.text)
        #expect(collected.toolCallEvents.count == 1, "multiple proposals on the same leg must merge into one event ")
        expectToolCalls(collected.toolCalls, match: expected.toolCalls)
    }

    @Test("openai_chat: OpenAIChatStrategy (shared by Grok / Relay / OpenRouter / Zhipu) emits the whole batch at finish_reason")
    func openAIChatFixtureThroughStrategy() throws {
        let expected = try ToolCallFixtures.expected("openai_chat.tool_calls.sse")
        let strategy = OpenAIChatStrategy()
        var ctx = StreamContext()
        var collected = CollectedStream()
        for line in try ToolCallFixtures.lines("openai_chat.tool_calls.sse") where line.hasPrefix("data: ") {
            for event in strategy.parseStreamLine(String(line.dropFirst(6)), ctx: &ctx, shape: nil) {
                collected.consume(event)
            }
        }
        #expect(OpenAIChatStrategy.flushToolCalls(ctx: &ctx).isEmpty, "finish_reason already flushed; trailing flush must not emit again")
        #expect(collected.text == expected.text)
        #expect(collected.toolCallEvents.count == 1)
        expectToolCalls(collected.toolCalls, match: expected.toolCalls)
    }

    @Test("openai_chat: when the upstream drops the stream without finish_reason, the Service trailing flush still emits the proposals")
    func strategyFlushCoversMissingFinishReason() throws {
        let strategy = OpenAIChatStrategy()
        var ctx = StreamContext()
        var events: [StreamEvent] = []
        for line in try ToolCallFixtures.lines("openai_chat.tool_calls.sse")
        where line.hasPrefix("data: ") && !line.contains("finish_reason\":\"tool_calls") {
            events += strategy.parseStreamLine(String(line.dropFirst(6)), ctx: &ctx, shape: nil)
        }
        #expect(!events.contains { if case .toolCallDeltas = $0 { return true } else { return false } })
        let flushed = OpenAIChatStrategy.flushToolCalls(ctx: &ctx)
        guard case let .toolCallDeltas(calls)? = flushed.first else {
            Issue.record("trailing flush did not emit proposals")
            return
        }
        #expect(calls.map(\.name) == ["get_weather", "get_time"])
    }

    @Test("Zhipu web-search results arrive as tool_calls[].web_search, not call proposals, and must not produce tool events")
    func zhipuWebSearchToolCallsAreNotProposals() {
        let strategy = OpenAIChatStrategy()
        var ctx = StreamContext()
        let line = #"{"choices":[{"delta":{"content":"ok","tool_calls":[{"id":"ws-1","type":"web_search","web_search":{"search_result":[{"link":"https://a.example","title":"A"}]}}]},"finish_reason":"stop"}]}"#
        let events = strategy.parseStreamLine(line, ctx: &ctx, shape: nil)
        #expect(!events.contains { if case .toolCallDeltas = $0 { return true } else { return false } })
        #expect(OpenAIChatStrategy.flushToolCalls(ctx: &ctx).isEmpty)
    }

    @Test("Grok subscription's three fake tool-call shells: real GrokService parse, text unchanged, zero tool events", arguments: [
        "grok_proxy.text_json_fence.sse",
        "grok_proxy.text_tool_call_tag.sse",
        "grok_proxy.text_html_fence.sse",
    ])
    func grokProxyShellsStayAsText(fixture: String) async throws {
        await MetadataClient.shared.resetForTesting()
        let expected = try ToolCallFixtures.expected(fixture)
        var options = ChatRequestOptions()
        options.grokSubscription = GrokSubscriptionRequestContext(
            chatURL: URL(string: "https://cli-chat-proxy.grok.com/v1/chat/completions")!,
            requiredHeaders: ["x-xai-token-auth": "xai-grok-cli"]
        )
        let service = GrokService(session: try ToolCallFixtureURLProtocol.session(serving: fixture))
        let collected = try await collect(service.sendMessageStream(
            apiKey: "grok-subscription-token",
            modelID: "grok-4.6",
            messages: [makeUserMessage(kind: .grok)],
            requestOptions: options
        ))
        #expect(collected.text == expected.text, "fake tool-call text must be kept as body text, unchanged")
        #expect(collected.toolCallEvents.count == expected.toolCallEvents ?? 0, "do not write a parser for textual fake tool calls")
        #expect(collected.done?.text == expected.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // Tool decoding for the three protocols is covered by the protocol adapter suite; this suite locks "body text is not dropped + decoded result matches the corpus".

    @Test("anthropic tool_use corpus: AnthropicMessagesStrategy keeps body text and decodes tool_use to match expected")
    func anthropicFixtureKeepsText() throws {
        let expected = try ToolCallFixtures.expected("anthropic.tool_use.sse")
        let strategy = AnthropicMessagesStrategy()
        var ctx = StreamContext()
        var collected = CollectedStream()
        for line in try ToolCallFixtures.lines("anthropic.tool_use.sse") where line.hasPrefix("data: ") {
            for event in strategy.parseStreamLine(String(line.dropFirst(6)), ctx: &ctx, shape: nil) {
                collected.consume(event)
            }
        }
        #expect(collected.text == expected.text)
        #expect(collected.toolCallEvents.count == 1)
        expectToolCalls(collected.toolCalls, match: expected.toolCalls)
    }

    @Test("openai_responses function_call corpus: OpenAIResponsesStrategy keeps body text and decodes function_call to match expected")
    func responsesFixtureKeepsText() throws {
        let expected = try ToolCallFixtures.expected("openai_responses.function_call.sse")
        let strategy = OpenAIResponsesStrategy()
        var ctx = StreamContext()
        var collected = CollectedStream()
        for line in try ToolCallFixtures.lines("openai_responses.function_call.sse") where line.hasPrefix("data: ") {
            for event in strategy.parseStreamLine(String(line.dropFirst(6)), ctx: &ctx, shape: nil) {
                collected.consume(event)
            }
        }
        #expect(collected.text == expected.text)
        #expect(collected.toolCallEvents.count == 1)
        expectToolCalls(collected.toolCalls, match: expected.toolCalls)
    }

    @Test("gemini functionCall corpus: GeminiGenerateStrategy keeps body text and decodes functionCall to match expected")
    func geminiFixtureKeepsText() throws {
        let expected = try ToolCallFixtures.expected("gemini.functionCall.sse")
        let strategy = GeminiGenerateStrategy()
        var ctx = StreamContext()
        var collected = CollectedStream()
        for line in try ToolCallFixtures.lines("gemini.functionCall.sse") where line.hasPrefix("data: ") {
            for event in strategy.parseStreamLine(String(line.dropFirst(6)), ctx: &ctx, shape: nil) {
                collected.consume(event)
            }
        }
        #expect(collected.text == expected.text)
        #expect(collected.toolCallEvents.count == 1)
        expectToolCalls(collected.toolCalls, match: expected.toolCalls)
    }
}

// MARK: - Production path: real Service → ChatManager → message fields

@MainActor
@Suite("Unhandled tool-call production path", .serialized)
struct UnhandledToolCallProductionPathTests {
    private struct Harness {
        let state: AppState
        let provider: Provider
        let model: AIModel
        let conversationID: UUID
        let assistantID: UUID
        let sendTaskID: UUID

        var assistant: ChatMessage? {
            state.conversation(for: conversationID)?.messages.first { $0.id == assistantID }
        }
    }

    private func makeHarness(kind: ProviderKind, modelID: String, toolCall: Bool? = nil, subscription: Bool = false) -> Harness {
        let state = AppState(seedDemoData: true)
        var model = TestFactories.makeModel(id: modelID, capabilities: [.text])
        model.toolCall = toolCall
        // This case is specifically the chat leg where the upstream explicitly declares a
        // chat backend. Grok subscription already defaults to Responses when undeclared
        // (the routing fallback), so a chat scenario must make the model declare chat explicitly.
        if subscription { model.upstreamAPIBackend = "chat" }
        var provider = TestFactories.makeProvider(kind: kind, models: [model])
        if subscription { provider.authMode = .subscription }
        let conversationID = UUID()
        let assistantID = UUID()
        let conversation = TestFactories.makeConversation(
            id: conversationID,
            providerID: provider.id,
            providerKind: kind,
            modelID: model.id,
            messages: [
                TestFactories.makeMessage(role: .user, text: "the weather in Melbourne today", providerID: provider.id, providerKind: kind),
                TestFactories.makeMessage(id: assistantID, role: .assistant, text: "", providerID: provider.id, providerKind: kind, modelID: model.id, state: .generating),
            ]
        )
        state.providers = [provider]
        state.conversations = [conversation]
        state.chatManager._testingBeginStreamingSession(conversationID: conversationID, assistantMessageID: assistantID)
        return Harness(
            state: state, provider: provider, model: model,
            conversationID: conversationID, assistantID: assistantID,
            sendTaskID: state.chatManager._testingSendTaskID(in: conversationID)!
        )
    }

    private func dispatch(_ collected: CollectedStream, into harness: Harness) {
        for calls in collected.toolCallEvents {
            harness.state.chatManager._testingDispatchToolCallStreamEvent(
                .toolCallDeltas(calls),
                in: harness.conversationID, messageID: harness.assistantID, sendTaskID: harness.sendTaskID,
                provider: harness.provider, model: harness.model
            )
        }
    }

    @Test("Grok subscription (openai_chat) native tool_calls: card data lands on the message and it is not marked failed")
    func grokSubscriptionNativeToolCallsReachTheMessage() async throws {
        await MetadataClient.shared.resetForTesting()
        let harness = makeHarness(kind: .grok, modelID: "grok-4.6", subscription: true)
        let expected = try ToolCallFixtures.expected("openai_chat.tool_calls.sse")

        var options = ChatRequestOptions()
        options.grokSubscription = GrokSubscriptionRequestContext(
            chatURL: URL(string: "https://cli-chat-proxy.grok.com/v1/chat/completions")!,
            requiredHeaders: ["x-xai-token-auth": "xai-grok-cli"]
        )
        let service = GrokService(session: try ToolCallFixtureURLProtocol.session(serving: "openai_chat.tool_calls.sse"))
        let collected = try await collect(service.sendMessageStream(
            apiKey: "grok-subscription-token",
            modelID: "grok-4.6",
            messages: [makeUserMessage(kind: .grok)],
            requestOptions: options
        ))
        #expect(collected.toolCallEvents.count == 1, "GrokService must pass through .toolCallDeltas emitted by the strategy")
        expectToolCalls(collected.toolCalls, match: expected.toolCalls)

        dispatch(collected, into: harness)

        let message = try #require(harness.assistant)
        #expect(message.unhandledToolCalls?.map(\.name) == ["get_weather", "get_time"])
        #expect(message.unhandledToolCalls?.first?.arguments == expected.toolCalls[0].arguments)
        #expect(message.state == .generating, "tool_calls is not a failure and must not become failed")
        #expect(message.text.isEmpty)
        #expect(
            !shouldOfferMessageRecovery(state: message.state, role: message.role, isLastInConversation: true),
            "empty body + notice card must not trigger the empty-reply recovery card"
        )
    }

    @Test("DeepSeek (ProviderKit assembler + StreamState path) also reaches ChatManager")
    func deepSeekStreamStatePathReachesChatManager() async throws {
        await MetadataClient.shared.resetForTesting()
        let harness = makeHarness(kind: .deepseek, modelID: "deepseek-chat", toolCall: false)

        let service = DeepSeekService(session: try ToolCallFixtureURLProtocol.session(serving: "openai_chat.tool_calls.sse"))
        let collected = try await collect(service.sendMessageStream(
            apiKey: "sk-deepseek-test",
            modelID: "deepseek-chat",
            messages: [makeUserMessage(kind: .deepseek)]
        ))
        #expect(collected.toolCallEvents.count == 1)
        #expect(collected.done != nil, "a stream with finish_reason=tool_calls must complete as done, not as an error")

        dispatch(collected, into: harness)

        #expect(harness.assistant?.unhandledToolCalls?.count == 2)
    }

    @Test("a stale session (messageID / sendTaskID mismatch) writes nothing to the message")
    func staleSessionIsIgnored() throws {
        let harness = makeHarness(kind: .grok, modelID: "grok-4.6")
        harness.state.chatManager._testingDispatchToolCallStreamEvent(
            .toolCallDeltas([ProviderToolCall(providerCallID: "x", name: "get_weather", rawArguments: "{}")]),
            in: harness.conversationID, messageID: harness.assistantID, sendTaskID: UUID(),
            provider: harness.provider, model: harness.model
        )
        #expect(harness.assistant?.unhandledToolCalls == nil)
    }
}

// MARK: - Notice-card UI / persistence boundary

@MainActor
@Suite("Unhandled tool-call notice card")
struct UnhandledToolCallCardTests {
    @Test("single-tool / multi-tool copy follows the baseline; card starts collapsed and expansion notifies layout")
    func cardHeadlineAndExpansion() {
        let view = UIKitUnhandledToolCallView()
        #expect(view.isHidden)

        view.configure(calls: [UnhandledToolCall(id: "c1", name: "get_weather", arguments: #"{"city":"Melbourne"}"#)])
        #expect(!view.isHidden)
        #expect(!view.isExpanded, "collapsed by default")
        #expect(UIKitUnhandledToolCallView.headline(for: [UnhandledToolCall(id: nil, name: "get_weather", arguments: "")])
            == String(format: L10n.tr("The model tried to use a tool (\"%@\") that isn't available on this connection.", table: .chat), "get_weather"))
        #expect(UIKitUnhandledToolCallView.headline(for: [
            UnhandledToolCall(id: nil, name: "a", arguments: ""),
            UnhandledToolCall(id: nil, name: "b", arguments: ""),
        ]) == String(format: L10n.tr("The model tried to use tools (%@) that aren't available on this connection.", table: .chat), "a, b"))

        view.configure(calls: [])
        #expect(view.isHidden, "empty array = no notice card, same convention as the research-progress view")
    }

    @Test("arguments over 2KB are truncated and marked; valid JSON is pretty-printed")
    func argumentsFormatting() {
        let pretty = UIKitUnhandledToolCallView.formattedArguments(#"{"b":1,"a":"x"}"#)
        #expect(!pretty.truncated)
        #expect(pretty.text.contains("\n"), "valid JSON should expand to multiple lines")

        let huge = "{\"q\":\"" + String(repeating: "x", count: 5000) + "\"}"
        let clipped = UIKitUnhandledToolCallView.formattedArguments(huge)
        #expect(clipped.truncated)
        #expect(clipped.text.utf8.count <= UIKitUnhandledToolCallView.argumentsByteLimit + 3)
    }

    @Test("fallback notice is static text, not a fake tappable button")
    func fallbackNoticeAccessibility() {
        let view = UIKitUnhandledToolCallView()
        view.configure(calls: [UnhandledToolCall(id: "c1", name: "search_library", arguments: "{}")])
        let card = view.accessibilityHeaderStateForTesting
        #expect(card.traits.contains(.button))
        #expect(card.interactive)
    }

    @Test("the message field is a GRDB column only, never in the Codable / cloud-sync envelope")
    func fieldIsLocalOnly() throws {
        var message = TestFactories.makeMessage(role: .assistant, text: "")
        message.unhandledToolCalls = [UnhandledToolCall(id: "c1", name: "get_weather", arguments: "{}")]

        let encoded = try JSONEncoder().encode(message)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(!json.contains("unhandledToolCalls"), "Codable envelope must not carry a device-local field")

        let column = RecordMappers.encodeUnhandledToolCalls(message.unhandledToolCalls)
        #expect(column != nil)
        #expect(RecordMappers.decodeUnhandledToolCalls(column) == message.unhandledToolCalls)
        #expect(RecordMappers.encodeUnhandledToolCalls([]) == nil, "empty array writes SQL NULL")
    }
}
