import Foundation
import Testing
@testable import Oriveo

/// An SSE stub that answers by path: a POST to `/responses` can be given its own status code (OpenAI's 404 falls
/// back to Chat Completions); every other POST gets 200 plus the given stream body.
private final class StreamErrorFrameURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stream = ""
    nonisolated(unsafe) private static var responsesStatus = 200

    static func session(stream: String, responsesStatus: Int = 200) -> URLSession {
        lock.lock()
        self.stream = stream
        self.responsesStatus = responsesStatus
        lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamErrorFrameURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let stream = Self.stream
        let responsesStatus = Self.responsesStatus
        Self.lock.unlock()
        var status = 200
        var body = Data(stream.utf8)
        var contentType = "text/event-stream"
        if request.httpMethod != "POST" {
            body = Data(#"{"data":[]}"#.utf8)
            contentType = "application/json"
        } else if request.url?.path.hasSuffix("/responses") == true, responsesStatus != 200 {
            status = responsesStatus
            body = Data(#"{"error":{"message":"Not found","type":"invalid_request_error"}}"#.utf8)
            contentType = "application/json"
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://provider.invalid")!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Streams used to skip in-stream error frames as empty frames: the user saw an empty reply and the message was
/// recorded as delivered. Every case replays a frame taken from the vendor documentation (copied byte for byte,
/// see the source of each constant) through the real service's parsing loop.
@Suite("In-stream error frames: every official service fails with the upstream error (iOS)", .serialized)
struct ProviderStreamErrorFrameTests {
    /// The example frame from OpenRouter's streaming documentation ("Errors after the response is committed"): the
    /// error sits at the top level next to `choices` and `finish_reason: "error"`, and may be the only frame in the
    /// stream. Every Chat Completions service shares this shape.
    static let chatCompletionsError = #"""
    data: {"id":"cmpl-abc123","object":"chat.completion.chunk","created":1702000000,"model":"gpt-3.5-turbo","provider":"openai","error":{"code":"server_error","message":"Provider disconnected unexpectedly"},"choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}


    """#

    static let chatCompletionsPartialThenError = #"""
    data: {"id":"cmpl-abc123","object":"chat.completion.chunk","created":1702000000,"model":"m","choices":[{"index":0,"delta":{"content":"Partial answer"},"finish_reason":null}]}

    """# + chatCompletionsError

    /// The example from Anthropic's streaming documentation ("Error events"), verbatim.
    static let anthropicOverloaded = #"""
    event: error
    data: {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}


    """#

    static let anthropicAPIError = #"""
    event: error
    data: {"type": "error", "error": {"type": "api_error", "message": "Internal server error"}}


    """#

    /// The `error` event example from the OpenAI Responses streaming event reference.
    static let responsesError = #"""
    event: error
    data: {"type":"error","code":"ERR_SOMETHING","message":"Something went wrong","param":null,"sequence_number":1}


    """#

    /// `response.failed`: the failure reason is in `response.error`.
    static let responsesFailed = #"""
    event: response.failed
    data: {"type":"response.failed","sequence_number":1,"response":{"id":"resp_123","object":"response","status":"failed","error":{"code":"server_error","message":"The model failed to generate a response."}}}


    """#

    private static func drain(
        _ stream: AsyncThrowingStream<StreamEvent, Error>
    ) async -> (text: String, done: Bool, error: ProviderServiceError?) {
        var text = ""
        var done = false
        do {
            for try await event in stream {
                if case let .delta(chunk) = event { text += chunk }
                if case .done = event { done = true }
            }
        } catch let error as ProviderServiceError {
            return (text, done, error)
        } catch {
            Issue.record("not a ProviderServiceError: \(error)")
        }
        return (text, done, nil)
    }

    private static func message(kind: ProviderKind) -> ChatMessage {
        ChatMessage(id: UUID(), role: .user, text: "ping", providerKind: kind, providerName: kind.displayName, modelName: "m", state: .delivered)
    }

    private static let key = "sk-stream-error-frame-test-0123456789"

    /// The official services that speak Chat Completions: each must fail with the upstream error and carry its text in the technical detail.
    private static func chatServices(_ session: URLSession) -> [(ProviderKind, String, any ProviderServiceProtocol)] {
        [
            (.openRouter, "openai/gpt-4o-mini", OpenRouterService(session: session)),
            (.groq, "llama-3.3-70b-versatile", GroqService(session: session)),
            (.mistral, "mistral-small-latest", MistralService(session: session)),
            (.miniMax, "MiniMax-M1", MiniMaxService(session: session)),
            (.siliconFlow, "Qwen/Qwen3-8B", SiliconFlowService(session: session)),
            (.together, "meta-llama/Llama-3.3-70B-Instruct-Turbo", TogetherService(session: session)),
            (.fireworks, "accounts/fireworks/models/llama-v3p3-70b-instruct", FireworksService(session: session)),
            (.zhipu, "glm-4.5", ZhipuService(session: session)),
            (.grok, "grok-3-mini", GrokService(session: session)),
            (.deepseek, "deepseek-chat", DeepSeekService(session: session)),
            (.qwen, "qwen-plus", QwenService(session: session)),
        ]
    }

    @Test("Chat Completions: a stream with a single error frame is no longer a completed empty reply, and the upstream text reaches the technical detail")
    func chatCompletionsErrorFrameFailsTheStream() async throws {
        await MetadataClient.shared.resetForTesting()
        for (kind, modelID, service) in Self.chatServices(StreamErrorFrameURLProtocol.session(stream: Self.chatCompletionsError)) {
            let result = await Self.drain(service.sendMessageStream(
                apiKey: Self.key, modelID: modelID, messages: [Self.message(kind: kind)]
            ))
            #expect(!result.done, "\(kind.rawValue): .done was delivered after the error frame")
            let error = try #require(result.error, "\(kind.rawValue): the error frame was skipped as an empty frame")
            #expect(error.technicalDetail.contains("Provider disconnected unexpectedly"), "\(kind.rawValue): \(error.technicalDetail)")
            #expect(!error.marksConnectionFailed, "\(kind.rawValue): a single upstream error must not mark the connection as failing")
        }
    }

    @Test("Chat Completions: an error frame after some content still delivers the received content, and the stream ends in an error rather than completing")
    func errorAfterPartialContentKeepsTheContentAndFails() async throws {
        await MetadataClient.shared.resetForTesting()
        for (kind, modelID, service) in Self.chatServices(StreamErrorFrameURLProtocol.session(stream: Self.chatCompletionsPartialThenError)) {
            let result = await Self.drain(service.sendMessageStream(
                apiKey: Self.key, modelID: modelID, messages: [Self.message(kind: kind)]
            ))
            #expect(result.text.contains("Partial answer"), "\(kind.rawValue): the received content was lost (\(result.text))")
            #expect(!result.done, "\(kind.rawValue): the failure was treated as completion")
            #expect(result.error?.technicalDetail.contains("Provider disconnected unexpectedly") == true, "\(kind.rawValue)")
        }
    }

    @Test("OpenAI: Chat Completions (via the /responses 404 fallback) and the Responses error and response.failed events all fail with the upstream error")
    func openAIOfficialStreams() async throws {
        await MetadataClient.shared.resetForTesting()
        let chat = await Self.drain(OpenAIService(
            session: StreamErrorFrameURLProtocol.session(stream: Self.chatCompletionsError, responsesStatus: 404)
        ).sendMessageStream(apiKey: Self.key, modelID: "gpt-4.1-mini", messages: [Self.message(kind: .openAI)]))
        #expect(chat.error?.technicalDetail.contains("Provider disconnected unexpectedly") == true, "chat: \(String(describing: chat.error))")
        #expect(!chat.done)

        for (stream, expected) in [
            (Self.responsesError, "Something went wrong"),
            (Self.responsesFailed, "The model failed to generate a response."),
        ] {
            let result = await Self.drain(OpenAIService(
                session: StreamErrorFrameURLProtocol.session(stream: stream)
            ).sendMessageStream(apiKey: Self.key, modelID: "gpt-4.1-mini", messages: [Self.message(kind: .openAI)]))
            #expect(!result.done, "responses: .done was delivered after \(expected)")
            #expect(result.error?.technicalDetail.contains(expected) == true, "responses: \(String(describing: result.error))")
        }
    }

    @Test("Anthropic: event: error fails with the upstream error; overloaded is classified as rate limiting and the original text stays in the technical detail")
    func anthropicOfficialStream() async throws {
        await MetadataClient.shared.resetForTesting()
        let overloaded = await Self.drain(AnthropicService(
            session: StreamErrorFrameURLProtocol.session(stream: Self.anthropicOverloaded)
        ).sendMessageStream(apiKey: Self.key, modelID: "claude-sonnet-4-5", messages: [Self.message(kind: .anthropic)]))
        let error = try #require(overloaded.error, "the Anthropic error event was skipped")
        guard case .rateLimited = error else {
            Issue.record("overloaded_error should be classified as rate limiting (the way out is to retry later), got \(error)")
            return
        }
        #expect(error.technicalDetail.contains("Overloaded"))
        #expect(!overloaded.done)

        let apiError = await Self.drain(AnthropicService(
            session: StreamErrorFrameURLProtocol.session(stream: Self.anthropicAPIError)
        ).sendMessageStream(apiKey: Self.key, modelID: "claude-sonnet-4-5", messages: [Self.message(kind: .anthropic)]))
        #expect(apiError.error?.technicalDetail.contains("Internal server error") == true, "\(String(describing: apiError.error))")
    }

    @Test("The Gemini Interactions ErrorEvent and llama.cpp's native error object are both recognized; ordinary content frames are not misjudged")
    func sharedRecognizerCoversTheRemainingShapes() throws {
        let interactions = Data(#"{"event_type":"error","event_id":"evt_1","error":{"code":"https://ai.google.dev/errors/internal","message":"Internal error encountered."}}"#.utf8)
        #expect(BaseAPIService.streamErrorFrame(in: interactions)?.technicalDetail.contains("Internal error encountered.") == true)
        let llamaNative = Data(#"{"error":{"code":400,"message":"the request exceeds the available context size","type":"exceed_context_size_error"}}"#.utf8)
        #expect(BaseAPIService.streamErrorFrame(in: llamaNative)?.technicalDetail.contains("exceeds the available context size") == true)
        // Some gateways echo the request headers back inside the error body: this request's key must not reach the technical detail.
        let echoed = Data(#"{"error":{"message":"bad header Authorization: Bearer sk-stream-error-frame-test-0123456789"}}"#.utf8)
        let redacted = try #require(BaseAPIService.streamErrorFrame(in: echoed, redacting: [Self.key]))
        #expect(!redacted.technicalDetail.contains(Self.key))
        for ordinary in [
            #"{"choices":[{"index":0,"delta":{"content":"hi"}}]}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}"#,
            #"{"type":"response.created","response":{"id":"resp_1","status":"in_progress","error":null}}"#,
            #"{"event_type":"step.delta","delta":{"text":"hi"}}"#,
        ] {
            #expect(BaseAPIService.streamErrorFrame(in: Data(ordinary.utf8)) == nil, "misjudged: \(ordinary)")
        }
    }
}
