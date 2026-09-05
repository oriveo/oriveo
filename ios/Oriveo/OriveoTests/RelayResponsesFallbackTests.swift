import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

@Suite("Relay Responses no automatic fallback", .serialized)
struct RelayResponsesFallbackTests {

    private func makeMessage(_ text: String) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            role: .user,
            text: text,
            providerKind: .relay,
            providerName: "Relay",
            modelName: "gpt-5.4",
            state: .delivered
        )
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedRelayProtocol.self]
        return URLSession(configuration: config)
    }

    private func drain(_ stream: AsyncThrowingStream<StreamEvent, Error>) async -> [StreamEvent] {
        var events: [StreamEvent] = []
        do {
            for try await ev in stream { events.append(ev) }
        } catch {
        }
        return events
    }


    @Test("Http4xx Image Tool Unsupported Triggers Retry Without Tools")
    func http4xxImageToolUnsupportedTriggersRetryWithoutTools() async {
        ScriptedRelayProtocol.reset()
        ScriptedRelayProtocol.script = [
            .json(status: 400, body: """
            {"error":{"code":"unknown_parameter","message":"Unknown parameter: tools[0].type (image_generation)","param":"tools[0].type"}}
            """),
            .sse(status: 200, body: "data: [DONE]\n\n"),
        ]

        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(transport: .openaiResponses, authMode: .bearer)
        let stream = service.sendMessageStream(
            apiKey: "yls-test", modelID: "gpt-5.4",
            messages: [makeMessage("hi")],
            baseURL: "https://code.example.com/codex",
            relayRequested: relay
        )
        _ = await drain(stream)

        let snap = ScriptedRelayProtocol.snapshot()
        #expect(snap.bodies.count == 1)

        let first = try? JSONSerialization.jsonObject(with: snap.bodies[0]) as? [String: Any]
        #expect((first?["tools"] as? [[String: Any]])?.isEmpty == false)
    }

    @Test("Http4xx Tool Not Supported Code Triggers Retry")
    func http4xxToolNotSupportedCodeTriggersRetry() async {
        ScriptedRelayProtocol.reset()
        ScriptedRelayProtocol.script = [
            .json(status: 400, body: """
            {"error":{"code":"tool_not_supported","message":"Tool not supported"}}
            """),
            .sse(status: 200, body: "data: [DONE]\n\n"),
        ]

        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(transport: .openaiResponses, authMode: .bearer)
        let stream = service.sendMessageStream(
            apiKey: "yls-test", modelID: "gpt-5.4",
            messages: [makeMessage("hi")],
            baseURL: "https://code.example.com/codex",
            relayRequested: relay
        )
        _ = await drain(stream)

        #expect(ScriptedRelayProtocol.snapshot().bodies.count == 1)
    }

    @Test("Http400 Image Endpoint Model Mismatch Triggers Retry")
    func http400ImageEndpointModelMismatchTriggersRetry() async {
        ScriptedRelayProtocol.reset()
        ScriptedRelayProtocol.script = [
            .json(status: 400, body: """
            {"error":{"message":"unsupported model: gpt-5.5 (only gpt-image-2 is supported on this endpoint)"}}
            """),
            .sse(status: 200, body: "data: [DONE]\n\n"),
        ]

        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(transport: .openaiResponses, authMode: .bearer)
        let stream = service.sendMessageStream(
            apiKey: "relay-test", modelID: "gpt-5.5",
            messages: [makeMessage("hi")],
            baseURL: "https://relay.example.com/v1",
            relayRequested: relay
        )
        _ = await drain(stream)

        let snap = ScriptedRelayProtocol.snapshot()
        #expect(snap.bodies.count == 1)
        let first = try? JSONSerialization.jsonObject(with: snap.bodies[0]) as? [String: Any]
        #expect(first?["tools"] != nil)
    }

    @Test("Http4xx Unrelated Error Does Not Trigger Retry")
    func http4xxUnrelatedErrorDoesNotTriggerRetry() async {
        ScriptedRelayProtocol.reset()
        ScriptedRelayProtocol.script = [
            .json(status: 404, body: """
            {"error":{"code":"model_not_found","message":"Model gpt-9 does not exist"}}
            """),
        ]

        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(transport: .openaiResponses, authMode: .bearer)
        let stream = service.sendMessageStream(
            apiKey: "yls-test", modelID: "gpt-9",
            messages: [makeMessage("hi")],
            baseURL: "https://code.example.com/codex",
            relayRequested: relay
        )
        _ = await drain(stream)

        #expect(ScriptedRelayProtocol.snapshot().bodies.count == 1)
    }

    @Test("Http4xx Vision Error Does Not Trigger Retry")
    func http4xxVisionErrorDoesNotTriggerRetry() async {
        ScriptedRelayProtocol.reset()
        ScriptedRelayProtocol.script = [
            .json(status: 400, body: """
            {"error":{"message":"Invalid image_url field for this model"}}
            """),
        ]

        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(transport: .openaiResponses, authMode: .bearer)
        let stream = service.sendMessageStream(
            apiKey: "yls-test", modelID: "gpt-5.4",
            messages: [makeMessage("hi")],
            baseURL: "https://code.example.com/codex",
            relayRequested: relay
        )
        _ = await drain(stream)

        #expect(ScriptedRelayProtocol.snapshot().bodies.count == 1)
    }

    @Test("Retry Attempt Still Fails Throws Terminal Error")
    func retryAttemptStillFailsThrowsTerminalError() async {
        ScriptedRelayProtocol.reset()
        ScriptedRelayProtocol.script = [
            .json(status: 400, body: """
            {"error":{"code":"unknown_parameter","message":"image_generation","param":"tools[0]"}}
            """),
            .json(status: 400, body: """
            {"error":{"code":"invalid_request","message":"still broken"}}
            """),
        ]

        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(transport: .openaiResponses, authMode: .bearer)
        let stream = service.sendMessageStream(
            apiKey: "yls-test", modelID: "gpt-5.4",
            messages: [makeMessage("hi")],
            baseURL: "https://code.example.com/codex",
            relayRequested: relay
        )
        _ = await drain(stream)

        #expect(ScriptedRelayProtocol.snapshot().bodies.count == 1)
    }


    @Test("Stream Image Tool Error Before Content Triggers Retry")
    func streamImageToolErrorBeforeContentTriggersRetry() async {
        ScriptedRelayProtocol.reset()
        let firstStream = """
        event: response.failed
        data: {"type":"response.failed","response":{"error":{"code":"unknown_parameter","message":"image_generation tool not supported","param":"tools[0]"}}}

        data: [DONE]

        """
        let secondStream = """
        event: response.output_text.delta
        data: {"delta":"hi"}

        data: [DONE]

        """
        ScriptedRelayProtocol.script = [
            .sse(status: 200, body: firstStream),
            .sse(status: 200, body: secondStream),
        ]

        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(transport: .openaiResponses, authMode: .bearer)
        let stream = service.sendMessageStream(
            apiKey: "yls-test", modelID: "gpt-5.4",
            messages: [makeMessage("hi")],
            baseURL: "https://code.example.com/codex",
            relayRequested: relay
        )
        let events = await drain(stream)

        let snap = ScriptedRelayProtocol.snapshot()
        #expect(snap.bodies.count == 1)
        #expect(!events.contains { if case .delta = $0 { return true }; return false })
    }

    @Test("Stream Image Tool Error After Content Locks Retry")
    func streamImageToolErrorAfterContentLocksRetry() async {
        ScriptedRelayProtocol.reset()
        let body = """
        event: response.output_text.delta
        data: {"delta":"partial"}

        event: response.failed
        data: {"type":"response.failed","response":{"error":{"code":"unknown_parameter","message":"image_generation","param":"tools[0]"}}}

        data: [DONE]

        """
        ScriptedRelayProtocol.script = [.sse(status: 200, body: body)]

        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(transport: .openaiResponses, authMode: .bearer)
        let stream = service.sendMessageStream(
            apiKey: "yls-test", modelID: "gpt-5.4",
            messages: [makeMessage("hi")],
            baseURL: "https://code.example.com/codex",
            relayRequested: relay
        )
        let events = await drain(stream)

        #expect(ScriptedRelayProtocol.snapshot().bodies.count == 1)
        let hasPartial = events.contains { event in
            if case .delta(let text) = event { return text == "partial" }
            return false
        }
        #expect(hasPartial)
    }


    private func doneResult(from events: [StreamEvent]) -> ProviderChatResult? {
        var result: ProviderChatResult?
        for event in events {
            if case let .done(value) = event { result = value }
        }
        return result
    }

    @Test("Stream Responses Usage Carries Cache Breakdown")
    func streamResponsesUsageCarriesCacheBreakdown() async throws {
        ScriptedRelayProtocol.reset()
        let body = """
        event: response.output_text.delta
        data: {"delta":"hi"}

        event: response.completed
        data: {"type":"response.completed","response":{"usage":{"input_tokens":1200,"input_tokens_details":{"cached_tokens":1000},"output_tokens":42,"output_tokens_details":{"reasoning_tokens":8}}}}

        data: [DONE]

        """
        ScriptedRelayProtocol.script = [.sse(status: 200, body: body)]

        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(transport: .openaiResponses, authMode: .bearer)
        let events = await drain(service.sendMessageStream(
            apiKey: "yls-test", modelID: "gpt-5.4",
            messages: [makeMessage("hi")],
            baseURL: "https://code.example.com/codex",
            relayRequested: relay
        ))

        let result = try #require(doneResult(from: events))
        let breakdown = try #require(result.usageBreakdown, "relay responses must produce usageBreakdown")
        #expect(breakdown.promptTokens == 200)
        #expect(breakdown.cachedInputTokens == 1000)
        #expect(breakdown.cacheReadObserved)
        #expect(breakdown.reasoningTokens == 8)
        #expect(result.promptTokens == 1200)
        #expect(result.completionTokens == 42)

        let metrics = ChatDeliveredUsageMetrics(result: result)
        #expect(metrics.inputTokens == 1200)
        #expect(metrics.cachedInputTokens == 1000)
    }

    @Test("Stream Responses Usage Keeps Cache Unobserved")
    func streamResponsesUsageKeepsCacheUnobserved() async throws {
        ScriptedRelayProtocol.reset()
        let body = """
        event: response.output_text.delta
        data: {"delta":"hi"}

        event: response.completed
        data: {"type":"response.completed","response":{"usage":{"input_tokens":30,"output_tokens":7}}}

        data: [DONE]

        """
        ScriptedRelayProtocol.script = [.sse(status: 200, body: body)]

        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(transport: .openaiResponses, authMode: .bearer)
        let events = await drain(service.sendMessageStream(
            apiKey: "yls-test", modelID: "gpt-5.4",
            messages: [makeMessage("hi")],
            baseURL: "https://code.example.com/codex",
            relayRequested: relay
        ))

        let result = try #require(doneResult(from: events))
        let breakdown = try #require(result.usageBreakdown)
        #expect(breakdown.promptTokens == 30)
        #expect(breakdown.cacheReadObserved == false)
        let metrics = ChatDeliveredUsageMetrics(result: result)
        #expect(metrics.cachedInputTokens == nil)
        #expect(metrics.cacheCreationInputTokens == nil)
    }

    @Test("Non Streaming Responses Usage Carries Cache Breakdown")
    func nonStreamingResponsesUsageCarriesCacheBreakdown() async throws {
        ScriptedRelayProtocol.reset()
        ScriptedRelayProtocol.script = [
            .json(status: 200, body: """
            {"id":"resp_1","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi"}]}],\
            "usage":{"input_tokens":900,"input_tokens_details":{"cached_tokens":640},"output_tokens":12}}
            """)
        ]

        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(transport: .openaiResponses, authMode: .bearer)
        let result = try await service.sendMessage(
            apiKey: "yls-test", modelID: "gpt-5.4",
            messages: [makeMessage("hi")],
            baseURL: "https://code.example.com/codex",
            relayRequested: relay
        )

        let breakdown = try #require(result.usageBreakdown, "Non-streaming relay responses must also produce usageBreakdown")
        #expect(breakdown.promptTokens == 260)
        #expect(breakdown.cachedInputTokens == 640)
        #expect(breakdown.cacheReadObserved)
        #expect(result.promptTokens == 900)
        #expect(result.completionTokens == 12)
    }
}


@Suite("Relay Error Classifier Tests")
struct RelayErrorClassifierTests {

    @Test("Matches Param Plus Message")
    func matchesParamPlusMessage() {
        let payload = RelayUpstreamErrorPayload(
            code: "unknown_parameter",
            message: "Unknown parameter: image_generation",
            param: "tools[0].type"
        )
        #expect(RelayErrorClassifier.isImageGenerationToolUnsupportedError(payload: payload, statusCode: 400))
    }

    @Test("Matches Plain Param")
    func matchesPlainParam() {
        let payload = RelayUpstreamErrorPayload(
            code: "unknown_parameter",
            message: "Tools rejected",
            param: "tools"
        )
        #expect(RelayErrorClassifier.isImageGenerationToolUnsupportedError(payload: payload, statusCode: 400))
    }

    @Test("Matches Tool Not Supported Code")
    func matchesToolNotSupportedCode() {
        let payload = RelayUpstreamErrorPayload(
            code: "tool_not_supported",
            message: "no tools",
            param: nil
        )
        #expect(RelayErrorClassifier.isImageGenerationToolUnsupportedError(payload: payload, statusCode: 400))
    }

    @Test("Matches Fallback Message")
    func matchesFallbackMessage() {
        let payload = RelayUpstreamErrorPayload(
            code: nil,
            message: "image_generation is not enabled",
            param: nil
        )
        #expect(RelayErrorClassifier.isImageGenerationToolUnsupportedError(payload: payload, statusCode: 400))
    }

    @Test("Matches Image Endpoint Model Mismatch")
    func matchesImageEndpointModelMismatch() {
        let payload = RelayUpstreamErrorPayload(
            code: nil,
            message: "unsupported model: gpt-5.5 (only gpt-image-2 is supported on this endpoint)",
            param: nil
        )
        #expect(RelayErrorClassifier.isImageGenerationToolUnsupportedError(payload: payload, statusCode: 400))
    }

    @Test("Does Not Match Image Url Vision Error")
    func doesNotMatchImageUrlVisionError() {
        let payload = RelayUpstreamErrorPayload(
            code: nil,
            message: "Invalid image_url schema",
            param: nil
        )
        #expect(!RelayErrorClassifier.isImageGenerationToolUnsupportedError(payload: payload, statusCode: 400))
    }

    @Test("Does Not Match5xx")
    func doesNotMatch5xx() {
        let payload = RelayUpstreamErrorPayload(
            code: nil, message: "image_generation", param: nil
        )
        #expect(!RelayErrorClassifier.isImageGenerationToolUnsupportedError(payload: payload, statusCode: 502))
    }

    @Test("Does Not Match Nil")
    func doesNotMatchNil() {
        #expect(!RelayErrorClassifier.isImageGenerationToolUnsupportedError(payload: nil, statusCode: 400))
    }

    @Test("Does Not Match Unrelated Code")
    func doesNotMatchUnrelatedCode() {
        let payload = RelayUpstreamErrorPayload(
            code: "rate_limited",
            message: "too many requests",
            param: "tools"
        )
        #expect(!RelayErrorClassifier.isImageGenerationToolUnsupportedError(payload: payload, statusCode: 400))
    }

    @Test("X High Matches Xhigh Word")
    func xHighMatchesXhighWord() {
        let payload = RelayUpstreamErrorPayload(
            code: nil,
            message: "Invalid value: xhigh",
            param: nil
        )
        #expect(RelayErrorClassifier.isReasoningEffortXHighError(payload: payload, statusCode: 400))
    }

    @Test("X High Matches Reasoning Effort")
    func xHighMatchesReasoningEffort() {
        let payload = RelayUpstreamErrorPayload(
            code: nil,
            message: "reasoning effort is not supported",
            param: nil
        )
        #expect(RelayErrorClassifier.isReasoningEffortXHighError(payload: payload, statusCode: 400))
    }

    @Test("Parses Standard Error Structure")
    func parsesStandardErrorStructure() {
        let body = #"{"error":{"code":"x","message":"y","param":"z"}}"#.data(using: .utf8)!
        let payload = RelayErrorClassifier.parseUpstreamErrorPayload(body)
        #expect(payload?.code == "x")
        #expect(payload?.message == "y")
        #expect(payload?.param == "z")
    }

    @Test("Parses Empty Or Invalid Body")
    func parsesEmptyOrInvalidBody() {
        #expect(RelayErrorClassifier.parseUpstreamErrorPayload(Data()) == nil)
        #expect(RelayErrorClassifier.parseUpstreamErrorPayload("not json".data(using: .utf8)!) == nil)
    }
}

// MARK: - Scripted URLProtocol

private final class ScriptedRelayProtocol: URLProtocol, @unchecked Sendable {
    enum ScriptedResponse {
        case json(status: Int, body: String)
        case sse(status: Int, body: String)
    }

    struct Snapshot {
        let requests: [URLRequest]
        let bodies: [Data]
    }

    nonisolated(unsafe) static var script: [ScriptedResponse] = []
    nonisolated(unsafe) private static var _requests: [URLRequest] = []
    nonisolated(unsafe) private static var _bodies: [Data] = []
    nonisolated(unsafe) private static var _index: Int = 0
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        script = []
        _requests = []
        _bodies = []
        _index = 0
    }

    static func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(requests: _requests, bodies: _bodies)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let captured = request
        var bodyData: Data?
        if let stream = captured.httpBodyStream {
            stream.open()
            var acc = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: 4096)
                if n <= 0 { break }
                acc.append(buf, count: n)
            }
            stream.close()
            bodyData = acc
        } else if let body = captured.httpBody {
            bodyData = body
        }

        let response: ScriptedResponse = {
            Self.lock.lock(); defer { Self.lock.unlock() }
            Self._requests.append(captured)
            if let b = bodyData { Self._bodies.append(b) }
            let idx = Self._index
            Self._index += 1
            if idx < Self.script.count { return Self.script[idx] }
            return .sse(status: 200, body: "data: [DONE]\n\n")
        }()

        switch response {
        case .json(let status, let body):
            let httpResp = HTTPURLResponse(
                url: captured.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: httpResp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body.data(using: .utf8) ?? Data())
            client?.urlProtocolDidFinishLoading(self)

        case .sse(let status, let body):
            let httpResp = HTTPURLResponse(
                url: captured.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client?.urlProtocol(self, didReceive: httpResp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body.data(using: .utf8) ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
