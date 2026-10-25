import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Every POST gets 200 plus the given SSE stream body; GET (model catalog etc.) returns an empty list.
private final class StreamFinishProtocolsURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stream = ""

    static func session(stream: String) -> URLSession {
        lock.lock()
        self.stream = stream
        lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamFinishProtocolsURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let stream = Self.stream
        Self.lock.unlock()
        let isPost = request.httpMethod == "POST"
        let body = isPost ? Data(stream.utf8) : Data(#"{"data":[]}"#.utf8)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://provider.invalid")!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": isPost ? "text/event-stream" : "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The streams of the Responses / Anthropic / Gemini families carry a StreamFinish on `.done`.
/// Each case feeds raw SSE bytes to the production services (OpenAI Responses main path, Anthropic Messages, Gemini generateContent),
/// asserts the done event they deliver, and goes through StopReasonResolver to the StopReason that is persisted.
@Suite("StreamFinish: Responses / Anthropic / Gemini (iOS)", .serialized, .sharedProcessState)
struct StreamFinishProtocolsTests {
    private static let key = "sk-stream-finish-test-0123456789"
    private static let responsesModel = "stream-finish-responses"

    private static func body(_ frames: [String]) -> String {
        frames.map { $0 + "\n\n" }.joined()
    }

    private static func message(kind: ProviderKind, model: String) -> ChatMessage {
        ChatMessage(id: UUID(), role: .user, text: "ping", providerKind: kind, providerName: kind.displayName, modelName: model, state: .delivered)
    }

    private static func drain(
        _ stream: AsyncThrowingStream<StreamEvent, Error>
    ) async -> (text: String, result: ProviderChatResult?, error: Error?) {
        var text = ""
        var result: ProviderChatResult?
        do {
            for try await event in stream {
                if case let .delta(chunk) = event { text += chunk }
                if case let .done(value) = event { result = value }
            }
        } catch {
            return (text, result, error)
        }
        return (text, result, nil)
    }

    /// The `.finish` event received before the throw, and the final error.
    private static func drainFinishes(
        _ stream: AsyncThrowingStream<StreamEvent, Error>
    ) async -> (text: String, finishes: [StreamFinish], sawDone: Bool, error: Error?) {
        var text = ""
        var finishes: [StreamFinish] = []
        var sawDone = false
        do {
            for try await event in stream {
                if case let .delta(chunk) = event { text += chunk }
                if case let .finish(value) = event { finishes.append(value) }
                if case .done = event { sawDone = true }
            }
        } catch {
            return (text, finishes, sawDone, error)
        }
        return (text, finishes, sawDone, nil)
    }

    private static func resolved(_ finish: StreamFinish?) -> StopReason? {
        finish.map {
            StopReasonResolver.resolve(family: $0.family, ended: $0.ended, finishRaw: $0.finishRaw, hadContent: true)
        }
    }

    // MARK: - OpenAI Responses

    /// Makes this model of official OpenAI go through Responses (without a catalog the default is chat completions).
    private static func loadResponsesCatalog() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "profiles": {},
          "providers": {"openAI": {
            "resolveMap": {"\(responsesModel)":"\(responsesModel)"},
            "models": {"\(responsesModel)": {
              "canonicalModelId":"\(responsesModel)",
              "transport":"openai_responses",
              "capabilities":["text"],
              "toolCall":false
            }}
          }}
        }
        """)
    }

    private static func responsesFrame(_ type: String, _ json: String) -> String {
        "event: \(type)\ndata: \(json)"
    }

    private static let responsesDelta = responsesFrame(
        "response.output_text.delta", #"{"type":"response.output_text.delta","item_id":"m1","output_index":0,"content_index":0,"delta":"Hello"}"#
    )

    private static func responsesTerminal(_ type: String, status: String, details: String = "null", usage: String = "null") -> String {
        responsesFrame(
            type,
            #"{"type":"\#(type)","response":{"id":"resp_1","object":"response","status":"\#(status)","incomplete_details":\#(details),"usage":\#(usage)}}"#
        )
    }

    private static func runResponses(_ frames: [String]) async throws -> (text: String, result: ProviderChatResult?, error: Error?) {
        try await loadResponsesCatalog()
        let service = OpenAIService(session: StreamFinishProtocolsURLProtocol.session(stream: body(frames)))
        let drained = await drain(service.sendMessageStream(
            apiKey: key, modelID: responsesModel, messages: [message(kind: .openAI, model: responsesModel)]
        ))
        await MetadataClient.shared.resetForTesting()
        return drained
    }

    @Test("responses_completed: response.completed → clean, finishRaw completed → stop")
    func responses_completed() async throws {
        let drained = try await Self.runResponses([
            Self.responsesDelta,
            Self.responsesTerminal("response.completed", status: "completed", usage: #"{"input_tokens":5,"output_tokens":2,"total_tokens":7}"#),
        ])
        #expect(drained.error == nil, "\(String(describing: drained.error))")
        let result = try #require(drained.result, "no done")
        #expect(result.text == "Hello")
        #expect(result.finish == StreamFinish(family: .openaiResponses, ended: .clean, finishRaw: "completed"), "\(String(describing: result.finish))")
        #expect(Self.resolved(result.finish) == .stop)
    }

    @Test("responses_incomplete_max_output_tokens: response.incomplete goes through done, finishRaw incomplete:max_output_tokens -> length")
    func responses_incomplete_max_output_tokens() async throws {
        let drained = try await Self.runResponses([
            Self.responsesDelta,
            Self.responsesTerminal("response.incomplete", status: "incomplete", details: #"{"reason":"max_output_tokens"}"#),
        ])
        #expect(drained.error == nil, "\(String(describing: drained.error))")
        let result = try #require(drained.result, "no done")
        #expect(result.text == "Hello")
        #expect(
            result.finish == StreamFinish(family: .openaiResponses, ended: .clean, finishRaw: "incomplete:max_output_tokens"),
            "\(String(describing: result.finish))"
        )
        #expect(Self.resolved(result.finish) == .length)
    }

    @Test("responses_incomplete_without_reason: status incomplete with no reason -> clean, finishRaw incomplete -> incomplete")
    func responses_incomplete_without_reason() async throws {
        let drained = try await Self.runResponses([
            Self.responsesDelta,
            Self.responsesTerminal("response.incomplete", status: "incomplete"),
        ])
        #expect(drained.error == nil, "\(String(describing: drained.error))")
        let result = try #require(drained.result, "no done")
        #expect(result.finish == StreamFinish(family: .openaiResponses, ended: .clean, finishRaw: "incomplete"), "\(String(describing: result.finish))")
        #expect(Self.resolved(result.finish) == .incomplete)
    }

    @Test("responses_incomplete_keeps_usage: response.incomplete also takes usage")
    func responses_incomplete_keeps_usage() async throws {
        let drained = try await Self.runResponses([
            Self.responsesDelta,
            Self.responsesTerminal(
                "response.incomplete", status: "incomplete", details: #"{"reason":"max_output_tokens"}"#,
                usage: #"{"input_tokens":11,"output_tokens":7,"total_tokens":18}"#
            ),
        ])
        #expect(drained.error == nil, "\(String(describing: drained.error))")
        let result = try #require(drained.result, "no done")
        #expect(result.promptTokens == 11)
        #expect(result.completionTokens == 7)
    }

    @Test("responses_eof_without_marker: cut with no completed / incomplete / failed -> eof_without_marker -> incomplete")
    func responses_eof_without_marker() async throws {
        let drained = try await Self.runResponses([Self.responsesDelta])
        #expect(drained.error == nil, "\(String(describing: drained.error))")
        let result = try #require(drained.result, "no done")
        #expect(result.text == "Hello")
        #expect(result.finish == StreamFinish(family: .openaiResponses, ended: .eofWithoutMarker, finishRaw: nil), "\(String(describing: result.finish))")
        #expect(Self.resolved(result.finish) == .incomplete)
    }

    @Test("responses_failed_carries_finish: response.failed still throws, delivering (openai_responses, clean, failed) before the throw")
    func responses_failed_carries_finish() async throws {
        try await Self.loadResponsesCatalog()
        let frames = [
            Self.responsesDelta,
            Self.responsesFrame(
                "response.failed",
                #"{"type":"response.failed","response":{"id":"resp_1","object":"response","status":"failed","error":{"code":"server_error","message":"boom"},"incomplete_details":null}}"#
            ),
        ]
        let service = OpenAIService(session: StreamFinishProtocolsURLProtocol.session(stream: Self.body(frames)))
        let drained = await Self.drainFinishes(service.sendMessageStream(
            apiKey: Self.key, modelID: Self.responsesModel, messages: [Self.message(kind: .openAI, model: Self.responsesModel)]
        ))
        await MetadataClient.shared.resetForTesting()
        #expect(drained.text == "Hello")
        #expect(drained.error != nil, "response.failed should still throw")
        #expect(!drained.sawDone)
        #expect(drained.finishes == [StreamFinish(family: .openaiResponses, ended: .clean, finishRaw: "failed")], "\(drained.finishes)")
        #expect(Self.resolved(drained.finishes.last) == .error)
    }

    // MARK: - Anthropic Messages

    private static func anthropicFrame(_ type: String, _ json: String) -> String {
        "event: \(type)\ndata: \(json)"
    }

    private static let anthropicStart = anthropicFrame(
        "message_start",
        #"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-test","content":[],"stop_reason":null,"usage":{"input_tokens":5,"output_tokens":1}}}"#
    )
    private static let anthropicBlockStart = anthropicFrame(
        "content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#
    )
    private static let anthropicDelta = anthropicFrame(
        "content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#
    )
    private static let anthropicBlockStop = anthropicFrame(
        "content_block_stop", #"{"type":"content_block_stop","index":0}"#
    )
    private static func anthropicMessageDelta(_ reason: String) -> String {
        anthropicFrame(
            "message_delta",
            #"{"type":"message_delta","delta":{"stop_reason":"\#(reason)","stop_sequence":null},"usage":{"output_tokens":2}}"#
        )
    }
    private static let anthropicStop = anthropicFrame("message_stop", #"{"type":"message_stop"}"#)

    private static func runAnthropic(_ frames: [String]) async -> (text: String, result: ProviderChatResult?, error: Error?) {
        await MetadataClient.shared.resetForTesting()
        let service = AnthropicService(session: StreamFinishProtocolsURLProtocol.session(stream: body(frames)))
        return await drain(service.sendMessageStream(
            apiKey: key, modelID: "claude-test", messages: [message(kind: .anthropic, model: "claude-test")]
        ))
    }

    @Test("anthropic_max_tokens: message_delta stop_reason max_tokens + message_stop → clean → length")
    func anthropic_max_tokens() async throws {
        let drained = await Self.runAnthropic([
            Self.anthropicStart, Self.anthropicBlockStart, Self.anthropicDelta, Self.anthropicBlockStop,
            Self.anthropicMessageDelta("max_tokens"), Self.anthropicStop,
        ])
        #expect(drained.error == nil, "\(String(describing: drained.error))")
        let result = try #require(drained.result, "no done")
        #expect(result.text == "Hello")
        #expect(result.finish == StreamFinish(family: .anthropic, ended: .clean, finishRaw: "max_tokens"), "\(String(describing: result.finish))")
        #expect(Self.resolved(result.finish) == .length)
    }

    @Test("anthropic_context_window_exceeded: stop_reason model_context_window_exceeded → context_window_exceeded")
    func anthropic_context_window_exceeded() async throws {
        let drained = await Self.runAnthropic([
            Self.anthropicStart, Self.anthropicBlockStart, Self.anthropicDelta, Self.anthropicBlockStop,
            Self.anthropicMessageDelta("model_context_window_exceeded"), Self.anthropicStop,
        ])
        #expect(drained.error == nil, "\(String(describing: drained.error))")
        let result = try #require(drained.result, "no done")
        #expect(
            result.finish == StreamFinish(family: .anthropic, ended: .clean, finishRaw: "model_context_window_exceeded"),
            "\(String(describing: result.finish))"
        )
        #expect(Self.resolved(result.finish) == .contextWindowExceeded)
    }

    @Test("anthropic_eof_before_message_stop: stop_reason seen but no message_stop -> eof_without_marker, finishRaw is still carried")
    func anthropic_eof_before_message_stop() async throws {
        let drained = await Self.runAnthropic([
            Self.anthropicStart, Self.anthropicBlockStart, Self.anthropicDelta, Self.anthropicBlockStop,
            Self.anthropicMessageDelta("end_turn"),
        ])
        #expect(drained.error == nil, "\(String(describing: drained.error))")
        let result = try #require(drained.result, "no done")
        #expect(result.text == "Hello")
        #expect(result.finish == StreamFinish(family: .anthropic, ended: .eofWithoutMarker, finishRaw: "end_turn"), "\(String(describing: result.finish))")
        #expect(Self.resolved(result.finish) == .incomplete)
    }

    @Test("anthropic_stream_usage_reported: message_start / message_delta carry usage -> usageReported true, priced by tokens")
    func anthropic_stream_usage_reported() async throws {
        let drained = await Self.runAnthropic([
            Self.anthropicStart, Self.anthropicBlockStart, Self.anthropicDelta, Self.anthropicBlockStop,
            Self.anthropicMessageDelta("end_turn"), Self.anthropicStop,
        ])
        #expect(drained.error == nil, "\(String(describing: drained.error))")
        let result = try #require(drained.result, "no done")
        #expect(result.usageReported)
        #expect(result.promptTokens == 5)
        #expect(result.completionTokens == 2)
    }

    @Test("anthropic_stream_without_usage: neither event carries usage -> usageReported false, and no cost is made up")
    func anthropic_stream_without_usage() async throws {
        let startWithoutUsage = Self.anthropicFrame(
            "message_start",
            #"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-test","content":[],"stop_reason":null}}"#
        )
        let deltaWithoutUsage = Self.anthropicFrame(
            "message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null}}"#
        )
        let drained = await Self.runAnthropic([
            startWithoutUsage, Self.anthropicBlockStart, Self.anthropicDelta, Self.anthropicBlockStop,
            deltaWithoutUsage, Self.anthropicStop,
        ])
        #expect(drained.error == nil, "\(String(describing: drained.error))")
        let result = try #require(drained.result, "no done")
        #expect(result.text == "Hello")
        #expect(!result.usageReported)
        var model = TestFactories.makeModel(id: "claude-test")
        model.promptPrice = 0.000003
        model.completionPrice = 0.000015
        #expect(ChatDeliveryAccounting.deliveredCost(result: result, model: model, providerKind: .relay) == 0,
                "without reported usage there is nothing to price")
    }

    // MARK: - Gemini generateContent

    private static let geminiText = #"data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Hello"}]},"index":0}],"modelVersion":"gemini-test"}"#

    private static func geminiFinish(_ reason: String) -> String {
        #"data: {"candidates":[{"content":{"role":"model","parts":[{"text":""}]},"finishReason":"\#(reason)","index":0}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":2,"totalTokenCount":7},"modelVersion":"gemini-test"}"#
    }

    private static func runGemini(_ frames: [String]) async -> (text: String, result: ProviderChatResult?, error: Error?) {
        await MetadataClient.shared.resetForTesting()
        let service = GeminiService(session: StreamFinishProtocolsURLProtocol.session(stream: body(frames)))
        return await drain(service.sendMessageStream(
            apiKey: key, modelID: "gemini-test", messages: [message(kind: .gemini, model: "gemini-test")]
        ))
    }

    @Test("gemini_max_tokens: candidate finishReason MAX_TOKENS → clean → length")
    func gemini_max_tokens() async throws {
        let drained = await Self.runGemini([Self.geminiText, Self.geminiFinish("MAX_TOKENS")])
        #expect(drained.error == nil, "\(String(describing: drained.error))")
        let result = try #require(drained.result, "no done")
        #expect(result.text == "Hello")
        #expect(result.finish == StreamFinish(family: .gemini, ended: .clean, finishRaw: "MAX_TOKENS"), "\(String(describing: result.finish))")
        #expect(Self.resolved(result.finish) == .length)
    }

    @Test("gemini_blocked_carries_finish: a blocked finishReason still throws, delivering (gemini, clean, SAFETY) before the throw")
    func gemini_blocked_carries_finish() async throws {
        await MetadataClient.shared.resetForTesting()
        let service = GeminiService(session: StreamFinishProtocolsURLProtocol.session(
            stream: Self.body([Self.geminiText, Self.geminiFinish("SAFETY")])
        ))
        let drained = await Self.drainFinishes(service.sendMessageStream(
            apiKey: Self.key, modelID: "gemini-test", messages: [Self.message(kind: .gemini, model: "gemini-test")]
        ))
        #expect(drained.text == "Hello")
        #expect(drained.error != nil, "a blocked finishReason should still throw")
        #expect(!drained.sawDone)
        #expect(drained.finishes == [StreamFinish(family: .gemini, ended: .clean, finishRaw: "SAFETY")], "\(drained.finishes)")
        #expect(Self.resolved(drained.finishes.last) == .contentFilter)
    }

    @Test("gemini_eof_without_finish_reason: cut with no finishReason at all -> eof_without_marker -> incomplete")
    func gemini_eof_without_finish_reason() async throws {
        let drained = await Self.runGemini([Self.geminiText])
        #expect(drained.error == nil, "\(String(describing: drained.error))")
        let result = try #require(drained.result, "no done")
        #expect(result.text == "Hello")
        #expect(result.finish == StreamFinish(family: .gemini, ended: .eofWithoutMarker, finishRaw: nil), "\(String(describing: result.finish))")
        #expect(Self.resolved(result.finish) == .incomplete)
    }

    @Test("gemini_prompt_block_carries_finish: promptFeedback.blockReason still throws, delivering (gemini, clean, blockReason:<value>) before the throw")
    func gemini_prompt_block_carries_finish() async throws {
        for (reason, expected) in [("SAFETY", StopReason.contentFilter), ("BLOCK_REASON_UNSPECIFIED", .unknown)] {
            await MetadataClient.shared.resetForTesting()
            let service = GeminiService(session: StreamFinishProtocolsURLProtocol.session(
                stream: Self.body([#"data: {"promptFeedback":{"blockReason":"\#(reason)"},"modelVersion":"gemini-test"}"#])
            ))
            let drained = await Self.drainFinishes(service.sendMessageStream(
                apiKey: Self.key, modelID: "gemini-test", messages: [Self.message(kind: .gemini, model: "gemini-test")]
            ))
            #expect(drained.error != nil, "blockReason should still throw")
            #expect(!drained.sawDone)
            #expect(drained.finishes == [StreamFinish(family: .gemini, ended: .clean, finishRaw: "blockReason:\(reason)")], "\(drained.finishes)")
            #expect(Self.resolved(drained.finishes.last) == expected, "\(reason)")
        }
    }

    // MARK: - Gemini Interactions

    private static func interactionsStatus(_ status: String) -> String {
        #"data: {"interaction":{"id":"v1_x","status":"\#(status)","object":"interaction","usage":{"total_input_tokens":5,"total_output_tokens":2}},"event_type":"interaction.completed"}"#
    }

    private static let interactionsDelta = #"data: {"index":0,"delta":{"type":"text","text":"Hello"},"event_type":"step.delta"}"#

    /// Goes through production `GeminiService.pumpInteractions` (the same function streamInteractions uses to read the stream); done carries the finish returned by pump.
    private static func runInteractions(_ frames: [String]) async -> (finishes: [StreamFinish], done: StreamFinish?, error: Error?) {
        let lines = frames.flatMap { [$0, ""] }
        let stream = AsyncThrowingStream<StreamEvent, Error> { continuation in
            Task {
                do {
                    var parser = GeminiService.InteractionsStreamParser(redacting: [key])
                    let source = AsyncStream<String> { input in
                        lines.forEach { input.yield($0) }
                        input.finish()
                    }
                    if let finish = try await GeminiService.pumpInteractions(lines: source, parser: &parser, continuation: continuation) {
                        continuation.yield(.done(ProviderChatResult(
                            text: parser.text, promptTokens: 0, completionTokens: 0, estimatedCost: 0, finish: finish
                        )))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        var finishes: [StreamFinish] = []
        var done: StreamFinish?
        do {
            for try await event in stream {
                if case let .finish(value) = event { finishes.append(value) }
                if case let .done(value) = event { done = value.finish }
            }
        } catch {
            return (finishes, done, error)
        }
        return (finishes, done, nil)
    }

    @Test("interactions_terminal_status_carries_finish: the terminal status becomes finishRaw (gemini_interactions); failed / requires_action / cancelled still throw and deliver finish before the throw; a cut stream = eof")
    func interactions_terminal_status_carries_finish() async throws {
        for (status, expected) in [("completed", StopReason.stop), ("incomplete", .length)] {
            let run = await Self.runInteractions([Self.interactionsDelta, Self.interactionsStatus(status)])
            #expect(run.error == nil, "\(status): \(String(describing: run.error))")
            #expect(run.done == StreamFinish(family: .geminiInteractions, ended: .clean, finishRaw: status), "\(status): \(String(describing: run.done))")
            #expect(Self.resolved(run.done) == expected, "\(status)")
        }
        for (status, expected) in [("failed", StopReason.error), ("requires_action", .tool), ("cancelled", .unknown)] {
            let run = await Self.runInteractions([Self.interactionsDelta, Self.interactionsStatus(status)])
            #expect(run.error != nil, "\(status) should still throw")
            #expect(run.done == nil)
            #expect(run.finishes == [StreamFinish(family: .geminiInteractions, ended: .clean, finishRaw: status)], "\(status): \(run.finishes)")
            #expect(Self.resolved(run.finishes.last) == expected, "\(status)")
        }
        let truncated = await Self.runInteractions([Self.interactionsDelta])
        #expect(truncated.error != nil, "a missing interaction.completed should throw as a cut stream")
        #expect(truncated.finishes == [StreamFinish(family: .geminiInteractions, ended: .eofWithoutMarker)], "\(truncated.finishes)")
        #expect(Self.resolved(truncated.finishes.last) == .incomplete)
    }
}
