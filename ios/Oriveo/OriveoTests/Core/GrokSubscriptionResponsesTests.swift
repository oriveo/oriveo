import Foundation
import Testing
@testable import Oriveo

// MARK: - Shared corpus (shared/test-fixtures/provider-toolcall) and mock session

private enum GrokResponsesFixture {
        static let directory = ["shared", "test-fixtures", "provider-toolcall"]
    static let file = "grok_proxy.responses.web_search.sse"

    static func url(_ name: String) throws -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = (directory + [name]).reduce(cursor) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }

        /// The entry of this corpus in `expected.json` (only the fields this test uses are decoded).
    struct Expected: Decodable {
        struct Cit: Decodable { let url: String; let title: String? }
        struct Usage: Decodable {
            let input_tokens: Int
            let output_tokens: Int
            let reasoning_tokens: Int
            let cached_tokens: Int
            let cost_in_usd_ticks: Int64
        }
        let text: String
        let tool_calls: [[String: String?]]
        let tool_call_events: Int
        let web_search_calls: Int
        let citations: [Cit]
        let reasoning_summary_prefix: String
        let usage: Usage
    }

        /// Decode only this corpus's entry (the expected shapes of the other corpora differ, and decoding the whole table would trip over them).
    static func expected() throws -> Expected {
        let root = try JSONSerialization.jsonObject(with: data("expected.json")) as? [String: Any]
        let fixtures = root?["fixtures"] as? [[String: Any]] ?? []
        let entry = try #require(fixtures.first { $0["file"] as? String == file }?["expected"])
        return try JSONDecoder().decode(Expected.self, from: JSONSerialization.data(withJSONObject: entry))
    }
}

private final class GrokResponsesMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var captured: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.captured.append(request)
        do {
            let (status, body) = try Self.handler?(request) ?? (200, Data())
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": status == 200 ? "text/event-stream" : "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GrokResponsesMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func reset(body: Data) {
        captured = []
        handler = { _ in (200, body) }
    }
}

private func requestBody(_ request: URLRequest) -> [String: Any] {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 4_096)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
    }
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

private struct Collected {
    var text = ""
    var reasoning = ""
    var citations: [Citation] = []
    var toolCallEvents = 0
    var webSearchActivityEvents = 0
    var done: ProviderChatResult?
}

private func collect(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> Collected {
    var out = Collected()
    for try await event in stream {
        switch event {
        case let .delta(text): out.text += text
        case let .reasoning(text): out.reasoning += text
        case let .citations(list): out.citations = list
        case .toolCallDeltas: out.toolCallEvents += 1
        case .activity(.webSearch): out.webSearchActivityEvents += 1
        // `mcp_tool` / `external_search` are only set by the local tool loop; upstream parsing never produces them.
        case .activity(.mcpTool), .activity(.externalSearch): break
        case let .done(result): out.done = result
        case .imagePart, .finish: break
        }
    }
    return out
}

private func makeUser(_ text: String) -> ChatMessage {
    ChatMessage(id: UUID(), role: .user, text: text, providerKind: .grok, providerName: "Grok", modelName: "grok-4.6", state: .delivered)
}

private func makeAssistant(_ text: String) -> ChatMessage {
    ChatMessage(id: UUID(), role: .assistant, text: text, providerKind: .grok, providerName: "Grok", modelName: "grok-4.6", state: .delivered)
}

/// The shape the subscription catalog writes: capability bits / tier table / api_backend are all copied from the upstream `/models`.
private func subscriptionModel(
    web: Bool = true,
    levels: [String] = ["xhigh", "high", "medium", "low"],
    defaultLevel: String? = "high",
    apiBackend: String? = "responses"
) -> AIModel {
    var model = TestFactories.makeModel(id: "grok-4.6", capabilities: web ? [.text, .web, .reasoning] : [.text, .reasoning])
    model.reasoningModeAvailable = true
    model.upstreamReasoningLevels = levels
    model.upstreamDefaultReasoningLevel = defaultLevel
    model.upstreamAPIBackend = apiBackend
    return model
}

private func subscriptionContext() -> GrokSubscriptionRequestContext {
    GrokSubscriptionRequestContext(
        chatURL: URL(string: "https://cli-chat-proxy.grok.com/v1/chat/completions")!,
        responsesURL: URL(string: "https://cli-chat-proxy.grok.com/v1/responses")!,
        requiredHeaders: ["x-xai-token-auth": "xai-grok-cli", "x-grok-client-version": "1.0.4"],
        transport: TransportKind.openaiResponses.rawValue
    )
}

private func options(model: AIModel, context: GrokSubscriptionRequestContext = subscriptionContext(), systemPrompt: String = "") -> ChatRequestOptions {
    var options = ChatRequestOptions()
    options.capabilityEvidenceModel = model
    options.grokSubscription = context
    options.systemPrompt = systemPrompt
    return options
}

// MARK: - Grok subscription Responses

/// Grok subscriptions go through Responses. Root cause: `/chat/completions` of `cli-chat-proxy` has no web capability at all,
/// and the model only emits `<web_search>` pseudo tool-call text; `/responses` + `tools:[{"type":"web_search"}]` really searches the web
/// (measured with a real subscription token on 2026-08-22, corpus `shared/test-fixtures/provider-toolcall/grok_proxy.responses.web_search.sse`).
@Suite("Grok subscription · Responses", .serialized, .sharedProcessState)
struct GrokSubscriptionResponsesTests {

    @Test("Grok subscription Responses web search exposes only Automatic and does not fake an Off that cannot be implemented")
    func webControlIsAlwaysOnAutomatic() {
        var provider = TestFactories.makeProvider(kind: .grok, models: [])
        provider.authMode = .subscription
        let verdict = CapabilityControlResolution.subscriptionVerdict(
            provider: provider,
            model: subscriptionModel(),
            capability: "web"
        )
        #expect(verdict.state == .autoAvailable)
        #expect(verdict.intents == ["automatic"])
        #expect(verdict.reasonCode == "subscription_web_always_on", "always-on is flagged separately, and the panel draws a read-only Always on")
    }

    @Test("A leaked <|eos|> control token from the proxy is stripped and the rest of the text is left as is")
    func leakedEOSControlTokenIsStripped() {
        #expect(GrokService.stripLeakedControlTokens("About 14°C.[[1]](https://bom.gov.au)<|eos|>") == "About 14°C.[[1]](https://bom.gov.au)")
        #expect(GrokService.stripLeakedControlTokens("<|eos|>") == "")
        #expect(GrokService.stripLeakedControlTokens("<web_search><query>x</query></web_search>") == "<web_search><query>x</query></web_search>", "only eos is stripped; no other text is touched")
    }
    private static let minimalStream = Data("""
    event: response.output_text.delta
    data: {"type":"response.output_text.delta","delta":"hi"}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"r1","usage":{"input_tokens":2,"output_tokens":1}}}

    """.utf8)

    // MARK: Request shape contract

    @Test("Subscription Responses request: URL = resourceBaseURL/responses, required headers + Bearer, input message shape, stream, store:false")
    func subscriptionRequestShape() async throws {
        await MetadataClient.shared.resetForTesting()
        GrokResponsesMockURLProtocol.reset(body: Self.minimalStream)
        defer { GrokResponsesMockURLProtocol.handler = nil }

        let service = GrokService(session: GrokResponsesMockURLProtocol.session())
        let collected = try await collect(service.sendMessageStream(
            apiKey: "grok-subscription-token",
            modelID: "grok-4.6",
            messages: [makeUser("What is the temperature in Melbourne now"), makeAssistant("About 14 degrees."), makeUser("And Sydney")],
            reasoningMode: .automatic,
            webSearchEnabled: false,
            requestOptions: options(model: subscriptionModel(), systemPrompt: "You are an assistant")
        ))
        #expect(collected.text == "hi")

        let request = try #require(GrokResponsesMockURLProtocol.captured.first)
        // The endpoint is taken whole from the delivered value; it is not mixed with the api.x.ai of metadata and no /v1/v1 appears.
        #expect(request.url?.absoluteString == "https://cli-chat-proxy.grok.com/v1/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer grok-subscription-token")
        #expect(request.value(forHTTPHeaderField: "x-xai-token-auth") == "xai-grok-cli")
        #expect(request.value(forHTTPHeaderField: "x-grok-client-version") == "1.0.4")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")

        let body = requestBody(request)
        #expect(body["model"] as? String == "grok-4.6")
        #expect(body["stream"] as? Bool == true)
        #expect(body["store"] as? Bool == false)
        #expect(body["instructions"] as? String == "You are an assistant")
        #expect(body["messages"] == nil, "Responses uses input, not the messages of chat")
        #expect(body["previous_response_id"] == nil, "multi-turn carries the full history and does not depend on the proxy persisting it")
        // A web-capable subscription model always carries web_search (the proxy cli-chat-proxy without a real tool plays pseudo tool calls at random and repeats them from history),
        // even when the web switch is off: this proxy has no "turn search off" semantics.
        #expect((body["tools"] as? [[String: Any]])?.first?["type"] as? String == "web_search")
        // Default tier: take the entry with default:true in the upstream reasoning_efforts (high).
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "high")
        #expect((body["reasoning"] as? [String: Any])?["summary"] as? String == "auto")

        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.count == 3)
        #expect(input[0]["role"] as? String == "user")
        #expect((input[0]["content"] as? [[String: Any]])?.first?["type"] as? String == "input_text")
        // Assistant history must be output_text (a single turn is all right, but multi-turn always gets a 400).
        #expect(input[1]["role"] as? String == "assistant")
        #expect((input[1]["content"] as? [[String: Any]])?.first?["type"] as? String == "output_text")
        #expect((input[1]["content"] as? [[String: Any]])?.first?["text"] as? String == "About 14 degrees.")
        #expect((input[2]["content"] as? [[String: Any]])?.first?["text"] as? String == "And Sydney")
    }

    @Test("An upstream that declares supports_backend_search always carries tools:[{type:web_search}] (regardless of the web switch); one that does not, carries none")
    func webSearchToolFollowsUpstreamDeclaration() async throws {
        await MetadataClient.shared.resetForTesting()
        defer { GrokResponsesMockURLProtocol.handler = nil }
        let service = GrokService(session: GrokResponsesMockURLProtocol.session())

        // Even with the web switch off the tool must be sent: cli-chat-proxy is an agent backend, and without a real tool the model plays
        // `<web_search>` text at random and, once it has, repeats it from history. Sending the real tool is the only way to stop the act.
        GrokResponsesMockURLProtocol.reset(body: Self.minimalStream)
        _ = try await collect(service.sendMessageStream(
            apiKey: "t", modelID: "grok-4.6", messages: [makeUser("What is the temperature in Melbourne now")],
            reasoningMode: .automatic, webSearchEnabled: false,
            requestOptions: options(model: subscriptionModel(web: true))
        ))
        let tools = requestBody(try #require(GrokResponsesMockURLProtocol.captured.first))["tools"] as? [[String: Any]]
        #expect(tools?.count == 1)
        #expect(tools?.first?["type"] as? String == "web_search")

        // A model for which the upstream declares no web capability carries no tool (a capability the upstream does not recognize is not forced in).
        GrokResponsesMockURLProtocol.reset(body: Self.minimalStream)
        _ = try await collect(service.sendMessageStream(
            apiKey: "t", modelID: "grok-4.6", messages: [makeUser("What is the temperature in Melbourne now")],
            reasoningMode: .automatic, webSearchEnabled: false,
            requestOptions: options(model: subscriptionModel(web: false))
        ))
        #expect(requestBody(try #require(GrokResponsesMockURLProtocol.captured.first))["tools"] == nil)
    }

    @Test("Thinking tiers map to the upstream reasoning_efforts: max->xhigh (when present), deep->high, fast->low; with none in the declared set no reasoning is sent")
    func reasoningEffortMapsToDeclaredEfforts() async throws {
        // Establish the "no modelFacts" premise explicitly: inject a payload without modelFacts, and a non-empty table will not fall back to the built-in snapshot
        // (the built-in snapshot contains the reasoningEfforts of grok/grok-4.6, which would distort the "upstream declares no tiers" assertions below).
        try await ModelFactsFixture.loadFacts(includeFacts: false)
        defer { GrokResponsesMockURLProtocol.handler = nil }
        let service = GrokService(session: GrokResponsesMockURLProtocol.session())

        func effort(mode: ReasoningMode, model: AIModel) async throws -> String? {
            GrokResponsesMockURLProtocol.reset(body: Self.minimalStream)
            _ = try await collect(service.sendMessageStream(
                apiKey: "t", modelID: "grok-4.6", messages: [makeUser("hi")],
                reasoningMode: mode, webSearchEnabled: false, requestOptions: options(model: model)
            ))
            let body = requestBody(try #require(GrokResponsesMockURLProtocol.captured.first))
            return (body["reasoning"] as? [String: Any])?["effort"] as? String
        }
        #expect(try await effort(mode: .max, model: subscriptionModel()) == "xhigh")
        #expect(try await effort(mode: .deep, model: subscriptionModel()) == "high")
        #expect(try await effort(mode: .balanced, model: subscriptionModel()) == "medium")
        #expect(try await effort(mode: .fast, model: subscriptionModel()) == "low")
        // grok-4.5 has no xhigh: max falls back to high.
        #expect(try await effort(mode: .max, model: subscriptionModel(levels: ["high", "medium", "low"])) == "high")
        // The upstream declares no tiers: no reasoning field at all is sent (a value the upstream does not recognize is not sent).
        #expect(try await effort(mode: .deep, model: subscriptionModel(levels: [], defaultLevel: nil)) == nil)
        #expect(try await effort(mode: .automatic, model: subscriptionModel(levels: [], defaultLevel: nil)) == nil)

        await MetadataClient.shared.resetForTesting()
    }

    /// Cold-start regression (outbound side).
    ///
    /// The previous case locks how a first-party declaration is mapped; this one locks **the window where no first-party declaration exists**:
    /// `upstreamReasoningLevels` is deliberately not persisted and is always empty after an app restart; before this fix nothing at all was sent as effort,
    /// and the panel at the same time judged the thinking tiers unavailable ("a subscription grok-4.6 does not support thinking mode" on a real device).
    /// Now the verdict and the outbound path share `subscriptionDeclaredReasoningLevels` (first-party > models.dev > empty),
    /// so when the verdict says xhigh exists, the request body must really be able to send xhigh.
    @Test("Cold start (first-party tier table empty) + modelFacts with tiers -> reasoning.effort is still sent, and it can land on xhigh")
    func coldStartEffortComesFromModelFacts() async throws {
        try await ModelFactsFixture.loadFacts()
        defer { GrokResponsesMockURLProtocol.handler = nil }
        let service = GrokService(session: GrokResponsesMockURLProtocol.session())

        func effort(mode: ReasoningMode, model: AIModel) async throws -> String? {
            GrokResponsesMockURLProtocol.reset(body: Self.minimalStream)
            _ = try await collect(service.sendMessageStream(
                apiKey: "t", modelID: "grok-4.6", messages: [makeUser("hi")],
                reasoningMode: mode, webSearchEnabled: false, requestOptions: options(model: model)
            ))
            let body = requestBody(try #require(GrokResponsesMockURLProtocol.captured.first))
            return (body["reasoning"] as? [String: Any])?["effort"] as? String
        }
        // App restart state: both the first-party tier table and the default tier are cleared.
        let coldStart = subscriptionModel(levels: [], defaultLevel: nil)
        #expect(try await effort(mode: .max, model: coldStart) == "xhigh")
        #expect(try await effort(mode: .deep, model: coldStart) == "high")
        #expect(try await effort(mode: .fast, model: coldStart) == "low")
        // The default tier is not in the dictionary (the contract does not deliver "which tier is the default") -> automatic still sends nothing and leaves it to the upstream default.
        #expect(try await effort(mode: .automatic, model: coldStart) == nil)
        // When the first-party value is back it overrides the dictionary: when the proxy declares only low, the xhigh in the dictionary must not lift max.
        let firstPartyOnlyLow = subscriptionModel(levels: ["low"], defaultLevel: nil)
        #expect(try await effort(mode: .max, model: firstPartyOnlyLow) == nil)
        #expect(try await effort(mode: .fast, model: firstPartyOnlyLow) == "low")

        await MetadataClient.shared.resetForTesting()
    }

    @Test("A subscription context whose transport is still openai_chat keeps hitting /chat/completions (no rerouting when the fallback chain does not land on responses)")
    func chatTransportStaysOnChatCompletions() async throws {
        await MetadataClient.shared.resetForTesting()
        GrokResponsesMockURLProtocol.reset(body: Data("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\ndata: [DONE]\n\n".utf8))
        defer { GrokResponsesMockURLProtocol.handler = nil }
        let service = GrokService(session: GrokResponsesMockURLProtocol.session())
        _ = try await collect(service.sendMessageStream(
            apiKey: "t", modelID: "grok-4.6", messages: [makeUser("hi")],
            reasoningMode: .automatic, webSearchEnabled: false,
            requestOptions: options(model: subscriptionModel(apiBackend: nil), context: subscriptionContext().withTransport(TransportKind.openaiChat.rawValue))
        ))
        let request = try #require(GrokResponsesMockURLProtocol.captured.first)
        #expect(request.url?.absoluteString == "https://cli-chat-proxy.grok.com/v1/chat/completions")
        #expect(requestBody(request)["messages"] != nil)
    }

    // MARK: Replay of the real proxy corpus

    @Test("Replay the real proxy SSE: body + [[1]](url) citations as they are, url_citation -> citations, reasoning summary -> thinking, usage lands in the breakdown, zero tool_call events, no pseudo tool-call text")
    func replaysRealProxyStream() async throws {
        await MetadataClient.shared.resetForTesting()
        let expected = try GrokResponsesFixture.expected()
        GrokResponsesMockURLProtocol.reset(body: try GrokResponsesFixture.data(GrokResponsesFixture.file))
        defer { GrokResponsesMockURLProtocol.handler = nil }

        let service = GrokService(session: GrokResponsesMockURLProtocol.session())
        let collected = try await collect(service.sendMessageStream(
            apiKey: "grok-subscription-token",
            modelID: "grok-4.6",
            messages: [makeUser("What is the temperature in Melbourne now? One sentence")],
            reasoningMode: .fast,
            webSearchEnabled: true,
            requestOptions: options(model: subscriptionModel())
        ))

        #expect(collected.text == expected.text)
        #expect(!collected.text.contains("<web_search"), "the Responses path really searches the web, so pseudo tool-call text must no longer appear")
        #expect(!collected.text.contains("<tool_call"))
        #expect(collected.toolCallEvents == expected.tool_call_events)
        // Activity status line contract: the output_item.added of every web_search_call is passed through GrokService as
        // `.activity(.webSearch)` (4 searches in the real proxy recording = 4 start signals).
        #expect(collected.webSearchActivityEvents == expected.web_search_calls)
        #expect(collected.reasoning.hasPrefix(expected.reasoning_summary_prefix))
        #expect(collected.citations.count == expected.citations.count)
        #expect(collected.citations.first?.url == expected.citations.first?.url)
        #expect(collected.citations.first?.title == expected.citations.first?.title)

        let done = try #require(collected.done)
        #expect(done.text == expected.text)
        #expect(done.reasoningText?.hasPrefix(expected.reasoning_summary_prefix) == true)
        #expect(done.costSource == .subscription)
        #expect(done.estimatedCost == 0, "a subscription is not billed per token, even if the upstream returned cost_in_usd_ticks")
        let breakdown = try #require(done.usageBreakdown)
        #expect(breakdown.totalInputTokens == expected.usage.input_tokens)
        #expect(breakdown.cachedInputTokens == expected.usage.cached_tokens)
        #expect(breakdown.completionTokens == expected.usage.output_tokens)
        #expect(breakdown.reasoningTokens == expected.usage.reasoning_tokens)
    }

    @Test("The Responses frame-level log counts by event type: web_search_call progress / body / thinking / citations / completed (neither body nor URL is recorded)")
    func responsesFrameLogCountsEventTypes() throws {
        let expected = try GrokResponsesFixture.expected()
        let raw = String(decoding: try GrokResponsesFixture.data(GrokResponsesFixture.file), as: UTF8.self)
        var log = GrokResponsesSSEFrameLog(lane: "subscription")
        var currentEvent = ""
        for line in raw.components(separatedBy: "\n") {
            if line.hasPrefix("event:") {
                currentEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty else { continue }
            let type = (try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])?["type"] as? String
            log.record(eventType: type ?? currentEvent, payloadLength: payload.utf8.count)
            currentEvent = ""
        }
        #expect(log.counts["response.web_search_call.in_progress"] == expected.web_search_calls)
        #expect(log.counts["response.web_search_call.searching"] == expected.web_search_calls)
        #expect(log.counts["response.web_search_call.completed"] == expected.web_search_calls)
        #expect(log.counts["response.output_text.annotation.added"] == expected.citations.count)
        #expect(log.counts["response.completed"] == 1)
        #expect((log.counts["response.output_text.delta"] ?? 0) > 0)
        #expect((log.counts["response.reasoning_summary_text.delta"] ?? 0) > 0)
        #expect(log.counts["untyped"] == nil, "every frame of the real proxy carries its own type in the data body")
        #expect(!log.summary.contains("bom.gov.au"), "the summary line must not carry a URL / body text")
        #expect(!log.summary.contains("\u{58A8}\u{5C14}\u{672C}"))
    }

    // MARK: Control plane: verdict -> badge from one source

    @Test("Model library badge: Grok subscription api_backend=responses AND supports_backend_search -> the web badge is shown; hidden when the path lands on chat")
    func webBadgeFollowsVerdict() async {
        await MetadataClient.shared.resetForTesting()
        var provider = TestFactories.makeProvider(kind: .grok, models: [])
        provider.authMode = .subscription

        let shown = ModelCapabilityEvidencePresentation(provider: provider, model: subscriptionModel())
        #expect(shown.permitsDisplay(.web))
        #expect(subscriptionModel().visibleMetadataCapabilities(provider: provider).contains(.web))

        // The path lands on chat only when the upstream explicitly declares chat (when undeclared it defaults to Responses).
        let hidden = ModelCapabilityEvidencePresentation(provider: provider, model: subscriptionModel(apiBackend: "chat"))
        #expect(!hidden.permitsDisplay(.web))
        let absent = ModelCapabilityEvidencePresentation(provider: provider, model: subscriptionModel(web: false))
        #expect(!absent.permitsDisplay(.web))
    }

    @Test("ToolCallCapabilityPolicy reads the new source of truth for the subscription transport: declaring responses -> openai_responses, and the local adapter already includes it")
    func toolCallPolicyReadsSubscriptionTransport() async throws {
        await MetadataClient.shared.resetForTesting()
        var provider = TestFactories.makeProvider(kind: .grok, models: [])
        provider.authMode = .subscription
        #expect(
            ToolCallCapabilityPolicy.finalTransportKindName(provider: provider, model: subscriptionModel())
                == TransportKind.openaiResponses.rawValue
        )
        #expect(ToolProtocolAdapters.adapter(for: TransportKind.openaiResponses.rawValue) != nil)
        // With no api_backend declared the fallback default is Responses (cli-chat-proxy chat is responses-only,
        // and falling back to chat always produces the "plays web_search" incident).
        #expect(
            ToolCallCapabilityPolicy.finalTransportKindName(provider: provider, model: subscriptionModel(apiBackend: nil))
                == TransportKind.openaiResponses.rawValue
        )
    }
}
