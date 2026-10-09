import Foundation
import CoreFoundation
import GRDB
import OriveoProviderKit
import Testing
@testable import Oriveo

/// This is deliberately a transport-level matrix: every row calls the actual
/// ProviderService implementation with a URLProtocol session.  It is not a
/// registry-only fixture assertion, so a provider that forgets to put `stream`
/// on its production body is caught here.
private final class ProviderMatrixURLProtocol: URLProtocol, @unchecked Sendable {
    struct CapturedRequest {
        let url: URL?
        let body: Data?
        var method: String? = nil
        var headerNames: [String] = []
    }
    nonisolated(unsafe) static var captured: [CapturedRequest] = []
    nonisolated(unsafe) static var responder: ((URLRequest, Data?) -> Data)?
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var failure: Error?
    nonisolated(unsafe) static var failureAfterLoad: Error?
    nonisolated(unsafe) static var failureAfterLoadResponder: ((URLRequest) -> Error?)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let requestBody = request.httpBody ?? Self.readBody(from: request.httpBodyStream)
        Self.captured.append(CapturedRequest(
            url: request.url, body: requestBody, method: request.httpMethod,
            headerNames: (request.allHTTPHeaderFields ?? [:]).keys.sorted()
        ))
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.statusCode, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let body = Self.responder?(request, requestBody)
            ?? ProviderMatrixURLProtocol.response(for: request, requestBody: requestBody)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        if let failureAfterLoad = Self.failureAfterLoadResponder?(request) ?? Self.failureAfterLoad {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                self.client?.urlProtocol(self, didFailWithError: failureAfterLoad)
            }
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}

    private static func response(for request: URLRequest, requestBody: Data?) -> Data {
        let body = (try? requestBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        if request.url?.absoluteString.contains(":streamGenerateContent?alt=sse") == true {
            // generateContent streaming is SSE even though its body deliberately has no
            // `stream` boolean; use the real wire shape rather than its nonstream JSON.
            return Data("""
            data: {"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}

            """.utf8)
        }
        let rawBody = requestBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if request.url?.absoluteString.contains("/responses") == true,
           rawBody.contains(#""stream":true"#) {
            return Data("""
            event: response.output_text.delta
            data: {"type":"response.output_text.delta","delta":"ok"}

            event: response.completed
            data: {"type":"response.completed","response":{"id":"resp_matrix","status":"completed"}}

            data: [DONE]
            """.utf8)
        }
        if body["stream"] as? Bool == true {
            if request.url?.absoluteString.contains("generativelanguage") == true {
                return Data("""
                data: {"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}

                """.utf8)
            }
            if request.url?.absoluteString.contains("anthropic") == true {
                return Data("""
                event: content_block_start
                data: {"index":0,"content_block":{"type":"text","text":""}}

                event: content_block_delta
                data: {"index":0,"delta":{"type":"text_delta","text":"ok"}}

                event: message_stop
                data: {}

                """.utf8)
            }
            return Data("""
            data: {"choices":[{"delta":{"content":"ok"}}]}

            data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

            data: [DONE]
            """.utf8)
        }
        if request.url?.absoluteString.contains("generativelanguage") == true {
            return Data(#"{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}"#.utf8)
        }
        if request.url?.absoluteString.contains("anthropic") == true {
            return Data(#"{"content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":1,"output_tokens":1}}"#.utf8)
        }
        if request.url?.absoluteString.contains("/responses") == true {
            return Data(#"{"output_text":"ok","usage":{"input_tokens":1,"output_tokens":1}}"#.utf8)
        }
        return Data(#"{"choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
    }

    private static func readBody(from stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result.isEmpty ? nil : result
    }
}

private func providerMatrixSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ProviderMatrixURLProtocol.self]
    return URLSession(configuration: config)
}

@Suite("Production request builder matrix", .serialized)
struct ProviderProductionBuilderMatrixTests {
    @Test("second user attempt is a new single dispatch, never an automatic recovery loop")
    func secondExplicitAttemptRemainsSingleDispatch() async throws {
        let execution = try Self.executionFixture()
        let row = try #require(execution.providerCoverage.first { $0.providerKind == "mistral" })
        let registry = try Self.capabilityRuntimeRegistry()
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try Self.runtimeGenerationMetadata(
            registry: registry, row: row, capabilityRecipeRefs: ["reasoning": "mistral.chat.reasoning.v1"]
        ))
        defer { ProviderMatrixURLProtocol.responder = nil; ProviderMatrixURLProtocol.statusCode = 200 }
        ProviderMatrixURLProtocol.statusCode = 400
        ProviderMatrixURLProtocol.responder = { _, _ in Data(#"{"error":"retry fixture"}"#.utf8) }
        let message = ChatMessage(id: UUID(), role: .user, text: "again", providerKind: .mistral,
                                  providerName: "Mistral", modelID: row.modelId, modelName: row.modelId, state: .delivered)
        for attempt in 0 ..< 2 {
            ProviderMatrixURLProtocol.captured = []
            var options = ChatRequestOptions(); options.capabilityPreferences = .init(web: .off, reasoningIntent: "balanced")
            let tracker = CapabilityExecutionTracker()
            let identity = Self.matrixIdentity(providerKind: .mistral, modelID: row.modelId, transport: row.transport)
            let stream = try await CapabilityExecutionRuntime.$current.withValue(tracker) {
                CapabilityEvidenceRequestContext.$current.withValue(identity) {
                    Self.sendStream(provider: .mistral, session: providerMatrixSession(), modelID: row.modelId, messages: [message], options: options)
                }
            }
            do { try await CapabilityExecutionRuntime.$current.withValue(tracker) { for try await _ in stream {} } } catch { }
            #expect(ProviderMatrixURLProtocol.captured.count == 1, "explicit attempt \(attempt) retried")
        }
    }
    @Test("authoritative custom fragment reaches one real wire then surfaces its explicit recovery boundary")
    func customFragment400DoesNotAutoRetry() async throws {
        let fixture = try Self.executionFixture()
        let custom = try #require(fixture.safeCustomCases.first { $0.owner == "web" && $0.configurationMode == "custom" })
        let registry = try Self.capabilityRuntimeRegistry()
        let definitions = try Self.loadJSONObject(named: [
            "shared", "capabilityrecipe", "capability_custom_controls.v2.json",
        ])
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try Self.customOwnerMetadata(
            registry: registry, definitions: definitions, providerKind: "qwen", modelID: "qwen-custom",
            transport: "openai_chat", recipeRefs: ["web": "qwen.chat.web.v1"], cases: [custom]
        ))
        defer { ProviderMatrixURLProtocol.responder = nil; ProviderMatrixURLProtocol.statusCode = 200 }
        ProviderMatrixURLProtocol.captured = []
        ProviderMatrixURLProtocol.statusCode = 400
        ProviderMatrixURLProtocol.responder = { _, _ in Data(#"{"error":"custom rejected"}"#.utf8) }
        var options = ChatRequestOptions()
        options.capabilityPreferences = .init(web: .force, reasoningIntent: nil)
        options.selectLocalCustomBodyFragments([.init(raw: try #require(custom.raw), owner: "web", declaredOwners: [:])])
        let message = ChatMessage(id: UUID(), role: .user, text: "custom", providerKind: .qwen,
                                  providerName: "Qwen", modelID: "qwen-custom", modelName: "qwen-custom", state: .delivered)
        let tracker = CapabilityExecutionTracker()
        let identity = Self.matrixIdentity(providerKind: .qwen, modelID: "qwen-custom", transport: "openai_chat")
        let stream = try await CapabilityExecutionRuntime.$current.withValue(tracker) {
            CapabilityEvidenceRequestContext.$current.withValue(identity) {
                Self.sendStream(provider: .qwen, session: providerMatrixSession(), modelID: "qwen-custom", messages: [message], options: options)
            }
        }
        do {
            try await CapabilityExecutionRuntime.$current.withValue(tracker) { for try await _ in stream {} }
            Issue.record("custom 400 unexpectedly succeeded")
        } catch { }
        #expect(ProviderMatrixURLProtocol.captured.count == 1)
        #expect(tracker.terminalResult().states["web"] == .unconfirmed)
        #expect(tracker.terminalResult().states["web"] != .rejected)
    }
    @Test("stream-started failure reaches the real parser once and never self-heals")
    func streamStartedFailureDoesNotRetry() async throws {
        await MetadataClient.shared.resetForTesting()
        defer {
            ProviderMatrixURLProtocol.responder = nil
            ProviderMatrixURLProtocol.failureAfterLoad = nil
            ProviderMatrixURLProtocol.statusCode = 200
        }
        let execution = try Self.executionFixture()
        let row = try #require(execution.providerCoverage.first { $0.providerKind == "anthropic" })
        let registry = try Self.capabilityRuntimeRegistry()
        try await MetadataClient.shared.loadForTesting(json: try Self.runtimeGenerationMetadata(
            registry: registry, row: row, capabilityRecipeRefs: ["reasoning": "anthropic.messages.reasoning.v1"]
        ))
        ProviderMatrixURLProtocol.captured = []
        ProviderMatrixURLProtocol.responder = { _, _ in Data("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"partial\"}}\n\n".utf8) }
        ProviderMatrixURLProtocol.failureAfterLoad = URLError(.networkConnectionLost)
        let message = ChatMessage(id: UUID(), role: .user, text: "partial", providerKind: .anthropic,
                                  providerName: "Anthropic", modelID: row.modelId, modelName: row.modelId, state: .delivered)
        var options = ChatRequestOptions()
        options.capabilityPreferences = .init(web: .off, reasoningIntent: "balanced")
        let tracker = CapabilityExecutionTracker()
        let identity = Self.matrixIdentity(providerKind: .anthropic, modelID: row.modelId, transport: row.transport)
        let stream = try await CapabilityExecutionRuntime.$current.withValue(tracker) {
            CapabilityEvidenceRequestContext.$current.withValue(identity) {
                Self.sendStream(provider: .anthropic, session: providerMatrixSession(), modelID: row.modelId, messages: [message], options: options)
            }
        }
        var sawPartial = false
        do {
            try await CapabilityExecutionRuntime.$current.withValue(tracker) {
                for try await event in stream {
                    if case .delta("partial") = event { sawPartial = true }
                }
            }
        } catch { }
        #expect(sawPartial)
        #expect(ProviderMatrixURLProtocol.captured.count == 1)
        #expect(tracker.terminalResult().states.values.allSatisfy { $0 != .rejected })
    }
    @Test("result roster feeds 15 real provider stream parsers before settling execution truth")
    func providerResultRosterUsesProductionStreamParsers() async throws {
        struct ResultRow: Decodable {
            let providerKind: String; let recipeRef: String; let modelId: String
            let transport: String; let expected: String; let producerEvents: [String]
        }
        struct ResultFixture: Decodable { let providerResultCoverage: [ResultRow] }
        let resultFixture: ResultFixture = try Self.loadJSON(named: ["shared", "model-contracts", "provider_recipe_result_facts.v1.json"])
        let execution = try Self.executionFixture()
        let registry = try Self.capabilityRuntimeRegistry()
        let session = providerMatrixSession()
        #expect(resultFixture.providerResultCoverage.count == 15)

        for row in resultFixture.providerResultCoverage {
            let kind = try #require(Self.localProviderKind(forServerKey: row.providerKind))
            let baseRow = try #require(execution.providerCoverage.first {
                $0.providerKind == row.providerKind && $0.transport == row.transport
            })
            let recipeObject = try #require(
                (registry["recipes"] as? [String: Any])?[row.recipeRef] as? [String: Any]
            )
            let owner = try #require(recipeObject["capability"] as? String)
            let declaredIntents = ((recipeObject["requestOps"] as? [[String: Any]]) ?? [])
                .compactMap { $0["intent"] as? String }
            let metadataRow = ProviderCoverage(
                providerKind: baseRow.providerKind, transport: baseRow.transport,
                selectorTransport: baseRow.selectorTransport, recipeRef: baseRow.recipeRef,
                modelId: row.modelId
            )
            await MetadataClient.shared.resetForTesting()
            try await MetadataClient.shared.loadForTesting(json: try Self.runtimeGenerationMetadata(
                registry: registry, row: metadataRow, capabilityRecipeRefs: [owner: row.recipeRef],
                webSearchProfile: Self.p5WebSearchProfile[row.providerKind]
            ))
            ProviderMatrixURLProtocol.responder = { _, body in
                Self.p5RawStream(
                    providerKind: row.providerKind, transport: row.transport, events: row.producerEvents,
                    requestBody: body
                )
            }
            defer { ProviderMatrixURLProtocol.responder = nil }
            let message = ChatMessage(id: UUID(), role: .user, text: "proof", providerKind: kind,
                                      providerName: kind.displayName, modelID: row.modelId, modelName: row.modelId, state: .delivered)
            var options = ChatRequestOptions()
            switch owner {
            case "reasoning":
                let intent = try #require(declaredIntents.first { $0 != "off" })
                options.capabilityPreferences = .init(web: .off, reasoningIntent: intent)
            case "web":
                options.capabilityPreferences = .init(
                    web: declaredIntents.contains("force") ? .force : .automatic, reasoningIntent: nil
                )
            default:
                options.capabilityPreferences = .init(web: .off, reasoningIntent: nil)
            }
            let tracker = CapabilityExecutionTracker()
            let identity = Self.matrixIdentity(providerKind: kind, modelID: row.modelId, transport: row.transport)
            let stream = try await CapabilityExecutionRuntime.$current.withValue(tracker) {
                CapabilityEvidenceRequestContext.$current.withValue(identity) {
                    // Production rule: `webSearchEnabled = typed.web != .off`. Moonshot only registers an executor for
                    // `$web_search` when web search is on; with it off the tool_result producer is never reached.
                    Self.sendStream(provider: kind, session: session, modelID: row.modelId, messages: [message],
                                    options: options, webSearchEnabled: owner == "web")
                }
            }
            // The body encoder/URLProtocol dispatch occur during stream iteration, so retain the
            // same production TaskLocal while consuming raw bytes through the actual Service.
            try await CapabilityExecutionRuntime.$current.withValue(tracker) {
                for try await event in stream {
                    // Match ChatManager's event-consumption latch: this is production Service /
                    // TransportStrategy parser output, not a synthesized consumer event.
                    CapabilityExecutionRuntime.recordUpstreamResponse()
                    switch event {
                    case let .citations(citations):
                        CapabilityExecutionRuntime.recordParserEvent(.citations, nonEmpty: !citations.isEmpty)
                    case let .reasoning(text):
                        CapabilityExecutionRuntime.recordParserEvent(.reasoning, nonEmpty: !text.isEmpty)
                    // tool_result is not reported here: it has no matching StreamEvent and can only be reported by the
                    // production service when it parses the upstream search result. Adding a line here would be a hand-made event.
                    default: break
                    }
                }
            }
            if row.expected == "no_execution_fact" {
                #expect(owner == "generation", "\(row.providerKind) no_execution_fact must be a generation recipe")
                #expect(tracker.terminalResult().states[owner] == nil, "\(row.providerKind)")
            } else {
                #expect(owner != "generation", "\(row.providerKind) generation recipe must expect no_execution_fact")
                #expect(tracker.terminalResult().states[owner] == (row.expected == "observed" ? .observed : .unconfirmed), "\(row.providerKind)")
            }
            #expect(!tracker.canOfferExplicitCustomRetry,
                    "\(row.providerKind) parser output must close the pre-token custom retry gate")
        }
    }

    // MARK: - Web search "observed" criteria (Moonshot / Zhipu / Gemini Interactions / Qwen)

    @Test("replaying the recorded Moonshot sample reports one tool_result and web search is observed")
    func moonshotRecordedWebSearchIsObserved() async throws {
        let leg1 = try Self.fixtureData(named: [
            "shared", "test-fixtures", "provider-toolcall", "recorded", "moonshot_web_search.leg1.sse",
        ])
        var chatLegs = 0
        let outcome = try await Self.webEvidenceOutcome(
            providerKind: "moonshot", transport: "openai_chat", recipeRef: "moonshot.chat.web.v1", modelID: "kimi-k2.6"
        ) { _, body in
            chatLegs += 1
            return Self.bodyCarriesToolResult(body) ? Self.plainChatAnswer : leg1
        }
        #expect(chatLegs == 2, "builtin search: leg 1 yields $web_search, leg 2 feeds the arguments back and produces the text")
        #expect(outcome.text == "ok")
        #expect(outcome.tracker.terminalResult().states["web"] == .observed)
    }

    @Test("Moonshot `$web_search` arguments that are invalid JSON or lack a search_id are not reported", arguments: [
        #"not json"#,
        #"{\"search_result\":{},\"usage\":{\"total_tokens\":1}}"#,
        #"{\"search_result\":{\"search_id\":\"\"}}"#,
    ])
    func moonshotWebSearchWithoutSearchIDStaysUnconfirmed(escapedArguments: String) async throws {
        let leg1 = Data("""
        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"t-web_search-1","type":"builtin_function","function":{"name":"$web_search","arguments":"\(escapedArguments)"}}]},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """.utf8)
        let outcome = try await Self.webEvidenceOutcome(
            providerKind: "moonshot", transport: "openai_chat", recipeRef: "moonshot.chat.web.v1", modelID: "kimi-k2.6"
        ) { _, body in
            Self.bodyCarriesToolResult(body) ? Self.plainChatAnswer : leg1
        }
        #expect(outcome.text == "ok")
        #expect(outcome.tracker.terminalResult().states["web"] == .unconfirmed)
    }

    @Test("a non-empty Moonshot Formula fiber result reports tool_result and web search is observed")
    func moonshotFormulaFiberResultIsObserved() async throws {
        var fiberCalls = 0
        let outcome = try await Self.webEvidenceOutcome(
            providerKind: "moonshot", transport: "openai_chat", recipeRef: "moonshot.formula.web.v1", modelID: "kimi-k2.6"
        ) { request, body in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/tools") {
                return Data(#"{"tools":[{"type":"function","function":{"name":"web_search","parameters":{"type":"object"}}}]}"#.utf8)
            }
            if path.hasSuffix("/fibers") {
                fiberCalls += 1
                return Data(#"{"context":{"encrypted_output":"opaque-result"}}"#.utf8)
            }
            if Self.bodyCarriesToolResult(body) { return Self.plainChatAnswer }
            return Data("""
            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"web_search","arguments":"{\\"query\\":\\"news\\"}"}}]}}]}

            data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

            data: [DONE]

            """.utf8)
        }
        #expect(fiberCalls == 1)
        #expect(outcome.text == "ok")
        #expect(outcome.tracker.terminalResult().states["web"] == .observed)
    }

    @Test("two top-level Zhipu web_search entries yield two sources (link/title/content mapped correctly) and web search is observed")
    func zhipuTopLevelWebSearchYieldsCitationsAndObserved() async throws {
        let outcome = try await Self.webEvidenceOutcome(
            providerKind: "zhipu", transport: "openai_chat", recipeRef: "zhipu.chat.web.v1", modelID: "glm-5"
        ) { _, _ in
            Data("""
            data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"ok"}}]}

            data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"web_search":[{"title":"First","link":"https://a.example/1","content":"alpha","media":"A","icon":"https://a.example/icon.png","refer":"ref_1","publish_date":"2026-10-01"},{"title":"Second","link":"https://b.example/2","content":"beta","media":"B","icon":"","refer":"ref_2","publish_date":"2026-10-02"}]}

            data: [DONE]

            """.utf8)
        }
        #expect(outcome.citations.map(\.url) == ["https://a.example/1", "https://b.example/2"])
        #expect(outcome.citations.map(\.title) == ["First", "Second"])
        #expect(outcome.citations.map(\.snippet) == ["alpha", "beta"])
        #expect(outcome.tracker.terminalResult().states["web"] == .observed)
    }

    @Test("the legacy Zhipu search_result path yields sources")
    func zhipuLegacySearchResultYieldsCitations() async throws {
        // This case attaches no webSearch profile: the legacy path must not be recognised only when metadata happens to supply a streamShape.
        let outcome = try await Self.webEvidenceOutcome(
            providerKind: "zhipu", transport: "openai_chat", recipeRef: "zhipu.chat.web.v1", modelID: "glm-5"
        ) { _, _ in
            Data("""
            data: {"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"ws_1","type":"web_search","web_search":{"search_result":[{"title":"Legacy","link":"https://legacy.example/1","content":"gamma"}]}}]}}]}

            data: {"choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}],"web_search":[{"title":"Legacy","link":"https://legacy.example/1","content":"gamma"}]}

            data: [DONE]

            """.utf8)
        }
        #expect(outcome.citations.map(\.url) == ["https://legacy.example/1"], "the same source from both paths is deduplicated")
        #expect(outcome.citations.first?.title == "Legacy")
        #expect(outcome.citations.first?.snippet == "gamma")
        #expect(outcome.tracker.terminalResult().states["web"] == .observed)
    }

    @Test("a plain Zhipu answer (no web_search) is not reported and stays unconfirmed")
    func zhipuPlainAnswerStaysUnconfirmed() async throws {
        let outcome = try await Self.webEvidenceOutcome(
            providerKind: "zhipu", transport: "openai_chat", recipeRef: "zhipu.chat.web.v1", modelID: "glm-5"
        ) { _, _ in Self.plainChatAnswer }
        #expect(outcome.text == "ok")
        #expect(outcome.citations.isEmpty)
        #expect(outcome.tracker.terminalResult().states["web"] == .unconfirmed)
    }

    @Test("a non-empty Gemini Interactions google_search_result yields tool_result, and a url_citation in text_annotation_delta yields a source")
    func geminiInteractionsSearchResultAndAnnotations() async throws {
        // Each signal stands on its own: a stream with only google_search_result shows that tool_result alone is enough.
        let searchOnly = try await Self.webEvidenceOutcome(
            providerKind: "gemini", transport: "gemini_generate_content",
            recipeRef: "gemini.interactions.web.v1", modelID: "gemini-3-flash"
        ) { _, _ in
            Data("""
            data: {"event_type":"step.delta","index":0,"delta":{"type":"google_search_result","call_id":"c1","is_error":false,"result":[{"url":"https://g.example/1","title":"G"}]}}

            data: {"event_type":"step.delta","index":1,"delta":{"type":"text","text":"ok"}}

            data: {"event_type":"interaction.complete","interaction":{"id":"i1","status":"completed"}}

            """.utf8)
        }
        #expect(searchOnly.text == "ok")
        #expect(searchOnly.citations.isEmpty, "google_search_result is evidence the search ran, not a body citation")
        #expect(searchOnly.tracker.terminalResult().states["web"] == .observed)

        let annotated = try await Self.webEvidenceOutcome(
            providerKind: "gemini", transport: "gemini_generate_content",
            recipeRef: "gemini.interactions.web.v1", modelID: "gemini-3-flash"
        ) { _, _ in
            Data("""
            data: {"event_type":"step.delta","index":0,"delta":{"type":"text","text":"ok"}}

            data: {"event_type":"step.delta","index":0,"delta":{"type":"text_annotation_delta","annotations":[{"type":"url_citation","url":"https://g.example/1","title":"G","start_index":0,"end_index":2},{"type":"file_citation","document_uri":"files/x"}]}}

            data: {"event_type":"interaction.complete","interaction":{"id":"i2","status":"completed"}}

            """.utf8)
        }
        #expect(annotated.citations.map(\.url) == ["https://g.example/1"])
        #expect(annotated.citations.first?.title == "G")
        #expect(annotated.tracker.terminalResult().states["web"] == .observed)

        // A failed or empty search and plain body text are not evidence.
        let failed = try await Self.webEvidenceOutcome(
            providerKind: "gemini", transport: "gemini_generate_content",
            recipeRef: "gemini.interactions.web.v1", modelID: "gemini-3-flash"
        ) { _, _ in
            Data("""
            data: {"event_type":"step.delta","index":0,"delta":{"type":"google_search_result","is_error":true,"result":[{"url":"https://g.example/1"}]}}

            data: {"event_type":"step.delta","index":0,"delta":{"type":"google_search_result","result":[]}}

            data: {"event_type":"step.delta","index":1,"delta":{"type":"text","text":"ok"}}

            """.utf8)
        }
        #expect(failed.text == "ok")
        #expect(failed.tracker.terminalResult().states["web"] == .unconfirmed)
    }

    @Test("a plain Qwen answer with web search on is still unconfirmed")
    func qwenPlainAnswerWithWebStaysUnconfirmed() async throws {
        let outcome = try await Self.webEvidenceOutcome(
            providerKind: "qwen", transport: "openai_chat", recipeRef: "qwen.chat.web.v1", modelID: "qwen3.7-plus"
        ) { _, _ in Self.plainChatAnswer }
        #expect(outcome.text == "ok")
        #expect(outcome.tracker.terminalResult().states["web"] == .unconfirmed)
    }

    private struct WebEvidenceOutcome {
        let tracker: CapabilityExecutionTracker
        let citations: [Citation]
        let text: String
    }

    private static let plainChatAnswer = Data("""
    data: {"choices":[{"index":0,"delta":{"content":"ok"}}]}

    data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

    data: [DONE]

    """.utf8)

    /// Only the feed-back leg's request body carries `role: tool` messages.
    private static func bodyCarriesToolResult(_ body: Data?) -> Bool {
        guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]] else { return false }
        return messages.contains { $0["role"] as? String == "tool" }
    }

    /// Feeds raw upstream bytes to the production service with web search on, and returns the execution facts of
    /// this send together with the parsed sources. The consuming side does only the one thing ChatManager does
    /// (report citations on `.citations`); tool_result has no matching StreamEvent and can only come from the
    /// service's own parsing path.
    private static func webEvidenceOutcome(
        providerKind: String, transport: String, recipeRef: String, modelID: String,
        responder: @escaping (URLRequest, Data?) -> Data
    ) async throws -> WebEvidenceOutcome {
        let kind = try #require(localProviderKind(forServerKey: providerKind))
        let registry = try capabilityRuntimeRegistry()
        let baseRow = try #require(try executionFixture().providerCoverage.first {
            $0.providerKind == providerKind && $0.transport == transport
        })
        let recipeObject = try #require((registry["recipes"] as? [String: Any])?[recipeRef] as? [String: Any])
        #expect(recipeObject["capability"] as? String == "web")
        let declaredIntents = ((recipeObject["requestOps"] as? [[String: Any]]) ?? []).compactMap { $0["intent"] as? String }
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try runtimeGenerationMetadata(
            registry: registry,
            row: ProviderCoverage(
                providerKind: baseRow.providerKind, transport: baseRow.transport,
                selectorTransport: baseRow.selectorTransport, recipeRef: baseRow.recipeRef, modelId: modelID
            ),
            capabilityRecipeRefs: ["web": recipeRef]
        ))
        ProviderMatrixURLProtocol.responder = responder
        defer { ProviderMatrixURLProtocol.responder = nil }
        let message = ChatMessage(id: UUID(), role: .user, text: "proof", providerKind: kind,
                                  providerName: kind.displayName, modelID: modelID, modelName: modelID, state: .delivered)
        var options = ChatRequestOptions()
        options.capabilityPreferences = .init(
            web: declaredIntents.contains("force") ? .force : .automatic, reasoningIntent: nil
        )
        let tracker = CapabilityExecutionTracker()
        let identity = matrixIdentity(providerKind: kind, modelID: modelID, transport: transport)
        let session = providerMatrixSession()
        let stream = try await CapabilityExecutionRuntime.$current.withValue(tracker) {
            CapabilityEvidenceRequestContext.$current.withValue(identity) {
                sendStream(provider: kind, session: session, modelID: modelID, messages: [message],
                           options: options, webSearchEnabled: true)
            }
        }
        var citations: [Citation] = []
        var text = ""
        try await CapabilityExecutionRuntime.$current.withValue(tracker) {
            for try await event in stream {
                CapabilityExecutionRuntime.recordUpstreamResponse()
                switch event {
                case let .citations(incoming):
                    citations = incoming
                    CapabilityExecutionRuntime.recordParserEvent(.citations, nonEmpty: !incoming.isEmpty)
                case let .delta(delta): text += delta
                default: break
                }
            }
        }
        return WebEvidenceOutcome(tracker: tracker, citations: citations, text: text)
    }

    private static func fixtureData(named suffix: [String]) throws -> Data {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while folder.path != folder.deletingLastPathComponent().path {
            let file = suffix.reduce(folder) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: file.path) { return try Data(contentsOf: file) }
            folder.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static let p5WebSearchProfile: [String: String] = ["openRouter": "or_web"]

    @Test("recovery roster sends every case through the real strict service gate exactly once")
    func recoveryRosterDoesNotInvokeLegacySelfHeal() async throws {
        struct RecoveryRow: Decodable {
            let providerKind: String; let recipeRef: String; let status: Int
            let errorKind: String?; let expected: String; let automaticRetryCount: Int
        }
        struct RecoveryFixture: Decodable { let recoveryCases: [RecoveryRow] }
        let fixture: RecoveryFixture = try Self.loadJSON(named: ["shared", "model-contracts", "provider_recipe_result_facts.v1.json"])
        let execution = try Self.executionFixture()
        let registry = try Self.capabilityRuntimeRegistry()
        let session = providerMatrixSession()
        #expect(fixture.recoveryCases.count >= 25)
        defer {
            ProviderMatrixURLProtocol.responder = nil
            ProviderMatrixURLProtocol.statusCode = 200
            ProviderMatrixURLProtocol.failure = nil
        }
        for row in fixture.recoveryCases {
            let kind = try #require(Self.localProviderKind(forServerKey: row.providerKind))
            let resultRow = try #require(execution.providerCoverage.first { $0.providerKind == row.providerKind })
            await MetadataClient.shared.resetForTesting()
            try await MetadataClient.shared.loadForTesting(json: try Self.runtimeGenerationMetadata(
                registry: registry, row: resultRow, capabilityRecipeRefs: [
                    row.recipeRef.contains("reasoning") ? "reasoning" : "web": row.recipeRef,
                ]
            ))
            ProviderMatrixURLProtocol.captured = []
            ProviderMatrixURLProtocol.statusCode = row.status == 0 ? 200 : row.status
            ProviderMatrixURLProtocol.failure = row.status == 0
                ? URLError(row.errorKind == "timeout" ? .timedOut : .notConnectedToInternet)
                : nil
            ProviderMatrixURLProtocol.responder = { _, _ in Data(#"{"error":"p5 fixture"}"#.utf8) }
            let message = ChatMessage(id: UUID(), role: .user, text: "recover", providerKind: kind,
                                      providerName: kind.displayName, modelID: resultRow.modelId, modelName: resultRow.modelId, state: .delivered)
            var options = ChatRequestOptions()
            options.capabilityPreferences = row.recipeRef.contains("reasoning")
                ? .init(web: .off, reasoningIntent: "balanced") : .init(web: .force, reasoningIntent: nil)
            let tracker = CapabilityExecutionTracker()
            let identity = Self.matrixIdentity(providerKind: kind, modelID: resultRow.modelId, transport: resultRow.transport)
            let stream = try await CapabilityExecutionRuntime.$current.withValue(tracker) {
                CapabilityEvidenceRequestContext.$current.withValue(identity) {
                    Self.sendStream(provider: kind, session: session, modelID: resultRow.modelId, messages: [message], options: options)
                }
            }
            do {
                try await CapabilityExecutionRuntime.$current.withValue(tracker) {
                    for try await _ in stream {}
                }
                Issue.record("\(row.providerKind) recovery case unexpectedly succeeded")
            } catch { }
            #expect(ProviderMatrixURLProtocol.captured.count == 1, "\(row.providerKind) retried despite empty locatorRules")
            #expect(row.automaticRetryCount <= 1)
            #expect(
                row.expected == "surface_error"
                    || row.expected == "user_confirmed_resend_without_located_setting"
            )
            #expect(tracker.terminalResult().states.values.allSatisfy { $0 != .rejected })
        }
    }

    @Test("17 runtime rows / 15 providers execute their real nonstream and stream builders")
    func allProvidersBuildBothStreamModes() async throws {
        await MetadataClient.shared.resetForTesting()
        ProviderMatrixURLProtocol.responder = nil
        let session = providerMatrixSession()
        let registry = try Self.capabilityRuntimeRegistry()
        // The cross-end contract, rather than a hand-maintained iOS list, owns the
        // coverage rows.  In particular togetherAI/fireworksAI are catalog keys and
        // must not be silently converted through ProviderKind.rawValue.
        let rows = try Self.executionFixture().providerCoverage
        #expect(rows.count == 17)
        #expect(Set(rows.map(\.providerKind)).count == 15)
        for row in rows {
            let kind = try #require(Self.localProviderKind(forServerKey: row.providerKind))
            _ = try #require(Self.service(for: kind, session: session))
            await MetadataClient.shared.resetForTesting()
            try await MetadataClient.shared.loadForTesting(
                json: try Self.runtimeGenerationMetadata(
                    registry: registry, row: row
                )
            )
            let message = ChatMessage(id: UUID(), role: .user, text: "hello", providerKind: kind,
                                      providerName: kind.displayName, modelID: row.modelId, modelName: row.modelId, state: .delivered)
            let resolved = try #require(MetadataClient.shared.syncResolveCatalogModel(
                modelID: row.modelId, providerKind: kind
            ))
            var generation = GenerationParameterOverrides()
            generation.values["temperature"] = .init(state: .value, value: .number(0.2))
            let options = ChatRequestOptions(
                generationParameters: generation, generationProfile: resolved.generationProfile
            )
            let identity = Self.matrixIdentity(
                providerKind: kind, modelID: row.modelId, transport: row.selectorTransport ?? row.transport
            )
            ProviderMatrixURLProtocol.captured = []
            let result: ProviderChatResult
            do {
                result = try await CapabilityEvidenceRequestContext.$current.withValue(identity) {
                    try await Self.sendNonstream(
                        provider: kind, session: session, modelID: row.modelId,
                        messages: [message], options: options
                    )
                }
            } catch {
                Issue.record("\(row.providerKind)/\(row.recipeRef) nonstream builder/parser threw: \(error)")
                throw error
            }
            #expect(result.text == "ok", "\(row.providerKind)/\(row.recipeRef) nonstream parser did not receive its production response")
            let nonstream = try #require(ProviderMatrixURLProtocol.captured.last)
            let nonstreamBody = try #require(nonstream.body)
            let nonstreamJSON = try #require(try JSONSerialization.jsonObject(with: nonstreamBody) as? [String: Any])
            let expectedGenerationPath = row.transport == "gemini_generate_content"
                ? ["generationConfig", "temperature"] : ["temperature"]
            #expect(
                Self.value(in: nonstreamJSON, path: expectedGenerationPath) as? Double == 0.2,
                "\(row.providerKind)/\(row.recipeRef) did not apply its runtime-authorized typed generation wire"
            )
            if kind == .gemini {
                #expect(nonstream.url?.absoluteString.contains(":generateContent") == true)
            } else {
                #expect(nonstreamJSON["stream"] == nil || nonstreamJSON["stream"] as? Bool == false)
            }

            // This generation-profile matrix deliberately carries no customControlRefs.
            // A forged caller map must not turn those typed wires into custom authority.
            var forgedOptions = ChatRequestOptions(generationProfile: resolved.generationProfile)
            forgedOptions.localSafeCustomBodyFragment = .init(
                raw: #"{"model":"forged"}"#, owner: "generation",
                declaredOwners: ["/model": "generation"]
            )
            ProviderMatrixURLProtocol.captured = []
            do {
                _ = try await CapabilityEvidenceRequestContext.$current.withValue(identity) {
                    try await Self.sendNonstream(
                        provider: kind, session: session, modelID: row.modelId,
                        messages: [message], options: forgedOptions
                    )
                }
                Issue.record("\(row.providerKind) accepted caller-declared ownership of builder field /model")
            } catch is ProviderServiceError {
                // Expected: compiler rejects before URLSession touches the transport.
            }
            #expect(ProviderMatrixURLProtocol.captured.isEmpty,
                    "\(row.providerKind) sent a request after rejecting forged safe ownership")

            ProviderMatrixURLProtocol.captured = []
            let stream = CapabilityEvidenceRequestContext.$current.withValue(identity) {
                Self.sendStream(
                    provider: kind, session: session, modelID: row.modelId,
                    messages: [message], options: options
                )
            }
            var receivedStreamText = ""
            for try await event in stream {
                if case let .delta(text) = event { receivedStreamText += text }
            }
            #expect(receivedStreamText == "ok", "\(row.providerKind) stream parser did not emit its production delta")
            let streaming = try #require(ProviderMatrixURLProtocol.captured.last)
            let streamingBody = try #require(streaming.body)
            let streamingJSON = try #require(try JSONSerialization.jsonObject(with: streamingBody) as? [String: Any])
            #expect(Self.value(in: streamingJSON, path: expectedGenerationPath) as? Double == 0.2,
                    "\(row.providerKind)/\(row.recipeRef) stream builder dropped runtime typed generation")
            if kind == .gemini {
                #expect(streaming.url?.absoluteString.contains(":streamGenerateContent?alt=sse") == true,
                        "Gemini stream=true must select its SSE endpoint, not invent a body flag")
            } else {
                #expect(streamingJSON["stream"] as? Bool == true, "\(row.providerKind) did not propagate stream=true")
            }
        }
    }

    // MARK: - Attachment delivery: text limits and native scope

    private static let attachmentDocxMime =
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

    private static func attachmentTextFile(_ name: String) -> Oriveo.Attachment {
        let content = "content of \(name)"
        return Oriveo.Attachment(
            id: UUID(), kind: .file, fileName: name, mimeType: "text/plain",
            base64Data: Data(content.utf8).base64EncodedString(),
            extractedSizeBytes: content.utf8.count
        )
    }

    private static func attachmentEvidenceModel(
        id: String, maxAttachments: Int? = nil, nativeFileMimes: [String] = []
    ) -> AIModel {
        AIModel(
            id: id, name: id, capabilities: [.text, .image, .file],
            reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "premium",
            attachmentExtraction: maxAttachments.map { AttachmentExtractionLimits(maxAttachments: $0) },
            nativeFileMimes: nativeFileMimes,
            pdfNativeDefault: !nativeFileMimes.isEmpty
        )
    }

    private static func jsonStrings(in value: Any) -> [String] {
        if let string = value as? String { return [string] }
        if let array = value as? [Any] { return array.flatMap(jsonStrings(in:)) }
        if let object = value as? [String: Any] { return object.values.flatMap(jsonStrings(in:)) }
        return []
    }

    private static func jsonKeys(in value: Any) -> Set<String> {
        if let array = value as? [Any] { return array.reduce(into: []) { $0.formUnion(jsonKeys(in: $1)) } }
        if let object = value as? [String: Any] {
            return object.reduce(into: Set(object.keys)) { $0.formUnion(jsonKeys(in: $1.value)) }
        }
        return []
    }

    /// Number of attachment text blocks actually present in the request body (xml and markdown wrappers each recognize their own block header).
    private static func attachmentBlockCount(in body: Data) throws -> Int {
        let json = try JSONSerialization.jsonObject(with: body)
        return jsonStrings(in: json).reduce(0) { total, string in
            total + string.components(separatedBy: "<ATTACHMENT_FILE>").count - 1
                + string.components(separatedBy: "## Attachment ").count - 1
        }
    }

    private struct AttachmentSendOutcome {
        let body: Data?
        let error: Error?
        /// Number of requests the URLProtocol actually received during this send.
        let requestCount: Int
        /// URL / method / header names of the last request (present only when the send succeeded).
        var request: ProviderMatrixURLProtocol.CapturedRequest? = nil
    }

    /// Every runtime row sends one non-streaming and one streaming request through the real Service. `turns` gives each message's role and attachments in order.
    private static func attachmentOutcomes(
        row: ProviderCoverage, registry: [String: Any], session: URLSession,
        turns: [(role: ChatRole, attachments: [Oriveo.Attachment])], evidenceModel: AIModel?,
        text: String = "hello"
    ) async throws -> [AttachmentSendOutcome] {
        let kind = try #require(localProviderKind(forServerKey: row.providerKind))
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: try runtimeGenerationMetadata(registry: registry, row: row)
        )
        let messages = turns.map { turn in
            var message = ChatMessage(id: UUID(), role: turn.role, text: text, providerKind: kind,
                                      providerName: kind.displayName, modelID: row.modelId, modelName: row.modelId, state: .delivered)
            message.attachments = turn.attachments.isEmpty ? nil : turn.attachments
            return message
        }
        let resolved = try #require(MetadataClient.shared.syncResolveCatalogModel(
            modelID: row.modelId, providerKind: kind
        ))
        var options = ChatRequestOptions(generationProfile: resolved.generationProfile)
        options.capabilityEvidenceModel = evidenceModel
        let identity = matrixIdentity(
            providerKind: kind, modelID: row.modelId, transport: row.selectorTransport ?? row.transport
        )
        var outcomes: [AttachmentSendOutcome] = []
        ProviderMatrixURLProtocol.captured = []
        do {
            _ = try await CapabilityEvidenceRequestContext.$current.withValue(identity) {
                try await sendNonstream(
                    provider: kind, session: session, modelID: row.modelId,
                    messages: messages, options: options
                )
            }
            outcomes.append(.init(
                body: ProviderMatrixURLProtocol.captured.last?.body, error: nil,
                requestCount: ProviderMatrixURLProtocol.captured.count,
                request: ProviderMatrixURLProtocol.captured.last
            ))
        } catch {
            outcomes.append(.init(body: nil, error: error, requestCount: ProviderMatrixURLProtocol.captured.count))
        }
        ProviderMatrixURLProtocol.captured = []
        let stream = CapabilityEvidenceRequestContext.$current.withValue(identity) {
            sendStream(
                provider: kind, session: session, modelID: row.modelId,
                messages: messages, options: options
            )
        }
        do {
            for try await _ in stream {}
            outcomes.append(.init(
                body: ProviderMatrixURLProtocol.captured.last?.body, error: nil,
                requestCount: ProviderMatrixURLProtocol.captured.count,
                request: ProviderMatrixURLProtocol.captured.last
            ))
        } catch {
            outcomes.append(.init(body: nil, error: error, requestCount: ProviderMatrixURLProtocol.captured.count))
        }
        return outcomes
    }

    private static func attachmentBodies(
        row: ProviderCoverage, registry: [String: Any], session: URLSession,
        attachments: [Oriveo.Attachment], evidenceModel: AIModel?
    ) async throws -> [Data] {
        try await attachmentOutcomes(
            row: row, registry: registry, session: session,
            turns: [(.user, attachments)], evidenceModel: evidenceModel
        ).map { outcome in
            if let error = outcome.error { throw error }
            return try #require(outcome.body)
        }
    }

    @Test("17 runtime rows: an outgoing turn over the attachment text limit is blocked before any request; the same files in history still send")
    func outgoingTurnOverAttachmentTextLimitIsBlocked() async throws {
        await MetadataClient.shared.resetForTesting()
        ProviderMatrixURLProtocol.responder = nil
        let session = providerMatrixSession()
        let registry = try Self.capabilityRuntimeRegistry()
        let rows = try Self.executionFixture().providerCoverage
        #expect(rows.count == 17)
        let files = ["a.txt", "b.txt", "c.txt", "d.txt"].map(Self.attachmentTextFile)
        for row in rows {
            let label = "\(row.providerKind)/\(row.recipeRef)"
            let model = Self.attachmentEvidenceModel(id: row.modelId)

            // The message being sent carries 4 text files (default limit 3): the real build path throws and no request is produced.
            let blocked = try await Self.attachmentOutcomes(
                row: row, registry: registry, session: session,
                turns: [(.user, files)], evidenceModel: model
            )
            #expect(blocked.count == 2)
            for outcome in blocked {
                #expect(outcome.requestCount == 0, "\(label) sent a request although a file was left out")
                guard case let .attachmentTextOverLimit(fileNames, fileCountLimit)? = outcome.error as? ProviderServiceError else {
                    Issue.record("\(label) did not block the over-limit outgoing turn: \(String(describing: outcome.error))")
                    continue
                }
                // The 4th file is over the count limit: no file is named, and the limit is given.
                #expect(fileNames.isEmpty && fileCountLimit == FileExtractionLimits.default.maxFiles, "\(label)")
            }

            // The same 4 files in an earlier user message: not blocked, and the request body carries the first 3.
            let history = try await Self.attachmentOutcomes(
                row: row, registry: registry, session: session,
                turns: [(.user, files), (.assistant, []), (.user, [])], evidenceModel: model
            )
            // A call without an evidence model is not a chat send: not blocked, and the default limits apply.
            let nonChat = try await Self.attachmentOutcomes(
                row: row, registry: registry, session: session,
                turns: [(.user, files)], evidenceModel: nil
            )
            for outcome in history + nonChat {
                #expect(outcome.error == nil, "\(label) blocked a turn that is not the outgoing chat turn: \(String(describing: outcome.error))")
                let body = try #require(outcome.body)
                #expect(try Self.attachmentBlockCount(in: body) == 3)
            }
        }
    }

    @Test("17 runtime rows: the model's attachment limit, not the default, decides how many text blocks reach the body")
    func attachmentTextLimitFollowsEvidenceModel() async throws {
        await MetadataClient.shared.resetForTesting()
        ProviderMatrixURLProtocol.responder = nil
        let session = providerMatrixSession()
        let registry = try Self.capabilityRuntimeRegistry()
        let rows = try Self.executionFixture().providerCoverage
        #expect(rows.count == 17)
        let files = [Self.attachmentTextFile("a.txt"), Self.attachmentTextFile("b.txt")]
        for row in rows {
            // Files in an earlier message: a turn carrying over-limit files would be blocked outright (see the next case), so the block count cannot be measured.
            let limited = try await Self.attachmentOutcomes(
                row: row, registry: registry, session: session,
                turns: [(.user, files), (.assistant, []), (.user, [])],
                evidenceModel: Self.attachmentEvidenceModel(id: row.modelId, maxAttachments: 1)
            )
            #expect(limited.count == 2)
            for outcome in limited {
                #expect(outcome.error == nil)
                #expect(try Self.attachmentBlockCount(in: try #require(outcome.body)) == 1,
                        "\(row.providerKind)/\(row.recipeRef) ignored the model's maxAttachments")
            }
            let unlimited = try await Self.attachmentBodies(
                row: row, registry: registry, session: session, attachments: files,
                evidenceModel: Self.attachmentEvidenceModel(id: row.modelId)
            )
            let withoutModel = try await Self.attachmentBodies(
                row: row, registry: registry, session: session, attachments: files,
                evidenceModel: nil
            )
            for body in unlimited + withoutModel {
                #expect(try Self.attachmentBlockCount(in: body) == 2,
                        "\(row.providerKind)/\(row.recipeRef) changed the default-limit body")
            }
        }
    }

    // MARK: - Attachment delivery: native file upload (per-route switches are in NativeFileUploadSwitch)

    /// The matrix rows for the four direct routes with native file upload enabled, and what each one's native block looks like in the request body.
    private struct NativeFileLine {
        let name: String
        let row: ProviderCoverage
        /// How to tell a native file block is present in the request body (by the route's wire shape).
        let hasNativePart: (_ strings: [String], _ keys: Set<String>) -> Bool
    }

    private static func nativeFileLines() throws -> [NativeFileLine] {
        let rows = try executionFixture().providerCoverage
        func row(_ providerKind: String, _ transport: String) throws -> ProviderCoverage {
            try #require(rows.first { $0.providerKind == providerKind && $0.transport == transport })
        }
        return [
            NativeFileLine(name: "openai-responses", row: try row("openAI", "openai_responses")) { strings, keys in
                strings.contains("input_file") && keys.contains("file_data") && keys.contains("filename")
            },
            NativeFileLine(name: "anthropic-messages", row: try row("anthropic", "anthropic_messages")) { strings, keys in
                strings.contains("document") && keys.contains("media_type")
            },
            NativeFileLine(name: "gemini-generate-content", row: try row("gemini", "gemini_generate_content")) { _, keys in
                keys.contains("inlineData")
            },
            NativeFileLine(name: "openrouter-chat", row: try row("openRouter", "openai_chat")) { strings, keys in
                strings.contains("file") && keys.contains("file_data") && keys.contains("filename")
            },
        ]
    }

    /// How to tell a native file block appeared where none should (the union of the four wire shapes).
    private static func carriesAnyNativeFilePart(strings: [String], keys: Set<String>) -> Bool {
        strings.contains("document") || strings.contains("input_file")
            || keys.contains("inlineData") || keys.contains("file_data")
    }

    static let nativePDFMarker = "ORIVEO-PDF-MARKER-7391"

    /// A minimal PDF with one page and one line holding a marker word (the cross-reference table is generated from the real offsets).
    private static func markerPDF() -> Data {
        let stream = "BT /F1 18 Tf 72 720 Td (\(nativePDFMarker)) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xrefOffset = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        return Data(pdf.utf8)
    }

    /// The extracted text deliberately omits the marker word: if the upstream can answer with it, it can only have read the native file.
    private static let nativePDFExtractedText = "extracted pdf text"

    private static func pdfAttachment(
        name: String = "paper.pdf", extractedText: String = nativePDFExtractedText,
        originalByteCount: Int? = nil
    ) -> Oriveo.Attachment {
        // When an original size is given, use filler bytes of that length: the native threshold looks only at the original file's byte count, and the extracted text always stays small.
        let original = originalByteCount.map { Data(count: $0) } ?? markerPDF()
        return Oriveo.Attachment(
            id: UUID(), kind: .file, fileName: name, mimeType: "application/pdf",
            base64Data: Data(extractedText.utf8).base64EncodedString(),
            extractedSizeBytes: extractedText.utf8.count,
            originalBase64Data: original.base64EncodedString()
        )
    }

    private static func sizedTextFile(_ name: String, bytes: Int) -> Oriveo.Attachment {
        let content = String(repeating: "x", count: bytes)
        return Oriveo.Attachment(
            id: UUID(), kind: .file, fileName: name, mimeType: "text/plain",
            base64Data: Data(content.utf8).base64EncodedString(), extractedSizeBytes: bytes
        )
    }

    @Test("native file upload: the four enabled direct transports send a whitelisted PDF as a native part and no longer as a text block")
    func whitelistedPDFGoesNativeOnEnabledDirectTransports() async throws {
        await MetadataClient.shared.resetForTesting()
        ProviderMatrixURLProtocol.responder = nil
        let session = providerMatrixSession()
        let registry = try Self.capabilityRuntimeRegistry()
        let lines = try Self.nativeFileLines()
        #expect(lines.count == 4)
        let pdf = Self.pdfAttachment()
        let pdfBase64 = try #require(pdf.originalBase64Data)
        for line in lines {
            let bodies = try await Self.attachmentBodies(
                row: line.row, registry: registry, session: session,
                attachments: [pdf, Self.attachmentTextFile("notes.txt")],
                evidenceModel: Self.attachmentEvidenceModel(id: line.row.modelId, nativeFileMimes: ["application/pdf"])
            )
            #expect(bodies.count == 2)
            for body in bodies {
                let json = try JSONSerialization.jsonObject(with: body)
                let strings = Self.jsonStrings(in: json)
                #expect(line.hasNativePart(strings, Self.jsonKeys(in: json)), "\(line.name) sent no native file part")
                #expect(strings.contains { $0.contains(pdfBase64) }, "\(line.name) did not carry the original PDF bytes")
                // The PDF no longer appears as a text block; text files in the same message are injected as usual.
                #expect(try Self.attachmentBlockCount(in: body) == 1, "\(line.name)")
                #expect(!strings.contains { $0.contains(Self.nativePDFExtractedText) }, "\(line.name) also injected the PDF as text")
                #expect(strings.contains { $0.contains("content of notes.txt") })
            }
        }
    }

    @Test("native file upload: without a whitelist the body is extracted text only, and transports that are not enabled ignore the whitelist")
    func nativeFilePartsNeedBothWhitelistAndEnabledTransport() async throws {
        await MetadataClient.shared.resetForTesting()
        ProviderMatrixURLProtocol.responder = nil
        let session = providerMatrixSession()
        let registry = try Self.capabilityRuntimeRegistry()
        let rows = try Self.executionFixture().providerCoverage
        #expect(rows.count == 17)
        let enabled = Set(try Self.nativeFileLines().map { "\($0.row.providerKind)/\($0.row.recipeRef)" })
        #expect(enabled.count == 4)
        let pdf = Self.pdfAttachment()
        let pdfBase64 = try #require(pdf.originalBase64Data)
        for row in rows {
            let label = "\(row.providerKind)/\(row.recipeRef)"
            // A model without an allow-list (the shape when a direct catalog lacks the field): the request body is the same as before native upload was enabled.
            var bodies = try await Self.attachmentBodies(
                row: row, registry: registry, session: session, attachments: [pdf],
                evidenceModel: Self.attachmentEvidenceModel(id: row.modelId)
            )
            // A call without an evidence model likewise carries text only.
            bodies += try await Self.attachmentBodies(
                row: row, registry: registry, session: session, attachments: [pdf], evidenceModel: nil
            )
            if !enabled.contains(label) {
                // The route is not enabled (or its builder never assembles native blocks): even with an allow-list on the model, only text goes out.
                bodies += try await Self.attachmentBodies(
                    row: row, registry: registry, session: session, attachments: [pdf],
                    evidenceModel: Self.attachmentEvidenceModel(id: row.modelId, nativeFileMimes: ["application/pdf"])
                )
            }
            for body in bodies {
                let json = try JSONSerialization.jsonObject(with: body)
                let strings = Self.jsonStrings(in: json)
                #expect(!Self.carriesAnyNativeFilePart(strings: strings, keys: Self.jsonKeys(in: json)),
                        "\(label) sent a native file part")
                #expect(!strings.contains { $0.contains(pdfBase64) }, "\(label) sent the original PDF bytes")
                #expect(try Self.attachmentBlockCount(in: body) == 1, "\(label)")
                #expect(strings.contains { $0.contains(Self.nativePDFExtractedText) }, "\(label)")
            }
        }
    }

    private final class TransportLog: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [AttachmentTransport] = []
        func record(_ transport: AttachmentTransport) { lock.lock(); seen.append(transport); lock.unlock() }
        var transports: Set<AttachmentTransport> { lock.lock(); defer { lock.unlock() }; return Set(seen) }
    }

    @Test("17 runtime rows: the transport resolved before sending is the one the production builder reports to attachment delivery")
    func presendTransportMatchesProductionBuilder() async throws {
        await MetadataClient.shared.resetForTesting()
        ProviderMatrixURLProtocol.responder = nil
        let session = providerMatrixSession()
        let registry = try Self.capabilityRuntimeRegistry()
        let rows = try Self.executionFixture().providerCoverage
        #expect(rows.count == 17)
        var covered: Set<AttachmentTransport> = []
        for row in rows {
            let label = "\(row.providerKind)/\(row.recipeRef)"
            let kind = try #require(Self.localProviderKind(forServerKey: row.providerKind))
            let model = Self.attachmentEvidenceModel(id: row.modelId)
            let log = TransportLog()
            // Send the real build path once non-streaming and once streaming, and record the route the build point reports to deliver.
            let outcomes = try await AttachmentDeliveryObservation.$onDeliver.withValue({ log.record($0) }) {
                try await Self.attachmentOutcomes(
                    row: row, registry: registry, session: session,
                    turns: [(.user, [Self.attachmentTextFile("a.txt")])], evidenceModel: model
                )
            }
            #expect(outcomes.count == 2, "\(label)")
            // The catalog still matches this row right now: the pre-send resolution must land on the same route.
            let resolved = AttachmentTransportResolver.resolve(
                provider: TestFactories.makeProvider(kind: kind, models: [model]), model: model, request: .init()
            )
            #expect(resolved != nil, "\(label) was not resolvable before sending")
            #expect(log.transports == Set([resolved].compactMap { $0 }), "\(label) built on \(log.transports), resolved \(String(describing: resolved))")
            if let resolved { covered.insert(resolved) }
        }
        #expect(covered == [
            .openAIResponses, .openAIChat, .anthropicMessages, .geminiGenerateContent, .openRouterChat,
            .groqChat, .deepSeekChat, .siliconFlowChat, .togetherChat, .fireworksChat, .miniMaxChat,
            .zhipuChat, .qwenChat, .grokResponses, .grokChat, .moonshotChat, .mistralChat,
        ])

        // The snapshot has not arrived: providers that pick their protocol from the catalog are not predicted, the rest work as usual.
        await MetadataClient.shared.resetForTesting()
        let anyModel = Self.attachmentEvidenceModel(id: "gpt-4.1")
        for kind in [ProviderKind.openAI, .grok, .gemini, .miniMax] {
            #expect(AttachmentTransportResolver.resolve(
                provider: TestFactories.makeProvider(kind: kind, models: [anyModel]), model: anyModel, request: .init()
            ) == nil, "\(kind)")
        }
        #expect(AttachmentTransportResolver.resolve(
            provider: TestFactories.makeProvider(kind: .anthropic, models: [anyModel]), model: anyModel, request: .init()
        ) == .anthropicMessages)
    }

    @Test("Gemini: web search on an Interactions recipe resolves to and builds on the Interactions transport; off stays on generateContent")
    func presendTransportMatchesGeminiInteractionsRoute() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try interactionsMetadataJSON())
        ProviderMatrixURLProtocol.responder = nil
        let session = providerMatrixSession()
        let model = Self.attachmentEvidenceModel(id: "gemini-interactions")
        var user = ChatMessage(id: UUID(), role: .user, text: "news", providerKind: .gemini,
                               providerName: "Gemini", modelID: "gemini-interactions", modelName: "gemini-interactions", state: .delivered)
        user.attachments = [Self.attachmentTextFile("a.txt")]
        var options = ChatRequestOptions()
        options.capabilityEvidenceModel = model
        let provider = TestFactories.makeProvider(kind: .gemini, models: [model])
        for (webSearchEnabled, expected) in [(true, AttachmentTransport.geminiInteractions), (false, .geminiGenerateContent)] {
            let log = TransportLog()
            await AttachmentDeliveryObservation.$onDeliver.withValue({ log.record($0) }) {
                // Only which route the build point took matters; the stub has no response body for this route, so whether the send itself succeeds is outside this assertion.
                _ = try? await Self.sendNonstream(
                    provider: .gemini, session: session, modelID: "gemini-interactions",
                    messages: [user], options: options, webSearchEnabled: webSearchEnabled
                )
                do {
                    for try await _ in Self.sendStream(
                        provider: .gemini, session: session, modelID: "gemini-interactions",
                        messages: [user], options: options, webSearchEnabled: webSearchEnabled
                    ) {}
                } catch {}
            }
            #expect(log.transports == [expected], "webSearchEnabled=\(webSearchEnabled)")
            #expect(AttachmentTransportResolver.resolve(
                provider: provider, model: model, request: .init(webSearchEnabled: webSearchEnabled)
            ) == expected, "webSearchEnabled=\(webSearchEnabled)")
        }
    }

    @Test("native file upload: a PDF over the transport's native size threshold falls back to extracted text")
    func oversizePDFFallsBackToText() async throws {
        await MetadataClient.shared.resetForTesting()
        ProviderMatrixURLProtocol.responder = nil
        let session = providerMatrixSession()
        let registry = try Self.capabilityRuntimeRegistry()
        for line in try Self.nativeFileLines() {
            let kind = try #require(Self.localProviderKind(forServerKey: line.row.providerKind))
            let model = Self.attachmentEvidenceModel(id: line.row.modelId, nativeFileMimes: ["application/pdf"])
            let oversize = Self.pdfAttachment(originalByteCount: AttachmentRouter.maxNativeBytes(for: kind) + 1)
            let atThreshold = Self.pdfAttachment(originalByteCount: AttachmentRouter.maxNativeBytes(for: kind))
            for body in try await Self.attachmentBodies(
                row: line.row, registry: registry, session: session, attachments: [oversize], evidenceModel: model
            ) {
                let json = try JSONSerialization.jsonObject(with: body)
                let strings = Self.jsonStrings(in: json)
                #expect(!Self.carriesAnyNativeFilePart(strings: strings, keys: Self.jsonKeys(in: json)), "\(line.name)")
                #expect(try Self.attachmentBlockCount(in: body) == 1, "\(line.name)")
                #expect(strings.contains { $0.contains(Self.nativePDFExtractedText) }, "\(line.name)")
            }
            // A file exactly at the threshold still goes native. This only asks about routing and does not stuff tens of MB of filler bytes into a request body;
            // that a file routed native really becomes a native block is shown on a real request body by the small-PDF case above.
            #expect(AttachmentRouter.decide(attachment: atThreshold, provider: kind, model: model) == .native, "\(line.name)")
        }
    }

    @Test("native file upload: a native file counts toward neither the text total nor the text file count")
    func nativeFilesDoNotConsumeTextBudget() async throws {
        await MetadataClient.shared.resetForTesting()
        ProviderMatrixURLProtocol.responder = nil
        let session = providerMatrixSession()
        let registry = try Self.capabilityRuntimeRegistry()
        let defaults = FileExtractionLimits.default
        // The PDF's extracted text and the text file each take 60% of the default total: both as text would be over the limit, while the PDF going native fits.
        let share = defaults.totalCap * 6 / 10
        let pdf = Self.pdfAttachment(extractedText: String(repeating: "p", count: share))
        let text = Self.sizedTextFile("big.txt", bytes: share)
        // Text files fill the default count limit, plus one native PDF.
        let fullCount = (1...defaults.maxFiles).map { Self.attachmentTextFile("f\($0).txt") }
        for line in try Self.nativeFileLines() {
            let native = Self.attachmentEvidenceModel(id: line.row.modelId, nativeFileMimes: ["application/pdf"])
            let textOnly = Self.attachmentEvidenceModel(id: line.row.modelId)

            for body in try await Self.attachmentBodies(
                row: line.row, registry: registry, session: session, attachments: [pdf, text], evidenceModel: native
            ) {
                let json = try JSONSerialization.jsonObject(with: body)
                #expect(line.hasNativePart(Self.jsonStrings(in: json), Self.jsonKeys(in: json)), "\(line.name)")
                #expect(try Self.attachmentBlockCount(in: body) == 1, "\(line.name)")
            }
            for body in try await Self.attachmentBodies(
                row: line.row, registry: registry, session: session,
                attachments: [Self.pdfAttachment()] + fullCount, evidenceModel: native
            ) {
                #expect(try Self.attachmentBlockCount(in: body) == defaults.maxFiles, "\(line.name)")
            }

            // Control: with both pieces of content going as text, this turn is blocked.
            let blocked = try await Self.attachmentOutcomes(
                row: line.row, registry: registry, session: session,
                turns: [(.user, [pdf, text])], evidenceModel: textOnly
            )
            for outcome in blocked {
                #expect(outcome.requestCount == 0, "\(line.name)")
                guard case let .attachmentTextOverLimit(fileNames, _)? = outcome.error as? ProviderServiceError else {
                    Issue.record("\(line.name) did not block the over-limit text turn: \(String(describing: outcome.error))")
                    continue
                }
                #expect(fileNames == ["big.txt"])
            }
        }
    }

    @Test("native file upload: catalog metadata carries nativeFileMimes / pdfNativeDefault onto direct models, and a missing field means none")
    func catalogMetadataFeedsNativeFileWhitelist() async throws {
        let registry = try Self.capabilityRuntimeRegistry()
        for line in try Self.nativeFileLines() {
            let kind = try #require(Self.localProviderKind(forServerKey: line.row.providerKind))
            let plain = try Self.runtimeGenerationMetadata(registry: registry, row: line.row)
            var document = try #require(JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any])
            var providers = try #require(document["providers"] as? [String: Any])
            var provider = try #require(providers[line.row.providerKind] as? [String: Any])
            var models = try #require(provider["models"] as? [String: Any])
            var entry = try #require(models[line.row.modelId] as? [String: Any])
            entry["nativeFileMimes"] = ["Application/PDF"]
            entry["pdfNativeDefault"] = true
            entry["attachmentExtraction"] = ["maxLines": 120, "totalCap": 51_200]
            models[line.row.modelId] = entry
            provider["models"] = models
            providers[line.row.providerKind] = provider
            document["providers"] = providers
            let withWhitelist = String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)

            await MetadataClient.shared.resetForTesting()
            try await MetadataClient.shared.loadForTesting(json: withWhitelist)
            let built = await CatalogModelBuilder.buildCatalogModel(
                providerKind: kind, runtimeModelId: line.row.modelId, fallbackName: line.row.modelId
            )
            #expect(built.nativeFileMimes == ["application/pdf"], "\(line.name)")
            #expect(built.pdfNativeDefault, "\(line.name)")
            #expect(AttachmentRouter.decide(attachment: Self.pdfAttachment(), provider: kind, model: built) == .native)
            // Per-model extraction limit overrides come from the catalog; the two not given fall back to defaults.
            let limits = FileExtractionLimits.resolve(model: built)
            #expect(limits.maxLines == 120 && limits.totalCap == 51_200, "\(line.name)")
            #expect(limits.maxBytes == FileExtractionLimits.default.maxBytes, "\(line.name)")
            #expect(limits.maxInputFileBytes == FileExtractionLimits.default.maxInputFileBytes, "\(line.name)")

            // The catalog stops providing them: after a re-enrich the allow-list is withdrawn, and a stored model does not keep going native with the old value.
            await MetadataClient.shared.resetForTesting()
            try await MetadataClient.shared.loadForTesting(json: plain)
            let withdrawn = CatalogModelBuilder.enrichStoredModel(built, providerKind: kind)
            #expect(withdrawn.nativeFileMimes.isEmpty, "\(line.name)")
            #expect(!withdrawn.pdfNativeDefault, "\(line.name)")
            #expect(withdrawn.attachmentExtraction == nil, "\(line.name)")
            let fresh = await CatalogModelBuilder.buildCatalogModel(
                providerKind: kind, runtimeModelId: line.row.modelId, fallbackName: line.row.modelId
            )
            #expect(fresh.nativeFileMimes.isEmpty && !fresh.pdfNativeDefault, "\(line.name)")
            #expect(FileExtractionLimits.resolve(model: fresh) == .default, "\(line.name)")
        }
        await MetadataClient.shared.resetForTesting()
    }

    /// Exports the real requests for the four routes, so a person can swap in a real key and send them upstream to verify that the upstream accepts native file blocks and reads the content.
    /// Files are written only when `ORIVEO_TEST_EXPORT_DIR` is set (to pass it to the test process through xcodebuild, add the `TEST_RUNNER_` prefix):
    ///   TEST_RUNNER_ORIVEO_TEST_EXPORT_DIR=<directory> <run the iOS tests> \
    ///     -only-testing:OriveoTests/ProviderProductionBuilderMatrixTests/exportNativeFileRequests
    /// Each route writes `<route>.nonstream.json` and `<route>.stream.json`: method / url / headerNames / body.
    /// The key in the request is the placeholder `test-key`; headers export names only.
    @Test("native file upload: export the production requests of the four enabled transports for a marker PDF")
    func exportNativeFileRequests() async throws {
        await MetadataClient.shared.resetForTesting()
        ProviderMatrixURLProtocol.responder = nil
        let session = providerMatrixSession()
        let registry = try Self.capabilityRuntimeRegistry()
        let exportDirectory = ProcessInfo.processInfo.environment["ORIVEO_TEST_EXPORT_DIR"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        if let exportDirectory {
            try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        }
        let question = "What is the marker code printed in the attached PDF? Reply with the code only."
        for line in try Self.nativeFileLines() {
            let outcomes = try await Self.attachmentOutcomes(
                row: line.row, registry: registry, session: session,
                turns: [(.user, [Self.pdfAttachment(name: "marker.pdf")])],
                evidenceModel: Self.attachmentEvidenceModel(id: line.row.modelId, nativeFileMimes: ["application/pdf"]),
                text: question
            )
            #expect(outcomes.count == 2)
            for (mode, outcome) in zip(["nonstream", "stream"], outcomes) {
                #expect(outcome.error == nil, "\(line.name) \(mode): \(String(describing: outcome.error))")
                let body = try #require(outcome.body)
                let json = try JSONSerialization.jsonObject(with: body)
                let strings = Self.jsonStrings(in: json)
                #expect(line.hasNativePart(strings, Self.jsonKeys(in: json)), "\(line.name) \(mode)")
                #expect(strings.contains { $0.contains(question) }, "\(line.name) \(mode)")
                // The marker word is only in the PDF bytes, never in any plaintext field.
                #expect(!strings.contains { $0.contains(Self.nativePDFMarker) }, "\(line.name) \(mode)")
                guard let exportDirectory else { continue }
                let request = try #require(outcome.request)
                let exported: [String: Any] = [
                    "line": line.name,
                    "mode": mode,
                    "modelId": line.row.modelId,
                    "method": request.method ?? "POST",
                    "url": request.url?.absoluteString ?? "",
                    "path": request.url?.path ?? "",
                    "headerNames": request.headerNames,
                    "marker": Self.nativePDFMarker,
                    "body": json,
                ]
                try JSONSerialization.data(withJSONObject: exported, options: [.prettyPrinted, .sortedKeys])
                    .write(to: exportDirectory.appendingPathComponent("\(line.name).\(mode).json"))
            }
        }
    }

    @Test("frozen three-owner modes reach production bodies without same-owner auto or typed fields")
    func threeOwnerCustomModesAreMutuallyExclusiveInProductionBodies() async throws {
        let fixture = try Self.executionFixture()
        let modeCases = fixture.safeCustomCases.filter { $0.configurationMode != nil }
        let customCases = Dictionary(uniqueKeysWithValues: modeCases.filter {
            $0.configurationMode == "custom"
        }.map { ($0.owner, $0) })
        #expect(Set(customCases.keys) == Set(["web", "reasoning", "generation"]))
        let registry = try Self.capabilityRuntimeRegistry()
        let definitions = try Self.loadJSONObject(named: [
            "shared", "capabilityrecipe",
            "capability_custom_controls.v2.json",
        ])
        let session = providerMatrixSession()
        let message = ChatMessage(
            id: UUID(), role: .user, text: "hello", providerKind: .openAI,
            providerName: "OpenAI", modelID: "fixture-model", modelName: "fixture-model", state: .delivered
        )

        let webCase = try #require(customCases["web"])
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try Self.customOwnerMetadata(
            registry: registry, definitions: definitions, providerKind: "qwen", modelID: "qwen-custom",
            transport: "openai_chat", recipeRefs: ["web": "qwen.chat.web.v1"], cases: [webCase]
        ))
        var webOptions = ChatRequestOptions()
        webOptions.capabilityPreferences = .init(web: .force, reasoningIntent: nil)
        webOptions.selectLocalCustomBodyFragments([.init(
            raw: try #require(webCase.raw), owner: webCase.owner, declaredOwners: [:]
        )])
        ProviderMatrixURLProtocol.captured = []
        _ = try await CapabilityEvidenceRequestContext.$current.withValue(
            Self.matrixIdentity(providerKind: .qwen, modelID: "qwen-custom", transport: "openai_chat")
        ) {
            try await Self.sendNonstream(
                provider: .qwen, session: session, modelID: "qwen-custom", messages: [message],
                options: webOptions, webSearchEnabled: true
            )
        }
        let webBody = try #require(ProviderMatrixURLProtocol.captured.last?.body)
        let webJSON = try #require(try JSONSerialization.jsonObject(with: webBody) as? [String: Any])
        #expect(webJSON["enable_search"] as? Bool == true)
        #expect(CapabilityRecipeExecution.customControlRiskTiers(
            owner: "web", providerKind: .qwen, modelID: "qwen-custom", transport: "openai_chat"
        ) == ["privacy_impacting"])

        let reasoningCase = try #require(customCases["reasoning"])
        let generationCase = try #require(customCases["generation"])
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try Self.customOwnerMetadata(
            registry: registry, definitions: definitions, providerKind: "openAI", modelID: "openai-custom",
            transport: "openai_responses",
            recipeRefs: [
                "reasoning": "openai.responses.reasoning.v1",
                "generation": "openai.responses.generation.v1",
            ], cases: [reasoningCase, generationCase]
        ))
        var generation = GenerationParameterOverrides()
        generation.values["max_output_tokens"] = .init(state: .value, value: .number(999))
        var openAIOptions = ChatRequestOptions(generationParameters: generation)
        openAIOptions.capabilityPreferences = .init(web: .off, reasoningIntent: "low")
        openAIOptions.selectLocalCustomBodyFragments([
            .init(raw: reasoningCase.raw ?? "", owner: reasoningCase.owner, declaredOwners: [:]),
        ])
        // Generation parameters go out through the additional request body: it coexists with the
        // panel's 999, and the additional request body wins for the same field.
        openAIOptions.localAdditionalRequestBody = .init(raw: generationCase.raw ?? "")
        ProviderMatrixURLProtocol.captured = []
        _ = try await CapabilityEvidenceRequestContext.$current.withValue(
            Self.matrixIdentity(providerKind: .openAI, modelID: "openai-custom", transport: "openai_responses")
        ) {
            try await Self.sendNonstream(
                provider: .openAI, session: session, modelID: "openai-custom", messages: [message],
                options: openAIOptions, reasoningMode: .fast
            )
        }
        let openAIBody = try #require(ProviderMatrixURLProtocol.captured.last?.body)
        let openAIJSON = try #require(try JSONSerialization.jsonObject(with: openAIBody) as? [String: Any])
        #expect((openAIJSON["reasoning"] as? [String: Any])?["effort"] as? String == "high")
        #expect(openAIJSON["max_output_tokens"] as? Int == 256)
        for owner in ["reasoning", "generation"] {
            #expect(CapabilityRecipeExecution.customControlRiskTiers(
                owner: owner, providerKind: .openAI, modelID: "openai-custom", transport: "openai_responses"
            ) == ["cost_impacting"], "\(owner)")
        }

        // Final transport identity is part of authority. A fragment accepted for Responses must
        // not cross into Chat Completions even when its pointer spelling is otherwise harmless.
        var mismatchedTransportBody: [String: Any] = ["model": "openai-custom"]
        do {
            try CapabilityRecipeExecution.applySafeCustomFragments(
                [.init(raw: reasoningCase.raw ?? "", owner: "reasoning", declaredOwners: [:])],
                to: &mismatchedTransportBody, providerKind: .openAI,
                modelID: "openai-custom", transport: "openai_chat"
            )
            Issue.record("custom fragment crossed its exact final transport")
        } catch is ProviderServiceError {}
        #expect(mismatchedTransportBody.count == 1)
        #expect(mismatchedTransportBody["model"] as? String == "openai-custom")

        // Empty/no-op raw and every published value domain fail at the final body boundary. These
        // use the real OpenAI Service so a rejection after URLSession would fail captured.isEmpty.
        for raw in [
            "", "{}", #"{"reasoning":{"effort":"ultra"}}"#,
            #"{"max_output_tokens":0}"#, #"{"max_output_tokens":1.5}"#,
        ] {
            var invalid = ChatRequestOptions()
            let owner = raw.contains("max_output_tokens") ? "generation" : "reasoning"
            invalid.selectLocalCustomBodyFragments([.init(raw: raw, owner: owner, declaredOwners: [:])])
            ProviderMatrixURLProtocol.captured = []
            do {
                _ = try await CapabilityEvidenceRequestContext.$current.withValue(
                    Self.matrixIdentity(
                        providerKind: .openAI, modelID: "openai-custom", transport: "openai_responses"
                    )
                ) {
                    try await Self.sendNonstream(
                        provider: .openAI, session: session, modelID: "openai-custom",
                        messages: [message], options: invalid
                    )
                }
                Issue.record("invalid custom value reached production transport: \(raw)")
            } catch is ProviderServiceError {}
            #expect(ProviderMatrixURLProtocol.captured.isEmpty)
        }

        // Boolean is also a typed published domain; a string lookalike cannot pass Qwen's builder.
        var invalidBoolean = ChatRequestOptions()
        invalidBoolean.selectLocalCustomBodyFragments([.init(
            raw: #"{"enable_search":"true"}"#, owner: "web", declaredOwners: [:]
        )])
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try Self.customOwnerMetadata(
            registry: registry, definitions: definitions, providerKind: "qwen", modelID: "qwen-custom",
            transport: "openai_chat", recipeRefs: ["web": "qwen.chat.web.v1"], cases: [webCase]
        ))
        ProviderMatrixURLProtocol.captured = []
        do {
            _ = try await CapabilityEvidenceRequestContext.$current.withValue(
                Self.matrixIdentity(providerKind: .qwen, modelID: "qwen-custom", transport: "openai_chat")
            ) {
                try await Self.sendNonstream(
                    provider: .qwen, session: session, modelID: "qwen-custom", messages: [message],
                    options: invalidBoolean
                )
            }
            Issue.record("invalid boolean custom value reached production transport")
        } catch is ProviderServiceError {}
        #expect(ProviderMatrixURLProtocol.captured.isEmpty)
    }

    /// Typed intentions must not stop at the compiler unit test: every official Service
    /// builds a real HTTP body with automatic / force / off from `ChatRequestOptions`.
    /// Force is emitted only when the exact official recipe has a force-specific operation;
    /// every other route must remain a normal body with zero capability delta rather than
    /// silently treating force as automatic.
    @Test("17 runtime rows / 15 providers carry typed automatic, exact force and off through real builders")
    func typedCapabilityPreferencesReachProductionBodies() async throws {
        await MetadataClient.shared.resetForTesting()
        ProviderMatrixURLProtocol.responder = nil
        let session = providerMatrixSession()
        let registry = try Self.capabilityRuntimeRegistry()
        let rows = try Self.executionFixture().providerCoverage
        #expect(Set(rows.map(\.providerKind)).count == 15)

        for row in rows {
            let kind = try #require(Self.localProviderKind(forServerKey: row.providerKind))
            let recipes = try Self.capabilityRecipes(registry: registry, row: row)
            try await MetadataClient.shared.loadForTesting(json: try Self.runtimeGenerationMetadata(
                registry: registry, row: row, capabilityRecipeRefs: recipes.mapValues { recipe in
                    try! #require(recipe["id"] as? String)
                }
            ))
            let message = ChatMessage(
                id: UUID(), role: .user, text: "typed", providerKind: kind,
                providerName: kind.displayName, modelID: row.modelId, modelName: row.modelId, state: .delivered
            )
            let identity = Self.matrixIdentity(
                providerKind: kind, modelID: row.modelId, transport: row.selectorTransport ?? row.transport
            )

            func capture(_ typed: CapabilityPreferenceValues) async throws -> [String: Any] {
                var options = ChatRequestOptions()
                options.capabilityPreferences = typed
                ProviderMatrixURLProtocol.captured = []
                _ = try await CapabilityEvidenceRequestContext.$current.withValue(identity) {
                    try await Self.sendNonstream(
                        provider: kind, session: session, modelID: row.modelId, messages: [message], options: options
                    )
                }
                let body = try #require(ProviderMatrixURLProtocol.captured.last?.body)
                return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            }

            let baseline = try await capture(.init(web: .off, reasoningIntent: nil))
            let automatic = try await capture(.init(web: .automatic, reasoningIntent: nil))
            if let webRecipe = recipes["web"], let decodedWebRecipe = Self.decodeCapabilityRecipe(webRecipe) {
                #expect(
                    Self.bodyContainsRecipeOperations(automatic, recipe: webRecipe, selectedIntent: nil),
                    "\(row.providerKind)/\(row.modelId) dropped typed automatic web from its real body"
                )
            } else {
                #expect(Self.jsonDataEqual(automatic, baseline), "\(row.providerKind) emitted a web delta without an official recipe")
            }

            let force = try await capture(.init(web: .force, reasoningIntent: nil))
            if let webRecipe = recipes["web"], let decodedWebRecipe = Self.decodeCapabilityRecipe(webRecipe) {
                if Self.recipeSupports(intent: "force", recipe: decodedWebRecipe) {
                    #expect(
                        Self.bodyContainsRecipeOperations(force, recipe: webRecipe, selectedIntent: "force"),
                        "\(row.providerKind)/\(row.modelId) dropped exact force from its real body"
                    )
                    let compilation = CapabilityRecipeRequestCompiler.compile(
                        recipe: decodedWebRecipe, providerKind: row.providerKind,
                        transport: row.transport, capability: "web", selectedIntent: "force",
                        availableIntents: ["force"], base: [:]
                    )
                    #expect(compilation.applied)
                } else {
                    let compilation = CapabilityRecipeRequestCompiler.compile(
                        recipe: decodedWebRecipe, providerKind: row.providerKind,
                        transport: row.transport, capability: "web", selectedIntent: "force",
                        availableIntents: ["force"], base: [:]
                    )
                    #expect(!compilation.applied && compilation.reason == "intent_not_supported")
                    #expect(Self.jsonDataEqual(force, baseline), "\(row.providerKind) silently downgraded unavailable force to automatic")
                }
            } else {
                #expect(Self.jsonDataEqual(force, baseline), "\(row.providerKind) emitted force without an official recipe")
            }

            let off = try await capture(.init(web: .off, reasoningIntent: "off"))
            if let reasoningRecipe = recipes["reasoning"],
               let decodedReasoningRecipe = Self.decodeCapabilityRecipe(reasoningRecipe),
               Self.recipeSupports(intent: "off", recipe: decodedReasoningRecipe) {
                #expect(
                    Self.bodyContainsRecipeOperations(off, recipe: reasoningRecipe, selectedIntent: "off"),
                    "\(row.providerKind)/\(row.modelId) dropped typed reasoning off from its real body"
                )
            } else {
                if let reasoningRecipe = recipes["reasoning"], let decodedReasoningRecipe = Self.decodeCapabilityRecipe(reasoningRecipe) {
                    let compilation = CapabilityRecipeRequestCompiler.compile(
                        recipe: decodedReasoningRecipe, providerKind: row.providerKind,
                        transport: row.transport, capability: "reasoning", selectedIntent: "off",
                        availableIntents: ["off"], base: [:]
                    )
                    #expect(!compilation.applied && compilation.reason == "intent_not_supported")
                }
                #expect(Self.jsonDataEqual(off, baseline), "\(row.providerKind) emitted a reasoning field for unavailable typed off")
            }
        }
    }

    @Test("typed body matcher normalizes Foundation JSON bridges without accepting a changed value")
    func typedBodyMatcherNormalizesFoundationJSON() {
        let expectedTool: [String: Any] = ["type": "web_search", "limit": 1]
        let bridgedTool: NSDictionary = ["type": "web_search", "limit": NSNumber(value: 1)]
        #expect(Self.jsonDataEqual(expectedTool, bridgedTool))
        #expect(!Self.jsonDataEqual(expectedTool, ["type": "web_search", "limit": 2]))
        let body: [String: Any] = ["tools": [bridgedTool]]
        #expect(Self.containsAppendedJSON(body, expected: expectedTool))
        #expect(Self.jsonDataEqual(NSNumber(value: true), true))
        #expect(!Self.jsonDataEqual(NSNumber(value: true), 1))
        let nestedFoundation: NSDictionary = ["thinking": NSDictionary(dictionary: ["type": "disabled"])]
        #expect(Self.jsonDataEqual(nestedFoundation, ["thinking": ["type": "disabled"]]))
        let setRecipe: [String: Any] = [
            "id": "fixture.matcher.web.v1", "providerKind": "qwen", "capability": "web",
            "transport": ["protocol": "openai_chat"], "executionKind": "request_overlay",
            "requestOps": [["op": "set", "pointer": "/enable_search", "value": true]],
        ]
        #expect(Self.bodyContainsRecipeOperations(["enable_search": NSNumber(value: true)], recipe: setRecipe, selectedIntent: nil))
    }

    @Test("Moonshot Formula tool-loop has priority over a concurrent reasoning continuation")
    func moonshotFormulaOwnsCombinedWebAndReasoningContinuation() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try formulaAndReasoningMetadataJSON())

        let toolLoop = RecipeContinuationRuntime.selectedRecipe(
            provider: .moonshot, modelID: "kimi-formula", transport: "openai_chat",
            webSearchEnabled: true, reasoningMode: .deep,
            continuationKind: "tool_loop", parser: { $0 == "moonshot_formula_web_v1" }
        )
        #expect(toolLoop?.id == "moonshot.formula.web.v1")

        let reasoning = RecipeContinuationRuntime.selectedRecipe(
            provider: .moonshot, modelID: "kimi-formula", transport: "openai_chat",
            webSearchEnabled: true, reasoningMode: .deep,
            continuationKind: "replay_reasoning", parser: { $0 == "moonshot_reasoning_v1" }
        )
        #expect(reasoning?.id == nil, "tool-loop completedMessages owns the joint web/reasoning turn")
    }

    @Test("runtime model/transport misses preserve plain production chat with zero generation delta")
    func runtimeMissesDoNotAuthorizeGeneration() async throws {
        let registry = try Self.capabilityRuntimeRegistry()
        let rows = try Self.executionFixture().providerCoverage
        let session = providerMatrixSession()
        ProviderMatrixURLProtocol.responder = nil
        for row in rows {
            let kind = try #require(Self.localProviderKind(forServerKey: row.providerKind))
            let resolvedModelID = row.modelId
            let generationPath = Self.generationPath(for: row)
            var generation = GenerationParameterOverrides()
            generation.values["temperature"] = .init(state: .value, value: .number(0.2))

            // Model selector miss: no runtime control may borrow the neighbouring model's
            // profile. The ordinary production builder must still send and parse plain chat.
            await MetadataClient.shared.resetForTesting()
            try await MetadataClient.shared.loadForTesting(json: try Self.runtimeGenerationMetadata(registry: registry, row: row))
            let knownProfile = MetadataClient.shared.syncResolveCatalogModel(
                modelID: resolvedModelID, providerKind: kind
            )?.generationProfile
            let missingModelID = "matrix-miss-\(resolvedModelID)"
            let message = ChatMessage(id: UUID(), role: .user, text: "hello", providerKind: kind,
                                      providerName: kind.displayName, modelID: missingModelID, modelName: missingModelID, state: .delivered)
            let options = ChatRequestOptions(generationParameters: generation, generationProfile: knownProfile)
            ProviderMatrixURLProtocol.captured = []
            let modelMiss = try await CapabilityEvidenceRequestContext.$current.withValue(
                Self.matrixIdentity(providerKind: kind, modelID: missingModelID, transport: row.selectorTransport ?? row.transport)
            ) {
                try await Self.sendNonstream(provider: kind, session: session, modelID: missingModelID, messages: [message], options: options)
            }
            #expect(modelMiss.text == "ok")
            let modelMissBody = try #require(ProviderMatrixURLProtocol.captured.last?.body)
            let modelMissJSON = try #require(try JSONSerialization.jsonObject(with: modelMissBody) as? [String: Any])
            #expect(Self.value(in: modelMissJSON, path: generationPath) == nil,
                    "\(row.providerKind) model miss inherited a generation wire")

            // Exact model but recipe transport miss: runtime delivery suppresses legacy evidence
            // and emits no generation delta; the service remains a normal plain-chat transport.
            await MetadataClient.shared.resetForTesting()
            try await MetadataClient.shared.loadForTesting(json: try Self.runtimeGenerationMetadata(
                registry: registry, row: row, runtimeTransportOverride: "matrix_transport_miss"
            ))
            let profile = MetadataClient.shared.syncResolveCatalogModel(
                modelID: resolvedModelID, providerKind: kind
            )?.generationProfile
            let exactMessage = ChatMessage(id: UUID(), role: .user, text: "hello", providerKind: kind,
                                           providerName: kind.displayName, modelID: resolvedModelID, modelName: resolvedModelID, state: .delivered)
            ProviderMatrixURLProtocol.captured = []
            let transportMiss = try await CapabilityEvidenceRequestContext.$current.withValue(
                Self.matrixIdentity(providerKind: kind, modelID: resolvedModelID, transport: row.selectorTransport ?? row.transport)
            ) {
                try await Self.sendNonstream(
                    provider: kind, session: session, modelID: resolvedModelID, messages: [exactMessage],
                    options: ChatRequestOptions(generationParameters: generation, generationProfile: profile)
                )
            }
            #expect(transportMiss.text == "ok")
            let transportMissBody = try #require(ProviderMatrixURLProtocol.captured.last?.body)
            let transportMissJSON = try #require(try JSONSerialization.jsonObject(with: transportMissBody) as? [String: Any])
            #expect(Self.value(in: transportMissJSON, path: generationPath) == nil,
                    "\(row.providerKind) transport miss emitted a generation wire")
        }
    }

    @Test("a locally stored custom fragment fails closed when its runtime schema changes")
    func storedCustomFragmentDoesNotSilentlyRetryWithoutCustomFields() async throws {
        let registry = try Self.capabilityRuntimeRegistry()
        let fixture = try Self.executionFixture()
        let generationCandidate: SafeCustomCase? = fixture.safeCustomCases.first { item in
            item.owner == "generation" && item.configurationMode == "custom"
        }
        let generationCase = try #require(generationCandidate)
        let definitions = try Self.loadJSONObject(named: [
            "shared", "capabilityrecipe",
            "capability_custom_controls.v2.json",
        ])
        let kind = ProviderKind.openAI
        let modelID = "openai-schema-change"
        let session = providerMatrixSession()
        let identity = Self.matrixIdentity(providerKind: kind, modelID: modelID, transport: "openai_responses")
        let message = ChatMessage(
            id: UUID(), role: .user, text: "hello", providerKind: kind,
            providerName: kind.displayName, modelID: modelID, modelName: modelID, state: .delivered
        )

        // This is what the editor accepted against the prior exact metadata revision.
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try Self.customOwnerMetadata(
            registry: registry, definitions: definitions, providerKind: "openAI", modelID: modelID,
            transport: "openai_responses", recipeRefs: [
                "generation": "openai.responses.generation.v1",
            ], cases: [generationCase]
        ))
        let priorProfile = try #require(MetadataClient.shared.syncResolveCatalogModel(
            modelID: modelID, providerKind: kind
        )?.generationProfile)
        var options = ChatRequestOptions(generationProfile: priorProfile)
        options.localSafeCustomBodyFragment = .init(
            raw: generationCase.raw ?? "", owner: "generation", declaredOwners: [:]
        )

        // A later catalog revision revokes customControlRefs while retaining automatic generation.
        // The existing
        // local raw must stay attached until the final builder rejects it; it must not become a
        // successful plain request with its custom field silently omitted.
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try Self.customOwnerMetadata(
            registry: registry, definitions: definitions, providerKind: "openAI", modelID: modelID,
            transport: "openai_responses", recipeRefs: [
                "generation": "openai.responses.generation.v1",
            ], cases: []
        ))
        ProviderMatrixURLProtocol.captured = []
        do {
            _ = try await CapabilityEvidenceRequestContext.$current.withValue(identity) {
                try await Self.sendNonstream(
                    provider: kind, session: session, modelID: modelID, messages: [message], options: options
                )
            }
            Issue.record("metadata-changed custom fragment was silently sent without custom fields")
        } catch is ProviderServiceError {
            // Expected: the final production body boundary fails before URLSession.
        }
        #expect(ProviderMatrixURLProtocol.captured.isEmpty)
    }

    @Test("shared 19-row continuation coverage reaches only its exact runtime recipe")
    func continuationRecipeCoverageExactRuntimeGate() async throws {
        let fixture = try Self.executionFixture()
        let registry = try Self.capabilityRuntimeRegistry()
        #expect(fixture.continuationRecipeCoverage.count == 19)
        let registryRecipes = try #require(registry["recipes"] as? [String: Any])
        let continuationAliases = [
            "openrouter.chat.reasoning.v2": "openrouter.chat.reasoning.v1",
            "openrouter.chat.reasoning.v3": "openrouter.chat.reasoning.v1",
            "openrouter.chat.reasoning.v4": "openrouter.chat.reasoning.v1",
        ]
        let nonNone = Set(registryRecipes.compactMap { key, value -> String? in
            guard let recipe = value as? [String: Any],
                  let kind = recipe["continuationKind"] as? String, kind != "none" else { return nil }
            return continuationAliases[key] ?? key
        })
        #expect(Set(fixture.continuationRecipeCoverage.map(\.recipeRef)) == nonNone)

        for row in fixture.continuationRecipeCoverage {
            let kind = try #require(Self.localProviderKind(forServerKey: row.providerKind))
            await MetadataClient.shared.resetForTesting()
            try await MetadataClient.shared.loadForTesting(json: try Self.continuationMetadata(
                registry: registry, row: row, installControl: row.selectorExpected
            ))
            let selected = MetadataClient.shared.syncCapabilityRecipe(
                modelID: row.modelId, providerKind: kind, capability: row.capability
            )
            if row.selectorExpected {
                #expect(selected?.id == row.recipeRef)
                let runtimeSelected = RecipeContinuationRuntime.selectedRecipe(
                    provider: kind, modelID: row.modelId, transport: row.selectorTransport ?? row.transport,
                    webSearchEnabled: row.capability == "web", reasoningMode: row.capability == "reasoning" ? .deep : .automatic,
                    continuationKind: row.continuationKind, parser: { $0 == row.responseParserKind }
                )
                #expect(runtimeSelected?.id == row.recipeRef, "\(row.recipeRef) failed parser/kind exact gate")

                await MetadataClient.shared.resetForTesting()
                try await MetadataClient.shared.loadForTesting(json: try Self.continuationMetadata(
                    registry: registry, row: row, installControl: true, modelTransport: "matrix_transport_miss"
                ))
                #expect(MetadataClient.shared.syncCapabilityRecipe(
                    modelID: row.modelId, providerKind: kind, capability: row.capability
                )?.id == nil, "\(row.recipeRef) accepted a selector transport miss")
            } else {
                #expect(selected?.id == nil, "registered-only recipe must not auto-activate")
            }
        }
    }

    @Test("shared 19-row continuation coverage joins real Service producer, local-only sidecar, explicit wire, and CAS ACK")
    func continuationRecipeCoverageJoinedServiceSidecarAndExplicitWire() async throws {
        let fixture = try Self.executionFixture()
        let registry = try Self.capabilityRuntimeRegistry()
        #expect(fixture.continuationRecipeCoverage.count == 19)

        for row in fixture.continuationRecipeCoverage {
            let provider = try #require(Self.localProviderKind(forServerKey: row.providerKind))
            await MetadataClient.shared.resetForTesting()
            // Gemini Interactions is registered-only in the published selector contract.  This
            // explicit test envelope installs its exact control; it is not evidence of auto-select.
            try await MetadataClient.shared.loadForTesting(json: try Self.continuationMetadata(
                registry: registry, row: row, installControl: true
            ))
            let isolated = try Self.isolatedContinuationStore()

            let producer = ChatMessage(
                id: UUID(), role: .user, text: "produce opaque state", providerKind: provider,
                providerName: provider.displayName, modelID: row.modelId, modelName: row.modelId,
                state: .delivered
            )
            let assistantID = UUID()
            let partial = ChatMessage(
                id: assistantID, role: .assistant, text: "partial", providerKind: provider,
                providerName: provider.displayName, modelID: row.modelId, modelName: row.modelId,
                state: .delivered
            )
            let followUp = ChatMessage(
                id: UUID(), role: .user, text: "continue", providerKind: provider,
                providerName: provider.displayName, modelID: row.modelId, modelName: row.modelId,
                state: .delivered
            )
            var producerOptions = ChatRequestOptions()
            producerOptions.localContinuationMessageID = assistantID
            var explicitOptions = ChatRequestOptions()
            explicitOptions.localExplicitContinuationMessageID = assistantID
            let webEnabled = row.capability == "web"
            let reasoningMode: ReasoningMode = row.capability == "reasoning" ? .deep : .automatic
            let loopScript = row.continuationKind == "tool_loop"
                ? JoinedMoonshotLoopScript(isFormula: row.continuationVariant == "fiber") : nil
            let session = JoinedURLProtocol.session { request, body, ordinal in
                if let loopScript { return loopScript.response(request, body, ordinal) }
                return JoinedContinuationFixture.response(
                    recipeRef: row.recipeRef, responseParserKind: row.responseParserKind,
                    transport: row.transport, stream: true
                )
            }

            try await RecipeContinuationRuntime.withStore(isolated.store) {
                for try await _ in Self.sendStream(
                    provider: provider, session: session, modelID: row.modelId, messages: [producer],
                    options: producerOptions, webSearchEnabled: webEnabled, reasoningMode: reasoningMode
                ) {}
            }
            guard let produced = try isolated.store.load(messageID: assistantID) else {
                Issue.record("\(row.recipeRef) produced no sidecar after its real stream parser")
                try isolated.store.dbPoolForTesting.close()
                try FileManager.default.removeItem(at: isolated.directory)
                continue
            }
            #expect(produced.kind == row.continuationKind, "\(row.recipeRef) did not persist its parser-owned kind")
            #expect(produced.interrupted == false)
            let token = try #require(await RecipeContinuationRuntime.withStore(isolated.store) {
                RecipeContinuationRuntime.explicitConsumptionToken(explicitMessageID: assistantID)
            })
            let requestCount = JoinedURLProtocol.capturedRequests().count

            try await RecipeContinuationRuntime.withStore(isolated.store) {
                for try await _ in Self.sendStream(
                    provider: provider, session: session, modelID: row.modelId,
                    messages: [producer, partial, followUp], options: explicitOptions,
                    webSearchEnabled: webEnabled, reasoningMode: reasoningMode
                ) {}
            }
            let followUpRequests = JoinedURLProtocol.capturedRequests().dropFirst(requestCount)
            #expect(followUpRequests.contains {
                JoinedContinuationFixture.hasExplicitContinuationWire(
                    $0.body, continuationKind: row.continuationKind, recipeRef: row.recipeRef
                )
            }, "\(row.recipeRef) did not put its persisted opaque state on the explicit wire")

            // A successful explicit leg ACKs exactly the snapshot it consumed.  If the second
            // response produced a newer sidecar, CAS must leave that newer revision intact.
            let acknowledged = try await RecipeContinuationRuntime.withStore(isolated.store) {
                try RecipeContinuationRuntime.acknowledgeExplicitConsumption(token)
            }
            if acknowledged {
                #expect(try isolated.store.load(messageID: assistantID) == nil)
            } else {
                let refreshed = try #require(try isolated.store.load(messageID: assistantID))
                #expect(refreshed.revision > token.revision)
            }
            try isolated.store.dbPoolForTesting.close()
            try FileManager.default.removeItem(at: isolated.directory)
        }
    }

    @Test("Moonshot Formula is network-activated only for web and completes its tools/fibers loop")
    func moonshotFormulaNetworkLoopIsWebGated() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try formulaMetadataJSON())
        defer { ProviderMatrixURLProtocol.responder = nil }
        let session = providerMatrixSession()
        let message = ChatMessage(id: UUID(), role: .user, text: "search", providerKind: .moonshot,
                                  providerName: "Moonshot", modelID: "kimi-formula", modelName: "kimi-formula", state: .delivered)
        var paths: [String] = []
        var urls: [String] = []
        var fiberBodies: [[String: Any]] = []
        var chatLeg = 0
        ProviderMatrixURLProtocol.responder = { request, body in
            let path = request.url?.path ?? ""; paths.append(path)
            urls.append(request.url?.absoluteString ?? "")
            if path.hasSuffix("/tools") {
                return Data(#"{"tools":[{"type":"function","function":{"name":"web_search","parameters":{"type":"object"}}}]}"#.utf8)
            }
            if path.hasSuffix("/fibers") {
                if let body,
                   let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    fiberBodies.append(object)
                }
                return Data(#"{"context":{"encrypted_output":"opaque-result"}}"#.utf8)
            }
            chatLeg += 1
            if chatLeg == 1 {
                return Data("""
                data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"web_search","arguments":"{\\"query\\":\\"news\\"}"}}]}}]}

                data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

                data: [DONE]
                """.utf8)
            }
            return Data("""
            data: {"choices":[{"delta":{"content":"answer"}}]}

            data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

            data: [DONE]
            """.utf8)
        }
        let service = MoonshotService(session: session)
        var events: [StreamEvent] = []
        for try await event in service.sendMessageStream(
            apiKey: "test-key", modelID: "kimi-formula", messages: [message],
            baseURL: "https://proxy.example/custom/v1", webSearchEnabled: true
        ) { events.append(event) }
        #expect(paths.filter { $0.hasSuffix("/tools") }.count == 1)
        #expect(paths.filter { $0.hasSuffix("/fibers") }.count == 1)
        #expect(paths.filter { $0.hasSuffix("/chat/completions") }.count == 2)
        #expect(paths.allSatisfy { $0.hasPrefix("/custom/v1/") },
                "Formula endpoints must retain a configured API root such as /custom/v1")
        let fiberBody = try #require(fiberBodies.first)
        #expect(Set(fiberBody.keys) == ["name", "arguments"])
        #expect(fiberBody["name"] as? String == "web_search")
        #expect(fiberBody["arguments"] as? String == #"{"query":"news"}"#)
        #expect(events.contains { if case .delta("answer") = $0 { return true }; return false })

        paths = []; urls = []; chatLeg = 0; fiberBodies = []
        for try await _ in service.sendMessageStream(
            apiKey: "test-key", modelID: "kimi-formula", messages: [message], webSearchEnabled: true
        ) {}
        #expect(urls.contains("https://api.moonshot.ai/v1/formulas/moonshot/web-search:latest/tools"))
        #expect(urls.contains("https://api.moonshot.ai/v1/formulas/moonshot/web-search:latest/fibers"))
        #expect(urls.filter { $0 == "https://api.moonshot.ai/v1/chat/completions" }.count == 2)

        paths = []; chatLeg = 0
        for try await _ in service.sendMessageStream(
            apiKey: "test-key", modelID: "kimi-formula", messages: [message],
            baseURL: "https://proxy.example/custom/v1", webSearchEnabled: false
        ) {}
        #expect(paths.filter { $0.hasSuffix("/tools") }.isEmpty)
        #expect(paths.filter { $0.hasSuffix("/fibers") }.isEmpty)
    }

    @Test("Moonshot tool side effect followed by second chat-leg failure never self-heals")
    func moonshotToolSideEffectThenFailureStaysSingleLoop() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try formulaMetadataJSON())
        defer {
            ProviderMatrixURLProtocol.responder = nil
            ProviderMatrixURLProtocol.failureAfterLoadResponder = nil
        }
        var paths: [String] = []
        var chatLeg = 0
        ProviderMatrixURLProtocol.responder = { request, _ in
            let path = request.url?.path ?? ""; paths.append(path)
            if path.hasSuffix("/tools") {
                return Data(#"{"tools":[{"type":"function","function":{"name":"$web_search","parameters":{"type":"object"}}}]}"#.utf8)
            }
            if path.hasSuffix("/fibers") {
                return Data(#"{"context":{"encrypted_output":"opaque-result"}}"#.utf8)
            }
            chatLeg += 1
            if chatLeg == 1 {
                return Data("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"builtin_function\",\"function\":{\"name\":\"$web_search\",\"arguments\":\"{\\\"q\\\":\\\"news\\\"}\"}}]}}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n".utf8)
            }
            return Data("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n".utf8)
        }
        ProviderMatrixURLProtocol.failureAfterLoadResponder = { request in
            request.url?.path.hasSuffix("/chat/completions") == true && chatLeg == 2
                ? URLError(.networkConnectionLost) : nil
        }
        let message = ChatMessage(id: UUID(), role: .user, text: "search", providerKind: .moonshot,
                                  providerName: "Moonshot", modelID: "kimi-formula", modelName: "kimi-formula", state: .delivered)
        let tracker = CapabilityExecutionTracker()
        do {
            try await CapabilityExecutionRuntime.$current.withValue(tracker) {
                for try await _ in MoonshotService(session: providerMatrixSession()).sendMessageStream(
                    apiKey: "test-key", modelID: "kimi-formula", messages: [message], webSearchEnabled: true
                ) {}
            }
            Issue.record("tool loop failure unexpectedly completed")
        } catch { }
        #expect(paths.filter { $0.hasSuffix("/tools") }.count == 1)
        #expect(paths.filter { $0.hasSuffix("/fibers") }.count == 1)
        #expect(paths.filter { $0.hasSuffix("/chat/completions") }.count == 2)
        #expect(!tracker.canOfferExplicitCustomRetry,
                "a completed Moonshot fiber must close the custom pre-token retry gate")
    }

    @Test("Moonshot Formula rejects duplicate fetched tool names before chat execution")
    func moonshotFormulaDuplicateToolsFailClosed() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try formulaMetadataJSON())
        defer { ProviderMatrixURLProtocol.responder = nil }
        var paths: [String] = []
        ProviderMatrixURLProtocol.responder = { request, _ in
            paths.append(request.url?.path ?? "")
            return Data(#"{"tools":[{"type":"function","function":{"name":"$web_search","parameters":{"type":"object"}}},{"type":"function","function":{"name":"$web_search","parameters":{"type":"object"}}}]}"#.utf8)
        }
        let message = ChatMessage(id: UUID(), role: .user, text: "search", providerKind: .moonshot,
                                  providerName: "Moonshot", modelID: "kimi-formula", modelName: "kimi-formula", state: .delivered)
        let stream = MoonshotService(session: providerMatrixSession()).sendMessageStream(
            apiKey: "test-key", modelID: "kimi-formula", messages: [message], webSearchEnabled: true
        )
        do {
            for try await _ in stream {}
            Issue.record("duplicate Formula tool names reached a chat request")
        } catch is ProviderServiceError {
            // expected fail-closed before the first chat leg
        }
        #expect(paths.filter { $0.hasSuffix("/tools") }.count == 1)
        #expect(paths.filter { $0.hasSuffix("/chat/completions") }.isEmpty)
    }

    @Test("Moonshot Formula at maxToolLoops: final leg is tool_choice=none; a dangling tool call is surfaced, not executed")
    func moonshotFormulaToolLoopBoundRejectsDanglingSuccess() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try formulaMetadataJSON())
        defer { ProviderMatrixURLProtocol.responder = nil }
        var chatLegs = 0
        var fiberCalls = 0
        ProviderMatrixURLProtocol.responder = { request, _ in
            if request.url?.path.hasSuffix("/tools") == true {
                return Data(#"{"tools":[{"type":"function","function":{"name":"$web_search","parameters":{"type":"object"}}}]}"#.utf8)
            }
            if request.url?.path.hasSuffix("/fibers") == true {
                fiberCalls += 1
                return Data(#"{"context":{"encrypted_output":"opaque"}}"#.utf8)
            }
            chatLegs += 1
            // Include text deliberately: a terminal tool call may never be reported as success.
            return Data("""
            data: {"choices":[{"delta":{"content":"partial","tool_calls":[{"index":0,"id":"call_\(chatLegs)","type":"builtin_function","function":{"name":"$web_search","arguments":"{\\"q\\":\\"news\\"}"}}]}}]}

            data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

            data: [DONE]
            """.utf8)
        }
        let message = ChatMessage(id: UUID(), role: .user, text: "search", providerKind: .moonshot,
                                  providerName: "Moonshot", modelID: "kimi-formula", modelName: "kimi-formula", state: .delivered)
        var doneText: String?
        var surfaced: [ProviderToolCall] = []
        for try await event in MoonshotService(session: providerMatrixSession()).sendMessageStream(
            apiKey: "test-key", modelID: "kimi-formula", messages: [message], webSearchEnabled: true
        ) {
            switch event {
            case let .done(result): doneText = result.text
            case let .toolCallDeltas(calls): surfaced.append(contentsOf: calls)
            default: break
            }
        }
        #expect(chatLegs == 5, "max=4 permits four completed tool legs and one final answer leg")
        #expect(fiberCalls == 4, "the dangling fifth-leg call must not run a fiber")
        #expect(surfaced.map(\.providerCallID) == ["call_5"])
        #expect(doneText == String(repeating: "partial", count: 5))
    }

    @Test("Gemini Interactions uses GA route and parses root/nonstream plus step.delta stream")
    func geminiInteractionsNetworkWire() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try interactionsMetadataJSON())
        defer { ProviderMatrixURLProtocol.responder = nil }
        let session = providerMatrixSession()
        let user = ChatMessage(id: UUID(), role: .user, text: "news", providerKind: .gemini,
                               providerName: "Gemini", modelID: "gemini-interactions", modelName: "gemini-interactions", state: .delivered)
        let assistant = ChatMessage(id: UUID(), role: .assistant, text: "old", providerKind: .gemini,
                                    providerName: "Gemini", modelID: "gemini-interactions", modelName: "gemini-interactions", state: .delivered)
        var requests: [ProviderMatrixURLProtocol.CapturedRequest] = []
        ProviderMatrixURLProtocol.responder = { request, body in
            requests.append(.init(url: request.url, body: body))
            if (try? JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any])?["stream"] as? Bool == true {
                return Data("""
                data: {"event_type":"step.delta","delta":{"type":"text","text":"stream"}}

                data: {"interaction":{"id":"interaction_stream","status":"completed"}}

                data: [DONE]
                """.utf8)
            }
            return Data(#"{"id":"interaction_root","status":"completed","steps":[{"type":"model_output","content":{"text":"nonstream"}}]}"#.utf8)
        }
        let service = GeminiService(session: session)
        let result = try await service.sendMessage(
            apiKey: "test-key", modelID: "gemini-interactions", messages: [user, assistant], webSearchEnabled: true
        )
        #expect(result.text == "nonstream")
        var streamed = ""
        for try await event in service.sendMessageStream(
            apiKey: "test-key", modelID: "gemini-interactions", messages: [user, assistant], webSearchEnabled: true
        ) {
            if case let .delta(text) = event { streamed += text }
        }
        #expect(streamed == "stream")
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1/interactions")
        }
        let nonstreamData = try #require(requests.first?.body)
        let streamingData = try #require(requests.last?.body)
        let nonstream = try #require(try JSONSerialization.jsonObject(with: nonstreamData) as? [String: Any])
        let streaming = try #require(try JSONSerialization.jsonObject(with: streamingData) as? [String: Any])
        #expect(nonstream["stream"] as? Bool == false)
        #expect(streaming["stream"] as? Bool == true)
        #expect((nonstream["input"] as? [[String: Any]])?.map { $0["role"] as? String } == ["user", "model"])

        let activeRecipe = try #require(MetadataClient.shared.syncCapabilityRecipe(
            modelID: "gemini-interactions", providerKind: .gemini, capability: "web"
        ))
        // Interactions has no exact generation transport recipe. A custom body fragment must
        // therefore be rejected rather than borrowing Gemini generateContent's schema.
        #expect(throws: ProviderServiceError.self) {
            _ = try service.buildInteractionsRequest(
                modelID: "gemini-interactions", messages: [user], apiKey: "test-key", stream: false,
                recipe: activeRecipe,
                safeCustomBodyFragments: [.init(
                    raw: #"{"generationConfig":{"temperature":0.2}}"#,
                    owner: "generation", declaredOwners: ["/generationConfig/temperature": "generation"]
                )]
            )
        }
        #expect(requests.count == 2, "invalid custom schema must fail before any network request")
    }

    private func formulaMetadataJSON() throws -> String {
        let registry = try Self.capabilityRuntimeRegistry()
        let recipes = try #require(registry["recipes"] as? [String: Any])
        let formulaRecipe = try #require(recipes["moonshot.formula.web.v1"] as? [String: Any])
        #expect(formulaRecipe["providerKind"] as? String == "moonshot")
        #expect((formulaRecipe["transport"] as? [String: Any])?["protocol"] as? String == "openai_chat")
        #expect(formulaRecipe["continuationKind"] as? String == "tool_loop")
        #expect(formulaRecipe["continuationVariant"] as? String == "fiber")
        let document: [String: Any] = [
            "version": 1,
            "providers": ["moonshot": [
                "resolveMap": ["kimi-formula": "kimi-formula"],
                "models": ["kimi-formula": ["canonicalModelId": "kimi-formula", "transport": "openai_chat",
                                                  "capabilityControls": ["web": ["state": "auto_available", "recipeRef": "moonshot.formula.web.v1"]]]],
            ]],
            "capabilityRuntime": ["schemaVersion": 2, "revision": "formula-test", "generatedAt": "2026-08-11T00:00:00Z",
                                  "recipes": recipes, "controlDefinitions": registry["controlDefinitions"] ?? [:], "sourceIndex": registry["sourceIndex"] ?? [:]],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)
    }

    private func formulaAndReasoningMetadataJSON() throws -> String {
        let data = try Data(formulaMetadataJSON().utf8)
        var document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var providers = try #require(document["providers"] as? [String: Any])
        var moonshot = try #require(providers["moonshot"] as? [String: Any])
        var models = try #require(moonshot["models"] as? [String: Any])
        var model = try #require(models["kimi-formula"] as? [String: Any])
        model["capabilityControls"] = [
            "web": ["state": "auto_available", "recipeRef": "moonshot.formula.web.v1"],
            "reasoning": ["state": "auto_available", "recipeRef": "moonshot.reasoning.v1"],
        ]
        models["kimi-formula"] = model
        moonshot["models"] = models
        providers["moonshot"] = moonshot
        document["providers"] = providers
        return String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)
    }

    private func interactionsMetadataJSON() throws -> String {
        let registry = try Self.capabilityRuntimeRegistry()
        let recipes = try #require(registry["recipes"] as? [String: Any])
        let interactionsRecipe = try #require(recipes["gemini.interactions.web.v1"] as? [String: Any])
        #expect(interactionsRecipe["executionKind"] as? String == "endpoint_route")
        #expect((interactionsRecipe["route"] as? [String: Any])?["path"] as? String == "/v1/interactions")
        let document: [String: Any] = [
            "version": 1,
            "providers": ["gemini": [
                "resolveMap": ["gemini-interactions": "gemini-interactions"],
                "models": ["gemini-interactions": ["canonicalModelId": "gemini-interactions", "transport": "gemini_generate",
                                                       "capabilityControls": ["web": ["state": "auto_available", "recipeRef": "gemini.interactions.web.v1"]]]],
            ]],
            "capabilityRuntime": ["schemaVersion": 2, "revision": "interactions-test", "generatedAt": "2026-08-11T00:00:00Z",
                                  "recipes": recipes, "controlDefinitions": registry["controlDefinitions"] ?? [:], "sourceIndex": registry["sourceIndex"] ?? [:]],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)
    }

    private static func capabilityRuntimeRegistry() throws -> [String: Any] {
        let fixture = try executionFixture()
        var registry = try loadJSONObject(named: fixture.registryPath.split(separator: "/").map(String.init))
        let definitions = try loadJSONObject(named: [
            "shared", "capabilityrecipe",
            "capability_result_definitions.v1.json",
        ])
        let bindings = try #require(definitions["recipeBindings"] as? [String: [String: Any]])
        let evidence = try #require(definitions["responseEvidenceDefinitions"] as? [String: [String: Any]])
        let locatorRules = (definitions["errorRecoveryDefinitions"] as? [String: Any])?["locatorRules"]
            as? [String: Any] ?? [:]
        var recipes = try #require(registry["recipes"] as? [String: Any])
        for (recipeID, raw) in recipes {
            guard var recipe = raw as? [String: Any],
                  let binding = bindings[recipeID],
                  let evidenceRef = binding["responseEvidenceRef"] as? String,
                  let recoveryRef = binding["errorRecoveryRef"] as? String else { continue }
            recipe["responseEvidenceRef"] = evidenceRef
            recipe["errorRecoveryRef"] = recoveryRef
            recipes[recipeID] = recipe
        }
        var recoveryDefinitions: [String: Any] = [:]
        for (ref, definition) in evidence {
            recoveryDefinitions[ref] = [
                "capability": definition["capability"] ?? "",
                "protocol": definition["protocol"] ?? "",
                "responseParserKind": definition["responseParserKind"] ?? "",
                "locatorRules": locatorRules[ref] ?? [],
            ]
        }
        registry["recipes"] = recipes
        registry["responseEvidenceDefinitions"] = evidence
        registry["errorRecoveryDefinitions"] = recoveryDefinitions
        return registry
    }

    private static func serverWebSearchProfiles() throws -> [String: Any] {
        let golden = try loadJSONObject(named: [
            "shared", "capabilityrecipe",
            "testdata", "legacy_profiles.golden.json",
        ])
        return try #require(golden["webSearch"] as? [String: Any])
    }

    private static func loadJSONObject(named suffix: [String]) throws -> [String: Any] {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while folder.path != "/" {
            let file = suffix.reduce(folder) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: file.path) {
                return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            }
            folder.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private struct ExecutionFixture: Decodable {
        let registryPath: String
        let providerCoverage: [ProviderCoverage]
        let continuationRecipeCoverage: [ContinuationRecipeCoverage]
        let safeCustomCases: [SafeCustomCase]
    }

    private struct SafeCustomCase: Decodable {
        let caseId: String
        let owner: String
        let configurationMode: String?
        let raw: String?
        let controlRefs: [String]?
        let expectRecipeSelected: Bool?
        let expectCustomApplied: Bool?
        let expectTypedOwnerOmitted: Bool?
    }

    private struct ProviderCoverage: Decodable {
        let providerKind: String
        let transport: String
        let selectorTransport: String?
        let recipeRef: String
        let modelId: String
    }

    private struct ContinuationRecipeCoverage: Decodable {
        let providerKind: String
        let transport: String
        let selectorTransport: String?
        let recipeRef: String
        let modelId: String
        let capability: String
        let responseParserKind: String
        let continuationKind: String
        let continuationVariant: String?
        let selectorExpected: Bool
    }

    private static func executionFixture() throws -> ExecutionFixture {
        try loadJSON(named: ["shared", "model-contracts", "provider_recipe_execution.v1.json"])
    }

    private static func localProviderKind(forServerKey key: String) -> ProviderKind? {
        switch key {
        case "togetherAI": return .together
        case "fireworksAI": return .fireworks
        default: return ProviderKind(rawValue: key)
        }
    }

    private static func service(for kind: ProviderKind, session: URLSession) -> (any ProviderServiceProtocol)? {
        switch kind {
        case .openAI: return OpenAIService(session: session)
        case .anthropic: return AnthropicService(session: session)
        case .gemini: return GeminiService(session: session)
        case .openRouter: return OpenRouterService(session: session)
        case .groq: return GroqService(session: session)
        case .deepseek: return DeepSeekService(session: session)
        case .siliconFlow: return SiliconFlowService(session: session)
        case .together: return TogetherService(session: session)
        case .fireworks: return FireworksService(session: session)
        case .miniMax: return MiniMaxService(session: session)
        case .zhipu: return ZhipuService(session: session)
        case .qwen: return QwenService(session: session)
        case .grok: return GrokService(session: session)
        case .moonshot: return MoonshotService(session: session)
        case .mistral: return MistralService(session: session)
        case .relay: return nil
        }
    }

    /// This switch is intentionally a dispatcher, not a second builder.  Each arm calls the
    /// public production Service overload that accepts `ChatRequestOptions`, so the matrix proves
    /// the runtime-authorized typed generation parameter reaches the real encoder for all rows.
    private static func sendNonstream(
        provider: ProviderKind, session: URLSession, modelID: String,
        messages: [ChatMessage], options: ChatRequestOptions,
        webSearchEnabled: Bool = false, reasoningMode: ReasoningMode = .automatic
    ) async throws -> ProviderChatResult {
        switch provider {
        case .openAI:
            return try await OpenAIService(session: session).sendMessage(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled, requestOptions: options
            )
        case .anthropic:
            return try await AnthropicService(session: session).sendMessage(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled, requestOptions: options
            )
        case .gemini:
            return try await GeminiService(session: session).sendMessage(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled, requestOptions: options
            )
        case .openRouter:
            return try await OpenRouterService(session: session).sendMessage(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled, requestOptions: options
            )
        case .groq:
            return try await GroqService(session: session).sendMessage(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, requestOptions: options
            )
        case .deepseek:
            return try await DeepSeekService(session: session).sendMessage(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, requestOptions: options
            )
        case .siliconFlow:
            return try await SiliconFlowService(session: session).sendMessage(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, requestOptions: options
            )
        case .together:
            return try await TogetherService(session: session).sendMessage(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, requestOptions: options
            )
        case .fireworks:
            return try await FireworksService(session: session).sendMessage(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, requestOptions: options
            )
        case .miniMax:
            var effectiveOptions = options
            if webSearchEnabled {
                var preferences = effectiveOptions.capabilityPreferences ?? CapabilityPreferenceValues()
                preferences.web = .automatic
                effectiveOptions.capabilityPreferences = preferences
            }
            return try await MiniMaxService(session: session).sendMessage(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, requestOptions: effectiveOptions
            )
        case .zhipu:
            return try await ZhipuService(session: session).sendMessage(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, requestOptions: options
            )
        case .qwen:
            return try await QwenService(session: session).sendMessage(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, requestOptions: options
            )
        case .grok:
            return try await GrokService(session: session).sendMessage(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled, requestOptions: options
            )
        case .moonshot:
            return try await MoonshotService(session: session).sendMessage(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled, requestOptions: options
            )
        case .mistral:
            return try await MistralService(session: session).sendMessage(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, requestOptions: options
            )
        case .relay:
            throw ProviderServiceError.invalidConfiguration(detail: "No official provider service.")
        }
    }

    private static func sendStream(
        provider: ProviderKind, session: URLSession, modelID: String,
        messages: [ChatMessage], options: ChatRequestOptions,
        webSearchEnabled: Bool = false, reasoningMode: ReasoningMode = .automatic
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        switch provider {
        case .openAI:
            return OpenAIService(session: session).sendMessageStream(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled, requestOptions: options
            )
        case .anthropic:
            return AnthropicService(session: session).sendMessageStream(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled, requestOptions: options
            )
        case .gemini:
            return GeminiService(session: session).sendMessageStream(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled, requestOptions: options
            )
        case .openRouter:
            return OpenRouterService(session: session).sendMessageStream(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled, requestOptions: options
            )
        case .groq:
            return GroqService(session: session).sendMessageStream(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, requestOptions: options
            )
        case .deepseek:
            return DeepSeekService(session: session).sendMessageStream(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, requestOptions: options
            )
        case .siliconFlow:
            return SiliconFlowService(session: session).sendMessageStream(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, requestOptions: options
            )
        case .together:
            return TogetherService(session: session).sendMessageStream(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, requestOptions: options
            )
        case .fireworks:
            return FireworksService(session: session).sendMessageStream(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, requestOptions: options
            )
        case .miniMax:
            var effectiveOptions = options
            if webSearchEnabled {
                var preferences = effectiveOptions.capabilityPreferences ?? CapabilityPreferenceValues()
                preferences.web = .automatic
                effectiveOptions.capabilityPreferences = preferences
            }
            return MiniMaxService(session: session).sendMessageStream(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, requestOptions: effectiveOptions
            )
        case .zhipu:
            return ZhipuService(session: session).sendMessageStream(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, requestOptions: options
            )
        case .qwen:
            return QwenService(session: session).sendMessageStream(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, requestOptions: options
            )
        case .grok:
            return GrokService(session: session).sendMessageStream(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled, requestOptions: options
            )
        case .moonshot:
            return MoonshotService(session: session).sendMessageStream(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled, requestOptions: options
            )
        case .mistral:
            return MistralService(session: session).sendMessageStream(
                apiKey: "test-key", modelID: modelID, messages: messages,
                reasoningMode: reasoningMode, requestOptions: options
            )
        case .relay:
            return AsyncThrowingStream { $0.finish(throwing: ProviderServiceError.invalidConfiguration(detail: "No official provider service.")) }
        }
    }

    private static func matrixIdentity(
        providerKind: ProviderKind, modelID: String, transport: String
    ) -> CapabilityEvidenceRequestIdentity {
        .init(query: .init(
            partitionID: "matrix", connectionInstanceID: "matrix-connection",
            connectionGeneration: "matrix-generation", credentialEpoch: "matrix-credential",
            providerKind: providerKind.rawValue, modelID: modelID,
            effectiveTransport: transport, now: 0, hasExplicitValue: true
        ))
    }

    private static func p5RawStream(
        providerKind: String, transport: String, events: [String], requestBody: Data? = nil
    ) -> Data {
        guard let event = events.first else {
            return Data("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n".utf8)
        }
        // Zhipu's sources are in the top-level `web_search` of the response (official API reference), not OpenRouter-style annotations.
        if providerKind == "zhipu", event == "citations" {
            return Data("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}],\"web_search\":[{\"title\":\"Proof\",\"link\":\"https://example.com\",\"content\":\"proof\"}]}\n\ndata: [DONE]\n".utf8)
        }
        // Moonshot builtin search: leg 1 replays the real recorded sample, the feed-back leg returns the body text.
        if providerKind == "moonshot", event == "tool_result" {
            if bodyCarriesToolResult(requestBody) { return plainChatAnswer }
            return (try? fixtureData(named: [
                "shared", "test-fixtures", "provider-toolcall", "recorded", "moonshot_web_search.leg1.sse",
            ])) ?? Data()
        }
        if providerKind == "mistral", event == "reasoning" {
            return Data("data: {\"choices\":[{\"delta\":{\"content\":[{\"type\":\"thinking\",\"thinking\":[{\"type\":\"text\",\"text\":\"proof\"}]}]}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n".utf8)
        }
        switch (transport, event) {
        case ("openai_responses", "citations"):
            return Data("event: response.output_text.annotation.added\ndata: {\"type\":\"response.output_text.annotation.added\",\"annotation\":{\"type\":\"url_citation\",\"url\":\"https://example.com\",\"title\":\"Proof\"}}\n\nevent: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"p5\",\"status\":\"completed\"}}\n\n".utf8)
        case ("anthropic_messages", "citations"):
            return Data("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"citations_delta\",\"citation\":{\"url\":\"https://example.com\",\"title\":\"Proof\"}}}\n\nevent: message_stop\ndata: {}\n\n".utf8)
        case ("gemini_generate_content", "citations"):
            return Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"ok\"}]},\"groundingMetadata\":{\"groundingChunks\":[{\"web\":{\"uri\":\"https://example.com\",\"title\":\"Proof\"}}]}}]}\n\n".utf8)
        case ("openai_chat", "citations"):
            return Data("data: {\"choices\":[{\"delta\":{\"annotations\":[{\"type\":\"url_citation\",\"url_citation\":{\"url\":\"https://example.com\",\"title\":\"Proof\"}}]}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n".utf8)
        case (_, "reasoning"):
            return Data("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"proof\"}}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n".utf8)
        default:
            return Data("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n".utf8)
        }
    }

    private static func value(in object: [String: Any], path: [String]) -> Any? {
        path.dropFirst().reduce(object[path.first ?? ""]) { value, component in
            (value as? [String: Any])?[component]
        }
    }

    private static func generationPath(for row: ProviderCoverage) -> [String] {
        row.transport == "gemini_generate_content" ? ["generationConfig", "temperature"] : ["temperature"]
    }

    private static func isolatedContinuationStore() throws -> (store: RecipeContinuationStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oriveo-joined-continuation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: directory.appendingPathComponent("sidecar.sqlite").path)
        return (try RecipeContinuationStore(dbPool: pool), directory)
    }

    private static func loadJSON<T: Decodable>(named suffix: [String]) throws -> T {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while folder.path != "/" {
            let file = suffix.reduce(folder) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: file.path) {
                return try JSONDecoder().decode(T.self, from: Data(contentsOf: file))
            }
            folder.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func capabilityRecipes(
        registry: [String: Any], row: ProviderCoverage
    ) throws -> [String: [String: Any]] {
        let all = try #require(registry["recipes"] as? [String: Any])
        let expectedTransport = CapabilityRecipeRequestCompiler.canonicalTransport(row.transport)
        var candidates: [String: [[String: Any]]] = [:]
        for raw in all.values {
            guard let recipe = raw as? [String: Any],
                  let capability = recipe["capability"] as? String,
                  ["web", "reasoning"].contains(capability),
                  recipe["providerKind"] as? String == row.providerKind,
                  let transport = recipe["transport"] as? [String: Any],
                  let protocolName = transport["protocol"] as? String,
                  CapabilityRecipeRequestCompiler.canonicalTransport(protocolName) == expectedTransport else {
                continue
            }
            candidates[capability, default: []].append(recipe)
        }
        // A registry can carry parallel revisions (Gemini does today). The test deliberately
        // refuses to invent a client-side winner: an ambiguous capability gets no control and
        // must therefore prove its typed value produces zero body delta until the catalog selects it.
        return candidates.compactMapValues { $0.count == 1 ? $0[0] : nil }
    }

    private static func recipeSupports(intent: String, recipe: MetadataClient.CapabilityRecipe) -> Bool {
        recipe.requestOps.contains { $0.intent == intent }
    }

    private static func decodeCapabilityRecipe(_ value: [String: Any]) -> MetadataClient.CapabilityRecipe? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(MetadataClient.CapabilityRecipe.self, from: data)
    }

    private static func bodyContainsRecipeOperations(
        _ body: [String: Any], recipe: [String: Any], selectedIntent: String?
    ) -> Bool {
        guard let decoded = decodeCapabilityRecipe(recipe) else { return false }
        var expected: [String: Any] = [:]
        let result = CapabilityRecipeRequestCompiler.compile(
            recipe: decoded, to: &expected, providerKind: decoded.providerKind,
            transport: decoded.transport.protocolName, capability: decoded.capability,
            selectedIntent: selectedIntent,
            availableIntents: selectedIntent.map { [$0] }
        )
        guard result.applied else { return false }
        let selectedOperations = ((recipe["requestOps"] as? [[String: Any]]) ?? []).filter { operation in
            let intent = operation["intent"] as? String
            return intent == nil || intent == selectedIntent
        }
        let roots = Set(selectedOperations.compactMap { operation in
            (operation["pointer"] as? String)?.split(separator: "/").first.map(String.init)
        })
        return roots.allSatisfy { root in
            guard let expectedValue = expected[root], let actualValue = body[root] else { return false }
            return jsonDataEqual(actualValue, expectedValue)
        }
    }

    private static func containsAppendedJSON(_ body: [String: Any], expected: Any) -> Bool {
        ((body["tools"] as? [Any]) ?? []).contains { jsonDataEqual($0, expected) }
    }

    private static func jsonDataEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        guard let normalizedLeft = normalizedJSON(lhs), let normalizedRight = normalizedJSON(rhs),
              JSONSerialization.isValidJSONObject(normalizedLeft),
              JSONSerialization.isValidJSONObject(normalizedRight),
              let left = try? JSONSerialization.data(withJSONObject: normalizedLeft, options: [.sortedKeys]),
              let right = try? JSONSerialization.data(withJSONObject: normalizedRight, options: [.sortedKeys]) else { return false }
        return left == right
    }

    /// Foundation bridges Bool and numbers through NSNumber, while JSONSerialization considers
    /// `true` and `1` interchangeable on some paths. Tag every scalar before comparing so nested
    /// NSDictionary/NSArray values stay structurally equal without weakening type identity.
    private static func normalizedJSON(_ value: Any) -> Any? {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return ["$bool": number.boolValue]
            }
            return ["$number": number.stringValue]
        }
        if let string = value as? String { return ["$string": string] }
        if value is NSNull { return ["$null": true] }
        if let object = value as? NSDictionary {
            var normalized: [String: Any] = [:]
            for (rawKey, rawChild) in object {
                guard let key = rawKey as? String,
                      let child = normalizedJSON(rawChild) else { return nil }
                normalized[key] = child
            }
            return ["$object": normalized]
        }
        if let array = value as? NSArray {
            let normalized = array.compactMap(normalizedJSON)
            guard normalized.count == array.count else { return nil }
            return ["$array": normalized]
        }
        if let object = value as? [String: Any] {
            var normalized: [String: Any] = [:]
            for (key, child) in object {
                guard let child = normalizedJSON(child) else { return nil }
                normalized[key] = child
            }
            return ["$object": normalized]
        }
        if let array = value as? [Any] {
            let normalized = array.compactMap(normalizedJSON)
            guard normalized.count == array.count else { return nil }
            return ["$array": normalized]
        }
        return nil
    }

    private static func runtimeGenerationMetadata(
        registry: [String: Any], row: ProviderCoverage, runtimeTransportOverride: String? = nil,
        capabilityRecipeRefs: [String: String] = [:], webSearchProfile: String? = nil
    ) throws -> String {
        let recipes = try #require(registry["recipes"] as? [String: Any])
        let recipe = try #require(recipes[row.recipeRef] as? [String: Any])
        let transport = try #require(recipe["transport"] as? [String: Any])
        let protocolName = try #require(transport["protocol"] as? String)
        let operation = try #require((recipe["requestOps"] as? [[String: Any]])?.first)
        let template = try #require(operation["template"] as? String)
        let wire = template == "gemini_generate_content"
            ? "generationConfig.temperature" : "temperature"
        let modelTransport = row.selectorTransport ?? protocolName
        var runtimeRecipes = recipes
        if let runtimeTransportOverride {
            var mutated = recipe
            var mutatedTransport = transport
            mutatedTransport["protocol"] = runtimeTransportOverride
            mutated["transport"] = mutatedTransport
            runtimeRecipes[row.recipeRef] = mutated
        }
        var capabilityControls: [String: Any] = [
            "generation": ["state": "auto_available", "recipeRef": row.recipeRef],
        ]
        for (capability, recipeRef) in capabilityRecipeRefs {
            guard let capabilityRecipe = recipes[recipeRef] as? [String: Any] else { continue }
            let intents = Set(((capabilityRecipe["requestOps"] as? [[String: Any]]) ?? []).compactMap {
                $0["intent"] as? String
            }).sorted()
            capabilityControls[capability] = [
                "state": "auto_available", "recipeRef": recipeRef, "availableIntents": intents,
            ]
        }
        var profiles: [String: Any] = ["generation": [
            "version": 1,
            "parameters": [:],
            "templates": [template: ["transport": template, "wire": ["temperature": wire]]],
        ]]
        var modelProfiles: [String: Any] = ["generation": [
            "template": template, "revision": "matrix-generation",
            "parameters": [["id": "temperature", "support": "supported", "source": "authoritative_metadata"]],
        ]]
        if let webSearchProfile {
            let definitions = try serverWebSearchProfiles()
            profiles["webSearch"] = [webSearchProfile: try #require(definitions[webSearchProfile])]
            modelProfiles["webSearch"] = webSearchProfile
        }
        let document: [String: Any] = [
            "version": 1,
            "profiles": profiles,
            "providers": [row.providerKind: [
                "resolveMap": [row.modelId: row.modelId],
                "models": [row.modelId: [
                    "canonicalModelId": row.modelId,
                    "transport": modelTransport,
                    "profiles": modelProfiles,
                    "capabilityControls": capabilityControls,
                ]],
            ]],
            "capabilityRuntime": [
                "schemaVersion": 2, "revision": "matrix-runtime", "generatedAt": "2026-08-11T00:00:00Z",
                "recipes": runtimeRecipes, "controlDefinitions": registry["controlDefinitions"] ?? [:],
                "sourceIndex": registry["sourceIndex"] ?? [:],
                "responseEvidenceDefinitions": registry["responseEvidenceDefinitions"] ?? [:],
                "errorRecoveryDefinitions": registry["errorRecoveryDefinitions"] ?? [:],
            ],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)
    }

    private static func customOwnerMetadata(
        registry: [String: Any], definitions: [String: Any], providerKind: String,
        modelID: String, transport: String, recipeRefs: [String: String], cases: [SafeCustomCase]
    ) throws -> String {
        let recipes = try #require(registry["recipes"] as? [String: Any])
        let refsByOwner = Dictionary(uniqueKeysWithValues: cases.map {
            ($0.owner, $0.controlRefs ?? [])
        })
        var controls: [String: Any] = [:]
        for owner in Set(recipeRefs.keys).union(refsByOwner.keys) {
            var control: [String: Any] = ["state": "auto_available"]
            if let recipeRef = recipeRefs[owner] { control["recipeRef"] = recipeRef }
            if let refs = refsByOwner[owner], !refs.isEmpty { control["customControlRefs"] = refs }
            if owner == "reasoning" { control["availableIntents"] = ["low", "balanced", "deep"] }
            controls[owner] = control
        }
        let generationProfile: [String: Any] = [
            "version": 1,
            "parameters": ["max_output_tokens": [
                "id": "max_output_tokens", "type": "number", "min": 1, "max": 128000,
                "support": "supported", "source": "authoritative_metadata",
            ]],
            "templates": ["openai_responses": [
                "transport": "openai_responses", "wire": ["max_output_tokens": "max_output_tokens"],
            ]],
        ]
        let document: [String: Any] = [
            "version": 1,
            "profiles": ["generation": generationProfile],
            "providers": [providerKind: [
                "resolveMap": [modelID: modelID],
                "models": [modelID: [
                    "canonicalModelId": modelID, "transport": transport,
                    "profiles": ["generation": [
                        "template": "openai_responses", "revision": "custom-owner-matrix",
                        "parameters": [[
                            "id": "max_output_tokens", "support": "supported",
                            "source": "authoritative_metadata",
                        ]],
                    ]],
                    "capabilityControls": controls,
                ]],
            ]],
            "capabilityRuntime": [
                "schemaVersion": 2, "revision": "custom-owner-matrix",
                "generatedAt": "2026-08-12T00:00:00Z", "recipes": recipes,
                "controlDefinitions": definitions, "sourceIndex": registry["sourceIndex"] ?? [:],
                "responseEvidenceDefinitions": registry["responseEvidenceDefinitions"] ?? [:],
                "errorRecoveryDefinitions": registry["errorRecoveryDefinitions"] ?? [:],
            ],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)
    }

    private static func continuationMetadata(
        registry: [String: Any], row: ContinuationRecipeCoverage,
        installControl: Bool, modelTransport: String? = nil
    ) throws -> String {
        let recipes = try #require(registry["recipes"] as? [String: Any])
        let recipe = try #require(recipes[row.recipeRef] as? [String: Any])
        let protocolName = try #require((recipe["transport"] as? [String: Any])?["protocol"] as? String)
        var model: [String: Any] = [
            "canonicalModelId": row.modelId,
            "transport": modelTransport ?? row.selectorTransport ?? protocolName,
        ]
        if installControl {
            model["capabilityControls"] = [row.capability: ["state": "auto_available", "recipeRef": row.recipeRef]]
        }
        let document: [String: Any] = [
            "version": 1,
            "providers": [row.providerKind: [
                "resolveMap": [row.modelId: row.modelId], "models": [row.modelId: model],
            ]],
            "capabilityRuntime": [
                "schemaVersion": 2, "revision": "continuation-matrix", "generatedAt": "2026-08-11T00:00:00Z",
                "recipes": recipes, "controlDefinitions": registry["controlDefinitions"] ?? [:],
                "sourceIndex": registry["sourceIndex"] ?? [:],
            ],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)
    }
}
