import Foundation

/// URLProtocol transport used by the continuation joined-path matrix.  The
/// matrix is serialized, but URLSession invokes this class on its own queue, so
/// request capture and script selection remain locked rather than relying on
/// XCTest's execution order.
final class JoinedURLProtocol: URLProtocol, @unchecked Sendable {
    struct CapturedRequest: Sendable {
        let url: URL?
        let body: Data?
        let ordinal: Int
    }

    /// URLProtocol itself owns cross-thread delivery; the locked storage below
    /// is the synchronization boundary.  Keeping the callback non-Sendable lets
    /// a `@Suite(.serialized)` test capture its decoded fixture row directly.
    typealias Responder = (URLRequest, Data?, Int) -> Data

    nonisolated(unsafe) private static var lock = NSLock()
    nonisolated(unsafe) private static var responder: Responder?
    nonisolated(unsafe) private static var captured: [CapturedRequest] = []

    static func session(responder: @escaping Responder) -> URLSession {
        reset(responder: responder)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JoinedURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset(responder: Responder? = nil) {
        lock.lock()
        self.responder = responder
        captured = []
        lock.unlock()
    }

    static func capturedRequests() -> [CapturedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.readBody(from: request.httpBodyStream)
        Self.lock.lock()
        let ordinal = Self.captured.count
        Self.captured.append(.init(url: request.url, body: body, ordinal: ordinal))
        let handler = Self.responder
        Self.lock.unlock()

        guard let url = request.url, let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let payload = handler(request, body, ordinal)
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

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

/// Fixtures are deliberately protocol-shaped source responses, not prebuilt
/// continuation state.  The production Service parser must derive the opaque
/// sidecar from these bodies before the matrix sends its explicit follow-up.
enum JoinedContinuationFixture {
    static let previousResponseID = "resp_joined"
    static let previousInteractionID = "interaction_joined"
    static let opaqueThinking = "opaque joined thinking"
    static let opaqueSignature = "opaque-joined-signature"
    static let joinedText = "joined"
    static let citationURL = "https://example.com/joined"

    /// Selects a real producer response from a shared continuation coverage row.
    /// The same body is valid for the initial producer and the explicit consumer
    /// round, preventing a fixture-only parsing path from hiding wire failures.
    static func response(
        recipeRef: String,
        responseParserKind: String,
        transport: String,
        stream: Bool
    ) -> Data {
        if recipeRef == "gemini.interactions.web.v1" || transport == "gemini_interactions" {
            return stream ? interactionsStream() : interactionsResponse()
        }
        if responseParserKind == "minimax_anthropic_web_v1" {
            return stream ? miniMaxAnthropicWebStream() : miniMaxAnthropicWebResponse()
        }
        if responseParserKind.hasPrefix("anthropic_") || transport == "anthropic_messages" {
            return stream ? anthropicStream() : anthropicResponse()
        }
        if responseParserKind.hasPrefix("gemini_") || transport == "gemini_generate_content" {
            return stream ? geminiGenerateStream() : geminiGenerateResponse()
        }
        if responseParserKind.hasPrefix("openai_responses_") || responseParserKind.hasPrefix("grok_") || transport == "openai_responses" {
            return stream ? responsesStream() : responsesResponse()
        }
        if responseParserKind == "openrouter_reasoning_v1" {
            return stream ? openRouterReasoningStream() : openRouterReasoningResponse()
        }
        if responseParserKind == "mistral_reasoning_v1" {
            return stream ? mistralReasoningStream() : mistralReasoningResponse()
        }
        return stream ? openAIChatStream() : openAIChatResponse()
    }

    /// The assertion uses the actual captured request body.  It intentionally
    /// checks only protocol-owned opaque fields: ordinary prompt text is not a
    /// continuation proof and must not make a joined test pass by accident.
    static func hasExplicitContinuationWire(
        _ data: Data?, continuationKind: String, recipeRef: String
    ) -> Bool {
        guard let data,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        switch continuationKind {
        case "previous_id":
            if recipeRef == "gemini.interactions.web.v1" {
                return body["previous_interaction_id"] as? String == previousInteractionID
            }
            return body["previous_response_id"] as? String == previousResponseID
        case "replay_blocks":
            if recipeRef == "minimax.messages.web.v1" {
                return miniMaxAnthropicWebReplayIsPresent(body)
            }
            if recipeRef.hasPrefix("anthropic.") {
                return anthropicOpaqueBlockIsPresent(body)
            }
            return geminiThoughtSignatureIsPresent(body)
        case "replay_reasoning":
            if recipeRef.hasPrefix("mistral.") {
                return mistralReasoningReplayIsPresent(body)
            }
            return openAIReasoningReplayIsPresent(body)
        case "tool_loop":
            return toolLoopReplayIsPresent(body)
        default:
            return false
        }
    }

    static func responsesStream() -> Data {
        Data("""
        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"\(joinedText)"}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"\(previousResponseID)","status":"completed"}}

        data: [DONE]
        """.utf8)
    }

    static func responsesResponse() -> Data {
        Data(#"{"id":"resp_joined","output_text":"joined","status":"completed"}"#.utf8)
    }

    static func anthropicStream() -> Data {
        Data("""
        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"\(opaqueThinking)"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"\(opaqueSignature)"}}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"\(joinedText)"}}

        event: message_stop
        data: {"type":"message_stop"}

        """.utf8)
    }

    static func anthropicResponse() -> Data {
        Data("""
        {"content":[{"type":"thinking","thinking":"\(opaqueThinking)","signature":"\(opaqueSignature)"},{"type":"text","text":"\(joinedText)"}],"usage":{"input_tokens":1,"output_tokens":1}}
        """.utf8)
    }

    static func miniMaxAnthropicWebStream() -> Data {
        Data("""
        event: message_start
        data: {"type":"message_start","message":{"usage":{"input_tokens":2}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"\(opaqueThinking)"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"\(opaqueSignature)"}}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"web_joined","name":"web_search","input":{}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"query\\":\\"joined\\"}"}}

        event: content_block_start
        data: {"type":"content_block_start","index":2,"content_block":{"type":"web_search_tool_result","tool_use_id":"web_joined","content":[{"type":"web_search_result","url":"\(citationURL)","title":"Joined","content":"joined citation"}]}}

        event: content_block_start
        data: {"type":"content_block_start","index":3,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"\(joinedText)"}}

        event: message_delta
        data: {"type":"message_delta","usage":{"output_tokens":3}}

        event: message_stop
        data: {"type":"message_stop"}

        """.utf8)
    }

    static func miniMaxAnthropicWebResponse() -> Data {
        Data("""
        {"content":[{"type":"thinking","thinking":"\(opaqueThinking)","signature":"\(opaqueSignature)"},{"type":"server_tool_use","id":"web_joined","name":"web_search","input":{"query":"joined"}},{"type":"web_search_tool_result","tool_use_id":"web_joined","content":[{"type":"web_search_result","url":"\(citationURL)","title":"Joined","content":"joined citation"}]},{"type":"text","text":"\(joinedText)"}],"usage":{"input_tokens":2,"output_tokens":3}}
        """.utf8)
    }

    static func geminiGenerateStream() -> Data {
        Data("""
        data: {"candidates":[{"content":{"role":"model","parts":[{"text":"\(joinedText)"},{"functionCall":{"name":"lookup","args":{"q":"joined"}},"thoughtSignature":"\(opaqueSignature)"}]},"finishReason":"STOP"}]}

        """.utf8)
    }

    static func geminiGenerateResponse() -> Data {
        Data("""
        {"candidates":[{"content":{"role":"model","parts":[{"text":"\(joinedText)"},{"functionCall":{"name":"lookup","args":{"q":"joined"}},"thoughtSignature":"\(opaqueSignature)"}]},"finishReason":"STOP"}]}
        """.utf8)
    }

    static func interactionsStream() -> Data {
        Data("""
        data: {"event_type":"step.delta","delta":{"type":"text","text":"\(joinedText)"}}

        data: {"interaction":{"id":"\(previousInteractionID)","status":"completed"}}

        data: [DONE]
        """.utf8)
    }

    static func interactionsResponse() -> Data {
        Data("""
        {"id":"\(previousInteractionID)","status":"completed","steps":[{"type":"model_output","content":{"text":"\(joinedText)"}}]}
        """.utf8)
    }

    static func openAIChatStream() -> Data {
        Data("""
        data: {"choices":[{"delta":{"content":"\(joinedText)","reasoning_content":"\(opaqueThinking)"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]
        """.utf8)
    }

    static func openAIChatResponse() -> Data {
        Data("""
        {"choices":[{"message":{"content":"\(joinedText)","reasoning_content":"\(opaqueThinking)"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
        """.utf8)
    }

    /// OpenRouter's continuation contract is `reasoning_details`, not the
    /// DeepSeek/Moonshot `reasoning_content` field.  Keep this distinct so the
    /// producer has to preserve the protocol's opaque encrypted detail.
    static func openRouterReasoningStream() -> Data {
        Data("""
        data: {"choices":[{"delta":{"content":"\(joinedText)","reasoning_details":[{"type":"reasoning.encrypted","data":"opaque-joined-detail"}]}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]
        """.utf8)
    }

    static func openRouterReasoningResponse() -> Data {
        Data("""
        {"choices":[{"message":{"content":"\(joinedText)","reasoning_details":[{"type":"reasoning.encrypted","data":"opaque-joined-detail"}]}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
        """.utf8)
    }

    static func mistralReasoningStream() -> Data {
        Data("""
        data: {"choices":[{"delta":{"role":"assistant","content":""}}]}
        data: {"choices":[{"delta":{"content":[{"type":"thinking","thinking":[{"type":"text","text":"\(opaqueThinking)"}]},{"type":"text","text":"\(joinedText)"}]}}]}
        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}
        data: [DONE]

        """.utf8)
    }

    static func mistralReasoningResponse() -> Data {
        Data("""
        {"choices":[{"message":{"role":"assistant","content":[{"type":"thinking","thinking":[{"type":"text","text":"\(opaqueThinking)"}]},{"type":"text","text":"\(joinedText)"}]}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
        """.utf8)
    }

    private static func anthropicOpaqueBlockIsPresent(_ body: [String: Any]) -> Bool {
        guard let messages = body["messages"] as? [[String: Any]] else { return false }
        return messages.contains { message in
            guard message["role"] as? String == "assistant",
                  let blocks = message["content"] as? [[String: Any]] else { return false }
            return blocks.contains {
                $0["type"] as? String == "thinking"
                    && $0["thinking"] as? String == opaqueThinking
                    && $0["signature"] as? String == opaqueSignature
            }
        }
    }

    private static func miniMaxAnthropicWebReplayIsPresent(_ body: [String: Any]) -> Bool {
        guard let messages = body["messages"] as? [[String: Any]],
              let blocks = messages.first(where: { $0["role"] as? String == "assistant" })?["content"] as? [[String: Any]]
        else { return false }
        let ordered = blocks.compactMap { $0["type"] as? String }
        return ordered == ["thinking", "server_tool_use", "web_search_tool_result", "text"]
            && blocks[0]["thinking"] as? String == opaqueThinking
            && blocks[0]["signature"] as? String == opaqueSignature
            && ((blocks[1]["input"] as? [String: Any])?["query"] as? String == "joined")
            && (((blocks[2]["content"] as? [[String: Any]])?.first?["url"] as? String) == citationURL)
    }

    private static func geminiThoughtSignatureIsPresent(_ body: [String: Any]) -> Bool {
        guard let contents = body["contents"] as? [[String: Any]] else { return false }
        return contents.contains { content in
            guard content["role"] as? String == "model",
                  let parts = content["parts"] as? [[String: Any]] else { return false }
            return parts.contains { $0["thoughtSignature"] as? String == opaqueSignature }
        }
    }

    private static func openAIReasoningReplayIsPresent(_ body: [String: Any]) -> Bool {
        guard let messages = body["messages"] as? [[String: Any]] else { return false }
        return messages.contains { message in
            message["role"] as? String == "assistant"
                && ((message["reasoning_content"] as? String == opaqueThinking)
                    || (message["reasoning_details"] as? [[String: Any]])?.isEmpty == false)
        }
    }

    private static func mistralReasoningReplayIsPresent(_ body: [String: Any]) -> Bool {
        guard let messages = body["messages"] as? [[String: Any]] else { return false }
        return messages.contains { message in
            guard message["role"] as? String == "assistant",
                  let blocks = message["content"] as? [[String: Any]] else { return false }
            return blocks.contains { block in
                guard block["type"] as? String == "thinking",
                      let thinking = block["thinking"] as? [[String: Any]] else { return false }
                return thinking.contains {
                    $0["type"] as? String == "text" && $0["text"] as? String == opaqueThinking
                }
            }
        }
    }

    private static func toolLoopReplayIsPresent(_ body: [String: Any]) -> Bool {
        guard let messages = body["messages"] as? [[String: Any]] else { return false }
        return messages.contains { ($0["role"] as? String) == "assistant" && $0["tool_calls"] != nil }
            && messages.contains { ($0["role"] as? String) == "tool" }
    }
}

/// Real two-leg Moonshot script.  The first chat response asks for a tool; the
/// production service obtains (Formula) or synthesizes (builtin) its result and
/// then receives a final response.  That is the only way its producer creates
/// `completedMessages` for an explicit continuation test.
final class JoinedMoonshotLoopScript: @unchecked Sendable {
    private let isFormula: Bool
    private let lock = NSLock()
    private var chatLeg = 0

    init(isFormula: Bool) {
        self.isFormula = isFormula
    }

    func response(_ request: URLRequest, _: Data?, _: Int) -> Data {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/tools") {
            return Data(#"{"tools":[{"type":"function","function":{"name":"$web_search","parameters":{"type":"object"}}}]}"#.utf8)
        }
        if path.hasSuffix("/fibers") {
            return Data(#"{"context":{"encrypted_output":"opaque formula output"}}"#.utf8)
        }
        lock.lock()
        chatLeg += 1
        let currentLeg = chatLeg
        lock.unlock()
        if currentLeg == 1 {
            let toolType = isFormula ? "function" : "builtin_function"
            return Data("""
            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_joined","type":"\(toolType)","function":{"name":"$web_search","arguments":"{\\"q\\":\\"joined\\"}"}}]}}]}

            data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

            data: [DONE]
            """.utf8)
        }
        return JoinedContinuationFixture.openAIChatStream()
    }
}
